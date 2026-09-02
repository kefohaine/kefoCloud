# Known issues and improvements

Tracked for follow-up. Items marked **[needs human approval]** require a decision or credential from the operator before an agent should act. Behaviours that look like bugs but are deliberate design choices are documented as rationale in `docs/GUIDE.md` — do not "fix" them. Resolved items are recorded under `#### install.sh hardcodes `admin@fxmq.net` for the PufferPanel admin  **[generalization drift]**
- **File**: `scripts/install.sh` (panel_admin seed + smoke recheck)
- **Problem**: rule 12 (stay global) — the panel admin email is hardcoded to `fxmq.net` while the rest of install.sh is `$DOMAIN`-driven; a fresh install for another domain still seeds an `@fxmq.net` admin, and `scripts/smoke-vhosts.sh` asserts it.
- **Fix**: derive the admin email from `$DOMAIN` (or accept fxmq.net as canonical and document it in GUIDE); needs an operator decision on whether the panel admin domain may ever differ.

## Solved`, one sentence each.

---

## Open

### Pending (Aug 2026)

#### Kuma config copy from the jehpok VPS is blocked  **[needs human approval]**
- **File**: `scripts/kuma-import.sh` (prepared); source db on `jehpok` (100.81.245.77)
- **Problem**: SSH to `jehpok` denies every key tried from fxmq (`root`/`op`/`debian`, incl. `github_key`), Tailscale SSH is not enabled there, and its Taildrop inbox is empty — the old `kuma.db` cannot be fetched. The operator's Mac is also blocked: jehpok's ED25519 host key changed (`REMOTE HOST IDENTIFICATION HAS CHANGED`, new fingerprint `SHA256:o0MmsggDn/Hi2LiThbkSLlLGUadoQfEKi0NBvmFb61k`) — likely the VPS was reinstalled. kuma.fxmq.net currently has the seeded admin (password reset Aug 2026, see `kuma/admin-pass.txt`) + 4 monitors but not the old account/status pages.
- **Fix**: on the Mac run `ssh-keygen -R 100.81.245.77` (clears the stale host key), then `ssh debian@100.81.245.77` — if the box was reinstalled the old key may no longer be authorized; re-add it. Deliver the db either by taildrop from jehpok (`tailscale file cp kuma.db fxmq:`, then on fxmq `tailscale file get /var/www/custom/projects/homelab/kuma/import`) or by adding the fxmq `op` SSH key to jehpok's `authorized_keys`. Then `make kuma-import` swaps it in, adapts it (jehpok.com→fxmq.net URLs, old container names, deactivates retired-service monitors) and re-seeds the current monitor set.

### Robustness

#### Undocumented host process: `node server/server.js` (dumb-init "extra")
- **File**: host (not in repo) — `ps` shows `dumb-init -- extra` (PID 51742) → `node server/server.js` (PID 51776, up since Aug 24, ~170 MB RSS, cwd `/`)
- **Problem**: matches no compose file, systemd unit, or script in the repo; purpose unknown. Not touched by any agent task.
- **Fix**: ask the operator what it is; document it in `docs/GUIDE.md` or remove it if stale.

#### Browser 1.12.2 server: effective view-distance is 6, not the tuned 4  **[needs human approval]**
- **File**: `puffer/data/servers/07fd7727/spigot.yml` (`world-settings.default.view-distance: 6`) + `server.properties` (`view-distance=4`)
- **Problem**: the 2026-08-31 tuning set `view-distance=4` in server.properties, but Spigot's per-world `world-settings.default.view-distance: 6` overrides it — the server boots with "View Distance: 6" for all three worlds, so the intended 4-chunk render/tick distance never took effect (1.12.2 has no separate sim-distance, so this also widens entity ticking).
- **Fix**: operator decision — either set spigot.yml `world-settings.default.view-distance: 4` (matches the tuning intent) or accept 6 and update the docs. Requires a server restart (spigot.yml is read at world load).

