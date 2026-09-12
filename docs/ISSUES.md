# Known issues and improvements

Tracked for follow-up. Items marked **[needs human approval]** require a decision or credential from the operator before an agent should act. Behaviours that look like bugs but are deliberate design choices are documented as rationale in `docs/GUIDE.md` — do not "fix" them. Resolved items are recorded under `## Solved`, one sentence each.

---

## Open

### Pending (Aug 2026)

#### Kuma config copy from the jehpok VPS is blocked  **[needs human approval]**
- **File**: `scripts/kuma-import.sh` (prepared); source db on `jehpok` (100.81.245.77)
- **Problem**: SSH to `jehpok` denies every key tried from fxmq (`root`/`op`/`debian`, incl. `github_key`), Tailscale SSH is not enabled there, and its Taildrop inbox is empty — the old `kuma.db` cannot be fetched. The operator's Mac is also blocked: jehpok's ED25519 host key changed (`REMOTE HOST IDENTIFICATION HAS CHANGED`, new fingerprint `SHA256:o0MmsggDn/Hi2LiThbkSLlLGUadoQfEKi0NBvmFb61k`) — likely the VPS was reinstalled. kuma.fxmq.net currently has the seeded admin (reset Aug 2026 — rotate with `make kuma-passwd`) + 4 monitors but not the old account/status pages.
- **Fix**: on the Mac run `ssh-keygen -R 100.81.245.77` (clears the stale host key), then `ssh debian@100.81.245.77` — if the box was reinstalled the old key may no longer be authorized; re-add it. Deliver the db either by taildrop from jehpok (`tailscale file cp kuma.db fxmq:`, then on fxmq `tailscale file get /var/www/custom/projects/homelab/kuma/import`) or by adding the fxmq `op` SSH key to jehpok's `authorized_keys`. Then `make kuma-import` swaps it in, adapts it (jehpok.com→fxmq.net URLs, old container names, deactivates retired-service monitors) and re-seeds the current monitor set.

### Robustness

#### Destructive make recipes run with no confirmation guard
- **File**: `Makefile`
- **Problem**: several recipes destroy data or overwrite live state with no prompt and no automatic backup. Data-destroying: `clean-docker` / `cleanup` (docker prune -af + apt autoremove), `clean-backups` (deletes older backups), `nc-user-del` / `mail-del` / `panel-del-user` / `kuma-del-user` (user + data), `storage` (moves the datadirectory and can delete the local copy). Live-state overwriting: `install-config` (overwrites host config, restarts sshd/dnsmasq), `deploy` / `install-secrets` (extract a bundle over `/etc`, `~/.ssh`, `/var/lib/tailscale`), `update` (apt upgrade + pull/recreate), `dok-recreate-all` / `dok-stop-all` / `dok-recreate-nextcloud-db`. Interrupting: `panel-passwd` (restarts the panel → stops a running game server) and `tail-auth` (restarts Caddy). `backup` also pulls live config into the repo (a secret-leak path — tracked separately).
- **Fix**: pick a policy — a `CONFIRM=1` gate on the destructive recipes, or keep them unguarded and list them explicitly in `make help-more`. Today they are not in one obvious list.
- **Why approval**: changing recipe UX affects every documented workflow (GUIDE/README).


#### PHP sessions live in a non-persistent Redis
- **File**: `services/nextcloud/docker-compose.yml` (redis runs `--save "" --appendonly no`, `allkeys-lru`)
- **Problem**: the image entrypoint stores PHP sessions in Redis, so a `redis` restart/recreate (or eviction) logs every user out.
- **Fix**: accept, or give Redis minimal RDB persistence so sessions survive a restart.

#### NFS datadirectory: hard mount + `sync` export + `no_root_squash`
- **File**: `/etc/fstab` (client), storage `/etc/exports`
- **Problem**: a `sync` export over the tailnet is the write-latency bottleneck (the 2026-09-10 migration stalled at ~227 KB/s); `hard` means a storage outage blocks Nextcloud I/O (right for integrity, but no timeout escape); `no_root_squash` lets any tailnet host write as root on the export.
- **Fix**: consider `async` (faster, weaker crash durability) and root-squashing — both change behaviour and need an explicit operator decision.

