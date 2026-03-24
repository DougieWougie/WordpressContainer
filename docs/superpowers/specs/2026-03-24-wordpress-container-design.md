# Containerised WordPress for VPS

**Date:** 2026-03-24
**Status:** Approved

## Overview

A containerised WordPress deployment for a VPS, using Docker Compose with two containers: WordPress (Apache + mod_php) and MariaDB. The VPS runs Nginx Proxy Manager for SSL termination and reverse proxying, so no proxy or SSL config is needed in the stack. Monthly automated backups with 3-backup rotation are stored locally on the host.

## Architecture

```
[Internet] → [Nginx Proxy Manager] → [wordpress:8080]
                                           ↕
                                      [mariadb:3306 (internal only)]
```

- **wordpress** — `wordpress:6-php8.3-apache`, exposed on host port 8080 (Alpine variant not available for Apache)
- **mariadb** — `mariadb:lts`, internal network only (no host port; Alpine variant not available)
- **Network** — single internal Docker bridge network (default Compose network). NPM connects to WordPress via the host-mapped port 8080, not via a shared Docker network.
- **Compose spec** — uses modern Compose Specification (no `version` key)
- **Persistence** — two named Docker volumes: `wp_data` and `db_data`

## WordPress Container

- **Image:** `wordpress:6-php8.3-apache`
- **Port:** 8080 on host, 80 in container
- **Restart policy:** `unless-stopped`
- **Environment:** DB connection variables sourced from `.env`
- **Volumes:**
  - `wp_data:/var/www/html` — WordPress files
  - `./config/php.ini:/usr/local/etc/php/conf.d/custom.ini:ro` — PHP overrides
- **Depends on:** mariadb (healthy)

### PHP Tuning (`config/php.ini`)

| Setting | Value |
|---------|-------|
| `upload_max_filesize` | 64M |
| `post_max_size` | 64M |
| `memory_limit` | 256M |
| `max_execution_time` | 300 |
| `opcache.enable` | 1 |
| `opcache.memory_consumption` | 128 |
| `opcache.interned_strings_buffer` | 8 |
| `opcache.max_accelerated_files` | 10000 |
| `opcache.revalidate_freq` | 60 |

## MariaDB Container

- **Image:** `mariadb:lts`
- **Port:** None exposed to host (3306 internal only)
- **Restart policy:** `unless-stopped`
- **Environment:** Database name, user, root password, user password from `.env`
- **Volumes:**
  - `db_data:/var/lib/mysql` — database files
  - `./config/my.cnf:/etc/mysql/conf.d/custom.cnf:ro` — MariaDB tuning
- **Healthcheck:** `mariadb-admin ping` every 10s, 5s timeout, 5 retries

### MariaDB Tuning (`config/my.cnf`)

| Setting | Value | Notes |
|---------|-------|-------|
| `innodb_buffer_pool_size` | 256M | Adjust to VPS RAM |
| `innodb_log_file_size` | 64M | |
| `max_connections` | 100 | |

## Environment Variables (`.env`)

```
MYSQL_ROOT_PASSWORD=<strong-random>
MYSQL_DATABASE=wordpress
MYSQL_USER=wordpress
MYSQL_PASSWORD=<strong-random>
WORDPRESS_DB_HOST=mariadb
WORDPRESS_DB_USER=${MYSQL_USER}
WORDPRESS_DB_PASSWORD=${MYSQL_PASSWORD}
WORDPRESS_DB_NAME=${MYSQL_DATABASE}
```

`WORDPRESS_DB_PASSWORD` references `MYSQL_PASSWORD` directly in `docker-compose.yml` to prevent mismatches. A `.env.example` is committed with placeholder values. The actual `.env` is gitignored.

### Reverse Proxy Headers

WordPress behind NPM requires these settings, injected via `WORDPRESS_CONFIG_EXTRA`:

```php
$_SERVER['HTTPS'] = 'on';
define('FORCE_SSL_ADMIN', true);
```

This prevents mixed-content URLs and redirect loops when NPM terminates SSL.

## Backup System

### Backup Script (`backup/backup.sh`)

- Uses `docker compose exec mariadb mariadb-dump` (Compose service name, not container name)
- Compresses the dump to `<timestamp>_db.sql.gz`
- Exports `wp_data` volume contents to `<timestamp>_files.tar.gz`
- Stores both in `/opt/backups/wordpress/`
- Deletes all but the 3 most recent backup sets
- Logs to `/opt/backups/wordpress/backup.log`

### Restore Script (`backup/restore.sh`)

- Accepts a backup timestamp as argument
- Restores the database: pipes `.sql.gz` through `gunzip` into `docker compose exec -T mariadb mariadb`
- Restores WordPress files: stops the wordpress container, runs a temporary Alpine container mounting `wp_data`, extracts the `.tar.gz` into it, then restarts wordpress

### Cron Schedule

```
0 3 1 * * /path/to/backup.sh >> /opt/backups/wordpress/backup.log 2>&1
```

Runs at 03:00 on the 1st of each month.

## Project File Structure

```
WordpressNPM/
├── docker-compose.yml
├── .env.example
├── .gitignore
├── config/
│   ├── php.ini
│   └── my.cnf
├── backup/
│   ├── backup.sh
│   └── restore.sh
└── docs/
    └── superpowers/
        └── specs/
            └── 2026-03-24-wordpress-container-design.md
```

## Decisions

1. **No nginx sidecar** — NPM handles reverse proxying; Apache in the WordPress image handles static files and PHP.
2. **Named volumes over bind mounts** — simpler, Docker-managed, portable.
3. **Host cron over in-container cron** — avoids adding cron daemons to Alpine containers, simpler to manage.
4. **`.env` file for secrets** — keeps sensitive values out of `docker-compose.yml` and version control.

## .gitignore

```
.env
/opt/backups/
```
