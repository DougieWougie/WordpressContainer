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

mkdir -p "$BACKUP_DIR"

echo "=== Backup started at $(date) ==="

# Database dump (password passed via env inside container to avoid process tree exposure)
echo "Dumping database..."
docker compose -f "$COMPOSE_DIR/docker-compose.yml" exec -T \
  -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mariadb \
  mariadb-dump -u root --all-databases \
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

echo "=== Backup completed at $(date) ==="