#### No automated validation of the scripts
- **File**: `scripts/`, `Makefile`
- **Problem**: only `make smoke` + the git hooks run; nothing lints the large bash scripts that produced two bugs on 2026-09-10 (storage.sh, optimize.sh).
- **Fix**: run `bash -n` + `shellcheck` on `scripts/*.sh` in a pre-push/CI job.

#### talk-hpb was OOM-killed
- **File**: `services/nextcloud/docker-compose.yml` (RAM caps)
- **Problem**: `journalctl` shows the kernel OOM-killing nextcloud-spreed-signaling on 2026-09-09 under the stack's RAM cap.
- **Fix**: confirm recurrence; raise the cap or reduce concurrency if it repeats.


#### Browser 1.12.2 server: effective view-distance is 6, not the tuned 4  **[needs human approval]**
- **File**: `puffer/data/servers/07fd7727/spigot.yml` (`world-settings.default.view-distance: 6`) + `server.properties` (`view-distance=4`)
- **Problem**: the 2026-08-31 tuning set `view-distance=4` in server.properties, but Spigot's per-world `world-settings.default.view-distance: 6` overrides it — the server boots with "View Distance: 6" for all three worlds, so the intended 4-chunk render/tick distance never took effect (1.12.2 has no separate sim-distance, so this also widens entity ticking).
- **Fix**: operator decision — either set spigot.yml `world-settings.default.view-distance: 4` (matches the tuning intent) or accept 6 and update the docs. Requires a server restart (spigot.yml is read at world load).

#### Nextcloud reset (2026-09-01) — fresh install, recovery manifests
- **File**: `cloud/recovery/{users,apps}.txt` (recovery manifests, OUTSIDE the repo — generated by `make nc-capture`) + `scripts/install.sh` `nextcloud_setup`
- **Problem**: the object-store migration corrupted the filecache repeatedly (blobs keyed `urn:oid:<fileid>`, scans trashing files, storage-switch SQL idempotency bugs). The instance held only default skeleton files, so it was erased and freshly installed: `cloud/users`, `pgdata` and `config.php` deleted, PostgreSQL recreated **on fxmq** (local latency — the storage VPS is for files/backups, not the DB), `occ maintenance:install` run, then the recovery applied.
- **Done (2026-09-01)**: fresh NC 34.0.3 on the local PG; `trusted_domains` + `cloud.fxmq.net` (occ install only trusts localhost — added to `install.sh`); users `admin`/`sunny`/`niyaz25` recreated from `cloud/recovery/users.txt` (new generated passwords for sunny/niyaz25 — printed once; share them with the users); apps `spreed`/`calendar`/`contacts`/`mail`/`notes` re-enabled, `app_api` disabled; occ config re-applied (trusted_proxies array, mail SMTP, serverid, maintenance window 4, cron mode, Talk signaling + TURN); quota admin 300 GB. Smoke passes. The recovery path is now scripted — a fresh install reproduces the exact setup (users, apps, config) without the data.
- **Residual**: sunny/niyaz25 passwords are new (reset); nothing else lost (data was skeleton-only).

#### No automated backup script (partial — DB side solved)
- **File**: (missing) `scripts/backup.sh`
- **Problem**: `make backup` tars Nextcloud `/data` in maintenance mode; there was no consistent PostgreSQL snapshot and no off-site copy target. Since 2026-08-31 the DB side is covered: `scripts/storage.sh` installs a nightly cron that `pg_dump`s the `postgresql` container and pushes it to `storage:/backups/nc` (key auth, keeps 7). The FILE side: user files live on the storage VPS (`cloud/users/` NFS export — the live datadirectory after `make storage`), so the only copy sits on the same box as the DB dumps; there is no off-site/DR copy.
- **Fix**: add `scripts/backup.sh` (or extend the cron): `occ maintenance:mode --on` → `pg_dump` (already nightly) + rsync the storage VPS's `/srv/nextcloud-data` to a second target (plus a copy of the DB dumps) → `--off`.
- **Why approval**: operator picks the file-backup target (second disk / another provider / off-site).

