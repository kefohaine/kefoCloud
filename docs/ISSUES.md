# Known issues and improvements

Tracked for follow-up. Items marked **[needs human approval]** require a decision or credential from the operator before an agent should act. Items under **Intended** describe behaviours that look like bugs but are deliberate design choices — do not fix; the rationale is recorded so future agents don't "correct" them.

---

## Open

### Robustness

#### Migrate SQLite → MariaDB  **[needs human approval]**
- **File**: `services/cloud/docker-compose.yml`
- **Problem**: SQLite has file-level locking. Concurrent sync writes contend → intermittent 504s / "database is locked". Also the backup-corruption risk (copying an online SQLite file).
- **Fix**: Add a MariaDB container on `net`, set `MYSQL_*` env vars, run `occ conversion:migrate` to move data, then back up with `mysqldump`.
- **Why approval**: destructive migration; operator should pick a maintenance window and verify clients reconnect.

#### No automated backup script
- **File**: (missing) `scripts/backup.sh`
- **Problem**: Backups are manual `rsync`. No cron, no consistency guarantee for the DB.
- **Fix**: Add `scripts/backup.sh`: `occ maintenance:mode --on` → DB snapshot (`sqlite3 .backup` now, `mariabackup` post-migration) + `rsync` of `cloud/users` → `--off`. Cron it.
- **Why approval**: operator must choose a backup target (local path / remote / S3) and schedule.

### Security

#### `ufw` status command broken on host
- **File**: `/usr/sbin/ufw` (host package)
- **Problem**: `sudo ufw status` returns `ERROR: Couldn't determine iptables version`. The UFW rules are still loaded (ttyd port allow from `172.22.0.0/16`, etc.) but status inspection fails — agents can't verify firewall state.
- **Fix**: Investigate root cause (likely `iptables`/`nftables` backend mismatch — Debian 12+ defaults to nft, UFW expects iptables-legacy). Either install `iptables-legacy` + `iptables-nft` both, or migrate to `nftables` directly, or pin `ufw` to the legacy backend via `update-alternatives`.
- **Why approval**: touches host firewall tooling; operator should decide path.

#### `fail2ban` installed but inactive
- **File**: host package `fail2ban`
- **Problem**: `fail2ban` is on the host but `systemctl is-active` returns `inactive`. No ban jail is protecting SSH even though sshd is hardened — defense-in-depth gap.
- **Fix**: `systemctl enable --now fail2ban` + configure an SSH jail (filter `/etc/fail2ban/jail.d/sshd.conf` with `enabled = true`, `maxretry = 5`, `bantime = 1h`). Verify with `fail2ban-client status sshd`.
- **Why approval**: needs a decision on retry threshold and ban duration; affects SSH UX for the operator.

#### Tailscale tailnet has 2 stale devices  **[needs human approval]**
- **File**: Tailscale admin console (outside repo)
- **Problem**: `kaliusb` (linux, 18d offline) and `iosphone` (iOS, 6h offline) are still registered in the tailnet. `kaliusb` is a Kali USB stick — likely a forensic / on-demand tool, not a daily driver. Stale devices widen the ACL blast radius.
- **Fix**: In Tailscale admin console, remove `kaliusb` and `iosphone`. Or rename and tag if they are still in active use.
- **Why approval**: outside the repo; operator must decide which devices stay.

#### `server.jehpok.com` has no auth beyond Tailscale membership  **[needs human approval]**
- **File**: `services/domain/Caddyfile` (`https://server.jehpok.com`)
- **Problem**: Any tailnet device can reach `server.jehpok.com` with no authentication. DNS-obscurity is the only access control — the link shortener admin UI at `/share` and the host ttyd shell at `/shell` (a host systemd unit running as `debian` with full host control) both sit behind `@not_tailnet` and nothing else.
- **Fix**: Add Caddy `basic_auth` on the `/share*` and `/shell*` matchers (needs a username + bcrypt hash from the operator), or apply Tailscale ACLs in the admin console to restrict who can reach the VPS at all.
- **Why approval**: requires a password / ACL policy from the operator.

