# Containerised WordPress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a production-ready containerised WordPress deployment with MariaDB, optimised PHP/DB config, and automated monthly backups.

**Architecture:** Two-container Docker Compose stack — WordPress (Apache + PHP 8.3 on Alpine) and MariaDB (Alpine). NPM handles SSL/proxy externally. Host cron triggers monthly backup/rotation.

**Tech Stack:** Docker Compose, WordPress 6.x, PHP 8.3, MariaDB LTS, Alpine Linux, Bash

**Spec:** `docs/superpowers/specs/2026-03-24-wordpress-container-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `.gitignore` | Create | Exclude `.env` and backup output |
| `.env.example` | Create | Template with placeholder credentials |
| `config/php.ini` | Create | PHP performance tuning (OPcache, upload limits, memory) |
| `config/my.cnf` | Create | MariaDB tuning (InnoDB buffer, connections) |
| `docker-compose.yml` | Create | Orchestrates wordpress + mariadb services, volumes, network |
| `backup/backup.sh` | Create | Monthly DB dump + wp-content volume backup with rotation |
| `backup/restore.sh` | Create | Restore DB and files from a timestamped backup |

---

### Task 1: Project scaffolding and .gitignore

**Files:**
- Create: `.gitignore`

- [ ] **Step 1: Initialise git repo**

```bash
cd /home/dougiewougie/Projects/applications/WordpressNPM
git init
```

- [ ] **Step 2: Create `.gitignore`**

```gitignore
.env
/opt/backups/
```

- [ ] **Step 3: Commit**

```bash
git add .gitignore
git commit -m "chore: initialise repo with .gitignore"
```

---

### Task 2: Environment template

**Files:**
- Create: `.env.example`

- [ ] **Step 1: Create `.env.example`**

```env
# MariaDB
MYSQL_ROOT_PASSWORD=change_me_root_password
MYSQL_DATABASE=wordpress
MYSQL_USER=wordpress
MYSQL_PASSWORD=change_me_db_password

# WordPress
WORDPRESS_DB_HOST=mariadb
```

Note: The `docker-compose.yml` maps `MYSQL_USER`, `MYSQL_PASSWORD`, and `MYSQL_DATABASE` directly to the WordPress service environment. No need to duplicate them as separate `WORDPRESS_DB_*` variables in `.env`.

- [ ] **Step 2: Commit**

```bash
git add .env.example
git commit -m "chore: add .env.example with placeholder credentials"
```

---

### Task 3: PHP tuning config

**Files:**
- Create: `config/php.ini`

- [ ] **Step 1: Create `config/php.ini`**

```ini
; Upload limits
upload_max_filesize = 64M
post_max_size = 64M

; Memory and execution
memory_limit = 256M
max_execution_time = 300