#### Storage VPS onboarded (Setup A) — files on Garage, DB stays on fxmq
- **File**: `scripts/storage.sh` + storage VPS (1 TB / 2 GB, tailnet-only)
- **Problem**: the 1 TB / 2 GB storage VPS was meant for a DB relocation; Setup A was chosen instead: PostgreSQL stays on fxmq (11 GB RAM, DB latency local), the 1 TB box serves Nextcloud's user files.
- **Status — SUPERSEDED (2026-09-01)**: the Garage/object-store path was abandoned (filecache corruption) and replaced. `scripts/storage.sh` is now an **NFS live-datadirectory tool**: it mounts the storage VPS's export at the NC datadirectory (`cloud/users`) over the tailnet, rsyncs the data over, prompts for the allocation size (validated against available disk) and whether to delete the local copies, and prints install.sh-style error tables + manual steps. Garage remains installed on storage (bucket holds orphaned blobs — harmless; remove with `docker rm -f garage` if unwanted). The nightly `pg_dump` → `storage:/backups/nc` coexists (backups, not the box's primary role).
- **Residual**: the NFS migration has NOT been run yet (files still local on fxmq); run `make storage` from the NC host when ready. The 2026-09-01 reset (fresh install, recovery manifests) stands as the current working state.

#### Nextcloud reset (2026-09-01) — fresh install, recovery manifests
- **File**: `config/nextcloud/{users,apps}.txt` (recovery manifests) + `scripts/install.sh` `nextcloud_setup`
- **Problem**: the object-store migration corrupted the filecache repeatedly (blobs keyed `urn:oid:<fileid>`, scans trashing files, storage-switch SQL idempotency bugs). The instance held only default skeleton files, so it was erased and freshly installed: `cloud/users`, `pgdata` and `config.php` deleted, PostgreSQL recreated **on fxmq** (local latency — the storage VPS is for files/backups, not the DB), `occ maintenance:install` run, then the recovery applied.
- **Done (2026-09-01)**: fresh NC 34.0.3 on the local PG; `trusted_domains` + `cloud.fxmq.net` (occ install only trusts localhost — added to `install.sh`); users `admin`/`sunny`/`niyaz25` recreated from `config/nextcloud/users.txt` (new generated passwords for sunny/niyaz25 — printed once; share them with the users); apps `spreed`/`calendar`/`contacts`/`mail`/`notes` re-enabled, `app_api` disabled; occ config re-applied (trusted_proxies array, mail SMTP, serverid, maintenance window 4, cron mode, Talk signaling + TURN); quota admin 300 GB. Smoke passes. The recovery path is now scripted — a fresh install reproduces the exact setup (users, apps, config) without the data.
- **Residual**: sunny/niyaz25 passwords are new (reset); nothing else lost (data was skeleton-only).

#### No automated backup script (partial — DB side solved)
- **File**: (missing) `scripts/backup.sh`
- **Problem**: `make backup` tars Nextcloud `/data` in maintenance mode; there was no consistent PostgreSQL snapshot and no off-site copy target. Since 2026-08-31 the DB side is covered: `scripts/storage.sh` installs a nightly cron that `pg_dump`s the `postgresql` container and pushes it to `storage:/backups/nc` (key auth, keeps 7). The FILE side: user files live in the Garage bucket on storage (their primary home) plus the untouched local copies under `cloud/users/` — but there is no off-site/DR copy of the bucket or a second location for the local copies.
- **Fix**: add `scripts/backup.sh` (or extend the cron): `occ maintenance:mode --on` → `pg_dump` (already nightly) + rsync of the Garage bucket (`/var/lib/garage/data` on storage) to a second target, and/or rsync `cloud/users` while the local copies still exist → `--off`.
- **Why approval**: operator picks the file-backup target (second disk / another provider / off-site).

#### Nextcloud password policy re-enabled + hardened  (resolved 2026-09-01)
- **File**: NC app `password_policy`
- **Done**: the app was briefly disabled so the operator could log in with the temporary password `silence`; re-enabled and hardened the same day — `minLength=16` (the app reads `minLength`, not `minimumLength`), upper+lower+special+numeric required, the 1M common-password list + compromised-list checks on. The operator has since set a proper admin password.