#### GUIDE "Nextcloud DB" section still documents moving PostgreSQL to the 1 TB VPS
- **File**: `docs/GUIDE.md` ("Nextcloud DB" section) + `services/nextcloud/docker-compose.db.yml` comments
- **Problem**: Setup A keeps PostgreSQL on fxmq and puts only Nextcloud's user files on the 1 TB VPS (which has already joined the tailnet — the nightly `pg_dump` lands on it), but GUIDE still gives step-by-step instructions to move the whole DB there and the db compose comments are tuned for "the 2 GB future DB host". One of the two is the plan.
- **Fix**: operator decision — delete the DB-migration steps from GUIDE (Setup A won) or re-document them as an option if the DB ever outgrows fxmq.

### Security

#### docker.sock holders = host root (PufferPanel + Uptime Kuma)
- **File**: `services/pufferpanel/docker-compose.yml` (rw), `services/uptimekuma/docker-compose.yml` (ro)
- **Problem**: both containers mount `/var/run/docker.sock`, so a compromise of either is host root — and PufferPanel's UI is publicly reachable at `mc.$DOMAIN/panel`. `no-new-privileges` was added to PufferPanel (2026-09-11) but does not neutralise the socket.
- **Fix** (pick one): run the panel against a dedicated/rootless Docker daemon; put `/panel` behind Cloudflare Access; or tailnet-gate `/panel` (keeps `/play` public). A socket-proxy adds little — a container manager needs near-full API access.
- **Why approval**: each option changes the operator's access path.

#### goose server secret is in git history
- **File**: `config/goose/goose.service` (history)
- **Problem**: `install.sh` used to `sed` a generated `GOOSE_SERVER__SECRET_KEY` into the tracked unit, so a real key sits in git history. The repo now uses `EnvironmentFile=/etc/goose/goose.env` (root:op 0640), but the old value is still in history and unrotated.
- **Fix**: rotate the key (new value in `/etc/goose/goose.env`, `systemctl restart goose`, update goose clients), then purge it from history if desired.
- **Why approval**: rotation restarts the agent service; a history purge needs a force-push.

#### `curl … | sh` in the installers
- **File**: `scripts/install.sh` (tailscale, goose), `scripts/storage.sh` (tailscale)
- **Problem**: piping a remote script into a shell is supply-chain exposure.
- **Fix**: use the official Tailscale apt repo (keyring + sources.list + `apt-get install`); keep the vendor's goose installer (or verify a released binary) and note the exception.

#### `make backup` copies live config into the repo
- **File**: `Makefile` (`backup` recipe — the live-config pull)
- **Problem**: `make backup` copies live host configs into `$(REPO)/repo/config/`; if one of those files ever carries a secret, the next `git add` commits it (the goose unit did exactly this until 2026-09-11).
- **Fix**: keep secrets in dedicated files outside the copied set (as goose now does); optionally add a secret-scan guard to the pre-commit hook.
- **Note (2026-09-12)**: the pull also resurrects *scrubbed* content — a stale live `/etc/sysctl.d/99-homelab.conf` re-imported a banned-assistant name the repo had deliberately removed (commit 070d35f), landing uncommitted in the working tree. After `make backup`, `git diff config/` before any `git add`; re-apply `make install-config` when the live copies are behind the repo.

#### `install.sh` `eval`s values from `scripts/defaults/install.conf`
- **File**: `scripts/install.sh` (`defaults_install` / `ask_modules`)
- **Problem**: module defaults are applied with `eval "DEF_${canon}=$val"` and `eval "$var=$def"` — arbitrary content in that file executes. It is repo-tracked (low risk today), but it is an injection surface if the file is ever untrusted.
- **Fix**: parse `key=value` with `read`/`case` instead of `eval`.


#### Mail platform: no PTR record (operator will set at AlphaVPS)  **[needs human approval]**
- **File**: `services/mailserver/docker-compose.yml` (installed); DNS + UFW configured
- **Problem**: inbound TCP 25 is now open (verified 2026-08-28: external nodes connect, postfix serves `220 mail.fxmq.net ESMTP` with the LE cert). The remaining blocker: 82.118.230.117 has **no PTR** — outbound mail to Gmail/Outlook will be rejected or spam-foldered until reverse DNS exists. The reverse zone is provider-hosted, not delegated to us, so only the operator can set it.
- **Fix** (operator, ~2 min): provider is **AlphaVPS** (netname `DAGroup`, RIPE `AA29428-RIPE`, block `82.118.230.0/24`). In the AlphaVPS client area (VPS → rDNS/Reverse DNS) set `82.118.230.117` → `mail.fxmq.net`, or ticket `support@alphavps.bg` / `abuse@alphavps.bg` with: *"Please set reverse DNS for 82.118.230.117 to `mail.fxmq.net`."* Must match postfix HELO + the `mail.fxmq.net` A record (both already `mail.fxmq.net`). Verify with `dig -x 82.118.230.117`, then send a test to an external inbox.

