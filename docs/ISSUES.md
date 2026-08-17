# Known issues and improvements

Tracked for follow-up. Categorized by goal. Items marked **[needs human approval]** require a decision or credential from the operator before an agent should act.

---

## Robustness

### Migrate SQLite → MariaDB  **[needs human approval]**
- **File**: `services/cloud/docker-compose.yml`
- **Problem**: SQLite has file-level locking. Concurrent sync writes contend → intermittent 504s / "database is locked". Also the backup-corruption risk (copying an online SQLite file).
- **Fix**: Add a MariaDB container on `net`, set `MYSQL_*` env vars, run `occ conversion:migrate` to move data, then back up with `mysqldump`.
- **Why approval**: destructive migration; operator should pick a maintenance window and verify clients reconnect.

### No automated backup script
- **File**: (missing) `scripts/backup.sh`
- **Problem**: Backups are manual `rsync`. No cron, no consistency guarantee for the DB.
- **Fix**: Add `scripts/backup.sh`: `occ maintenance:mode --on` → DB snapshot (`sqlite3 .backup` now, `mariabackup` post-migration) + `rsync` of `cloud/users` → `--off`. Cron it.
- **Why approval**: operator must choose a backup target (local path / remote / S3) and schedule.

---

## Security

### `vps.jehpok.com` has no auth beyond Tailscale membership  **[needs human approval]**
- **File**: `services/domain/Caddyfile` (`https://vps.jehpok.com`)
- **Problem**: Any tailnet device can reach `vps.jehpok.com` with no authentication. DNS-obscurity is the only access control. This now also exposes the link shortener admin UI at `/link` — anyone on tailnet can create or delete redirects.
- **Fix**: Add Caddy `basic_auth` on the `/link*` matcher (needs a username + bcrypt hash from the operator), or apply Tailscale ACLs in the admin console to restrict who can reach the VPS at all.
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
- **Problem**: The PAT that was in `.git/config` `origin` is compromised — it lived in git history before the purge. Even though the remote and the history are gone, the token value was exposed.
- **Fix**: Revoke the PAT at https://github.com/settings/tokens (or confirm it's already expired). Drop PAT usage entirely in favor of SSH.
- **Why approval**: operator action on GitHub.

---

## Efficiency

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
- **Problem**: Ollama holds ~44 MB RSS idle with no models loaded. Protected by docs/AGENTS.md safety rules (must not delete), but temporary `systemctl stop` between sessions would free RAM.
- **Fix**: `systemctl stop ollama` when not in use; `systemctl start ollama` before use.
- **Why approval**: operator convenience trade-off (cold start latency vs. idle RAM).

---

## Solved (kept for history)

### Jul 2026 — early system build
- **Initial site + Docker** — `index.html`, first `docker-compose.yml`.
- **Caddy setup** — first vhost config.
- **GitHub Actions deploy** — `.github/workflows/deploy.yml` with SSH-key deploys; later retired.
- **AI/LLM API service** — `containers/ai/app.py` on a separate network, Ollama-backed; later removed.

### Aug 2026 — Nextcloud, TLS, hardening, ops
- **TLS certificates** — valid Cloudflare Origin cert provided; dummy certs deleted.
- **Nextcloud integration** — first hosted on the VPS, migrated to `app.jehpok.com/cloud`, reverted, then linked via PHP-FPM.
- **Nextcloud backend upgrade** — image bump.
- **CoreDNS isolated** — split into its own directory; config renamed.
- **FPM worker regulation** — `zz-custom.conf` added, pool tuning.
- **Container renames** — `domain`, `cloud`, `tailnet` names pinned.
- **Local LLM hosting removed, open resolver fixed, Caddy hardened.**
- **SSH hardened** — password auth + root login disabled, `AllowUsers debian`.
- **Log rotation deployed** — all 3 containers with `json-file` size caps.
- **Image tags pinned** — `caddy:2.11.4`, `coredns:1.14.6`, `nextcloud:34.0.2-fpm`.
- **PHP-FPM `ondemand`** — idle workers freed after 10s.
- **CoreDNS multi-upstream** — `1.1.1.1 1.0.0.1 9.9.9.9` sequential.
- **Caddy admin API closed** — `admin off` in global options block.
- **Caddy FastCGI timeouts** — `dial_timeout 10s read_timeout 300s write_timeout 300s`.
- **Nextcloud `trusted_proxies`** — `172.22.0.0/16` (Caddy's `net` subnet).
- **Nextcloud `overwrite.cli.url` → https**.
- **Static site placeholders** — non-blank `index.html` on www/app/vps.
- **Healthchecks** — domain + cloud healthy; tailnet `NONE` (`FROM scratch`).
- **Security headers** — HSTS, X-Content-Type-Options, X-Frame-Options, Referrer-Policy on all vhosts.
- **Makefile** — recipes for up/restart/logs/status/push/backup/clean.
- **Nextcloud overrides env-driven** — `TRUSTED_PROXIES` + `OVERWRITECLIURL` in compose; removed from `config.php`.
- **Deploy/ops helper scripts** — covered by the Makefile recipes.
- **System made fully recoverable** — `backup-secrets` + `migrate` recipes, README runbook.
- **Reference configs in repo** — Ollama unit + SSH hardening copied under `setup/`.
- **Cheyenne anniversary page** — FR, Spotify embed, countdown, styled.
- **Nextcloud bind mount split** — `cloud/html` (root) + `cloud/users` (datadirectory).
- **`.md` writing rules** — 10 rules added to AGENTS.md; README deduped (328→271 lines).
- **Docs reorganized** — AGENTS.md + ISSUES.md moved to `docs/`; README stays at root.
- **Sensitive files purged from git history** — `config/web/certs/key.pem`, `cert.pem`, `.github/workflows/deploy.yml`, `install.sh`, `app.py` removed via `git filter-repo`; `origin` remote (PAT-embedded) removed; history rewritten, force-pushed.
- **CoreDNS SPOF resolved** — `services/tailnet/` deleted; replaced with host dnsmasq (`/etc/dnsmasq.d/10-tailnet.conf`) bound to `100.81.245.77:53`, `Restart=always`, `After=tailscaled`; `tailnet_default` spare bridge gone; DNS now survives `docker stop` / image pulls / `systemctl restart docker`.
- **dnsmasq recovery covered** — `setup-host` installs config + drop-in; `backup-secrets` bundles them; `migrate` adds `dnsmasq` to apt; Makefile gets `restart-dns`/`logs-dns`, drops tailnet targets.
- **URL shortener** — Flask + SQLite at `services/link/` (`jehpok/link:1`); public 301-redirects at `link.jehpok.com`, admin UI at `vps.jehpok.com/link` (Tailscale-only); source in `content/link/` bind-mounted at `/app/src` so `restart-link` picks up edits without rebuild; `backup-link` + `migrate` cover the DB; `up-all` runs `up-link` first.
- **Nextcloud nested bind mount fixed** — `nextcloud:34.0.2-fpm` declares `VOLUME ["/var/www/html"]`; nesting `cloud/users` at `/var/www/html/data` silently vanished after long uptimes causing HTTP 500 "unable to open database file"; `datadirectory` moved to `/data` (standalone path, no nesting); diagnostic: `docker exec cloud ls /data` — if missing, `make up-cloud`.
