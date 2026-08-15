# Known issues and improvements

Tracked for follow-up. Categorized by goal. Items marked **[needs human approval]** require a decision or credential from the operator before an agent should act.

---

## Cleaner

### GitHub PAT token in remote URL  **[needs human approval]**
- **File**: `.git/config` — git remote `origin` contains a GitHub PAT embedded in the URL
- **Problem**: The PAT is stored in plaintext. If the repo is cloned elsewhere or config is exposed, the token leaks. Pushes via `origin` fail with 403; pushes must go through the `jehpok.com` SSH remote.
- **Fix**: `git remote remove origin` (or switch to SSH). Then rotate the exposed PAT on GitHub.
- **Why approval**: the operator may want `origin` for read-only fetches with a rotated token.

### Nextcloud config overrides mixed into auto-generated `config.php`
- **File**: `/var/www/github/jehpok.com/cloud/data/config/config.php` (live, not in git)
- **Problem**: Manual overrides (`trusted_proxies`, `overwrite.cli.url`) are inside the auto-generated config that Nextcloud rewrites on upgrades — diffs become noisy and overrides can be lost.
- **Fix**: Move overrides into `/var/www/github/jehpok.com/cloud/data/config/jehpok.config.php` as a drop-in (Nextcloud merges `*.config.php` files). Survives upgrades cleanly.
- **Status**: partial — overrides are currently in `config.php`; move when convenient.

### `tailnet_default` Docker network created unnecessarily
- **File**: `services/tailnet/docker-compose.yml`
- **Problem**: Compose creates a default bridge network even though CoreDNS only needs host port mapping.
- **Fix**: Cosmetic; harmless. Leave as-is.

---

## More robust

### Migrate SQLite → MariaDB  **[needs human approval]**
- **File**: `services/cloud/docker-compose.yml`
- **Problem**: SQLite has file-level locking. Concurrent sync writes contend → intermittent 504s / "database is locked". Also the backup-corruption risk (copying an online SQLite file).
- **Fix**: Add a MariaDB container on `net`, set `MYSQL_*` env vars, run `occ conversion:migrate` to move data, then back up with `mysqldump`.
- **Why approval**: destructive migration; operator should pick a maintenance window and verify clients reconnect.

### No automated backup script
- **File**: (missing) `scripts/backup.sh`
- **Problem**: Backups are manual `rsync`. No cron, no consistency guarantee for the DB.
- **Fix**: Add `scripts/backup.sh`: `occ maintenance:mode --on` → DB snapshot (`sqlite3 .backup` now, `mariabackup` post-migration) + `rsync` of `cloud/data` → `--off`. Cron it.
- **Why approval**: operator must choose a backup target (local path / remote / S3) and schedule.

### CoreDNS single point of failure for Tailscale DNS
- **File**: `services/tailnet/docker-compose.yml`
- **Problem**: If `tailnet` stops, every `*.jehpok.com` query on Tailscale times out. `restart: unless-stopped` handles crashes, not deliberate `docker stop`.
- **Fix**: (a) add a second CoreDNS instance; (b) move DNS to host `dnsmasq` on `100.81.245.77:53`; (c) add a healthcheck + watchdog auto-restart.

### Healthchecks still need deploy to take effect
- **File**: `services/{cloud,domain}/docker-compose.yml`
- **Problem**: Healthcheck blocks were added and applied. `domain` and `cloud` are healthy. `tailnet` (CoreDNS) is a `FROM scratch` image with no shell — no in-container healthcheck is possible; set to `test: ["NONE"]`.
- **Fix**: For tailnet, consider an external watchdog (host-side `systemd` timer that checks `dig @100.81.245.77 vps.jehpok.com` and restarts the container on failure) if health monitoring is needed.

---

## More secure

### `vps.jehpok.com` has no auth beyond Tailscale membership  **[needs human approval]**
- **File**: `services/domain/Caddyfile` (`https://vps.jehpok.com`)
- **Problem**: Any tailnet device can reach `vps.jehpok.com` with no authentication. DNS-obscurity is the only access control.
- **Fix**: Add Caddy `basic_auth` (needs a username + bcrypt hash from the operator) or Tailscale ACLs in the admin console.
- **Why approval**: requires a password / ACL policy from the operator.

### Tailscale ACLs not configured  **[needs human approval]**
- **File**: Tailscale admin console (outside repo)
- **Problem**: `ts-input` accepts all tailnet traffic. Any added device reaches every open port on the VPS.
- **Fix**: In Tailscale admin console, restrict which devices/tags can reach the VPS.
- **Why approval**: outside the repo; operator must edit the Tailscale policy.

