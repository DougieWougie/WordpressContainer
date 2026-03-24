# WordPress Docker Setup

Containerised WordPress with MariaDB, behind Nginx Proxy Manager.

## Prerequisites

- Docker and Docker Compose
- Nginx Proxy Manager running on the same host

## Install

```bash
# 1. Clone and enter the project
git clone <repo-url> && cd WordpressNPM

# 2. Create environment file
cp .env.example .env

# 3. Generate strong passwords and update .env
sed -i "s/change_me_root_password/$(openssl rand -base64 24)/" .env
sed -i "s/change_me_db_password/$(openssl rand -base64 24)/" .env

# 4. Lock down .env permissions
chmod 600 .env

# 5. Start the stack
docker compose up -d

# 6. Create backup directory
sudo mkdir -p /opt/backups/wordpress

# 7. Add monthly backup cron (runs 1st of each month at 3am)
(crontab -l 2>/dev/null; echo "0 3 1 * * $(pwd)/backup/backup.sh >> /opt/backups/wordpress/backup.log 2>&1") | crontab -
```

## Configure Nginx Proxy Manager

1. Add a new Proxy Host
2. Set the forward hostname to `127.0.0.1` and port to `8080`
3. Enable SSL via Let's Encrypt under the SSL tab
4. Enable "Force SSL" and "HTTP/2 Support"

## Manage

```bash
docker compose up -d       # Start
docker compose down        # Stop
docker compose logs -f     # View logs
docker compose pull        # Update images
```

## Backup and Restore

```bash
# Manual backup
./backup/backup.sh

# List available backups
./backup/restore.sh

# Restore from a specific backup
./backup/restore.sh 20260301_030000
```

Backups are stored in `/opt/backups/wordpress/` with automatic rotation (keeps last 3).