#### Tailscale tailnet has 2 stale devices  **[needs human approval]**
- **File**: Tailscale admin console (outside repo)
- **Problem**: `kaliusb` (linux, 18d offline) and `iosphone` (iOS, 6h offline) are still registered in the tailnet. `kaliusb` is a Kali USB stick — likely a forensic / on-demand tool, not a daily driver. Stale devices widen the ACL blast radius.
- **Fix**: In Tailscale admin console, remove `kaliusb` and `iosphone`. Or rename and tag if they are still in active use.
- **Why approval**: outside the repo; operator must decide which devices stay.

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

#### install.sh hardcodes `admin@fxmq.net` for the PufferPanel admin  **[generalization drift]**
- **File**: `scripts/install.sh` (panel_admin seed + smoke recheck)
- **Problem**: rule 12 (stay global) — the panel admin email is hardcoded to `fxmq.net` while the rest of install.sh is `$DOMAIN`-driven; a fresh install for another domain still seeds an `@fxmq.net` admin, and `scripts/smoke-vhosts.sh` asserts it.
- **Fix**: derive the admin email from `$DOMAIN` (or accept fxmq.net as canonical and document it in REF.md/GUIDE); needs an operator decision on whether the panel admin domain may ever differ.

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

#### `storage.sh` re-prompts for the storage root password on every run
- **File**: `scripts/storage.sh`
- **Problem**: even when the operator's SSH key is already on the storage VPS (the script installs it) and the tailnet path works, a re-run still demands `STORAGE_PASS` + `TS_AUTHKEY`.
- **Fix**: after the tailnet check, if `ssh -o BatchMode=yes root@$TS_IP true` succeeds, skip the password/key prompts and go straight to the re-check.

#### Nextcloud Talk: no Client Push proxy
- **File**: `services/nextcloud/docker-compose.yml` (Talk stack: `talk-hpb` HPB + `talk-relay` already deployed)
- **Problem**: mobile push notifications are delayed — no push proxy (UnifiedPush / nextcloud-push) is installed. The old entry's "no HPB" premise is stale: the Go signaling server (strukturag/nextcloud-spreed-signaling) has run since the 2026-08-30 rebuild.
- **Fix**: install a push proxy + Notifications backend when Talk push becomes a real use case.

---

## Planned ideas

Future roadmap, operator-reviewed later; when one is picked up it moves to Open, when done it lands in Solved.
Implemented 2026-09-06 (→ Solved): installer per-module prompts + `scripts/defaults/install.conf` (default all ON), `REF.md` demo-terms reference, the original `make status` merge (later rebuilt 2026-09-11 as `scripts/status.sh`), `make taildrop-file|folder`, `TARGET=` dispatchers for the dok actions, Debian-system wording in README/www.

#### NC user isolation across apps
- **Goal**: keep Nextcloud users isolated from each other (own groups) across the apps they touch.
- **Reality check**: mail, Nextcloud, Vaultwarden, Minecraft each have separate user models — full cross-app isolation needs per-app groups + consistent naming + documented matrix; true SSO-style isolation is a bigger architecture question. Spike/design before committing.

#### GitHub workflow (Issues + Projects + PRs), ISSUES.md as backup
- **Plan**: move day-to-day tracking to GitHub Issues/Projects/PRs; keep ISSUES.md canonical and mirror outward, not the reverse (GitHub-side state proved lossy/poisonable in the 2026-09 graph saga). Keep the Solved-by-month history in ISSUES.md.

