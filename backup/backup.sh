#!/usr/bin/env bash
set -euo pipefail

# Cron setup (add to host crontab):
# 0 3 1 * * /path/to/WordpressNPM/backup/backup.sh >> /opt/backups/wordpress/backup.log 2>&1

# Configuration
COMPOSE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP_DIR="${BACKUP_DIR:-/opt/backups/wordpress}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
KEEP=3

if [ ! -f "$COMPOSE_DIR/docker-compose.yml" ]; then
  echo "ERROR: docker-compose.yml not found at $COMPOSE_DIR"
  exit 1
fi

# Load environment variables
set -a
# shellcheck source=/dev/null
source "$COMPOSE_DIR/.env"
set +a

# Resolve the actual Docker volume name for wp_data
WP_VOLUME="$(docker volume ls --filter "name=wp_data" --format '{{.Name}}' | head -1)"
if [ -z "$WP_VOLUME" ]; then
  echo "ERROR: wp_data volume not found. Is the stack running?"
  exit 1
fi

mkdir -p "$BACKUP_DIR" || { echo "ERROR: Cannot create $BACKUP_DIR"; exit 1; }
if [ ! -w "$BACKUP_DIR" ]; then
  echo "ERROR: $BACKUP_DIR is not writable by $(whoami)"
  exit 1
fi

echo "=== Backup started at $(date) ==="

# Database dump (root password read from the Docker secret inside the container;
# it never touches the host environment or process tree)
echo "Dumping database..."
docker compose -f "$COMPOSE_DIR/docker-compose.yml" exec -T mariadb \
  sh -c 'MYSQL_PWD="$(cat /run/secrets/db_root_password)" mariadb-dump -u root --all-databases --single-transaction' \
  | gzip > "$BACKUP_DIR/${TIMESTAMP}_db.sql.gz"
echo "Database dump: ${TIMESTAMP}_db.sql.gz"

# WordPress files
echo "Backing up WordPress files..."
docker run --rm \
  -v "${WP_VOLUME}":/data:ro \
  -v "$BACKUP_DIR":/backup \
  alpine:latest \
  tar czf "/backup/${TIMESTAMP}_files.tar.gz" -C /data .
echo "Files backup: ${TIMESTAMP}_files.tar.gz"

# Validate backup integrity
echo "Validating backups..."
gzip -t "$BACKUP_DIR/${TIMESTAMP}_db.sql.gz" || { echo "ERROR: DB backup corrupt"; exit 1; }
docker run --rm \
  -v "$BACKUP_DIR":/backup:ro \
  alpine:latest \
  tar tzf "/backup/${TIMESTAMP}_files.tar.gz" > /dev/null || { echo "ERROR: Files backup corrupt"; exit 1; }
echo "Backups validated."

# Rotation — keep only the most recent $KEEP backup sets
echo "Rotating old backups (keeping $KEEP most recent)..."
ls -t "$BACKUP_DIR"/*_db.sql.gz 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r f; do
  base="${f%_db.sql.gz}"
  rm -f "${base}_db.sql.gz" "${base}_files.tar.gz"
  echo "Deleted: $(basename "$base")"
done

# Offsite copy (optional — set RCLONE_REMOTE in .env, e.g. b2:my-bucket/wordpress).
# Uses copy, not sync, so offsite retention is never reduced by local rotation.
if [ -n "${RCLONE_REMOTE:-}" ]; then
  echo "Copying backup offsite to ${RCLONE_REMOTE}..."
  rclone copy "$BACKUP_DIR/${TIMESTAMP}_db.sql.gz" "$RCLONE_REMOTE" \
    && rclone copy "$BACKUP_DIR/${TIMESTAMP}_files.tar.gz" "$RCLONE_REMOTE" \
    && echo "Offsite copy complete." \
    || { echo "ERROR: Offsite copy failed"; exit 1; }
fi

echo "=== Backup completed at $(date) ==="
