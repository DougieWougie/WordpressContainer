# Nginx Proxy Manager Hardening & Caching

These settings live in NPM, not this repo. Apply them to the WordPress proxy host.

## 1. Rate-limit zone (one-off, http context)

NPM's Advanced tab only accepts server/location-level directives, so the
`limit_req_zone` must go in NPM's custom include. On the NPM host/container,
create `/data/nginx/custom/http_top.conf`:

```nginx
limit_req_zone $binary_remote_addr zone=wplogin:10m rate=10r/m;
```

Restart NPM to load it.

## 2. Proxy host — Advanced tab

Paste into the proxy host's **Custom Nginx Configuration**:

```nginx
# Block XML-RPC entirely (brute-force and pingback abuse vector)
location = /xmlrpc.php {
    deny all;
}

# Rate-limit login attempts (10/min per IP, small burst)
location = /wp-login.php {
    limit_req zone=wplogin burst=5 nodelay;
    proxy_pass http://wordpress:80;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}

# Long-lived caching for static assets
location ~* \.(css|js|jpg|jpeg|png|gif|webp|avif|svg|ico|woff2?)$ {
    expires 30d;
    add_header Cache-Control "public, immutable";
    proxy_pass http://wordpress:80;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

Also enable **Cache Assets**, **Block Common Exploits**, **Force SSL**, and
**HTTP/2 Support** on the proxy host.

## 3. Page caching for anonymous visitors

Install a page-caching plugin in WordPress (e.g. **WP Super Cache** in simple
mode) so anonymous requests skip PHP and MariaDB. The Redis object cache
(already wired into the stack) accelerates the remaining dynamic requests —
install and activate the **Redis Object Cache** plugin, then click
*Enable Object Cache*; connection settings are injected via `wp-config`.

## 4. Fail2ban (host)

Ban repeat offenders at the firewall before they reach Nginx.
`/etc/fail2ban/jail.d/npm.local`:

```ini
[npm-4xx]
enabled  = true
port     = http,https
filter   = npm-4xx
logpath  = /path/to/npm/data/logs/proxy-host-*_access.log
maxretry = 20
findtime = 300
bantime  = 3600
```

`/etc/fail2ban/filter.d/npm-4xx.conf`:

```ini
[Definition]
failregex = ^.* (403|401|444) .* \[Client <HOST>\] .*$
```

Adjust `logpath` to the NPM data directory on your host, then
`systemctl restart fail2ban`.
