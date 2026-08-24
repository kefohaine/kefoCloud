# Known issues and improvements

Tracked for follow-up. Items marked **[needs human approval]** require a decision or credential from the operator before an agent should act. Items under **Intended** describe behaviours that look like bugs but are deliberate design choices — do not fix; the rationale is recorded so future agents don't "correct" them.

---

## Open

### Robustness

#### Migrate SQLite → MariaDB  **[needs human approval]**
- **File**: `services/nextcloud/docker-compose.yml`
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

#### `server.homelab.com` has no auth beyond Tailscale membership  **[needs human approval]**
- **File**: `services/vhosts/vhosts/server.homelab.com.caddy`
- **Problem**: Any tailnet device can reach `server.homelab.com` with no authentication. DNS-obscurity is the only access control — the link shortener admin UI at `/share` and the host ttyd shell at `/shell` (a host systemd unit running as `debian` with full host control) both sit behind `@not_tailnet` and nothing else.
- **Fix**: Add Caddy `basic_auth` on the `/share*` and `/shell*` matchers (needs a username + bcrypt hash from the operator), or apply Tailscale ACLs in the admin console to restrict who can reach the VPS at all.
- **Why approval**: requires a password / ACL policy from the operator.

#### `server.homelab.com/shell` gives a `debian` shell to any tailnet device  **[needs human approval]**
- **File**: `services/vhosts/vhosts/server.homelab.com.caddy`
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

#### Re-apply Cloudflare WAF skip on the new domain
- **File**: Cloudflare dashboard (new zone)
- **Problem**: after migrating to a new domain, `cloud.<new-domain>` Nextcloud desktop sync will be bot-challenged until the per-hostname WAF rule skip is re-created (same rationale as the `cloud.homelab.com` `Intended` entry).
- **Fix**: re-add the per-hostname WAF rule skip for `cloud.<new-domain>` after `scripts/install.sh` finishes.

### Efficiency

#### PHP-FPM pool sizing under concurrent sync
- **File**: `services/nextcloud/php-fpm.d/zz-custom.conf`
- **Problem**: `pm.max_children = 8` with 200s terminate timeout. Slow syncs can occupy all 8 children. (Already switched to `ondemand` — idle workers now free at rest.)
- **Fix**: Monitor `docker exec -w /var/www/html cloud php occ status` and `docker stats cloud`. Raise `max_children` only if sync load grows; lower `request_terminate_timeout` if 504s appear.

#### No Nextcloud distributed cache (Redis)
- **File**: `services/nextcloud/docker-compose.yml`
- **Problem**: Only `memcache.local` (APCu) is set. No `memcache.distributed` or `memcache.locking` — file locking falls back to DB locks, which under SQLite is coarse.
- **Fix**: Add a small Redis container on `net` and set `memcache.distributed` + `memcache.locking` to Redis. Skip at current traffic levels; revisit if sync contention appears.

#### Stop goose when idle  **[needs human approval]**
- **File**: `/etc/systemd/system/goose.service`
- **Problem**: The goose agent service (`goose serve`) holds memory idle when no session is active. Protected by `docs/AGENTS.md` safety rules (must not delete), but temporary `systemctl stop` between sessions would free RAM.
- **Fix**: `systemctl stop goose` when not in use; `systemctl start goose` before use.
- **Why approval**: operator convenience trade-off (cold start latency vs. idle RAM).

#### Nextcloud Talk: no High-performance backend, no Client Push
- **File**: `services/nextcloud/docker-compose.yml` (or new compose for HPB + push proxy)
- **Problem**: Talk scales only to ~3 participants without an HPB container; Client Push proxy absent → delayed notifications. Currently a low-impact warning; grows if Talk is used.
- **Fix**: Add a Talk HPB container on `net` + the `nextcloud-talk-hpb` image, set `TURN_SERVER` / `SIGNALING_*` env; install `nextcloud_announcements` or a separate push proxy. Both are out-of-scope unless Talk calls become a real use case.

---

## Intended

Behaviours that look like bugs but are deliberate. Do not fix; the rationale is the answer.

### `server.homelab.com` is unresolvable from the public internet
Looks like: DNS lookup fails for `server.homelab.com` outside Tailscale, *or* a `curl` against `https://server.homelab.com/...` (or any path under it: `/share`, `/shell`) from a non-tailnet source times out, returns 403, or connection-refuses — including from the VPS host itself if the host isn't on the tailnet resolver. Reality: this is the only access control — see the access model table in `README.md`. The Caddy `@not_tailnet` matcher requires the `domain` container to be on the host network namespace (`network_mode: host`) so Caddy sees the real source IP — Docker DNAT through the bridge would rewrite it to `172.22.0.1` and break the matcher. **A failed curl is `@not_tailnet` working, not a service outage** — verify from a tailnet device or by SSH'ing in and curling from a tailnet-joined source.