#### GUIDE "Nextcloud DB" migration steps contradict ISSUES Setup A
- **File**: `docs/GUIDE.md` (Nextcloud DB section) vs `docs/ISSUES.md` "Storage VPS onboarded (Setup A)"
- **Problem**: Setup A (2026-09-01) keeps PostgreSQL on fxmq and moves only Nextcloud's user files to the 1 TB VPS, but the GUIDE section still documents moving the whole DB there "when it joins the tailnet" — and it has already joined (nightly `pg_dump` lands on it). One of the two is the plan.
- **Fix**: operator decision — delete the DB-migration steps from GUIDE (Setup A won) or re-document them as the option if the DB ever outgrows fxmq.

### Security

#### Mail platform: no PTR record (operator will set at AlphaVPS)  **[needs human approval]**
- **File**: `services/mailserver/docker-compose.yml` (installed); DNS + UFW configured
- **Problem**: inbound TCP 25 is now open (verified 2026-08-28: external nodes connect, postfix serves `220 mail.fxmq.net ESMTP` with the LE cert). The remaining blocker: 82.118.230.117 has **no PTR** — outbound mail to Gmail/Outlook will be rejected or spam-foldered until reverse DNS exists. The reverse zone is provider-hosted, not delegated to us, so only the operator can set it.
- **Fix** (operator, ~2 min): provider is **AlphaVPS** (netname `DAGroup`, RIPE `AA29428-RIPE`, block `82.118.230.0/24`). In the AlphaVPS client area (VPS → rDNS/Reverse DNS) set `82.118.230.117` → `mail.fxmq.net`, or ticket `support@alphavps.bg` / `abuse@alphavps.bg` with: *"Please set reverse DNS for 82.118.230.117 to `mail.fxmq.net`."* Must match postfix HELO + the `mail.fxmq.net` A record (both already `mail.fxmq.net`). Verify with `dig -x 82.118.230.117`, then send a test to an external inbox.

#### Nextcloud admin password was in git history  **[needs human approval]**
- **File**: `services/nextcloud/.env` (removed from the git index 2026-08-28; file stays on disk, gitignored)
- **Problem**: the Nextcloud admin password was committed to the repo. It is now untracked and future changes are gitignored, but the value remains in git history — if the GitHub repo is or was public, the password is exposed.
- **Fix**: operator decision — rotate the Nextcloud admin password (`occ user:resetpassword admin`, update `services/nextcloud/.env`), and if the repo is public, purge history or treat the password as compromised.

#### Tailscale tailnet has 2 stale devices  **[needs human approval]**
- **File**: Tailscale admin console (outside repo)
- **Problem**: `kaliusb` (linux, 18d offline) and `iosphone` (iOS, 6h offline) are still registered in the tailnet. `kaliusb` is a Kali USB stick — likely a forensic / on-demand tool, not a daily driver. Stale devices widen the ACL blast radius.
- **Fix**: In Tailscale admin console, remove `kaliusb` and `iosphone`. Or rename and tag if they are still in active use.
- **Why approval**: outside the repo; operator must decide which devices stay.

#### `tail.fxmq.net` has no auth beyond Tailscale membership  **[needs human approval]**
- **File**: `services/fxmq.net/vhosts/tail.fxmq.net.caddy`
- **Problem**: Any tailnet device can reach `tail.fxmq.net` with no authentication. DNS-obscurity is the only access control — the host ttyd shell at `/ttyd` (a host systemd unit running as `op` with full host control) sits behind `@not_tailnet` and nothing else.
- **Fix**: Add Caddy `basic_auth` on the vhost (needs a username + bcrypt hash from the operator), or apply Tailscale ACLs in the admin console to restrict who can reach the VPS at all.
- **Why approval**: requires a password / ACL policy from the operator.

