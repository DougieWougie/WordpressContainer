# WordPress Docker Setup

Containerised WordPress with MariaDB and Redis object cache, behind Nginx Proxy Manager.

## Prerequisites

- Docker and Docker Compose
- Nginx Proxy Manager running on the same host
- `rclone` configured on the host (optional, for offsite backups)

## Install

```bash
# 1. Clone and enter the project
git clone <repo-url> && cd WordpressNPM

# 2. Create the proxy network (if it doesn't already exist)
docker network create proxy

# 3. Create environment file
cp .env.example .env

# 4. Create database password secrets
mkdir -p secrets
openssl rand -base64 24 > secrets/db_root_password.txt
openssl rand -base64 24 > secrets/db_password.txt
chmod 600 secrets/*.txt

# 5. Set a Redis password in .env
sed -i "s/change_me_redis_password/$(openssl rand -base64 24 | tr -d '/+=')/" .env

# 6. Lock down .env permissions
chmod 600 .env

# 7. Start the stack
docker compose up -d

# 8. Create backup directory
sudo mkdir -p /opt/backups/wordpress

# 9. Add monthly backup cron (3am) and image update cron (4am — always
#    runs after a fresh backup)
(crontab -l 2>/dev/null; \
 echo "0 3 1 * * $(pwd)/backup/backup.sh >> /opt/backups/wordpress/backup.log 2>&1"; \
 echo "0 4 1 * * cd $(pwd) && docker compose pull && docker compose up -d") | crontab -
```

After the WordPress install wizard, install and activate the **Redis Object
Cache** plugin and click *Enable Object Cache* (connection settings are
pre-configured via `wp-config`). A page-caching plugin (e.g. WP Super Cache)
is also recommended — see `docs/npm-hardening.md`.

### Offsite backups (recommended)

Configure an rclone remote on the host (`rclone config`), then set it in `.env`:

```bash
RCLONE_REMOTE=b2:my-bucket/wordpress
```

Each backup run then pushes the new backup set offsite. Local rotation keeps
3 sets; offsite copies accumulate — prune them with your provider's lifecycle
rules.

## Configure Nginx Proxy Manager

> NPM must be connected to a Docker network named `proxy`. If it doesn't exist yet, create it: `docker network create proxy` and add the network to your NPM compose file.

1. Add a new Proxy Host
2. Set the forward hostname to `wordpress` and port to `80`
3. Enable SSL via Let's Encrypt under the SSL tab
4. Enable "Force SSL", "HTTP/2 Support", "Cache Assets", and "Block Common Exploits"
5. Apply the hardening and caching config from `docs/npm-hardening.md`
   (XML-RPC blocking, login rate-limiting, static asset caching, fail2ban)

## Manage

```bash
docker compose up -d       # Start
docker compose down        # Stop
docker compose logs -f     # View logs
docker compose pull        # Update images
```

Note: OPcache runs with `validate_timestamps = 0`, so after WordPress
core/plugin/theme updates run `docker compose restart wordpress` to pick up
the new code.

## Backup and Restore

```bash
# Manual backup
./backup/backup.sh

# List available backups
./backup/restore.sh

# Restore from a specific backup
./backup/restore.sh 20260301_030000
```

Backups are stored in `/opt/backups/wordpress/` with automatic rotation (keeps last 3), and optionally pushed offsite via rclone.

## Upgrading an existing deployment

If you previously ran this stack with passwords in `.env`:

1. Copy the **existing** passwords into the secret files (MariaDB will not
   pick up new ones from an initialised volume):
   ```bash
   mkdir -p secrets
   printf '%s' "$OLD_ROOT_PASSWORD" > secrets/db_root_password.txt
   printf '%s' "$OLD_DB_PASSWORD" > secrets/db_password.txt
   chmod 600 secrets/*.txt
   ```
2. Remove `MYSQL_ROOT_PASSWORD`/`MYSQL_PASSWORD` from `.env` and add `REDIS_PASSWORD`.
3. The healthcheck now uses MariaDB's built-in `healthcheck.sh`, which needs a
   healthcheck user that only exists on volumes initialised by recent images.
   If the container never turns healthy, create it once:
   ```bash
   docker compose exec mariadb sh -c \
     'MYSQL_PWD="$(cat /run/secrets/db_root_password)" mariadb -u root -e \
     "CREATE USER IF NOT EXISTS healthcheck@localhost IDENTIFIED VIA unix_socket; GRANT USAGE ON *.* TO healthcheck@localhost;"'
   docker compose exec mariadb healthcheck.sh --su-mysql --connect --innodb_initialized
   ```
4. The `127.0.0.1:8080` port mapping has been removed — all access is via NPM
   over the `proxy` network.

## Troubleshooting

### "Error establishing a database connection"

If you changed database credentials in `secrets/` after the database volume was already created, MariaDB won't reinitialise with the new values. Reset the volume:

```bash
docker compose down
docker volume ls                        # find the db_data volume name
docker volume rm <project>_db_data      # remove it
docker compose up -d
```

### 502 Bad Gateway

Ensure the `proxy` network exists and that your NPM compose file also uses it. WordPress must be reachable from NPM over this shared network.

### Redis "connection refused" in Redis Object Cache plugin

Check `REDIS_PASSWORD` in `.env` matches what the redis container was started
with (`docker compose up -d` after changing it), and that the plugin shows
host `redis`, port `6379`.