#### Deeper REF.md sweep (later)
- **Note**: REF.md exists and docs point to it, but older GUIDE/ISSUES text still carries raw demo values (historical Solved entries intentionally stay). A future pass can sweep remaining live references in operational docs.

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
- **AI-assistant project safety rail** — deny-only settings deployed, later removed from the repo.
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
- **Boot-race NFS datadir mount outage (2026-09-12)** — reboot raced the datadir mount against tailscaled (unit started 1 s in, 0 peers) and the default 90 s mount timeout killed it; `nofail` boot continued, docker bound the empty placeholder dir as NC's `/data` → "data directory is invalid" 503s + kuma `cloud.fxmq.net` HTTP-down alert. Fixed live (systemctl start mount + `make dok-restart-nextcloud`); fstab line now `x-systemd.after=tailscaled.service,x-systemd.mount-timeout=300s,x-systemd.before=docker.service` (written by storage.sh `ensure_mount`, applied to the live fstab) so ordering is deterministic and containers never bind the placeholder; GUIDE gotcha has the full lesson.
- **Basic-auth session reworked on `tail.$DOMAIN` (2026-09-11, superseded the same-day navigate-to-/ttyd design)** — `log in` now prompts for the password inline (masked) and validates it in the background against `/ttyd`'s basic auth with an explicit Authorization header, so the browser's cached credential is never the login and nothing is auto-logged-in; the session is a per-tab sessionStorage flag, `log out` forgets it plus evicts any cached `/ttyd` credential (primed bogus fetch) — no remembered session after logout.
- **GitHub graph empty + ghost contributor fixed** — two-root merge DAG made GitHub's date queries 500 (graph empty since 08-01); single-root linearization restored the cells and scrubbing `Co-Authored-By:` AI-assistant trailer credits removed the ghost contributor (details in the GUIDE 2026-09-06 debug-hell lesson); the two-root repo was deleted and the clean history is now canonical on `kefohaine/server` (scratch repos deleted).
- **installer: per-module install selection** — `ask_inputs` now prompts for cloud/vault/mail/games/monitor (default all ON, env/state-overridable); `phase2_op`, `containers_up`, `cf_dns` and `issue_certs` gate on the choice; defaults come from `scripts/defaults/install.conf`; verified with `bash -n` + parser unit test (fresh-VPS run still pending).
- **`make status`** — rebuilt as the AIO dashboard (`scripts/status.sh`): one aligned colored read of perf/modules/git/units/docker/tmux/backups/mail/tailnet with no duplicate rows (the 2026-09-11 list+perf merge listed containers/units twice).
- **Module-aware smoke + status via `installed-modules.conf`** — `install.sh` writes the installed-module list to `$PROJECT_DIR/installed-modules.conf` at install end; `make smoke` structures its sections per module, still checks everything factually, but marks a failed section whose module was not installed as "intended behaviour" (per-section) and keeps it out of the exit code; a missing conf = all modules expected.
- **`make smoke` expanded** — beyond the vhost checks: tailnet-edge (`/` serves tailnet sources, `/ttyd` challenges without credentials), containers/units/ufw/NFS/disk/nc-status/coturn assertions; `ok` lines carry short plain-words descriptions.
- **`make taildrop-file` / `make taildrop-folder`** — `sudo tailscale file cp` wrappers (`FILE=`/`DIR=`, `TAILDROP_HOST` default `server`).
- **Makefile `TARGET=` dispatchers** — `dok-recreate/restart/stop/logs TARGET=<ctn>` as the primary style; the `-<ctn>` suffixes remain as aliases.
- **`REF.md`** — demo public-terms reference (domain, IPs, names, proxy modes) so docs stay portable; secrets excluded; scripts still auto-detect live values.
- **`make install-ttyd` self-kill guard (2026-09-11)** — refuses from any shell inside the ttyd cgroup: the evening's `systemctl restart ttyd` killed the running agent + its tmux session mid-deploy.
- **smoke `nc-status` false FAIL fixed** — the check grepped JSON keys against `occ status` YAML output; now uses `--output=json` and passes.
- **docs neutralised via `docs/REF.md` variables** — GUIDE + MIGRATE now reference `$DOMAIN` / `$PROJECT_DIR` / `$GITHUB_REPO` (defined per-setup in `docs/REF.md`); README points there; ISSUES keeps concrete values as tracker + history.
- **`scripts/defaults/`** — per-script prompt-defaults files (`install.conf` populated, `optimize.conf`/`storage.conf` skeletons); README + www copy matched to the real module flow.
- **Debian VPS → Debian system wording** — README and the www welcome lede no longer imply only a rented VPS.
- **`optimize.sh` universal VPS optimizer** — OPTIMIZE.md + repo tuning + `make cleanup`'s apt/docker part merged into one idempotent, zero-prompt bash script with an Enter-refresh error loop; applied here (swap RAM/3, noatime, THP, sysctls, tuned/irqbalance/earlyoom auto, SSD/HDD auto-detect → fstrim or SETRA).
- **`turn.fxmq.net` renamed `talk.fxmq.net`** — vhost, DNS (grey-cloud A record), occ signaling entry, coturn cert path, smoke and docs updated; stale cert dir removed.
- **`shell.fxmq.net` renamed `tail.fxmq.net`** — vhost now serves a clickable vhost-links home at `/`, ttyd at `/ttyd`; dnsmasq + smoke + docs updated.
- **mc.fxmq.net paths reworked** — websocket moved to `/play/server`, `/download` moved to `www.fxmq.net/download`, unknown paths answer the usual `ok`, catch-all 404 dropped.
- **All 301 redirects upgraded to 308** — CardDAV/CalDAV well-known redirects included.
- **Docs restructured** — AGENTS.md portable-only (project specifics + lessons + intended moved to GUIDE.md), ISSUES.md Solved one sentence per record, volatile operator-editable state removed everywhere.
- **`kefohaine/server` GitHub web page restored after history rewrite** — web code views 404'd and git-data API 500'd while git/raw/codeload stayed healthy; fixed by pushing an empty nudge commit (`daf119d`), which rebuilt GitHub's index (intermittent 500s for ~10 min while settling).
- **`services/nextcloud/.env` purged from all GitHub history** — removed from every commit via `scripts/drop-path.sh` plumbing rebuild (661 commits / 2 roots / 9 merges preserved, tip tree byte-identical); the exposed NC admin password is moot — the account no longer exists.
- **Local backup tags destroyed** — `history-backup-20260902` / `history-20260902-noreply` / `history-developer-email-20260903` deleted + objects pruned (`gc --prune=now`); the jehpok-era record lives on only inside `main` under the noreply identity, per operator choice.
- **NC recovery manifests moved out of the repo** — `users/groups/default-quota/apps.txt` now live at `homelab/cloud/recovery/` (op-owned, outside the repo like pgdata), generated by `make nc-capture`, consumed by install.sh; paths scrubbed from all history (664 commits preserved, personal doc addresses censored via `scripts/replace-string.sh`).
- **Storage VPS onboarded (Setup A)** — `scripts/storage.sh` migrated Nextcloud's datadirectory to the 1 TB VPS (`/srv/nextcloud-data` NFS export at `cloud/users`); PostgreSQL stays on fxmq and the nightly `pg_dump` → `/backups/nc` runs alongside.
- **storage.sh live-run fixes (2026-09-10)** — the first live run exposed a missing NFS client (`nfs-common`) and an unverified rollback delete that lost the datadirectory files; the script now installs the client, verifies the copy before the delete prompt, and installs the operator's ssh key — files were restored from `backups/cloud-backup-20260906`.
- **`tail.$DOMAIN` mini terminal + gated shell** — unauthenticated command terminal at `/` (`go <vhost> [page]` / `log in` / `log out`, live prediction over a catalogue generated from the vhost files by `make tail-targets`) and `basic_auth` (user `kefohaine`) on `/ttyd`; `log in` prompts inline and validates in the background (explicit Authorization header); `make tail-auth` sets/rotates it and prints the password once.
- **goose secret moved out of the repo** — the unit reads `EnvironmentFile=/etc/goose/goose.env` (root:op 0640); `install.sh` generates it there instead of `sed`ing it into a tracked file.
- **NFS datadirectory mount tightened** — `/etc/fstab` options are now `rw,nofail,_netdev,noatime,vers=4`.
- **Nextcloud password policy hardened** — the app is re-enabled with `minLength=16`, upper/lower/special/numeric requirements and the common/compromised-password lists on.
- **False alarm: the "undocumented host process" was the uptimekuma container** — host `ps` lists container processes (`node server/server.js` → `docker-<id>.scope` = uptimekuma; `supervisord` = mailserver), not stray host daemons.
- **optimize.sh live-run bugs fixed (2026-09-10)** — `append_lines()` doubled `/etc/fstab` and `/etc/security/limits.conf` (which broke the noatime step) and re-checks false-failed on a box without docker; it now appends only missing lines, skips absent software, and installs only the performance helpers (tuned/irqbalance/earlyoom).