#### `server.jehpok.com/shell` gives a `debian` shell to any tailnet device  **[needs human approval]**
- **File**: `services/domain/Caddyfile` (`https://server.jehpok.com`)
- **Problem**: `/shell` is a host systemd unit (`ttyd.service`) running `/usr/local/bin/ttyd bash` as `debian` (uid 1000). The process is on the host, not in a container, so `sudo -i` reaches root and every host file is writable. The systemd unit has no filesystem sandbox (all `ProtectSystem`, `PrivateTmp`, etc. directives stripped — operator preference: no permission hunts). Tailscale membership alone gates it.
- **Fix**: Add Caddy `basic_auth` on the `/shell*` matcher (needs a username + bcrypt hash), or apply Tailscale ACLs to restrict which devices can reach the VPS, or restrict the container with `cap_drop` + a read-only root mount + a write whitelist.
- **Why approval**: requires a password / ACL policy from the operator.

#### Tailscale ACLs not configured  **[needs human approval]**
- **File**: Tailscale admin console (outside repo)
- **Problem**: `ts-input` accepts all tailnet traffic. Any added device reaches every open port on the VPS.
- **Fix**: In Tailscale admin console, restrict which devices/tags can reach the VPS.
- **Why approval**: outside the repo; operator must edit the Tailscale policy.

#### Rotate the exposed GitHub PAT  **[needs human approval]**
- **File**: GitHub account settings (outside repo)
- **Problem**: The PAT that was in `.git/config` `origin` is compromised — it lived in git history before the purge. Even though the remote and the history are gone, the token value was exposed.
- **Fix**: Revoke the PAT at https://github.com/settings/tokens (or confirm it's already expired). Drop PAT usage entirely in favor of SSH.
- **Why approval**: operator action on GitHub.

### Efficiency

#### PHP-FPM pool sizing under concurrent sync
- **File**: `services/cloud/php-fpm.d/zz-custom.conf`
- **Problem**: `pm.max_children = 8` with 200s terminate timeout. Slow syncs can occupy all 8 children. (Already switched to `ondemand` — idle workers now free at rest.)
- **Fix**: Monitor `docker exec -w /var/www/html cloud php occ status` and `docker stats cloud`. Raise `max_children` only if sync load grows; lower `request_terminate_timeout` if 504s appear.

#### No Nextcloud distributed cache (Redis)
- **File**: `services/cloud/docker-compose.yml`
- **Problem**: Only `memcache.local` (APCu) is set. No `memcache.distributed` or `memcache.locking` — file locking falls back to DB locks, which under SQLite is coarse.
- **Fix**: Add a small Redis container on `net` and set `memcache.distributed` + `memcache.locking` to Redis. Skip at current traffic levels; revisit if sync contention appears.

#### Stop Ollama when idle  **[needs human approval]**
- **File**: `/etc/systemd/system/ollama.service`
- **Problem**: Ollama holds ~44 MB RSS idle with no models loaded. Protected by `docs/AGENTS.md` safety rules (must not delete), but temporary `systemctl stop` between sessions would free RAM.
- **Fix**: `systemctl stop ollama` when not in use; `systemctl start ollama` before use.
- **Why approval**: operator convenience trade-off (cold start latency vs. idle RAM).

#### Nextcloud Talk: no High-performance backend, no Client Push
- **File**: `services/cloud/docker-compose.yml` (or new compose for HPB + push proxy)
- **Problem**: Talk scales only to ~3 participants without an HPB container; Client Push proxy absent → delayed notifications. Currently a low-impact warning; grows if Talk is used.
- **Fix**: Add a Talk HPB container on `net` + the `nextcloud-talk-hpb` image, set `TURN_SERVER` / `SIGNALING_*` env; install `nextcloud_announcements` or a separate push proxy. Both are out-of-scope unless Talk calls become a real use case.

---

## Intended

Behaviours that look like bugs but are deliberate. Do not fix; the rationale is the answer.

### `server.jehpok.com` is unresolvable from the public internet
Looks like: DNS lookup fails for `server.jehpok.com` outside Tailscale, *or* a `curl` against `https://server.jehpok.com/...` (or any path under it: `/share`, `/shell`) from a non-tailnet source times out, returns 403, or connection-refuses — including from the VPS host itself if the host isn't on the tailnet resolver. Reality: this is the only access control. The hostname is deliberately absent from Cloudflare DNS so the resolver only knows it on the tailnet. Caddy additionally returns 403 for any non-tailnet source IP via `@not_tailnet`, so a forged Host header against the public IP also fails. **A failed curl is `@not_tailnet` working, not a service outage** — only the operator and tailnet devices can reach `server.jehpok.com`; verify from a tailnet device or by SSH'ing in and curling from a tailnet-joined source.