### Cloudflare Bot Fight Mode blocks `curl` against `api.homelab.com`
Looks like: Cloudflare rejects `curl`/scripts hitting `api.homelab.com` with a 403 / challenge. Reality: terminal traffic cannot solve the Browser Integrity Check. The intended fix is a per-hostname WAF rule skip on `api.homelab.com` (and the same mitigation is required for `cloud.homelab.com` desktop sync); the goal is to keep Cloudflare's full protection on everywhere else.

### `share.homelab.com/share`-style paths return `not found` instead of redirecting to `server.homelab.com/share`
Looks like: the link shortener admin UI is unreachable from `share.homelab.com/share`. Reality: the public vhost hides `/share`, `/api/*`, and `/healthz` via a Caddy `@admin` matcher returning 404, because admin has no app-level auth and the public side shouldn't leak its existence. Admin lives at `server.homelab.com/share` (tailnet-only) — see the access model table in `README.md`.

---

## Solved

Resolved items grouped by month. One line per item, aggressively short.

### Jul 2026 — early system build
- **Initial site + Docker** — `index.html`, first `docker-compose.yml`.
- **Caddy setup** — first vhost config.
- **GitHub Actions deploy** — `.github/workflows/deploy.yml` with SSH-key deploys; later retired.
- **AI/LLM API service** — `services/ai/app.py` on a separate network, Ollama-backed; later removed.

