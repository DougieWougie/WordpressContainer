#!/usr/bin/env bash
set -euo pipefail

COMPOSE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP_DIR="/opt/backups/wordpress"

# Load environment variables
set -a
# shellcheck source=/dev/null
source "$COMPOSE_DIR/.env"
set +a

if [ -z "${1:-}" ]; then
  echo "Usage: $0 <timestamp>"
  echo "Example: $0 20260301_030000"
  echo ""
  echo "Available backups:"
  ls -1 "$BACKUP_DIR"/*_db.sql.gz 2>/dev/null | sed 's|.*/||; s|_db.sql.gz||' | sort -r
  exit 1
fi

TIMESTAMP="$1"
DB_BACKUP="$BACKUP_DIR/${TIMESTAMP}_db.sql.gz"
FILES_BACKUP="$BACKUP_DIR/${TIMESTAMP}_files.tar.gz"

for f in "$DB_BACKUP" "$FILES_BACKUP"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: Not found: $f"
    exit 1
  fi
done

# Resolve the actual Docker volume name for wp_data
WP_VOLUME="$(docker volume ls --filter "name=wp_data" --format '{{.Name}}' | head -1)"
if [ -z "$WP_VOLUME" ]; then
  echo "ERROR: wp_data volume not found. Is the stack running?"
  exit 1
fi

echo "=== Restore started at $(date) ==="
echo "Restoring from timestamp: $TIMESTAMP"

# Ensure MariaDB is running and healthy
echo "Ensuring MariaDB is running..."
docker compose -f "$COMPOSE_DIR/docker-compose.yml" up -d mariadb
echo "Waiting for MariaDB to be healthy..."
docker compose -f "$COMPOSE_DIR/docker-compose.yml" exec -T mariadb \
  mariadb-admin ping -u root -p"${MYSQL_ROOT_PASSWORD}" --wait=30 > /dev/null 2>&1

# Restore database
echo "Restoring database..."
gunzip -c "$DB_BACKUP" | docker compose -f "$COMPOSE_DIR/docker-compose.yml" exec -T mariadb \
  mariadb -u root -p"${MYSQL_ROOT_PASSWORD}"
echo "Database restored."

# Restore WordPress files
echo "Stopping WordPress container..."
docker compose -f "$COMPOSE_DIR/docker-compose.yml" stop wordpress

echo "Restoring WordPress files..."
docker run --rm \
  -v "${WP_VOLUME}":/data \
  -v "$BACKUP_DIR":/backup:ro \
  alpine:latest \
  sh -c "rm -rf /data/* && tar xzf /backup/${TIMESTAMP}_files.tar.gz -C /data"

echo "Starting WordPress container..."
docker compose -f "$COMPOSE_DIR/docker-compose.yml" start wordpress

echo "=== Restore completed at $(date) ==="