### TLS validation on `server.jehpok.com` shows an untrusted-CA warning
Looks like: a tailnet device hits `https://server.jehpok.com/...` and the browser/curl rejects the certificate (`unknown CA`, `SSL certificate problem: unable to get local issuer certificate`). Reality: `server.jehpok.com` is not in Cloudflare DNS, so tailnet devices connect directly to Caddy on the VPS — Caddy serves the wildcard Cloudflare Origin cert from `$(REPO)/certs/cert.pem`, signed by `CloudFlare Origin SSL Certificate Authority`, which is **not** in the system trust store. Cloudflare-fronted hostnames (www/share/api/vault/cloud/kuma) don't hit this because the client → Cloudflare edge handshake uses a public cert, not the Origin cert. This is the same behaviour as before any agent touched the cert config — the wildcard cert has always matched `server.jehpok.com`. The operator's working pattern before this was documented: accept the cert warning in the browser (one-time exception) and use `curl -k` for scripts. A per-device CA install is *one* way to silence the warning, not a requirement — see the warning against changing the cert config in `docs/AGENTS.md` rule #10 and the project-specific note under "Project-specific overrides".

### Cloudflare Bot Fight Mode blocks `curl` against `api.jehpok.com`
Looks like: Cloudflare rejects `curl`/scripts hitting `api.jehpok.com` with a 403 / challenge. Reality: terminal traffic cannot solve the Browser Integrity Check. The intended fix is a per-hostname WAF rule skip on `api.jehpok.com` (and the same mitigation is required for `cloud.jehpok.com` desktop sync); the goal is to keep Cloudflare's full protection on everywhere else.

### `share.jehpok.com/share`-style paths return `not found` instead of redirecting to `server.jehpok.com/share`
Looks like: the link shortener admin UI is unreachable from `share.jehpok.com/share`. Reality: the public vhost hides `/share`, `/api/*`, and `/healthz` via a Caddy `@admin` matcher returning 404, because admin has no app-level auth and the public side shouldn't leak its existence. Admin lives at `server.jehpok.com/share`, which is tailnet-only.

---

## Solved