### Aug 2026 — Nextcloud, TLS, hardening, ops
- **Nextcloud integration** — first hosted on the VPS, migrated to `app.homelab.com/cloud`, reverted, then linked via PHP-FPM.
- **Nextcloud backend upgrade** — image bump.
- **CoreDNS isolated** — split into its own directory; config renamed.
- **FPM worker regulation** — `zz-custom.conf` added, pool tuning.
- **Container renames** — `domain`, `cloud`, `tailnet` names pinned.
- **Local LLM hosting removed, open resolver fixed, Caddy hardened.**
- **Wildcard cert retired for per-vhost ACME** — every vhost now uses LE DNS-01; the `certs/` dir is no longer mounted.
- **Per-vhost Caddyfiles replace the monolithic Caddyfile** — `vhosts/<host>.caddy` files own their own TLS blocks.
- **Custom Caddy image with `caddy-dns/cloudflare`** — `services/vhosts/Dockerfile` builds `caddy-dns:local` via xcaddy.
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
- **Healthchecks** — domain + cloud healthy.
- **Security headers** — HSTS, X-Content-Type-Options, X-Frame-Options, Referrer-Policy on all vhosts.
- **Claude Code project safety rail** — `config/claude/settings.local.json` (deny-only, AGENTS.md-protected resources + user-data bind mounts) deployed by `make install-config`.
- **Backup + migrate recipes broken as `debian`** — root-owned `/var/www/custom/projects/homelab/` blocked `cp/tar/mkdir` destinations; `bkp-cloud` source was unreachable (`cloud/users` is `770 www-data:www-data`); `migrate` recipe was deleted by `582b789` and only its help line survived. Now: bkp-share/vault/secrets use `sudo` for destinations; bkp-cloud streams via `docker exec cloud tar cf - -C /data . | sudo tar xf -`; `migrate` recipe restored verbatim.
- **Makefile `set -u` foot-gun** — `SHELLFLAGS := -eu -c` with unset `SHELL` ran recipes under `dash -eu`, where `-u` semantics differ from bash; latent crash on any unset var. Fixed: `SHELL := /bin/bash` set explicitly at top; documented in `GUIDE.md` operational gotchas.
- **`bkp-cloud` maintenance trap** — added `trap 'occ maintenance:mode --off' EXIT` so a tar-stream failure can't leave Nextcloud in maintenance mode.
- **`clean` split into `clean-docker` + `clean-apt` + `clean-backups` + `clean-all`** — old `clean` was a hardcoded mix of apt + docker prune; now each is independently runnable; `clean-backups` keeps latest 3 per pattern and prunes older.
- **`bkp-all`** — chains the five backup recipes in order; daily timer now runs `make update` → `make bkp-all` → `make clean-all`.
- **Migrate runbook extracted to `docs/MIGRATE.md`** — `make migrate` now cats the doc instead of echoing ~50 lines inline; prose rewritten per `.md` writing rules (points at executable source, doesn't retype).
- **Makefile** — recipes for up/restart/logs/status/push/backup/clean.
- **Nextcloud overrides env-driven** — `TRUSTED_PROXIES` + `OVERWRITECLIURL` in compose; removed from `config.php`.
- **Deploy/ops helper scripts** — covered by the Makefile recipes.
- **System made fully recoverable** — `bundle-secrets` + `migrate` recipes, README runbook.
- **Reference configs in repo** — Ollama unit + SSH hardening copied under `config/`.
- **Static landing page** — FR, Spotify embed, countdown, styled; served from the static `www` vhost before Homer replaced it.
- **Nextcloud bind mount split** — `cloud/html` (root) + `cloud/users` (datadirectory).
- **`.md` writing rules** — 10 rules added to AGENTS.md; README deduped (328→271 lines).
- **Docs reorganized** — AGENTS.md + ISSUES.md moved to `docs/`; README stays at root.
- **Sensitive files purged from git history** — `config/web/certs/key.pem`, `cert.pem`, `.github/workflows/deploy.yml`, `install.sh`, `app.py` removed via `git filter-repo`; `origin` remote (PAT-embedded) removed; history rewritten, force-pushed.
- **CoreDNS → dnsmasq** — container removed; host dnsmasq on `100.81.245.77:53`.
- **`tailnet_default` gone** — spare bridge removed with the container.
- **URL shortener** — Flask + SQLite; `share.homelab.com` public, `server.homelab.com/share` admin.
- **Nextcloud bind mount fixed** — `datadirectory` moved to `/data`, no nesting.
- **`share.homelab.com` admin leak closed** — Caddy `@admin` matcher returns 404 for `/share`, `/api/*`, `/healthz`, `/` on public vhost; admin still reachable via `server.homelab.com/share`.
- **Cloudflare 100 MB body cap aligned** — all vhosts `max_size 100m` to match CF free-tier; inconsistent 10G on cloud vhost removed.
- **Nextcloud `maintenance_window_start`** — set to `4` (04:00) so heavy background jobs don't run during peak.
- **Nextcloud DB missing indices** — `mail_*` table indices added via `occ db:add-missing-indices`.
- **Nextcloud mimetype migrations** — applied via `occ maintenance:repair --include-expensive`.
- **Nextcloud `TRUSTED_PROXIES` expanded** — added all 15 Cloudflare edge ranges so real client IPs reach Nextcloud.
- **Homer + Uptime Kuma added** — `www.homelab.com` serves Homer (static landing page retired); `kuma.homelab.com` serves Uptime Kuma; both reverse-proxied via Caddy, no published ports.
- **Docs split into four** — `README.md` (visitor), `docs/AGENTS.md` (portable agent rules), `docs/GUIDE.md` (project operator guide), `docs/ISSUES.md` (task tracker + Intended section).
- **Log tightening** — Caddy global `log -> /dev/null` (no per-request access logs); dnsmasq `log-queries` removed; `share` container cap raised to 10m×3 to match the other 5.
- **`server.homelab.com/shell`** — ttyd-backed host shell; bind-mounts `/` rw + Docker socket; container `privileged`, runs as the host path-aware bash from `/var/www/custom/projects/homelab/repo`.
- **`status.homelab.com` → `kuma.homelab.com`** — hostname rename to match the container name; Cloudflare + Caddy + Homer YAML updated.
- **Kuma monitor set trimmed** — `tcp: vps 443` (unreachable from Kuma's netns), `ping: vps` (redundant), `docker: kuma` (self-check) dropped; `docker: *` monitors moved to 3600s; HTTP monitors stay at 60s.
- **Kuma `seed-monitors.sql`** — idempotent SQL for the 9 monitors + 2 groups; applied once via `docker exec -i kuma sqlite3 ... < seed-monitors.sql`.
- **Homer config bind tightened** — bind only `services/homer/config/config.yml` → `/www/assets/config.yml` so the bundled icons/themes/manifest stay intact.
- **Repo relocated** — moved from `/var/www/github/homelab.com` to `/var/www/custom/projects/homelab`; `/var/www/github/` deleted; all compose/Makefile/.md/live-`homelab-daily.sh` paths rewritten; `cloud/html` + `cloud/users` chowned to uid 33.
- **Hostname `vps.homelab.com` → `ops.homelab.com` → `server.homelab.com`** — Caddyfile + dnsmasq + Homer config + 3 .md docs renamed twice; live dnsmasq + Caddy reloaded; vps.homelab.com + ops.homelab.com now unmentioned anywhere.
- **`server.homelab.com/shell` runs as `debian`** — ttyd entrypoint switched from `exec bash` (root in container) to `exec runuser -u debian -- bash`; container also bind-mounts `/etc/passwd` + `/etc/group` so runuser can resolve uid 1000.
- **Homer dashboard expanded** — Files (`share.homelab.com/files`) and Terminal (`server.homelab.com/shell`) added; API added to the top links bar.
- **Terminal `host-exec` shim** — Alpine ttyd container can't run host glibc binaries (`smem`, `sudo`, etc.) directly. Added `/usr/local/bin/host-exec` that `chroot`s to `/host` and runs the command under the host shell. Use `host-exec 'smem'` from inside the ttyd session.
- **`browser` user dropped from sshd, `runner` user deleted** — `AllowUsers debian browser` → `AllowUsers debian`; `userdel -r runner`. Both were unused leftovers; host now has `debian` as the sole human account.
- **Uniform 404 format** — every Caddy-controlled 404 now returns plain text `not found` (no JSON, no HTML). Flask `not_found` handler switched from `jsonify(error=...)` to `Response("not found", mimetype="text/plain")`; cloud `@blocked` matcher now responds with body. Vaultwarden / Homer / Nextcloud 404s left as their own upstream pages.
- **`www.homelab.com` keeps Homer's HTML 404** — explicit operator call: upstream containers with their own 404 page (Homer, Vaultwarden, Nextcloud) keep that page; only Caddy-controlled paths (share, api, ops, cloud `@blocked`) return plain text `not found`.
- **`make` from terminal needs `host-exec`** — the docker compose plugin at `/host/usr/libexec/docker/cli-plugins/docker-compose` is glibc-linked and fails in the Alpine ttyd container with a cryptic `unknown shorthand flag: 'f' in -f`. Run any make recipe via `host-exec 'make ...'` from inside `server.homelab.com/shell` (the Alpine container has since been replaced by a host systemd ttyd, so this is no longer needed but kept for history).
- **Terminal migrated to host systemd ttyd** — `services/terminal/` removed; `ttyd.service` runs as `debian` on the host, binds `172.22.0.1:7681` (not `0.0.0.0`), gated by Caddy `@not_tailnet` + UFW INPUT allow from the `net` bridge. Caddy proxies to `172.22.0.1:7681` with `transport http { versions 1.1 }`. `host-exec` / `runuser` shims are gone — the shell is a real host shell directly.
- **Hostname `vps-742a45f9` → `server`** — system hostname + `/etc/hosts` updated; SSH host keys regenerated so the old `root@vps-742a45f9` comment is gone from the `.pub` files; cloud-init stale state (`/var/lib/cloud/data/{previous,set}-hostname`) deleted.
- **`debian` has passwordless sudo** — `/etc/sudoers.d/debian-passwordless` (`NOPASSWD:ALL`, mode 0440). Reduces permission prompts during normal agent operations; still requires sudo for anything privileged.
- **Claude Code allow-list curated + backed up** — `.claude/settings.local.json` is gitignored (per-operator); tracked template lives at `config/claude/settings.local.json`; `make install-config` deploys it. Allow-list covers ollama/maintenance commands; destructive ops still prompt. Later superseded by the project-level deny-only safety rail (see Claude Code project safety rail).
- **ttyd hardening removed** — `ProtectSystem`, `PrivateTmp`, `MemoryDenyWriteExecute`, `PrivateDevices`, `RestrictAddressFamilies`, `LockPersonality`, `RestrictRealtime`, `ProtectControlGroups` all stripped from `ttyd.service` (operator preference: no permission hunts); access control stays at Tailscale + `Caddy @not_tailnet`.
- **Minecraft server** — Paper + Geyser/Floodgate at `mc.homelab.com` (Java `:25565`, Bedrock `:19132`); tailnet-only tabbed Flask+rcon dashboard at `server.homelab.com/mc` (Status / Console / Players / Settings / Files / World; 2 s polling; per-player stats + actions; file browser + YAML editor; world download/upload/regenerate). World data bind-mounted under `$(REPO)/mc/data`; world backups at `$(REPO)/backups/mc-backup-<date>.tar.gz` (`make bkp-mc`).
- **Minecraft dashboard TPS fixed** — rcon was calling `/debug` (vanilla JFR profiler, no TPS section), so the regex never matched and the card rendered `—`. Now calls `/tps` and strips `§X` color codes from the response before regex.
- **Minecraft dashboard deprecated fields removed** — `pvp` (vanilla 1.21.2+), `spawn-protection` (Paper ignores enforcement since 1.16.5), `enable-command-block` (canonical toggle moved to `paper-world-defaults.yml → gameplay.allow-command-blocks` in Paper 1.19+). Added `enforce-whitelist` (complementary to `white-list`).
- **Minecraft container IP drift fixed** — `mc` and `mc-web` pinned to `172.22.0.7` and `172.22.0.8` via `networks.net.ipv4_address`; Caddy `@mc` upstream (`172.22.0.8:5000`) stays valid across recreates. Same pinning applied to the other 5 upstreams (homer `.2`, share `.3`, vault `.4`, cloud `.5`, kuma `.6`) so no recreate can drift a Caddy upstream.
- **Minecraft dashboard form actions broken** — template posted to `/control` `/rcon` `/config` (no `/mc` prefix); routes live at `/mc/*` because Caddy doesn't strip. All three forms were 404s. Fixed to `/mc/control` `/mc/rcon` `/mc/config`.
- **Minecraft config save 500 (read-only bind)** — `mc-web` mounted the game data dir `:ro`; dashboard's `write_properties()` couldn't persist. Changed to `:rw` (dashboard only writes `server.properties`; game data still owned by the game container).
- **Transient `Connection refused` rcon error silenced** — Paper's rcon listener binds late in startup (after the compose healthcheck on the Java port already marked the container healthy). For the few-second window, the dashboard surfaced `rcon: [Errno 111] Connection refused`. Now caught and treated as "starting", with no error message; the cards just show `—` until rcon comes up.
- **Minecraft dashboard redesigned** — Aternos-style tabs (Status / Console / Players / Settings / Files / World), 2 s polling for live state (no page reloads), per-player actions (kick/ban/op/whitelist/gamemode) wired through rcon, per-player stats parsed from `/world/players/stats/<uuid>.json`, file browser with safe upload + Paper/Bukkit/Spigot YAML editor, world tar-stream download + zip upload + backup-and-regenerate flow. `make bkp-mc` tars the world folder; `bkp-all` chains it; `daily.sh` stops the game container before `bkp-all` and restarts it after, so the world tar is quiescent. All routes still under `/mc/`.
- **Minecraft uptime stat showed stale value when server was stopped** — `docker inspect State.StartedAt` preserves the last start time even when the container is stopped, so the uptime card kept ticking down from the previous start until the operator restarted manually. Guarded the uptime computation on `running`; offline now correctly renders `—`.
- **Minecraft `booting` status + rcon-listener-anchored uptime** — status now reports `booting` (gold pill) until the first `[Server thread/INFO]: Thread RCON Listener started` line appears in `latest.log` for the current session (matched against the container `StartedAt` to skip previous sessions' lines that may still sit in `latest.log`). Uptime is anchored to that moment instead of container `StartedAt`, so Paper's startup time is excluded from the count.
- **Minecraft uptime reset after restart** — when the game container restarted while `mc-web` stayed up, the `_rcon_ready_cache` would fall back to the previous session's client-connect line (newer `latest.log` lines for the current session weren't being matched) and report uptime from the wrong moment. Fixed by switching the trigger to Paper's once-per-JVM `[Server thread/INFO]: Thread RCON Listener started` line AND validating the `[bootstrap]` line's HH:MM:SS against the container `StartedAt` so older session lines on disk are ignored until Paper actually logs a fresh session.
- **Minecraft dashboard settings search** — `server.properties` table now has a `Filter fields…` search bar that runs a case-insensitive substring match on the field name; hidden rows remain in the DOM so Save still iterates every input the API expects.
- **Dashboard prunes world backups after each snapshot** — `/mc/api/world/backup` and `/mc/api/world/regenerate` now silently call `_prune_mc_backups()` after the tar succeeds, mirroring the host-side `make clean-backups` policy (keep latest 3 `mc-backup-*.tar.gz`, delete older by mtime). The dashboard reimplements the rotation in Python rather than shelling out to `make` (mc-web has no make binary or sudo) — both writers now drop old files from the same `$(REPO)/backups/` directory without stepping on each other. Prune failures are isolated (logged to stderr) so they can never break a successful snapshot.
- **Dashboard `container not found: 404` on `/mc/api/control` was a misleading 500** — when the `mc` container is absent (not yet provisioned, recreated while stopped, or pruned) the Docker SDK raises `docker.errors.NotFound` from `containers.get(CONTAINER)`, which `container_action` was re-raising as `f"container not found: {e}"` (the raw 404 traceback). The endpoint then returned 500 with a wall of HTTPError text that looked like a bug. Now `container_action` catches `NotFound` separately and returns a friendly message ("`mc container is not running (was it recreated while stopped?)`"); other lookup errors still pass through. The 500 status code stays (the operator action did fail) but the body is actionable.
- **Game container renamed `mc` → `mc-server`** — the game container's `container_name: mc` predated the compose-file split and overlapped awkwardly with the `mc` service key in `services/mc/docker-compose.yml` (now only the game) and the sibling `mc-web` compose. Renamed the game container to `mc-server` to mirror `mc-web` and match the GUIDE.md service-reference table. `app.py` defaults `CONTAINER=mc-server` + `RCON_HOST=mc-server`; `services/mc/docker-compose.mc-web.yml` sets `RCON_HOST: mc-server`; `config/maintenance/daily.sh` now `docker stop/start mc-server`. The Makefile keys stay `mc`/`mc-web` (they're recipe labels, not container names).
- **Booting status stuck `true` when Paper logged bootstrap after Docker's StartedAt** — the previous `_rcon_ready_since()` fix demanded the `[bootstrap]` line's HH:MM:SS equal the container's `State.StartedAt` HH:MM:SS to identify the current session, but Paper's JVM can take anywhere from ~1 s to ~30 s after Docker records StartedAt before it writes the first `[bootstrap]` line (depends on image init + Java startup). When the gap was > 1 s the comparison failed and `booting` stayed true forever. New logic drops the bootstrap-anchor approach: find the latest `[Server thread/INFO]: Thread RCON Listener started` line and trust it iff its timestamp is after `StartedAt` (a listener line with a pre-start timestamp must be residue from a previous session). Removes the brittle same-second equality check while keeping the session-boundary guard.
- **Font showcase page at `/mc/fonts`** — temporary comparison page letting the operator preview pixel-font candidates (Press Start 2P, VT323, Silkscreen, Pixelify Sans, Major Mono Display, Minecraft Seven) at the sizes the dashboard actually renders them, on dark + light swatches, before committing to a swap. Delete once the chosen font pair is locked in.
- **Minecraft dashboard Bedrock-style redesign** — full visual overhaul on top of the Aternos-style structure: Press Start 2P for headings/buttons/pills, VT323 for body/logs; 3D beveled block primitives (hard 90° corners, no smoothing, instant state changes); chunky stone-knob sliders; color-coded emphasis cards — `.nether` (obsidian + lava edges) wraps Container actions and the Regenerate zone; `.end` (end-stone + purple headings) wraps the Backups list and the Player Roster. Status Server card is full-width above the stat grid. Google Fonts CDN for the pixel fonts (already allowed by Caddy's default CSP).
- **Boot window forces every stat to `—`** — while the server is in the `booting` state (container running, rcon listener not yet ready), the dashboard JS now renders all stats as `—` regardless of what `/mc/api/stats` returns. The API already returns nulls during this window, but the client-side guard ensures a stale value (e.g. if a poll races with the boot transition) never leaks through to the card. Header bar matches: Players shows `— / —`, TPS shows `—`.
- **World backup/download endpoints used a host path that didn't exist inside the container** — `HOST_BACKUP_DIR` and `HOST_WORLD_SOURCE` pointed at `/var/www/custom/projects/homelab/...` on the host, but the dashboard bind mount only exposes `/server` (= `/var/www/custom/projects/homelab/mc/data`), so every world op returned 404 "world directory not found". Replaced with `BACKUP_DIR = /server/.backups` (a sibling of `world/` inside the existing bind mount, auto-created at import time). Also dropped `sudo` from the tar/chown calls (the dashboard runs as root inside the container; `sudo` wasn't installed). Aligned the dashboard JS download link with the existing query-param endpoint.
- **Fonts self-hosted to fix Safari ITP cross-origin block** — Safari (and Firefox with strict ETP) silently blocks Google Fonts CSS that crosses an opaque-proxy boundary, leaving the page in the fallback `monospace`. Downloaded latin-subset .woff2 files for Press Start 2P, VT323, Silkscreen (400/700), Pixelify Sans (variable, single file covers 400/500/700), and Major Mono Display into `content/minecraft/static/fonts/`. Replaced the `<link rel="stylesheet">` on both the dashboard and `/mc/fonts` with `@font-face` declarations pointing at `/mc/static/fonts/*.woff2`. Same-origin → no ITP issue, no third-party CDN. `static_url_path='/mc/static'` set on the Flask app because Caddy's `@mc path` matches `/mc/*` without stripping the prefix.
- **`mc.homelab.com` now serves a LE cert via DNS-01 ACME** — every vhost now uses LE DNS-01 via the `caddy-dns/cloudflare` plugin (token in `CF_API_TOKEN`). Wildcard cert retired (it was SNI-blocking the per-vhost automation policy).
- **Per-vhost Caddyfiles replace the monolithic Caddyfile** — `vhosts/<host>.caddy` files own their own TLS blocks; the top-level `Caddyfile` only carries snippets + global options + imports.
- **Custom Caddy image is rebuilt by `make recreate-vhosts`** — `services/vhosts/Dockerfile` builds `caddy-dns:local` via xcaddy (Go 1.25 + commit `a8737d0` of caddy-dns/cloudflare, which relaxed the API token regex from `{35,50}` to accept the new 53-char CF token format).
- **Renamed six container names for clarity** — `vault` → `vaultwarden`, `cloud` → `nextcloud`, `share` → `share-flask`, `kuma` → `ut-kuma`, `domain` → `vhosts`, `mc-web` → `mc-flask`. Compose `container_name:` fields, Makefile `CONTAINERS` list (recipe labels follow: `make recreate-cloud` is now `make recreate-nextcloud` etc.), `bkp-cloud` recipe's `docker exec cloud` → `docker exec nextcloud`, Claude Code deny rules (`Bash(docker exec cloud ...)` → `Bash(docker exec nextcloud ...)`), `services/ut-kuma/seed-monitors.sql` comments, and `docs/{GUIDE,AGENTS}.md` + `README.md` all updated. Caddy vhosts are unaffected: every upstream is a pinned bridge IP (`172.22.0.X:port`), not a container name. The `mc-web` compose file is renamed `services/mc/docker-compose.mc-flask.yml` to match the new recipe key (the other five keeps their `services/<ctn>/docker-compose.yml` paths; the directory name still conveys the service). Image registry tags and vhost hostnames stay.
- **`scripts/install.sh` new-VPS installer** — plug-and-play: prompts domain / CF token / TS authkey, then unattended (host services, docker, tailscale, 4 containers, CF DNS records, certs, Kuma seed); renames `vhosts`→`$DOMAIN`, `debian`→`op`, `server.`→`shell.` on the new host's clone.
- **Kuma `seed-monitors.sql` stale container names** — `docker: domain`/`cloud`/`share`/`vault` rows referenced pre-rename container names; fixed to `vhosts`/`nextcloud`/`share-flask`/`vaultwarden` (the installer rewrites them again for the 4-container set).
- **SSH: root login re-enabled key-only** — `PermitRootLogin prohibit-password`, `AllowUsers debian root` (installer writes `op root`); root and op both SSH in with keys automatically; GUIDE.md SSH section updated.

---

## Lessons learned (cert debug trail)

These are facts that were non-obvious during the `mc.homelab.com` cert fix and only surfaced by grepping the repo. They're documented here so a future agent doesn't have to re-discover them. See `docs/GUIDE.md` § Operational gotchas for the operational checklist.

- **A vhost with no `tls` directive does not "use ACME by default" — it picks up any loaded cert that matches the SNI.** The `mc.homelab.com` vhost had no `tls` directive, intended to fall through to ACME, but Caddy served the wildcard `*.homelab.com` CF Origin cert as a SNI fallback. The automation policy never had a reason to fire because the wildcard cert was always available. Symptom: `mc.homelab.com` returned 200 OK from the first hit, but the cert issuer was `CloudFlare Origin CA`, not `Let's Encrypt`. To confirm ACME is actually firing, check the issuer on a fresh TLS handshake (`echo | openssl s_client -connect mc.homelab.com:443 -servername mc.homelab.com | openssl x509 -noout -issuer`) — not the HTTP response code.
- **Caddy stock `caddy:2.x` images do not include the `caddy-dns/cloudflare` plugin.** Symptom: `module not registered: dns.providers.cloudflare` on container startup. Fix: build a custom image with `xcaddy build --with github.com/caddy-dns/cloudflare@<commit>` (see `services/vhosts/Dockerfile`). The `caddy` Docker Hub image only includes the core modules plus the conventional ACME issuer.
- **The `caddy-dns/cloudflare` v0.2.3 tagged release rejects the new 53-char CF API tokens** with a confusing "API token ... appears invalid; ensure it's correctly entered and not wrapped in braces nor quotes" error. The provider's regex is `^[A-Za-z0-9_-]{35,50}$` (40–50 character token range) — the new CF tokens are 53 chars. PR #123 on `caddy-dns/cloudflare` relaxed the regex; pull from `a8737d0` (master) until a tagged release lands.
- **`caddy:2.11.4` requires Go ≥ 1.25.1 to build.** The `golang:1.25-bookworm` image satisfies this. Older builder images (`golang:1.24-bookworm` and earlier) fail with `go: github.com/caddyserver/caddy/v2@v2.11.4 requires go >= 1.25.1`. If you bump Caddy later, check the `go` directive in `caddy/v2/go.mod` and bump the builder image accordingly.
- **The cert's issuer is the only reliable indicator of which path it took.** When debugging Caddy TLS, `curl -sk` returning 200 means "the listener responded" — not "the right cert was served." Always check `openssl x509 -noout -issuer` on a fresh `-no-keepalive` request. The CF Origin CA cert, the LE cert, and the staging LE cert all return 200 to `curl`; only the issuer tells you which path served it.
- **The `mc.homelab.com` vhost is the only one that *had* to use DNS-01** — the game ports (25565 Java, 19132 Bedrock) are published directly on the VPS and bypass the CF proxy at the port layer, so `mc.homelab.com` is DNS-only at CF. Turning the CF proxy on would break the game ports. The other vhosts use DNS-01 now too for consistency, but HTTP-01 would have worked for them.
- **`network_mode: host` is required for `@not_tailnet` to work** — Caddy needs to see the real client source IP, and Docker DNAT on the bridge network rewrites every packet to `172.22.0.1` (the gateway). Without `network_mode: host`, the `100.64.0.0/10` matcher matches nothing and every tailnet request gets 403. This is set in `services/vhosts/docker-compose.yml` — do not "fix" it by removing the `hosts: network_mode`.
- **The CF API token file at `$(REPO)/caddy_data/CF_API_TOKEN` is the only thing the operator needs to migrate to a new VPS** — Caddy renews certs from the token, so transferring it skips the 0–90-day issuance window. The token file is not in `bundle-secrets` (Caddy regenerates the certs from the token on the new host, so off-VPS cert copies aren't needed). The `bundle-secrets` recipe was reduced to drop the retired `$(REPO)/certs` reference.
- **The Caddy data dir lives at `$(REPO)/caddy_data/`, OUTSIDE the repo, and `git status` will never mention it** — surprising because every other secret in this project (`services/nextcloud/.env`, the Vaultwarden admin token, etc.) sits inside `services/<ctn>/.env` and shows up under `git status` as a tracked-or-ignored file. Caddy's is the opposite: it lives one directory above the project root, is never tracked, never ignored, and is invisible to `git` until you specifically `ls /var/www/custom/projects/homelab/`. A grep for `CF_API_TOKEN` across `repo/services/` returns nothing — the env wiring happens entirely via the `env_file:` directive in `services/vhosts/docker-compose.yml`.
- **`docker compose env_file:` reads the file as the UID running `make recreate-domain`, NOT as the UID inside the container** — surprising because most Docker env handling happens at container start. Compose parses `env_file:` at the host side and injects the variables into the container spec; the file just needs to be readable by the user running the compose command (the `debian` user via `make`, NOT uid 201 inside the Caddy container). `chown 201:201` on the file actually breaks the read for `make` and Caddy ends up with no token — the right ownership is `debian:debian` mode 0644. Discovered when `chown 201:201` (matching the persistent `/data` dir) silently left Caddy unable to read the token at first hit.
- **Caddy's `import` directive resolves relative paths against the *containing file's directory*, not the process working dir** — surprising because `import vhosts/server.homelab.com.caddy` "looks like" a relative path from `/etc/caddy` but only works if the file lives at `/etc/caddy/vhosts/server.homelab.com.caddy`. The compose file mounts `./` to `/etc/caddy:ro` (not `./Caddyfile`) precisely so the imports resolve. Mounting only the Caddyfile leaves every `import` failing with `File to import not found`.
- **`make recreate-domain` (or `make recreate-all`) takes ~3 minutes on a fresh VPS and prints zero progress** — `docker compose up --build` runs `docker build` in a streaming-tty mode that buffers until the step finishes, so a future agent on a cold cache will think the command hung. The actual build chain is `golang:1.25-bookworm` → `go install xcaddy` → `xcaddy build --with caddy-dns/cloudflare@a8737d0 v2.11.4` → `FROM caddy:2.11.4` + `COPY --from=builder`. Each step is fast but they queue. `docker build --progress=plain` or `docker compose build --progress=plain` shows the steps; the default JSON-progress mode swallows them.
- **The wildcard CF Origin cert covered `*.homelab.com` AND `homelab.com` (the apex)** — surprising because the operator's mental model was "wildcard covers subdomains" but CF Origin wildcard certs actually include both the apex and the wildcard SAN. This is *why* the cert was being served as SNI fallback for `mc.homelab.com`: the wildcard matched. And it meant `curl https://homelab.com/` also returned the wildcard cert (no untrusted-CA warning on the apex), masking the fact that the apex had no per-vhost ACME policy either — only `mc.homelab.com` was being debugged because the user noticed the warning there.
- **The CF API token uses the new `cfut_*` scoped format (53 chars), not the legacy `v1.0-...` format** — and the caddy-dns/cloudflare plugin's regex specifically checks length. The `v0.2.3` tag's regex is `^[A-Za-z0-9_-]{35,50}$`; new tokens are 53 chars; the plugin's provisioning step rejects with a generic "API token ... appears invalid" error that doesn't mention length. The plugin still accepts the 40-char legacy tokens, so this only bites operators who've migrated to the new scoped tokens (which is everyone on the CF dashboard as of 2024+).
- **Caddy stores per-vhost ACME certs at `/data/caddy/acme/<directory>/<host>.crt` after the first issuance** — surprising because the `/data` volume is bind-mounted at `$(REPO)/caddy_data/` (mode 201:201), so the cert files on the host are owned by uid 201. They look like "garbage" in an `ls -l` if you don't know to expect that — but that's correct: it's the same uid as the `/data` mount point inside the container.
- **CF proxy mode and the "DNS-only" toggle live at the zone level in Cloudflare's dashboard, not in the zone's DNS records themselves** — surprising because the dashboard UI looks like a per-record toggle. The actual control is the orange/grey cloud icon next to each record; flipping it on a `mc.homelab.com` A record puts just that one hostname behind the proxy. Flipping the proxy for `mc.homelab.com` would break the game ports because the game ports (25565/19132) are published directly on the VPS, not on Cloudflare's edge.
- **`docker compose env_file:` paths are host-absolute, not container-relative** — `env_file: /var/www/custom/projects/homelab/caddy_data/CF_API_TOKEN` is a host path (the compose parser reads it on the host before passing the variables into the container spec). It looks like a path "inside the container" because env vars are usually a container concept, but `env_file:` is host-side. A relative `env_file: ./CF_API_TOKEN` would resolve against the compose file's directory on the host, not against `/etc/caddy` inside the container.
- **The `net` Docker network must be created with an explicit `--subnet=172.22.0.0/16`** — `docker network create net` (what `docs/MIGRATE.md` and `docs/GUIDE.md` said before Aug 2026) creates the default `172.18.0.0/16` range; the compose files' pinned `ipv4_address: 172.22.0.x` then fail to attach with a subnet error on the first `make recreate-*`. The gateway `172.22.0.1` is also what ttyd binds and what the UFW ttyd rule allows — the whole scheme depends on the subnet.
- **`ls -1 <dir>` returns 0 lines, not the directory's contents** — surprising because `ls -1d <dir>` returns exactly one line (the dir name) and `ls -1 <dir>/` returns the contents. Bare `ls -1 <dir>` is a listing of the *target* (the directory itself), which is one entry but `ls` formats it without a newline when the target is a directory path, so `wc -l` counts 0. Symptom in this repo: `make bkp-list` counted `cloud-backup-*` as 0 even though `cloud-backup-20260821/` was sitting on disk. Fix: use `ls -1d <glob>` in any "count matching entries" loop — `-d` lists directory entries without descending, so the count equals the match count regardless of file/dir.