### Cloudflare 100 MB body cap vs Caddy 10G  **[needs human approval]**
- **File**: `services/domain/Caddyfile` (`request_body { max_size 10G }`)
- **Problem**: Cloudflare free-tier proxy caps request bodies at 100 MB. Nextcloud uploads > 100 MB fail at the edge regardless of Caddy's 10G.
- **Fix options**: (a) upgrade Cloudflare plan; (b) grey-cloud `cloud.jehpok.com` (exposes VPS IP); (c) rely on Nextcloud chunked upload; (d) lower Caddy `max_size` to 100 MB so failures are consistent.
- **Why approval**: trade-off between cost, exposure, and UX — operator's call.

### Rotate the exposed GitHub PAT  **[needs human approval]**
- **File**: GitHub account settings (outside repo)
- **Problem**: The PAT in `.git/config` `origin` is already exposed. Even if `origin` is removed, the token is compromised.
- **Fix**: Revoke the PAT at https://github.com/settings/tokens and issue a new one (or drop PAT usage entirely in favor of SSH).
- **Why approval**: operator action on GitHub.

---

## More comfy

### No deploy/ops helper scripts
- **File**: (missing) `scripts/`, `Makefile` or `justfile`
- **Problem**: The `docker compose -f /var/www/...` commands are long and easy to mistype.
- **Fix**: Add a `Makefile` or `justfile` with recipes: `up-<service>`, `restart-<service>`, `logs-<service>`, `push`, `backup`, `status`. Optionally `alias dc=docker compose` in `~/.bashrc`.

### No security-headers snippet on Nextcloud vhost
- **File**: `services/domain/Caddyfile`
- **Problem**: Static vhosts use the `(serve_static)` snippet; the Nextcloud vhost doesn't get consistent security headers (HSTS, `X-Content-Type-Options`).
- **Fix**: Add a `(security_headers)` snippet and import it on all vhosts.

---

## More efficient

### PHP-FPM pool sizing under concurrent sync
- **File**: `services/cloud/php-fpm.d/zz-custom.conf`
- **Problem**: `pm.max_children = 8` with 200s terminate timeout. Slow syncs can occupy all 8 children. (Already switched to `ondemand` — idle workers now free at rest.)
- **Fix**: Monitor `docker exec -w /var/www/html cloud php occ status` and `docker stats cloud`. Raise `max_children` only if sync load grows; lower `request_terminate_timeout` if 504s appear.

### No Nextcloud distributed cache (Redis)
- **File**: `services/cloud/docker-compose.yml`
- **Problem**: Only `memcache.local` (APCu) is set. No `memcache.distributed` or `memcache.locking` — file locking falls back to DB locks, which under SQLite is coarse.
- **Fix**: Add a small Redis container on `net` and set `memcache.distributed` + `memcache.locking` to Redis. Skip at current traffic levels; revisit if sync contention appears.

### Stop Ollama when idle  **[needs human approval]**
- **File**: `/etc/systemd/system/ollama.service`
- **Problem**: Ollama holds ~44 MB RSS idle with no models loaded. Protected by AGENTS.md safety rules (must not delete), but temporary `systemctl stop` between sessions would free RAM.
- **Fix**: `systemctl stop ollama` when not in use; `systemctl start ollama` before use.
- **Why approval**: operator convenience trade-off (cold start latency vs. idle RAM).

---

## Resolved (kept for history)

- **Log rotation deployed** — all 3 containers running with `json-file` size caps (Aug 2026).
- **Image tags pinned** — `caddy:2.11.4`, `coredns:1.14.6`, `nextcloud:34.0.2-fpm` (Aug 2026).
- **PHP-FPM `ondemand`** — idle workers freed after 10s (Aug 2026).
- **CoreDNS multi-upstream** — `1.1.1.1 1.0.0.1 9.9.9.9` sequential (Aug 2026).
- **Caddy admin API closed** — `admin off` in Caddyfile (Aug 2026).
- **Caddy FastCGI timeouts** — `dial_timeout 10s read_timeout 300s write_timeout 300s` (Aug 2026).
- **Nextcloud `trusted_proxies` set** — `172.22.0.0/16` (Caddy's `net` subnet) (Aug 2026).
- **Nextcloud `overwrite.cli.url` → https** (Aug 2026).
- **Static site placeholders** — non-blank index.html on www/app/vps (Aug 2026).
- **Healthchecks added** to all 3 compose files (pending recreate to apply).