; OPcache
opcache.enable = 1
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 8
opcache.max_accelerated_files = 10000
opcache.revalidate_freq = 60
```

- [ ] **Step 2: Commit**

```bash
git add config/php.ini
git commit -m "feat: add PHP tuning config with OPcache and upload limits"
```

---

### Task 4: MariaDB tuning config

**Files:**
- Create: `config/my.cnf`

- [ ] **Step 1: Create `config/my.cnf`**

```ini
[mysqld]
innodb_buffer_pool_size = 256M
innodb_log_file_size = 64M
max_connections = 100
```

- [ ] **Step 2: Commit**

```bash
git add config/my.cnf
git commit -m "feat: add MariaDB tuning config"
```

---

### Task 5: Docker Compose file

**Files:**
- Create: `docker-compose.yml`

- [ ] **Step 1: Create `docker-compose.yml`**

```yaml
services:
  mariadb:
    image: mariadb:lts-alpine
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    volumes:
      - db_data:/var/lib/mysql
      - ./config/my.cnf:/etc/mysql/conf.d/custom.cnf:ro
    healthcheck:
      test: ["CMD", "mariadb-admin", "ping", "-h", "localhost", "-u", "root", "-p${MYSQL_ROOT_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 5

  wordpress:
    image: wordpress:php8.3-apache-alpine
    restart: unless-stopped
    depends_on:
      mariadb:
        condition: service_healthy
    ports:
      - "8080:80"
    environment:
      WORDPRESS_DB_HOST: ${WORDPRESS_DB_HOST}
      WORDPRESS_DB_USER: ${MYSQL_USER}
      WORDPRESS_DB_PASSWORD: ${MYSQL_PASSWORD}
      WORDPRESS_DB_NAME: ${MYSQL_DATABASE}
      WORDPRESS_CONFIG_EXTRA: |
        $$_SERVER['HTTPS'] = 'on';
        define('FORCE_SSL_ADMIN', true);
    volumes:
      - wp_data:/var/www/html
      - ./config/php.ini:/usr/local/etc/php/conf.d/custom.ini:ro

volumes:
  db_data:
  wp_data:
```

Note: `$$_SERVER` uses double `$` to escape the dollar sign in Compose YAML.

- [ ] **Step 2: Validate the compose file syntax**

```bash
docker compose config --quiet
```

Expected: no output (valid syntax).

- [ ] **Step 3: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add Docker Compose with WordPress and MariaDB services"
```

---

### Task 6: Backup script

**Files:**
- Create: `backup/backup.sh`

- [ ] **Step 1: Create `backup/backup.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Cron setup (add to host crontab):
# 0 3 1 * * /path/to/WordpressNPM/backup/backup.sh >> /opt/backups/wordpress/backup.log 2>&1

# Configuration
COMPOSE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP_DIR="/opt/backups/wordpress"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
KEEP=3

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

# Database dump
echo "Dumping database..."
docker compose -f "$COMPOSE_DIR/docker-compose.yml" exec -T mariadb \
  mariadb-dump -u root -p"${MYSQL_ROOT_PASSWORD}" --all-databases \
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

# Rotation — keep only the most recent $KEEP backup sets
echo "Rotating old backups (keeping $KEEP most recent)..."
ls -t "$BACKUP_DIR"/*_db.sql.gz 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r f; do
  base="${f%_db.sql.gz}"
  rm -f "${base}_db.sql.gz" "${base}_files.tar.gz"
  echo "Deleted: $(basename "$base")"
done

echo "=== Backup completed at $(date) ==="
```

- [ ] **Step 2: Make executable**

```bash
chmod +x backup/backup.sh
```

- [ ] **Step 3: Verify script syntax**

```bash
bash -n backup/backup.sh
```

Expected: no output (valid syntax).

- [ ] **Step 4: Commit**

```bash
git add backup/backup.sh
git commit -m "feat: add monthly backup script with rotation"
```

---

### Task 7: Restore script

**Files:**
- Create: `backup/restore.sh`

- [ ] **Step 1: Create `backup/restore.sh`**

```bash
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
```

- [ ] **Step 2: Make executable**

```bash
chmod +x backup/restore.sh
```

- [ ] **Step 3: Verify script syntax**

```bash
bash -n backup/restore.sh
```

Expected: no output (valid syntax).

- [ ] **Step 4: Commit**

```bash
git add backup/restore.sh
git commit -m "feat: add restore script for backup recovery"
```

---

### Task 8: Smoke test the full stack

- [ ] **Step 1: Create a `.env` from the template**

```bash
cp .env.example .env
```

Edit `.env` and replace placeholder passwords with real values (e.g., use `openssl rand -base64 24`).

- [ ] **Step 2: Start the stack**

```bash
docker compose up -d
```

Expected: Both containers start. MariaDB passes healthcheck. WordPress becomes available.

- [ ] **Step 3: Verify WordPress is responding**

```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:8080
```

Expected: `302` (redirects to install page) or `200`.

- [ ] **Step 4: Verify MariaDB healthcheck**

```bash
docker compose ps
```

Expected: mariadb shows `healthy`, wordpress shows `running`.

- [ ] **Step 5: Verify wp-config.php has correct HTTPS settings**

```bash
docker compose exec wordpress grep 'HTTPS' /var/www/html/wp-config.php
```

Expected: output contains `$_SERVER['HTTPS'] = 'on';`

- [ ] **Step 6: Tear down**

```bash
docker compose down
```

- [ ] **Step 7: Commit any fixes if needed**