#### `tail.fxmq.net` gives an `op` shell to any tailnet device  **[needs human approval]**
- **File**: `services/fxmq.net/vhosts/tail.fxmq.net.caddy`
- **Problem**: ttyd (a host systemd unit) serves a full `op` shell at `/ttyd` — the process is on the host, not in a container, so `sudo -i` reaches root and every host file is writable (the root itself is a plain `ok` page). The systemd unit has no filesystem sandbox (all `ProtectSystem`, `PrivateTmp`, etc. directives stripped — operator preference: no permission hunts). Tailscale membership alone gates it.
- **Fix**: Add Caddy `basic_auth` on the vhost (needs a username + bcrypt hash), or apply Tailscale ACLs to restrict which devices can reach the VPS, or restrict the container with `cap_drop` + a read-only root mount + a write whitelist.
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

#### Nextcloud 2FA not enforced  **[needs human approval]**
- **File**: `services/nextcloud/docker-compose.yml` (app config via `occ`)
- **Problem**: the setup check reports second-factor providers are available but two-factor authentication is not enforced — any stolen password alone grants access.
- **Fix**: operator sets up a 2FA provider on their account (TOTP app), then `occ twofactorauth:enforce admin` (or `--all` for every user). Enforcing before the provider is configured can lock the account out.
- **Why approval**: operator's own account; lockout risk.

#### Nextcloud default phone region not set  **[needs human approval]**
- **File**: app config via `occ`
- **Problem**: `default_phone_region` is unset — profile phone numbers without a country code can't be validated (setup check warns).
- **Fix**: `occ config:system:set default_phone_region --value <ISO-3166-1-ALPHA-2>` (e.g. `DE`, `FR`) — the operator picks their country code.
- **Why approval**: operator-specific value.

#### Re-apply Cloudflare WAF skip on the new domain
- **File**: Cloudflare dashboard (fxmq.net zone)
- **Problem**: after the migration, `cloud.fxmq.net` Nextcloud desktop sync is bot-challenged until the per-hostname WAF rule skip is re-created (same rationale as the `cloud.fxmq.net` `Intended` entry).
- **Fix**: re-add the per-hostname WAF rule skip for `cloud.fxmq.net` after `scripts/install.sh` finishes.

