# Known issues and improvements

Tracked for follow-up. Items marked **[needs human approval]** require a decision or credential from the operator before an agent should act. Behaviours that look like bugs but are deliberate design choices are documented as rationale in `docs/GUIDE.md` — do not "fix" them. Resolved items are recorded under `## Solved`, one sentence each.

---

### `make connect` covers nextcloud only
- **File**: `scripts/ops/connect.sh`
- **Problem**: the menu lists kuma and vaultwarden but both print why they cannot be linked instead of acting. Kuma is SQLite (v2 supports MariaDB only if installed that way, so switching is a migration); Vaultwarden is a single SQLite file with no server-side database, and sharing it over NFS is unsafe because it does not lock across hosts.
- **Fix**: for Kuma, make it MariaDB-native on this host first, then reuse the nextcloud shape (dump → restore → re-point) through Kuma's own migration tool. For Vaultwarden, implement the documented move: stop the service, copy `db.sqlite3` + attachments + rsa keys, then either run it there or mount the remote path — a file operation, not a connection.

### Per-device shells are host-local by design
- **File**: `scripts/access/ttyd-devices.sh`
- **Problem**: `make ttyd-add NAME=<device>` creates a *session on this host* and lists it on the tail page; it does not start anything on the named device. Reaching a device is a manual `ssh`/`tailscale ssh` from inside that session.
- **Fix (if wanted)**: automate the ssh hop per device — but that is where credentials and authorisation live, so it needs an explicit decision (per-device keys? Tailscale SSH ACLs?) rather than a default. Tracked as a deliberate limitation until then.

## Open

### `http: vault` Kuma monitor watches a module that is not installed
- **File**: the `uptimekuma` module's SQLite (`monitor` table)
- **Problem**: the monitor `http: vault` points at `https://vault.$DOMAIN`, but the `vault` module is not in `installed-modules.conf` — no container, no route — so it is permanently down. That is a *not installed* module, NOT a tailnet-only route (the two are distinct: see GUIDE "Module state vs route exposure").
- **Fix** (operator, in the Kuma UI — an agent must not write to a user service): install the vault module, or pause/delete the monitor. Nothing in the repo needs to change.

### Pending (Aug 2026)