Resolved items grouped by month. One line per item, aggressively short.

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
- **Claude Code project safety rail** — `setup/claude/settings.local.json` (deny-only, AGENTS.md-protected resources + user-data bind mounts) deployed by `make setup`.
- **Backup + migrate recipes broken as `debian`** — root-owned `/var/www/custom/projects/jehpok/` blocked `cp/tar/mkdir` destinations; `backup-cloud` source was unreachable (`cloud/users` is `770 www-data:www-data`); `migrate` recipe was deleted by `582b789` and only its help line survived. Now: backup-share/vault/secrets use `sudo` for destinations; backup-cloud streams via `docker exec cloud tar cf - -C /data . | sudo tar xf -`; `migrate` recipe restored verbatim.
- **Makefile `set -u` foot-gun** — `SHELLFLAGS := -eu -c` with unset `SHELL` ran recipes under `dash -eu`, where `-u` semantics differ from bash; latent crash on any unset var. Fixed: `SHELL := /bin/bash` set explicitly at top; documented in `GUIDE.md` operational gotchas.
- **`backup-cloud` maintenance trap** — added `trap 'occ maintenance:mode --off' EXIT` so a tar-stream failure can't leave Nextcloud in maintenance mode.
- **`clean` split into `clean-docker` + `clean-apt` + `clean-backups` + `clean-all`** — old `clean` was a hardcoded mix of apt + docker prune; now each is independently runnable; `clean-backups` keeps latest 3 per pattern and prunes older.
- **`backup-all`** — chains the four backup recipes in order; daily timer now runs `make refresh` → `make backup-all` → `make clean-all`.
- **Migrate runbook extracted to `docs/MIGRATE.md`** — `make migrate` now cats the doc instead of echoing ~50 lines inline; prose rewritten per `.md` writing rules (points at executable source, doesn't retype).
- **Makefile** — recipes for up/restart/logs/status/push/backup/clean.
- **Nextcloud overrides env-driven** — `TRUSTED_PROXIES` + `OVERWRITECLIURL` in compose; removed from `config.php`.
- **Deploy/ops helper scripts** — covered by the Makefile recipes.
- **System made fully recoverable** — `backup-secrets` + `migrate` recipes, README runbook.
- **Reference configs in repo** — Ollama unit + SSH hardening copied under `setup/`.
- **Static landing page** — FR, Spotify embed, countdown, styled; served from the static `www` vhost before Homer replaced it.
- **Nextcloud bind mount split** — `cloud/html` (root) + `cloud/users` (datadirectory).
- **`.md` writing rules** — 10 rules added to AGENTS.md; README deduped (328→271 lines).
- **Docs reorganized** — AGENTS.md + ISSUES.md moved to `docs/`; README stays at root.
- **Sensitive files purged from git history** — `config/web/certs/key.pem`, `cert.pem`, `.github/workflows/deploy.yml`, `install.sh`, `app.py` removed via `git filter-repo`; `origin` remote (PAT-embedded) removed; history rewritten, force-pushed.
- **CoreDNS → dnsmasq** — container removed; host dnsmasq on `100.81.245.77:53`.
- **`tailnet_default` gone** — spare bridge removed with the container.
- **URL shortener** — Flask + SQLite; `link.jehpok.com` public, `ops.jehpok.com/link` admin.
- **Nextcloud bind mount fixed** — `datadirectory` moved to `/data`, no nesting.
- **`link.jehpok.com` admin leak closed** — Caddy `@admin` matcher returns 404 for `/link`, `/api/*`, `/healthz`, `/` on public vhost; admin still reachable via `ops.jehpok.com/link`.
- **Cloudflare 100 MB body cap aligned** — all vhosts `max_size 100m` to match CF free-tier; inconsistent 10G on cloud vhost removed.
- **Nextcloud `maintenance_window_start`** — set to `4` (04:00) so heavy background jobs don't run during peak.
- **Nextcloud DB missing indices** — `mail_*` table indices added via `occ db:add-missing-indices`.
- **Nextcloud mimetype migrations** — applied via `occ maintenance:repair --include-expensive`.
- **Nextcloud `TRUSTED_PROXIES` expanded** — added all 15 Cloudflare edge ranges so real client IPs reach Nextcloud.
- **Homer + Uptime Kuma added** — `www.jehpok.com` serves Homer (static landing page retired); `kuma.jehpok.com` serves Uptime Kuma; both reverse-proxied via Caddy, no published ports.
- **Docs split into four** — `README.md` (visitor), `docs/AGENTS.md` (portable agent rules), `docs/GUIDE.md` (project operator guide), `docs/ISSUES.md` (task tracker + Intended section).
- **Log tightening** — Caddy global `log -> /dev/null` (no per-request access logs); dnsmasq `log-queries` removed; `share` container cap raised to 10m×3 to match the other 5.
- **`ops.jehpok.com/terminal`** — ttyd-backed host shell; bind-mounts `/` rw + Docker socket; container `privileged`, runs as the host path-aware bash from `/var/www/custom/projects/jehpok/repo`.
- **`status.jehpok.com` → `kuma.jehpok.com`** — hostname rename to match the container name; Cloudflare + Caddy + Homer YAML updated.
- **Kuma monitor set trimmed** — `tcp: vps 443` (unreachable from Kuma's netns), `ping: vps` (redundant), `docker: kuma` (self-check) dropped; `docker: *` monitors moved to 3600s; HTTP monitors stay at 60s.
- **Kuma `seed-monitors.sql`** — idempotent SQL for the 9 monitors + 2 groups; applied once via `docker exec -i kuma sqlite3 ... < seed-monitors.sql`.
- **Homer config bind tightened** — bind only `services/homer/config/config.yml` → `/www/assets/config.yml` so the bundled icons/themes/manifest stay intact.
- **Repo relocated** — moved from `/var/www/github/jehpok.com` to `/var/www/custom/projects/jehpok`; `/var/www/github/` deleted; all compose/Makefile/.md/live-`jehpok-daily.sh` paths rewritten; `cloud/html` + `cloud/users` chowned to uid 33.
- **Hostname `vps.jehpok.com` → `ops.jehpok.com`** — Caddyfile + dnsmasq + Homer config + 3 .md docs renamed; live dnsmasq + Caddy reloaded; vps.jehpok.com now unmentioned anywhere.
- **`ops.jehpok.com/terminal` runs as `debian`** — ttyd entrypoint switched from `exec bash` (root in container) to `exec runuser -u debian -- bash`; container also bind-mounts `/etc/passwd` + `/etc/group` so runuser can resolve uid 1000.
- **Homer dashboard expanded** — Files (`share.jehpok.com/files`) and Terminal (`ops.jehpok.com/terminal`) added; API added to the top links bar.
- **Terminal `host-exec` shim** — Alpine ttyd container can't run host glibc binaries (`smem`, `sudo`, etc.) directly. Added `/usr/local/bin/host-exec` that `chroot`s to `/host` and runs the command under the host shell. Use `host-exec 'smem'` from inside the ttyd session.
- **`browser` user dropped from sshd, `runner` user deleted** — `AllowUsers debian browser` → `AllowUsers debian`; `userdel -r runner`. Both were unused leftovers; host now has `debian` as the sole human account.
- **Uniform 404 format** — every Caddy-controlled 404 now returns plain text `not found` (no JSON, no HTML). Flask `not_found` handler switched from `jsonify(error=...)` to `Response("not found", mimetype="text/plain")`; cloud `@blocked` matcher now responds with body. Vaultwarden / Homer / Nextcloud 404s left as their own upstream pages.
- **`www.jehpok.com` keeps Homer's HTML 404** — explicit operator call: upstream containers with their own 404 page (Homer, Vaultwarden, Nextcloud) keep that page; only Caddy-controlled paths (share, api, ops, cloud `@blocked`) return plain text `not found`.
- **`make` from terminal needs `host-exec`** — the docker compose plugin at `/host/usr/libexec/docker/cli-plugins/docker-compose` is glibc-linked and fails in the Alpine ttyd container with a cryptic `unknown shorthand flag: 'f' in -f`. Run any make recipe via `host-exec 'make ...'` from inside `ops.jehpok.com/terminal`.
- **Terminal migrated to host systemd ttyd** — `services/terminal/` removed; `ttyd.service` runs as `debian` on the host, binds `172.22.0.1:7681` (not `0.0.0.0`), gated by Caddy `@not_tailnet` + UFW INPUT allow from the `net` bridge. Caddy proxies to `172.22.0.1:7681` with `transport http { versions 1.1 }`. `host-exec` / `runuser` shims are gone — the shell is a real host shell directly.
- **`ops.jehpok.com/terminal` → `ops.jehpok.com/server`** — URL renamed; Caddy `@server` matcher at `/server*`, Homer dashboard updated, README + ISSUES + GUIDE all point at `/server`. systemd unit stays `ttyd.service` (it's the runtime, not the URL).
- **Hostname `vps-742a45f9` → `server`** — system hostname + `/etc/hosts` updated; SSH host keys regenerated so the old `root@vps-742a45f9` comment is gone from the `.pub` files; cloud-init stale state (`/var/lib/cloud/data/{previous,set}-hostname`) deleted.
- **`debian` has passwordless sudo** — `/etc/sudoers.d/debian-passwordless` (`NOPASSWD:ALL`, mode 0440). Reduces permission prompts during normal agent operations; still requires sudo for anything privileged.
- **Claude Code allow-list curated + backed up** — `.claude/settings.local.json` is gitignored (per-operator); tracked template lives at `setup/claude/settings.local.json`; `make setup` deploys it. Allow-list covers ollama/maintenance commands; destructive ops still prompt. Later superseded by the project-level deny-only safety rail (see Claude Code project safety rail).
- **ttyd hardening removed** — `ProtectSystem`, `PrivateTmp`, `MemoryDenyWriteExecute`, `PrivateDevices`, `RestrictAddressFamilies`, `LockPersonality`, `RestrictRealtime`, `ProtectControlGroups` all stripped from `ttyd.service` (operator preference: no permission hunts); access control stays at Tailscale + `Caddy @not_tailnet`.
- **Minecraft server** — Paper + Geyser/Floodgate at `mc.jehpok.com` (Java `:25565`, Bedrock `:19132`); tailnet-only Flask+rcon dashboard at `server.jehpok.com/mc` (start/stop/restart, live stats, editable `server.properties`, log tail, quick rcon). World data bind-mounted under `$(REPO)/minecraft/data`.