#### Bedrock skins invisible to Java clients (Geyser 1228 / Floodgate b140 upstream bug)  **[needs human approval]**
- **File**: upstream Geyser/Floodgate; local workaround = plugin drop
- **Problem**: Java players see a default skin for Bedrock players despite classic skin + online mode + healthy skin service — a known upstream regression in exactly these builds (GeyserMC/Geyser #6659, #6574).
- **Fix**: drop the **Bedrock Skin Restorer** plugin (`https://modrinth.com/plugin/bedrock-skin-restorer`) into `plugins/` (works per issue #6659 reporter, same builds), or bump Geyser/Floodgate once upstream ships a fix; needs a players-off restart. Add the jar to the GUIDE plugin portability list when installed.
- **Why approval**: third-party plugin + restart while players are off.

### Efficiency

#### PHP-FPM pool sizing under concurrent sync
- **File**: `services/nextcloud/php-fpm.d/zz-custom.conf`
- **Problem**: `pm.max_children = 8` with 200s terminate timeout. Slow syncs can occupy all 8 children. (Already switched to `ondemand` — idle workers now free at rest.)
- **Fix**: Monitor `docker exec -w /var/www/html nextcloud php occ status` and `docker stats nextcloud`. Raise `max_children` only if sync load grows; lower `request_terminate_timeout` if 504s appear.

#### Stop goose when idle  **[needs human approval]**
- **File**: `/etc/systemd/system/goose.service`
- **Problem**: The goose agent service (`goose serve`) holds memory idle when no session is active. Protected by `docs/AGENTS.md` safety rules (must not delete), but temporary `systemctl stop` between sessions would free RAM.
- **Fix**: `systemctl stop goose` when not in use; `systemctl start goose` before use.
- **Why approval**: operator convenience trade-off (cold start latency vs. idle RAM).

#### PufferPanel Statistics tab never shows RAM (upstream #1482)
- **File**: `services/pufferpanel/docker-compose.yml` (panel `pufferpanel/pufferpanel:latest` = 3.0.9, Jul 2026)
- **Problem**: Server Statistics page shows no memory usage for the Minecraft (Paper) server. Matches upstream [pufferpanel/pufferpanel#1482](https://github.com/pufferpanel/pufferpanel/issues/1482) (open): RAM metric missing for Minecraft servers on `:latest`; a PaperMC reporter confirms it worked on the unmaintained `pufferpanel/pufferpanel:java` image. No fix released (3.0.9 is latest); maintainer asked for the reporter's server JSON (never provided).
- **Fix**: wait for upstream release only — operator decision: no GitHub issue interaction (do not open, comment, or send anything). Monitoring unaffected — use `docker exec 2ecfbe8c jcmd 1 GC.heap_info` / `jstat` / `docker stats` (see earlier session notes). Do NOT pin the old `:java` image (unmaintained, no Java 25).

#### PufferPanel template library stalls ~1s on first open + missing minecraft README
- **File**: `services/pufferpanel/docker-compose.yml` (runtime data under `/var/www/custom/projects/homelab/puffer/data/cache/template-repos/`)
- **Problem**: opening Templates triggers an on-demand git checkout of the community repo (`Checking out repo community: cache/template-repos/1`) — the only >100ms request in the panel log (`GET /api/templates/1` = 936ms; every other request is sub-ms). Also the community `minecraft` template dir contains only `data.json` + `minecraft.json` (no `README.md`, upstream), so every view logs `Error reading readme cache/template-repos/1/minecraft/README.md: no such file or directory`.
- **Fix**: cosmetic/stall only — the checkout is cached after first run (subsequent opens are ~1ms). For the README error, delete the repo dir and let PufferPanel re-checkout, or accept it as an upstream data gap. Not worth action unless template browsing is a daily use case.

#### Nextcloud Talk: no Client Push proxy
- **File**: `services/nextcloud/docker-compose.yml` (Talk stack: `talk-hpb` HPB + `talk-relay` already deployed)
- **Problem**: mobile push notifications are delayed — no push proxy (UnifiedPush / nextcloud-push) is installed. The old entry's "no HPB" premise is stale: the Go signaling server (strukturag/nextcloud-spreed-signaling) has run since the 2026-08-30 rebuild.
- **Fix**: install a push proxy + Notifications backend when Talk push becomes a real use case.

---

## Solved

Resolved items grouped by month. One line per item, one sentence per record.

### Jul 2026 — early system build
- **Initial site + Docker** — `index.html` and the first `docker-compose.yml`.
- **Caddy setup** — first vhost config.
- **GitHub Actions deploy** — SSH-key deploy workflow, later retired.
- **AI/LLM API service** — Ollama-backed `services/ai/app.py`, later removed.

### Aug 2026 — Nextcloud, TLS, hardening, ops
- **Orphaned MC template `ea3b4585` removed** — lazymc-era Fabric install deleted (pre-removal tarball kept in `backups/`).
- **`mail` container renamed `mailserver`** — data dir, refs, Makefile and docs updated; SMTP/IMAP verified after recreate.
- **LazyMC sleep proxy + Geyser Bedrock** — Java 25565 behind lazymc, Bedrock via Geyser, idle sleep timer.
- **ufw status fixed** — `sudo ufw status` works again.
- **MC game ports opened** — `25565/tcp` + `19132/udp` allowed.
- **MC server optimized** — 4 G heap + Aikar flags + native caps, simulation/view distance, culling, Chunky + StackMob plugins.
- **Online mode restored with Floodgate** — `online-mode=true`, Bedrock joins via Xbox with real Java session auth back.
- **MC autosave interval set to 1 h** — `auto-save-interval` 72000 ticks.
- **Browser Minecraft live** — eaglercraft at `mc.fxmq.net/play` (PufferPanel server `07fd7727`, Paper 1.12.2 + EaglerXServer, Java 17).
- **Terralith / Distant Horizons not installable on this stack** — Terralith is 1.18+ Forge-only, the browser client can't load DH.
- **`07fd7727` registered in the panel DB** — file-dropped server made UI-visible with `servers`+`permissions` rows.
- **Playground tuning applied** — render/view distance 4, entity limits halved, 4 G heap.
- **Playground autorestart off** — operator disabled it while pregen-testing patched Chunky.
- **Web instance switched to EaglercraftX 1.8.8** — official u53 client at `/play`, Via family on the 1.12.2 backend, websocket at `/play/server`, public Java port 25565.
- **Modded server restored** — `ea3b4585` deleted as an "orphan" despite a DB row, then restored from the pre-removal tarball (a DB row means the operator owns it).
- **Default server seeded in the browser client** — `servers` hint in `eaglercraftXOptsHints` pre-lists fxmq.net in fresh browsers.
- **Any-version Java access** — ViaBackwards + ViaRewind bridge Java clients 1.7.10–latest to the 1.12.2 backend.
- **Browser-MC port consolidated to 25565** — shared with the protected server (one runs at a time by design).
- **Vaultwarden SMTP wired** — `vaultwarden@fxmq.net` sender via the local mailserver (STARTTLS 587).
- **NC setup warnings cleared** — `trusted_proxies` as a real array, SMTP auth/tls fixes, cron, DB indices + repair, opcache bump.
- **Talk HPB single registration** — internal `http://172.22.0.12:8080` signaling entry removed; only the public `wss://talk.fxmq.net/signaling` is registered.
- **NC 34.0.3 upgrade** — image tag bumped, `occ upgrade` ran clean.
- **Setup-check noise silenced** — `serverid=1`, AppAPI disabled, Talk recording/SIP intentionally unconfigured.
- **Security headers deduplicated + completed** — `header_down` at each app proxy strips upstream copies; every vhost sets one of each.
- **mc websocket smoke check removed** — the game server isn't run 24/7, so smoke asserts `/play` only.
- **Chunky built for 1.12.2** — tag 1.1.21 rebuilt from source with dead-repo + version-gate patches.
- **Nextcloud integration** — hosted on the VPS, linked via PHP-FPM.
- **Nextcloud backend upgrade** — image bump.
- **CoreDNS isolated** — split into its own directory, config renamed.
- **FPM worker regulation** — `zz-custom.conf` pool tuning added.
- **Container renames** — `domain`, `cloud`, `tailnet` names pinned.
- **Local LLM hosting removed, open resolver fixed, Caddy hardened.**
- **Wildcard cert retired for per-vhost ACME** — every vhost now uses LE DNS-01.
- **Custom Caddy image with `caddy-dns/cloudflare`** — xcaddy build accepting the 53-char CF token format.
- **SSH hardened** — password auth + root login disabled, `AllowUsers op root`.
- **Log rotation deployed** — `json-file` size caps on the containers.
- **Image tags pinned** — caddy/nextcloud/coredns versions.
- **PHP-FPM `ondemand`** — idle workers freed after 10s.
- **CoreDNS multi-upstream** — `1.1.1.1 1.0.0.1 9.9.9.9`.
- **Caddy admin API closed** — `admin off`.
- **Caddy FastCGI timeouts** — dial/read/write timeouts set.
- **Nextcloud `trusted_proxies` + `overwrite.cli.url`** — set to the `net` subnet and https.
- **Static site placeholders** — non-blank `index.html` on www/app/vps.
- **Healthchecks** — domain + cloud healthy.
- **Security headers** — HSTS/XCTO/XFO/Referrer-Policy on all vhosts.
- **Claude Code project safety rail** — deny-only settings deployed, later removed from the repo.
- **Backup + migrate recipes fixed** — sudo destinations, tar-stream cloud backup, migrate recipe restored.
- **Makefile `set -u` foot-gun fixed** — `SHELL := /bin/bash` set explicitly.
- **`bkp-cloud` maintenance trap** — `occ maintenance:mode --off` on EXIT.
- **`clean` split into `clean-docker` / `clean-apt` / `clean-backups` / `clean-all`.**
- **`bkp-all`** — chains the backup recipes in order.
- **Migrate runbook extracted to `docs/MIGRATE.md`.**
- **Makefile** — up/restart/logs/status/push/backup/clean recipes.
- **Nextcloud overrides env-driven** — `TRUSTED_PROXIES` + `OVERWRITECLIURL` moved from `config.php` to compose.
- **Deploy/ops helper scripts** — covered by the Makefile recipes.
- **System made fully recoverable** — `bundle-secrets` + `migrate` recipes.
- **Reference configs in repo** — Ollama unit + SSH hardening under `config/`.
- **Static landing page** — FR/Spotify/countdown page served before Homer replaced it.
- **Nextcloud bind mount split** — `cloud/html` + `cloud/users` (datadirectory).
- **`.md` writing rules added to AGENTS.md; README deduped.**
- **Docs reorganized** — AGENTS.md + ISSUES.md moved to `docs/`.
- **Sensitive files purged from git history** — `git filter-repo` rewrite, force-pushed.
- **CoreDNS → dnsmasq** — container removed; host dnsmasq on the Tailscale IP.
- **`tailnet_default` bridge removed** — spare network gone with its container.
- **URL shortener** — Flask + SQLite at `share.homelab.com`.
- **Nextcloud bind mount fixed** — datadirectory moved to `/data`, no nesting.
- **`share.homelab.com` admin leak closed** — Caddy `@admin` matcher 404s the admin paths on the public vhost.
- **Cloudflare 100 MB body cap aligned** — all vhosts `max_size 100m`.
- **Nextcloud `maintenance_window_start`** — set to 04:00.
- **Nextcloud DB indices + mimetype migrations** — `occ db:add-missing-indices` + `maintenance:repair`.
- **Nextcloud `TRUSTED_PROXIES` expanded** — all Cloudflare edge ranges.
- **Homer + Uptime Kuma added** — `www.homelab.com` dashboard + `kuma.homelab.com` monitors.
- **Docs split into four** — visitor/agent-rules/operator-guide/task-tracker.
- **Log tightening** — Caddy logs to /dev/null, dnsmasq query logging off.
- **`server.homelab.com/shell`** — ttyd-backed host shell with `/` bind-mounted.
- **`status.homelab.com` → `kuma.homelab.com`** — hostname renamed to match the container.
- **Kuma monitor set trimmed** — unreachable/redundant/self-check monitors dropped.
- **Kuma `seed-monitors.sql`** — idempotent SQL applied once.
- **Homer config bind tightened** — only `config.yml` bound into the container.
- **Repo relocated** — `/var/www/github/homelab.com` → `/var/www/custom/projects/homelab`.
- **Hostname `vps` → `ops` → `server.homelab.com`** — renamed in Caddyfile, dnsmasq, docs.
- **`server.homelab.com/shell` runs as `debian`** — ttyd entrypoint switched to `runuser`.
- **Homer dashboard expanded** — Files + Terminal entries.
- **Terminal `host-exec` shim** — chroot-to-host wrapper for glibc binaries in the Alpine ttyd container.

### Sep 2026 — edge renames + docs overhaul
- **Duplicate `fxmq.net` edge container cleaned up** — an interrupted `--force-recreate` had left two host-network Caddys on :80/:443 sharing the cert store; both removed, recreate verified non-duplicating.
- **`optimize.sh` universal VPS optimizer** — OPTIMIZE.md + repo tuning + `make cleanup`'s apt/docker part merged into one idempotent, zero-prompt bash script with an Enter-refresh error loop; applied here (swap RAM/3, noatime, THP, sysctls, tuned/irqbalance/earlyoom auto, SSD/HDD auto-detect → fstrim or SETRA).
- **`turn.fxmq.net` renamed `talk.fxmq.net`** — vhost, DNS (grey-cloud A record), occ signaling entry, coturn cert path, smoke and docs updated; stale cert dir removed.
- **`shell.fxmq.net` renamed `tail.fxmq.net`** — vhost now serves a clickable vhost-links home at `/`, ttyd at `/ttyd`; dnsmasq + smoke + docs updated.
- **mc.fxmq.net paths reworked** — websocket moved to `/play/server`, `/download` moved to `www.fxmq.net/download`, unknown paths answer the usual `ok`, catch-all 404 dropped.
- **All 301 redirects upgraded to 308** — CardDAV/CalDAV well-known redirects included.
- **Docs restructured** — AGENTS.md portable-only (project specifics + lessons + intended moved to GUIDE.md), ISSUES.md Solved one sentence per record, volatile operator-editable state removed everywhere.