#### Kuma config copy from the $GITHUB_USER VPS is blocked  **[needs human approval]**
- **File**: `scripts/modules/kuma-import.sh` (prepared); source db on `$GITHUB_USER` (<the old box's tailnet IP>)
- **Problem**: SSH to `$GITHUB_USER` denies every key tried from the app host (`root`/`root`/`debian`, incl. `github_key`), Tailscale SSH is not enabled there, and its Taildrop inbox is empty — the old `kuma.db` cannot be fetched. The operator's Mac is also blocked: $GITHUB_USER's ED25519 host key changed (`REMOTE HOST IDENTIFICATION HAS CHANGED`, new fingerprint `SHA256:o0MmsggDn/Hi2LiThbkSLlLGUadoQfEKi0NBvmFb61k`) — likely the VPS was reinstalled. kuma.$DOMAIN currently has the seeded admin (reset Aug 2026 — rotate with `make kuma-passwd`) + 4 monitors but not the old account/status pages.
- **Fix**: on the Mac run `ssh-keygen -R <the old box's tailnet IP>` (clears the stale host key), then `ssh debian@<the old box's tailnet IP>` — if the box was reinstalled the old key may no longer be authorized; re-add it. Deliver the db either by taildrop from $GITHUB_USER (`tailscale file cp kuma.db the app host:`, then on the app host `tailscale file get {{DATA_DIR}}/kuma/import`) or by adding the the app host `root` SSH key to $GITHUB_USER's `authorized_keys`. Then `make kuma-import` swaps it in, adapts it ($DOMAIN→$DOMAIN URLs, old container names, deactivates retired-service monitors) and re-seeds the current monitor set.

### Robustness

#### Destructive make recipes run with no confirmation guard
- **File**: `Makefile`
- **Problem**: several recipes destroy data or overwrite live state with no prompt and no automatic backup. Data-destroying: `clean-docker` / `cleanup` (docker prune -af + apt autoremove), `clean-backups` (deletes older backups), `nc-user-del` / `mail-del` / `kuma-del-user` (user + data), `connect` → datadirectory (moves the datadirectory and can delete the local copy). Live-state overwriting: `install-config` (overwrites host config, restarts sshd/dnsmasq), `deploy` / `install-secrets` (extract a bundle over `/etc`, `~/.ssh`, `/var/lib/tailscale`), `update` (pull/recreate; the apt half is now the separate `apt-upgrade`), `dok-recreate-all` / `dok-stop-all` / `dok-recreate-nextcloud-db`. Interrupting: `install-config`/`update` (recreate or restart units) and `connect` (datadirectory). `backup` also pulls live config into the repo (a secret-leak path — tracked separately).
- **Fix**: pick a policy — a `CONFIRM=1` gate on the destructive recipes, or keep them unguarded and list them explicitly in `make help-more`. Today they are not in one obvious list.
- **Why approval**: changing recipe UX affects every documented workflow (GUIDE/README).

#### PHP sessions live in a non-persistent Redis
- **File**: `modules/nextcloud/docker-compose.yml` (redis runs `--save "" --appendonly no`, `allkeys-lru`)
- **Problem**: the image entrypoint stores PHP sessions in Redis, so a `redis` restart/recreate (or eviction) logs every user out.
- **Fix**: accept, or give Redis minimal RDB persistence so sessions survive a restart.

#### NFS datadirectory: hard mount + `sync` export + `no_root_squash`
- **File**: `/etc/fstab` (client), storage `/etc/exports`
- **Problem**: a `sync` export over the tailnet is the write-latency bottleneck (the 2026-09-10 migration stalled at ~227 KB/s); `hard` means a storage outage blocks Nextcloud I/O (right for integrity, but no timeout escape); `no_root_squash` lets any tailnet host write as root on the export.
- **Fix**: consider `async` (faster, weaker crash durability) and root-squashing — both change behaviour and need an explicit operator decision.

#### No automated validation of the scripts
- **File**: `scripts/`, `Makefile`
- **Problem**: only `make smoke` + the git hooks run; nothing lints the large bash scripts that produced two bugs on 2026-09-10 (datadir-nfs.sh, optimize.sh).
- **Fix**: run `bash -n` + `shellcheck` on `scripts/*.sh` in a pre-push/CI job.

#### (solved 2026-09-22) install.sh rewrote the tracked `config/dnsmasq/10-tailnet.conf` in place
- **File**: `scripts/install/install.sh` (`host_services`), `config/dnsmasq/10-tailnet.conf`
- **Problem**: the installer `sed -i`s the live Tailscale IP into the repo's tracked reference copy before `make install-config` copies it to `/etc/dnsmasq.d/`, so every run leaves an instance-specific IP as an uncommitted diff — and a `git commit -a` would bake it into the repo (rule 12: stay global).
- **Fix**: keep the repo file as a placeholder and write the instance value into the live file after the copy (`make install-config`, then `sed` `/etc/dnsmasq.d/10-tailnet.conf` + `systemctl restart dnsmasq`).

#### talk-hpb was OOM-killed
- **File**: `modules/nextcloud/docker-compose.yml` (RAM caps)
- **Problem**: `journalctl` shows the kernel OOM-killing nextcloud-spreed-signaling on 2026-09-09 under the stack's RAM cap.
- **Fix**: confirm recurrence; raise the cap or reduce concurrency if it repeats.

#### Nextcloud reset (2026-09-01) — fresh install, recovery manifests
- **File**: `cloud/recovery/{users,apps}.txt` (recovery manifests, OUTSIDE the repo — generated by `make nc-capture`) + `scripts/install/install.sh` `nextcloud_setup`
- **Problem**: the object-store migration corrupted the filecache repeatedly (blobs keyed `urn:oid:<fileid>`, scans trashing files, storage-switch SQL idempotency bugs). The instance held only default skeleton files, so it was erased and freshly installed: `cloud/users`, `pgdata` and `config.php` deleted, PostgreSQL recreated **on the app host** (local latency — the storage VPS is for files/backups, not the DB), `occ maintenance:install` run, then the recovery applied.
- **Done (2026-09-01)**: fresh NC 34.0.3 on the local PG; `trusted_domains` + `cloud.$DOMAIN` (occ install only trusts localhost — added to `install.sh`); users `admin`/`sunny`/`niyaz25` recreated from `cloud/recovery/users.txt` (new generated passwords for sunny/niyaz25 — printed once; share them with the users); apps `spreed`/`calendar`/`contacts`/`mail`/`notes` re-enabled, `app_api` disabled; occ config re-applied (trusted_proxies array, mail SMTP, serverid, maintenance window 4, cron mode, Talk signaling + TURN); quota admin 300 GB. Smoke passes. The recovery path is now scripted — a fresh install reproduces the exact setup (users, apps, config) without the data.
- **Residual**: sunny/niyaz25 passwords are new (reset); nothing else lost (data was skeleton-only).

#### No automated backup script (partial — DB side solved)
- **File**: (missing) `scripts/backup.sh`
- **Problem**: `make backup` tars Nextcloud `/data` in maintenance mode; there was no consistent PostgreSQL snapshot and no off-site copy target. Since 2026-08-31 the DB side is covered: `scripts/ops/datadir-nfs.sh` installs a nightly cron that `pg_dump`s the `postgresql` container and pushes it to `storage:/backups/nc` (key auth, keeps 7). The FILE side: user files live on the storage VPS (`cloud/users/` NFS export — the live datadirectory after the datadirectory move), so the only copy sits on the same box as the DB dumps; there is no off-site/DR copy.
- **Fix**: add `scripts/backup.sh` (or extend the cron): `occ maintenance:mode --on` → `pg_dump` (already nightly) + rsync the storage VPS's `/srv/nextcloud-data` to a second target (plus a copy of the DB dumps) → `--off`.
- **Why approval**: operator picks the file-backup target (second disk / another provider / off-site).

#### GUIDE "Nextcloud DB" section still documents moving PostgreSQL to the 1 TB VPS
- **File**: `docs/GUIDE.md` ("Nextcloud DB" section) + `modules/nextcloud/docker-compose.db.yml` comments
- **Problem**: Setup A keeps PostgreSQL on the app host and puts only Nextcloud's user files on the 1 TB VPS (which has already joined the tailnet — the nightly `pg_dump` lands on it), but GUIDE still gives step-by-step instructions to move the whole DB there and the db compose comments are tuned for "the 2 GB future DB host". One of the two is the plan.
- **Fix**: operator decision — delete the DB-migration steps from GUIDE (Setup A won) or re-document them as an option if the DB ever outgrows the app host.

### Security

#### docker.sock holders = host root (Uptime Kuma)
- **File**: `modules/uptimekuma/docker-compose.yml` (ro socket).
- **Problem**: a container with the docker socket is host root — a compromise of either is host root. `no-new-privileges` does not neutralise the socket. Accepted because the monitoring module needs the socket.
- **Status**: accepted, documented. Tracked for the edge/agent work: any socket holder should be treated as host root when writing policy.
#### goose server secret is in git history
- **File**: `config/goose/goose.service` (history)
- **Problem**: `install.sh` used to `sed` a generated `GOOSE_SERVER__SECRET_KEY` into the tracked unit, so a real key sits in git history. The repo now uses `EnvironmentFile=/etc/goose/goose.env` (root:root 0640), but the old value is still in history and unrotated.
- **Fix**: rotate the key (new value in `/etc/goose/goose.env`, `systemctl restart goose`, update goose clients), then purge it from history if desired.
- **Why approval**: rotation restarts the agent service; a history purge needs a force-push.

#### `curl … | sh` in the installers
- **File**: `scripts/install/install.sh` (tailscale, goose), `scripts/ops/datadir-nfs.sh` (tailscale)
- **Problem**: piping a remote script into a shell is supply-chain exposure.
- **Fix**: use the official Tailscale apt repo (keyring + sources.list + `apt-get install`); keep the vendor's goose installer (or verify a released binary) and note the exception.

#### `make backup` copies live config into the repo
- **File**: `Makefile` (`backup` recipe — the live-config pull)
- **Problem**: `make backup` copies live host configs into `$(REPO)/repo/config/`; if one of those files ever carries a secret, the next `git add` commits it (the goose unit did exactly this until 2026-09-11).
- **Fix**: keep secrets in dedicated files outside the copied set (as goose now does); optionally add a secret-scan guard to the pre-commit hook.
- **Note (2026-09-12)**: the pull also resurrects *scrubbed* content — a stale live `/etc/sysctl.d/99-{{HOSTNAME}}.conf` re-imported a banned-assistant name the repo had deliberately removed (commit 070d35f), landing uncommitted in the working tree. After `make backup`, `git diff config/` before any `git add`; re-apply `make install-config` when the live copies are behind the repo.

#### Mail platform: PTR record does not resolve to mail.$DOMAIN (operator must set it provider-side)  **[needs human approval]**
- **File**: `modules/mailserver/docker-compose.yml` (installed); DNS + UFW configured
- **Problem**: inbound TCP 25 is open (external nodes connect, postfix serves `220 mail.$DOMAIN ESMTP` with the LE cert). A reverse record for `$SERVER_IP` exists but points at the hosting provider's own hostname, not `mail.$DOMAIN` — outbound mail to Gmail/Outlook is rejected or spam-foldered until it matches. The reverse zone belongs to the provider, not us, so only the operator can change it.
- **Fix** (operator, ~2 min): in the VPS provider's control panel (rDNS / Reverse DNS) set the PTR for `$SERVER_IP` → `mail.$DOMAIN`, or open a support ticket asking for it. It must match the postfix HELO and the `mail.$DOMAIN` A record (both already `mail.$DOMAIN`). Verify with `dig -x $SERVER_IP`, then send a test to an external inbox.

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
- **File**: `modules/nextcloud/docker-compose.yml` (app config via `occ`)
- **Problem**: the setup check reports second-factor providers are available but two-factor authentication is not enforced — any stolen password alone grants access.
- **Fix**: operator sets up a 2FA provider on their account (TOTP app), then `occ twofactorauth:enforce admin` (or `--all` for every user). Enforcing before the provider is configured can lock the account out.
- **Why approval**: operator's own account; lockout risk.

#### Nextcloud default phone region not set  **[needs human approval]**
- **File**: app config via `occ`
- **Problem**: `default_phone_region` is unset — profile phone numbers without a country code can't be validated (setup check warns).
- **Fix**: `occ config:system:set default_phone_region --value <ISO-3166-1-ALPHA-2>` (e.g. `DE`, `FR`) — the operator picks their country code.
- **Why approval**: operator-specific value.

#### Re-apply Cloudflare WAF skip on the new domain
- **File**: Cloudflare dashboard ($DOMAIN zone)
- **Problem**: after the migration, `cloud.$DOMAIN` Nextcloud desktop sync is bot-challenged until the per-hostname WAF rule skip is re-created (same rationale as the `cloud.$DOMAIN` `Intended` entry).
- **Fix**: re-add the per-hostname WAF rule skip for `cloud.$DOMAIN` after `scripts/install/install.sh` finishes.

### Efficiency

#### PHP-FPM pool sizing under concurrent sync
- **File**: `modules/nextcloud/php-fpm.d/zz-custom.conf`
- **Problem**: `pm.max_children = 8` with 200s terminate timeout. Slow syncs can occupy all 8 children. (Already switched to `ondemand` — idle workers now free at rest.)
- **Fix**: Monitor `docker exec -w /var/www/html nextcloud php occ status` and `docker stats nextcloud`. Raise `max_children` only if sync load grows; lower `request_terminate_timeout` if 504s appear.

#### Stop goose when idle  **[needs human approval]**
- **File**: `/etc/systemd/system/goose.service`
- **Problem**: The goose agent service (`goose serve`) holds memory idle when no session is active. Protected by `docs/AGENTS.md` safety rules (must not delete), but temporary `systemctl stop` between sessions would free RAM.
- **Fix**: `systemctl stop goose` when not in use; `systemctl start goose` before use.
- **Why approval**: operator convenience trade-off (cold start latency vs. idle RAM).

#### `datadir-nfs.sh` (was storage.sh) re-prompts for the storage root password on every run
- **File**: `scripts/ops/datadir-nfs.sh`
- **Problem**: even when the operator's SSH key is already on the storage VPS (the script installs it) and the tailnet path works, a re-run still demands `STORAGE_PASS` + `TS_AUTHKEY`.
- **Fix**: after the tailnet check, if `ssh -o BatchMode=yes root@$TS_IP true` succeeds, skip the password/key prompts and go straight to the re-check.

#### Nextcloud Talk: no Client Push proxy
- **File**: `modules/nextcloud/docker-compose.yml` (Talk stack: `talk-hpb` HPB + `talk-relay` already deployed)
- **Problem**: mobile push notifications are delayed — no push proxy (UnifiedPush / nextcloud-push) is installed. The old entry's "no HPB" premise is stale: the Go signaling server (strukturag/nextcloud-spreed-signaling) has run since the 2026-08-30 rebuild.
- **Fix**: install a push proxy + Notifications backend when Talk push becomes a real use case.

#### `goose session remove` cannot prune sessions  **[goose 1.47.0 bug]**
- **File**: `~/.local/share/goose/sessions/sessions.db` (host state; no `sqlite3` binary on the host)
- **Problem**: `goose session remove --regex <re>` lists the matching sessions and then fails with `Error: not connected` — the CLI drives removal through the running `goose serve` ACP endpoint and the handshake never succeeds, so the store (which has no retention) can only be trimmed out-of-band.
- **Fix**: prune with python3 against `sessions.db` (delete `messages` + `usage_ledger` by `session_id`, then the `sessions` row; keep the live session) — the procedure is in the goose token bullet of `docs/GUIDE.md`. Re-test after a goose upgrade; if ACP removal starts working, drop the workaround.

#### Auto-compaction has never been observed firing
- **File**: `config/goose/token-policy.yaml` (`GOOSE_AUTO_COMPACT_THRESHOLD` — the threshold the policy sets, not this entry)
- **Problem**: the unit is settled (goose validates the value as `>0 … ≤1`, i.e. a fraction), but no session has been driven past the threshold, so what the built-in compaction actually sends (`Conversation summary` + `compaction_summary.md` visible in the binary) and whether the session is continued or forked is untested.
- **Fix**: drive one session past the configured threshold (or set it to a deliberately tiny fraction once) and confirm in `~/.local/state/goose/logs/llm_request.*.jsonl` that the transcript is replaced by a summary inside the same session id.

---

## Planned ideas

Future roadmap, operator-reviewed later; when one is picked up it moves to Open, when done it lands in Solved.
Implemented 2026-09-06 (→ Solved): installer per-module prompts + `scripts/install/defaults/install.conf` (default all ON), the token/terms reference (now `docs/SKELETON.md`), the original `make status` merge (later rebuilt 2026-09-11 as `scripts/status.sh`), `make taildrop-file|folder`, `TARGET=` dispatchers for the dok actions, Debian-system wording in README/www.

#### social.$DOMAIN — Mastodon (or the minimal fediverse alternative)
- **Status**: operator is thinking it through (2026-09-12) — do not start without the go-ahead.
- **Decision needed**: Mastodon (5 containers, ~1.2–1.8 GB added idle — a full-featured instance) vs GoToSocial (single Go binary, SQLite, ~60 MB — same ActivityPub network, minimal by construction).
- **If built (either way)**: new `social` module — compose file + data under `$DATA_DIR` local disk, SMTP via the mailserver (`social@$DOMAIN` mailbox, `mail-gen` pattern), CF-proxied A record + LE DNS-01, kuma monitor + smoke section + fetch row, install.sh/uninstall.sh module hooks, mem limits from day one (the RAM-budget review applies), docs.

#### NC user isolation across apps
- **Goal**: keep Nextcloud users isolated from each other (own groups) across the apps they touch.
- **Reality check**: mail, Nextcloud and Vaultwarden each have separate user models — full cross-app isolation needs per-app groups + consistent naming + documented matrix; true SSO-style isolation is a bigger architecture question. Spike/design before committing.

#### GitHub workflow (Issues + Projects + PRs), ISSUES.md as backup
- **Plan**: move day-to-day tracking to GitHub Issues/Projects/PRs; keep ISSUES.md canonical and mirror outward, not the reverse (GitHub-side state proved lossy/poisonable in the 2026-09 graph saga). Keep the Solved-by-month history in ISSUES.md.

## Solved

Resolved items grouped by month. One line per item, one sentence per record.

### Jul 2026 — early system build
- **Initial site + Docker** — `index.html` and the first `docker-compose.yml`.
- **Caddy setup** — first vhost config.
- **GitHub Actions deploy** — SSH-key deploy workflow, later retired.
- **AI/LLM API service** — Ollama-backed `modules/ai/app.py`, later removed.

### Aug 2026 — Nextcloud, TLS, hardening, ops
- **`mail` container renamed `mailserver`** — data dir, refs, Makefile and docs updated; SMTP/IMAP verified after recreate.
- **ufw status fixed** — `sudo ufw status` works again.
- **Vaultwarden SMTP wired** — `vaultwarden@$DOMAIN` sender via the local mailserver (STARTTLS 587).
- **NC setup warnings cleared** — `trusted_proxies` as a real array, SMTP auth/tls fixes, cron, DB indices + repair, opcache bump.
- **Talk HPB single registration** — internal `http://172.22.0.12:8080` signaling entry removed; only the public `wss://talk.$DOMAIN/signaling` is registered.
- **NC 34.0.3 upgrade** — image tag bumped, `occ upgrade` ran clean.
- **Setup-check noise silenced** — `serverid=1`, AppAPI disabled, Talk recording/SIP intentionally unconfigured.
- **Security headers deduplicated + completed** — `header_down` at each app proxy strips upstream copies; every vhost sets one of each.
- **Nextcloud integration** — hosted on the VPS, linked via PHP-FPM.
- **Nextcloud backend upgrade** — image bump.
- **CoreDNS isolated** — split into its own directory, config renamed.
- **FPM worker regulation** — `zz-custom.conf` pool tuning added.
- **Container renames** — `domain`, `cloud`, `tailnet` names pinned.
- **Local LLM hosting removed, open resolver fixed, Caddy hardened.**
- **Wildcard cert retired for per-vhost ACME** — every vhost now uses LE DNS-01.
- **Custom Caddy image with `caddy-dns/cloudflare`** — xcaddy build accepting the 53-char CF token format.
- **SSH hardened** — password auth + root login disabled, `AllowUsers root`.
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
- **Repo relocated** — `/var/www/custom/projects/homelab/repo` → `{{REPO_DIR}}`, data under `{{DATA_DIR}}`.
- **Hostname `vps` → `ops` → `server.homelab.com`** — renamed in Caddyfile, dnsmasq, docs.
- **`server.homelab.com/shell` runs as `debian`** — ttyd entrypoint switched to `runuser`.
- **Homer dashboard expanded** — Files + Terminal entries.
- **Terminal `host-exec` shim** — chroot-to-host wrapper for glibc binaries in the Alpine ttyd container.

### Sep 2026 — edge renames + docs overhaul
- **HTTP basic auth removed everywhere** — `/ttyd` and the whole `tail.$DOMAIN` vhost are gated by Tailscale membership only; `make tail-auth`, its script and every basic-auth check/doc are gone.
- **Web root moved to `$DATA_DIR/www`** — the repo ships no pages; the edge mounts the instance web root read-only, only the tail door-list template is tracked, and the tail catalogue lists tailnet-only routes.
- **Module vocabulary fixed** — `not installed` (absent, no route) is now distinct from `tailnet-only` (a route that exists); `config/modules.conf` is the module roster and `make fetch-more` prints the classification.
### Sep 2026 — modules rename + scripts categories
- **`services/` renamed to `modules/`** — every path, compose, hook, doc and recipe follows; the module roster itself is now declared once in `config/modules.conf`.
- **`scripts/` organised per category** — `lib/ install/ render/ stack/ modules/ access/ info/ ops/ hooks/`; each script resolves the checkout through `scripts/lib/instance.sh`, so depth no longer matters.
- **Setup-specific values removed before the installer can rename them** — the tracked dnsmasq placeholder is a literal (was the instance's own Tailscale IP), `TAILNET_SUBNET` is gone, and the `kefoserver-stack` retirement step was deleted.
- **Web root is instance data** — `$DATA_DIR/www` (operator pages + generated `targets.json`); the repo keeps only the tail template in `config/www/`.
- **`make backup` path bug fixed + reverse-rendered** — it pointed at `$(REPO)/backups` and `$(REPO)/vault`, both of which moved under `data/` in the layout migration (the vault tar was failing with "Error is not recoverable"); it now reverse-renders every file it pulls back, so live config lands in the skeleton as `{{TOKENS}}` — verified with a zero-diff round trip against all seven tracked config files.
- **`make connect` (replaces `make storage`)** — interactive connector: module → server → `link` (use the database that already lives there) or `overwrite` (copy this host's database there first), plus the NFS datadirectory move as choice 3 (`scripts/ops/datadir-nfs.sh`, the old `storage.sh`); refuses to re-point until the target DB answers.
- **Per-device web-terminal sessions** — `make ttyd-add/ttyd-rm/ttyd-devices`: one named tmux session per tailnet device served by the single ttyd listener (`/ttyd?arg=<name>`), listed as a card on the tail page; no new listener and no edge edit.
- **`make render` + `docs/SKELETON.md`** — the skeleton is documented end to end: tokens, compose substitution, script variables, domain-free filenames and the rename procedure.
- **Logs consolidated under one namespace** — every project log moved to `{{LOG_DIR}}` with one logrotate rule; the stale `/var/log/homelab-install.log` was relocated, not deleted, and the old uninstall log mode 660→640.
- **`REF.md` merged into `docs/SKELETON.md`** — one doc covers the tokens, the single values file and the render pipeline.
- **tmux is installed and persistent** — `install.sh` installs tmux; `config/systemd/tmux-main.service` keeps a `main` session on every boot (no `ExecStop`, so a restart never kills live shells).
- **`make fetch-more`** — read-only deep dive beyond `make fetch`: per-core cpu, memory breakdown, top processes, zombies, sockets, units/timers/cron, docker's effective log caps + per-container stats + log sizes, disk+inodes, `data/` growth, tailnet prefs, live DNS probes, TLS expiry.
- **Uptime Kuma upgraded to v2** — `louislam/uptime-kuma:2` (v1 is EOL); `data/kuma` backed up first, DB migrated to `database_version 10`, admin hash preserved.
- **talk-hpb zombie leak fixed** — `init: true` (tini reaps the unreaped `timeout` children); 81 zombies → 0.
- **Edge renamed to `caddy`** — dir/container/image are `modules/caddy`, `caddy`, `caddy:local` (rollback tag `caddy:rollback`); the old names read as a domain and made the compose project name `the app host.net`.
- **Repo is a skeleton** — `{{TOKENS}}` in templates, `${VARS}` from a generated `.env` block in compose, `data/instance.conf` as the only real values, `make render` → `data/rendered/` (the edge mounts that), domain-free filenames, `REPO` derived from the Makefile path; `install.sh` writes the instance file and preserves values it does not own.
- **Root-only {{HOSTNAME}} layout migration** — repo moved to `{{REPO_DIR}}` with all state under `data/`, host + tailnet renamed `{{HOSTNAME}}`, units/cron switched to root, every deployed unit recreated on the new mounts by `scripts/install/migrate-layout.sh`.
- **`make update` split and made safe** — apt moved to its own `apt-upgrade` recipe, `update` runs `scripts/stack/stack-up.sh --update` (failures collected, edge last behind a config gate + image rollback, PostgreSQL unit included) and ends with `make smoke`.
- **`{{HOSTNAME}}-stack.service`** — enabled boot unit that brings every deployed compose unit up via `scripts/stack/stack-up.sh`, edge last.
- **`config/dnsmasq/10-tailnet.conf` rendered at deploy time** — the tracked file keeps a placeholder address; install-config writes the live Tailscale IP and `make backup` restores the placeholder.
- **`scripts/install/uninstall.sh`** — the installer's exact opposite in the same house style: per-module prompts (all default keep), the edge/host-modules/packages/user/tailnet phases in install-reverse order (tailscale last), tagged errors with problem/hint, Enter-refresh re-checks, a success block, and `installed-modules.conf` refreshed after every module removal (empty conf = nothing expected; the file is emptied, never deleted — a missing conf means "all expected" to smoke). Data is never touched without explicit confirms; the storage NFS export is untouchable, sshd hardening deliberately kept. Prompt defaults file: `scripts/install/defaults/uninstall.conf`.
- **Boot-race NFS datadir mount outage (2026-09-12)** — reboot raced the datadir mount against tailscaled (unit started 1 s in, 0 peers) and the default 90 s mount timeout killed it; `nofail` boot continued, docker bound the empty placeholder dir as NC's `/data` → "data directory is invalid" 503s + kuma `cloud.$DOMAIN` HTTP-down alert. Fixed live (systemctl start mount + `make dok-restart-nextcloud`); fstab line now `x-systemd.after=tailscaled.service,x-systemd.mount-timeout=300s,x-systemd.before=docker.service` (written by datadir-nfs.sh `ensure_mount`, applied to the live fstab) so ordering is deterministic and containers never bind the placeholder; GUIDE gotcha has the full lesson.
- **`scripts/install/uninstall.sh` scope selector (2026-09-12)** — the first prompt picks between specific modules (per-module prompts, default keep) and the whole framework (every phase preselected — modules + edge + host services + packages + user + tailnet; data prompts still default keep), plus cancel; preselectable via `uninstall mode` in `scripts/install/defaults/uninstall.conf` or `UNINSTALL_MODE`.
- **Mem limits reviewed + tightened (2026-09-12)** — caddy edge 256m→128m, vaultwarden 512m→384m, roundcube 512m→384m (idle→limit headroom vs realistic spike for every container; caps are ceilings not allocations); live after `make dok-recreate` of the three; smoke green.
- **Welcome-1..3 (2026-09-12)** — three alternate tellings of the repo pitch live at `/welcome-1` (proof: everything is running from one repo), `/welcome-2` (terminal-native tour), `/welcome-3` (the numbers: constraints over screenshots); the original `/welcome` untouched; all four auto-appear in the tail door list and the smoke passes.
- **Welcome-4..9 (2026-09-13)** — six more welcome tellings, each a distinct design: Swiss typographic manifest, vaporwave neon grid, literary journal (split cover + columns), operator's field manual, quiet minimal, monospace poster; all live at `/welcome-4`…`/welcome-9`, cross-linked with the earlier four, auto-catalogued in the tail door list.
- **Welcome pages curated (2026-09-13)** — the operator kept the original `/welcome` plus four favourites: `/welcome-5` (neon), `/welcome-6` (journal), `/welcome-7` (field manual), `/welcome-9` (poster); the other five (proof/terminal/numbers/Swiss/quiet) were removed — files, vhost routes, footer cross-links and the door-list entries all updated, numbers intentionally non-contiguous.
- **GitHub graph empty + ghost contributor fixed** — two-root merge DAG made GitHub's date queries 500 (graph empty since 08-01); single-root linearization restored the cells and scrubbing `Co-Authored-By:` AI-assistant trailer credits removed the ghost contributor (details in the GUIDE 2026-09-06 debug-hell lesson); the two-root repo was deleted and the clean history is now canonical on `$GITHUB_USER/{{REPO_NAME}}` (scratch repos deleted).
- **installer: per-module install selection** — `ask_inputs` now prompts for cloud/vault/mail/monitor (default all ON, env/state-overridable); `phase2_op`, `containers_up`, `cf_dns` and `issue_certs` gate on the choice; defaults come from `scripts/install/defaults/install.conf`; verified with `bash -n` + parser unit test (fresh-VPS run still pending).
- **`make status`** — rebuilt as the AIO dashboard (`scripts/status.sh`): one aligned colored read of perf/modules/git/units/docker/tmux/backups/mail/tailnet with no duplicate rows (the 2026-09-11 list+perf merge listed containers/units twice).
- **Module-aware smoke + status via `installed-modules.conf`** — `install.sh` writes the installed-module list to `$DATA_DIR/installed-modules.conf` at install end; `make smoke` structures its sections per module, still checks everything factually, but marks a failed section whose module was not installed as "intended behaviour" (per-section) and keeps it out of the exit code; a missing conf = all modules expected.
- **`make smoke` expanded** — beyond the vhost checks: tailnet-edge (`/` serves tailnet sources, `/ttyd` challenges without credentials), containers/units/ufw/NFS/disk/nc-status/coturn assertions; `ok` lines carry short plain-words descriptions.
- **`make taildrop-file` / `make taildrop-folder`** — `sudo tailscale file cp` wrappers (`FILE=`/`DIR=`, `TAILDROP_HOST` default `server`).
- **Makefile `TARGET=` dispatchers** — `dok-recreate/restart/stop/logs TARGET=<ctn>` as the primary style; the `-<ctn>` suffixes remain as aliases.
- **`docs/SKELETON.md`** — the token/terms reference (domain, IPs, names, proxy modes) so docs stay portable; secrets excluded; scripts still auto-detect live values.
- **`make install-ttyd` self-kill guard (2026-09-11)** — refuses from any shell inside the ttyd cgroup: the evening's `systemctl restart ttyd` killed the running agent + its tmux session mid-deploy.
- **smoke `nc-status` false FAIL fixed** — the check grepped JSON keys against `occ status` YAML output; now uses `--output=json` and passes.
- **docs neutralised via `docs/SKELETON.md` variables** — GUIDE + MIGRATE now reference `$DOMAIN` / `$DATA_DIR` / `$GITHUB_REPO` (defined per-setup in `docs/SKELETON.md`); README points there; ISSUES keeps concrete values as tracker + history.
- **`scripts/install/defaults/`** — per-script prompt-defaults files (`install.conf` populated, `optimize.conf`/`storage.conf` skeletons); README + www copy matched to the real module flow.
- **Debian VPS → Debian system wording** — README and the www welcome lede no longer imply only a rented VPS.
- **`optimize.sh` universal VPS optimizer** — OPTIMIZE.md + repo tuning + `make cleanup`'s apt/docker part merged into one idempotent, zero-prompt bash script with an Enter-refresh error loop; applied here (swap RAM/3, noatime, THP, sysctls, tuned/irqbalance/earlyoom auto, SSD/HDD auto-detect → fstrim or SETRA).
- **`turn.$DOMAIN` renamed `talk.$DOMAIN`** — vhost, DNS (grey-cloud A record), occ signaling entry, coturn cert path, smoke and docs updated; stale cert dir removed.
- **`shell.$DOMAIN` renamed `tail.$DOMAIN`** — vhost now serves a clickable vhost-links home at `/`, ttyd at `/ttyd`; dnsmasq + smoke + docs updated.
- **All 301 redirects upgraded to 308** — CardDAV/CalDAV well-known redirects included.
- **Docs restructured** — AGENTS.md portable-only (project specifics + lessons + intended moved to GUIDE.md), ISSUES.md Solved one sentence per record, volatile operator-editable state removed everywhere.
- **`$GITHUB_USER/{{REPO_NAME}}` GitHub web page restored after history rewrite** — web code views 404'd and git-data API 500'd while git/raw/codeload stayed healthy; fixed by pushing an empty nudge commit (`daf119d`), which rebuilt GitHub's index (intermittent 500s for ~10 min while settling).
- **`modules/nextcloud/.env` purged from all GitHub history** — removed from every commit via `scripts/ops/drop-path.sh` plumbing rebuild (661 commits / 2 roots / 9 merges preserved, tip tree byte-identical); the exposed NC admin password is moot — the account no longer exists.
- **Local backup tags destroyed** — `history-backup-20260902` / `history-20260902-noreply` / `history-developer-email-20260903` deleted + objects pruned (`gc --prune=now`); the $GITHUB_USER-era record lives on only inside `main` under the noreply identity, per operator choice.
- **NC recovery manifests moved out of the repo** — `users/groups/default-quota/apps.txt` now live at `homelab/cloud/recovery/` (root-owned, outside the repo like pgdata), generated by `make nc-capture`, consumed by install.sh; paths scrubbed from all history (664 commits preserved, personal doc addresses censored via `scripts/ops/replace-string.sh`).
- **Storage VPS onboarded (Setup A)** — `scripts/ops/datadir-nfs.sh` migrated Nextcloud's datadirectory to the 1 TB VPS (`/srv/nextcloud-data` NFS export at `cloud/users`); PostgreSQL stays on the app host and the nightly `pg_dump` → `/backups/nc` runs alongside.
- **datadir-nfs.sh live-run fixes (2026-09-10)** — the first live run exposed a missing NFS client (`nfs-common`) and an unverified rollback delete that lost the datadirectory files; the script now installs the client, verifies the copy before the delete prompt, and installs the operator's ssh key — files were restored from `backups/cloud-backup-20260906`.
- **goose secret moved out of the repo** — the unit reads `EnvironmentFile=/etc/goose/goose.env` (root:root 0640); `install.sh` generates it there instead of `sed`ing it into a tracked file.
- **NFS datadirectory mount tightened** — `/etc/fstab` options are now `rw,nofail,_netdev,noatime,vers=4`.
- **Nextcloud password policy hardened** — the app is re-enabled with `minLength=16`, upper/lower/special/numeric requirements and the common/compromised-password lists on.
- **False alarm: the "undocumented host process" was the uptimekuma container** — host `ps` lists container processes (`node server/server.js` → `docker-<id>.scope` = uptimekuma; `supervisord` = mailserver), not stray host daemons.
- **optimize.sh live-run bugs fixed (2026-09-10)** — `append_lines()` doubled `/etc/fstab` and `/etc/security/limits.conf` (which broke the noatime step) and re-checks false-failed on a box without docker; it now appends only missing lines, skips absent software, and installs only the performance helpers (tuned/irqbalance/earlyoom).
- **Fresh-install installer bugs (2026-09-22)** — fixed in `install.sh`/`goose-tokens.sh`: missing `python3-yaml`, an untraversable `caddy_data` dir, `talk:turn:add` flags instead of positional protocols, non-idempotent DKIM keygen + a truncated publish source, a stuck ACME order, `trusted_domains` clobbered with the bare domain, and the `sweep`/recheck scope mismatch.
- **Installer no longer ships prompt defaults (2026-09-25)** — `scripts/install/defaults/` deleted; every prompt is always asked and a re-run asks whether to resume (no re-asks all).
- **Installer hostname + accounts (2026-09-25)** — hostname set to `kefoserver` (the tailnet node name) and every non-root login account removed.
- **Installer goose dependency (2026-09-25)** — `bzip2` added to the apt set so goose's `.tar.bz2` release extracts (its absence surfaced as a phantom unexpected error).
- **Installer aborted mid-run (`ROOT: unbound variable`)** — its `$ROOT/data/...` paths used a name only the rest of the repo defines (`$REPO` was the checkout root here); `$ROOT` is now an alias.
- **False `render` error tag on a healthy run (2026-09-25)** — `write_instance_conf` logged and rendered into `$LOG` before the installer created `$LOG_DIR`, so the redirect failed and the renderer never ran.
- **`GITHUB_USER` resolved to the placeholder and rewrote `origin` to it (2026-09-25)** — the installer now derives the owner from the checkout's `origin` remote and writes it into `instance.conf`.
