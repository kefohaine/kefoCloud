# Known issues and improvements

Tracked for follow-up by other agents. Ordered by severity.

## High

### Nextcloud SQLite backup corruption risk
- **File**: `services/cloud/docker-compose.yml` (SQLite auto-selected, db at `db/owncloud.db`)
- **Problem**: README documents `rsync` of the data dir as the backup method. Copying an online SQLite file can produce a corrupt snapshot.
- **Fix**: Wrap backups with `docker exec cloud occ maintenance:mode --on` before copy, `--off` after. Or script a `sqlite3 db/owncloud.db ".backup"` hot snapshot. Add a `backup.sh` script to the repo.

### Nextcloud `trusted_proxies` not set
- **File**: `services/cloud/docker-compose.yml`
- **Problem**: Caddy terminates TLS and proxies to Nextcloud via `php_fastcgi cloud:9000`. Nextcloud does not know the real client IP because `trusted_proxies` is not configured. This affects brute-force protection, audit logs, and admin notifications.
- **Fix**: Add `TRUSTED_PROXIES` env var (or add Caddy's IP/subnet to Nextcloud's `config.php` trusted_proxies array). Since both containers are on the `net` bridge, the proxy IP is Caddy's container IP on that subnet.

### Cloudflare 100 MB body cap vs Caddy 10G for Nextcloud uploads
- **File**: `services/domain/Caddyfile` (`request_body { max_size 10G }`)
- **Problem**: Cloudflare's free-tier proxy caps request bodies at 100 MB. Nextcloud desktop client large-file uploads through `cloud.jehpok.com` will be rejected at the edge regardless of Caddy's 10G setting. Sync clients will hang or error on files > 100 MB.
- **Fix options**: (a) Increase Cloudflare plan for higher body limit; (b) Bypass Cloudflare proxy for `cloud.jehpok.com` (grey cloud, DNS-only) — but this exposes the VPS IP; (c) Use Nextcloud's chunked upload (clients split into < 100 MB chunks) — verify client config; (d) Accept the 100 MB limit and lower Caddy's `max_size` to match so failures are consistent.

## Medium

### PHP-FPM pool sizing may starve under concurrent sync
- **File**: `services/cloud/php-fpm.d/zz-custom.conf`
- **Problem**: `pm.max_children = 8` with `request_terminate_timeout = 200s`. A few slow Nextcloud sync requests can occupy all 8 children for minutes, starving other requests.
- **Fix**: Tune `pm.max_children` based on available RAM (each PHP-FPM child uses ~30-50 MB). Consider `pm = dynamic` with higher `max_children` or `pm = ondemand` with a shorter `request_terminate_timeout`. Monitor with `docker exec cloud sh -c 'ps aux | grep php-fpm'`.

### SQLite under concurrent Nextcloud sync
- **File**: `services/cloud/docker-compose.yml` (no DB env vars → SQLite)
- **Problem**: SQLite has coarse file-level locking. Multiple sync clients doing writes concurrently will contend, producing intermittent 504s or "database is locked" errors.
- **Fix**: Migrate to MariaDB/PostgreSQL in a container on the `net` network. Add `MYSQL_*` or `POSTGRES_*` env vars and a DB service to the compose file. Back up with `mysqldump`/`pg_dump`.

### No Caddy proxy timeouts tuned for Nextcloud
- **File**: `services/domain/Caddyfile` (`php_fastcgi cloud:9000 { ... }`)
- **Problem**: No explicit `transport_fastcgi` or `reverse_proxy` timeout settings. Large uploads / slow PHP operations rely on Caddy defaults, which may time out before PHP finishes (especially with the 200s `request_terminate_timeout`).
- **Fix**: Add `php_fastcgi cloud:9000 { dial_timeout 10s read_timeout 300s write_timeout 300s }` or equivalent, aligned with the PHP-FPM `request_terminate_timeout`.

### `vps.jehpok.com` has no auth beyond Tailscale membership
- **File**: `services/domain/Caddyfile` (`https://vps.jehpok.com`)
- **Problem**: Any device on the Tailscale network (including any future added device) can reach `vps.jehpok.com` with no authentication. If a Tailscale device is compromised, the vps hostname is open.
- **Fix**: Add Caddy `basic_auth` or Tailscale ACLs to restrict which tailnet devices/tags can reach the vps hostname. Or add `tailscale serve` / `tailscale funnel` with Tailscale's built-in HTTPS + auth.

### CoreDNS single point of failure for Tailscale DNS
- **File**: `services/tailnet/docker-compose.yml`
- **Problem**: If the `tailnet` container stops, every `*.jehpok.com` query on Tailscale times out (including `www`, `app`, `cloud` — not just `vps`). `restart: unless-stopped` handles crashes but not a deliberate `docker stop` during edits.
- **Fix**: (a) Add a second CoreDNS instance with the same Corefile, both bound to the Tailscale IP (requires a different port or IP — tricky); (b) Move DNS to host-level `dnsmasq` bound to `100.81.245.77:53`, independent of Docker; (c) Add a healthcheck + watchdog that auto-restarts the container.

## Low

### `tailnet_default` Docker network created unnecessarily
- **File**: `services/tailnet/docker-compose.yml`
- **Problem**: Compose creates a default bridge network (`tailnet_default`) even though CoreDNS only needs host port mapping. `network_mode: none` would prevent this but also disables port mapping, so it can't be used.
- **Fix**: This is cosmetic. The network is unused but harmless. Could suppress with `networks: { default: { driver: none } }` but that may break port mapping. Leave as-is.

### Empty static site directories
- **File**: `content/domain/www/index.html`, `content/domain/app/index.html`, `content/domain/vps/index.html`, `content/domain/app/template.py`
- **Problem**: All static site index files and `template.py` are empty (0 bytes). The sites serve blank pages.
- **Fix**: Add actual content or a placeholder page to each.

### No Nextcloud healthcheck
- **File**: `services/cloud/docker-compose.yml`
- **Problem**: No Docker healthcheck defined. Container shows "Up" even if PHP-FPM or Nextcloud is internally broken.
- **Fix**: Add `healthcheck: test: ["CMD-SHELL", "php-fpm-healthcheck || exit 1"]` (the FPM image includes a healthcheck script if `pm.status_path` is configured).

### GitHub Actions PAT token in remote URL
- **File**: `.git/config` — git remote `origin` contains a GitHub PAT (`github_pat_...`) embedded in the URL
- **Problem**: The PAT is stored in `.git/config` in plaintext. If the repo is cloned elsewhere or config is exposed, the token leaks. Pushes via `origin` fail with 403 (write access not granted); pushes must go through the `jehpok.com` SSH remote.
- **Fix**: Remove the `origin` remote or switch it to SSH: `git remote set-url origin git@github.com:friedutch/jehpok.com.git`. The self-hosted runner uses `origin` for `git fetch` in the deploy workflow — if removed, update the workflow to use `jehpok.com` instead. Rotate the exposed PAT on GitHub.