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

### Nextcloud `overwrite.cli.url` is HTTP, not HTTPS
- **File**: `/var/www/github/jehpok.com/cloud/data/config/config.php` (live, not in git)
- **Problem**: `overwrite.cli.url` is set to `http://cloud.jehpok.com`. Nextcloud uses this to generate URLs from CLI/cron/background jobs. With HTTP, cron-generated URLs and notifications point at the plaintext URL, causing mixed-content warnings and bad redirects for clients that follow them.
- **Fix**: `docker exec cloud occ config:system:set overwrite.cli.url --value="https://cloud.jehpok.com"`. Also add `overwriteprotocol https` is already set via env, but `overwrite.cli.url` overrides for CLI context.

### Caddy admin API exposed on the `net` bridge
- **File**: `services/domain/docker-compose.yml` (Caddy listens on `:2019` by default, no `admin off` in Caddyfile)
- **Problem**: Caddy's admin endpoint is bound to `:2019` inside the container with no auth. Since `domain` is on the `net` bridge, any container on `net` (e.g. a compromised Nextcloud) can reach `http://domain:2019/config/` and reload/reconfigure Caddy at runtime — add vhosts, change upstreams, or stop the server.
- **Fix**: Add `admin off` (or `admin 127.0.0.1:2019`) to the top of `services/domain/Caddyfile` so the admin API is disabled or loopback-only.

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

### Tailscale `ts-input` iptables rule accepts all tailnet traffic
- **File**: host iptables `ts-input` chain (managed by Tailscale)
- **Problem**: Rule 2 in `ts-input` is `ACCEPT all from 0.0.0.0/0`, which accepts all traffic from the Tailscale interface before ufw rules apply. This means any tailnet device can reach any open port on the VPS (e.g. Caddy on 443, Docker ports). Ufw's SSH restriction still works because ufw rules apply to non-tailnet interfaces, but the broad Tailscale accept bypasses ufw for tailnet sources.
- **Fix**: This is Tailscale's default behavior (tailnet devices are trusted). To restrict further, use Tailscale ACLs in the admin console to limit which devices/tags can reach the VPS, or add explicit iptables rules in `ts-input` to drop unwanted ports from tailnet sources. Do not modify the `ts-input` chain directly — Tailscale rewrites it on restart.

### `tailnet_default` Docker network created unnecessarily
- **File**: `services/tailnet/docker-compose.yml`
- **Problem**: Compose creates a default bridge network (`tailnet_default`) even though CoreDNS only needs host port mapping. `network_mode: none` would prevent this but also disables port mapping, so it can't be used.
- **Fix**: This is cosmetic. The network is unused but harmless. Could suppress with `networks: { default: { driver: none } }` but that may break port mapping. Leave as-is.

### CoreDNS upstream failover is sequential only
- **File**: `services/tailnet/Corefile` (`forward . 1.1.1.1 1.0.0.1 { policy sequential }`)
- **Problem**: Both upstreams are Cloudflare resolvers (`1.1.1.1`, `1.0.0.1`). If Cloudflare has an outage, all Tailscale DNS fails. `policy sequential` only fails over when the first upstream times out, adding latency before the second is tried.
- **Fix**: Add a non-Cloudflare tertiary upstream (e.g. `9.9.9.9` Quad9 or `8.8.8.8` Google) and consider `policy round_robin` for load spreading.

### Empty static site directories
- **File**: `content/domain/www/index.html`, `content/domain/app/index.html`, `content/domain/vps/index.html`, `content/domain/app/template.py`
- **Problem**: All static site index files and `template.py` are empty (0 bytes). The sites serve blank pages.
- **Fix**: Add actual content or a placeholder page to each.

### No Nextcloud healthcheck
- **File**: `services/cloud/docker-compose.yml`
- **Problem**: No Docker healthcheck defined. Container shows "Up" even if PHP-FPM or Nextcloud is internally broken.
- **Fix**: Add `healthcheck: test: ["CMD-SHELL", "php-fpm-healthcheck || exit 1"]` (the FPM image includes a healthcheck script if `pm.status_path` is configured).

### GitHub PAT token in remote URL
- **File**: `.git/config` — git remote `origin` contains a GitHub PAT (`github_pat_...`) embedded in the URL
- **Problem**: The PAT is stored in `.git/config` in plaintext. If the repo is cloned elsewhere or config is exposed, the token leaks. Pushes via `origin` fail with 403 (write access not granted); pushes must go through the `jehpok.com` SSH remote.
- **Fix**: Remove the `origin` remote or switch it to SSH: `git remote set-url origin git@github.com:friedutch/jehpok.com.git`. Rotate the exposed PAT on GitHub.
