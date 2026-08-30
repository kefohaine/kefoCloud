# Project guide

How to operate `fxmq.net` — the project's repository layout, deployment commands, protected host resources, per-service edit-safe facts, and operational gotchas. Read this before editing anything.

For system architecture and design rationale, see `README.md`. For agent rules, see `docs/AGENTS.md`. For open problems and improvements, see `docs/ISSUES.md`.

## Repository layout

Top-level dirs: `services/` (one compose file per running container), `config/` (reference copies of host configs, restored by `make install-config`), `docs/` (agent rules, this guide, issue tracker, migration runbook), `scripts/` (installer + kuma import), `archives/` (retired jehpok-era Flask apps, moved out of `content/` in the Aug 2026 cleanup — not deployed). `ls` is the source of truth — what's described here is the intent, not the full inventory.

- `services/<ctn>/docker-compose.yml` — one per running container. Compose files are the source of truth for images, env vars, ports, volumes, healthchecks, and logging.
- `config/` — reference copies of host-level configs (goose systemd unit, SSH hardening, dnsmasq, ttyd, docker daemon, sysctl, PufferPanel server template). Restored to live paths by `make install-config`. For an offline copy of the whole `config/` tree, use `make bundle-config`.
- `docs/` — `AGENTS.md`, `GUIDE.md` (this file), `ISSUES.md`, `MIGRATE.md` (runbook for moving to a new VPS; printed by `make migrate`).

## Deployment

Manual — no CI/CD, pushes to `main` trigger nothing. Use the `Makefile` recipes (canonical) rather than raw `docker compose`.

### First-time setup and migration

`scripts/install.sh` is the plug-and-play path: it prompts for the domain, Cloudflare API token, and Tailscale auth key, then runs unattended — host services, docker, tailscale, the four containers (Caddy, `nextcloud`, `vaultwarden`, `uptimekuma`), Cloudflare DNS records, and certs. `make migrate` prints the manual runbook (`docs/MIGRATE.md`).

### CMD Sheet

```bash
make                   # default: print help with categories
make migrate           # cat docs/MIGRATE.md — the full VPS-to-VPS migration runbook
make deploy            # copy config/ to live + extract the latest secrets bundle (self-contained)
make update            # apt update/upgrade + pull all images + recreate all compose units (self-contained)
make backup            # full snapshot: container data + live secrets compressed into $(REPO)/backups/; live config pulled into $(REPO)/repo/config/ subdirs (the one uncompressed part)
make cleanup           # apt autoremove+clean; docker prune; backups keep latest 3 (self-contained)
make status            # overview: git; systemd; docker; tmux; backups; mails
make smoke             # live edge test: every vhost must serve its real app + SMTP/IMAP banners (scripts/smoke-vhosts.sh)
make install-hooks     # install git hooks: pre-commit (Caddy validate + app-vhost stub guard) + pre-push (runs make smoke)
make dok-recreate-<ctn>  # force-recreate one container — dok-recreate-fxmq.net (rebuilds, buildx fallback) | dok-recreate-uptimekuma | dok-recreate-nextcloud | dok-recreate-vaultwarden | dok-recreate-pufferpanel | dok-recreate-mailserver | dok-recreate-roundcube
make dok-recreate-all  # recreate every compose unit in order (self-contained loop)
make dok-restart-<ctn> # restart every container in the compose file — after editing a mounted config
make dok-restart-all   # restart every compose unit (mailserver unit = mailserver + roundcube)
make dok-stop-<ctn>    # stop the compose unit (mailserver unit = mailserver + roundcube)
make dok-stop-all      # stop every compose unit
make dok-logs-<ctn>    # follow one container's logs
make dok-logs-all      # tail all container logs in one stream, each line prefixed with [container]
make systemd-restart-<svc>  # restart one host service (ttyd | dnsmasq | goose)
make systemd-restart-all    # restart all host services
make systemd-log-<svc>      # follow one host service journal
make systemd-log-all        # follow all host service journals
make git-pull         # git pull homelab main
make git-add          # git add -A in $(REPO)/repo
make git-com MSG="…"  # git commit -m MSG (MSG required)
make git-push         # git push homelab main
make bkp-cloud        # snapshot Nextcloud data (maintenance mode on during the copy)
make bkp-vault        # tar the Vaultwarden data dir to $(REPO)/backups/vault-backup-<date>.tar.gz
make bkp-list         # list every artifact under $(REPO)/backups/ + count per pattern
make bundle-secrets   # collect live secrets into $(REPO)/backups/secrets-bundle-<date>.tar.gz
make install-secrets  # extract a secrets bundle to live paths (BUNDLE=<path> to override)
make bundle-config    # snapshot $(REPO)/repo/config/ into $(REPO)/backups/config-bundle-<date>.tar.gz
make install-config-bundle  # extract a config bundle into $(REPO)/repo/config/ (BUNDLE=<path> to override)
make install-config   # one-shot host bootstrap: install ttyd, copy config/ to live, enable goose + ttyd + sshd + dnsmasq, open UFW rule
make install-<file>   # per-file install from config/ → live (goose, ttyd, ssh, dnsmasq-conf, dnsmasq-override, docker, sysctl)
make kuma-import      # import an adapted Uptime Kuma db from another host (KUMA_DB=/path)
make mail-add-user USER=name@fxmq.net  # create a mailbox — password is prompted via read -s, never on the command line
make mail-passwd USER=name@fxmq.net    # rotate a mailbox password (also prompted)
make mail-del-user USER=name@fxmq.net  # delete mailbox + aliases + quota
make mail-list-users                   # list mailboxes (with quota usage)
make mail-gen                          # disposable mailbox: random 7-letter address + random 16-char password, printed once
make mail-alias-gen TO=target@example.com  # disposable forwarding alias: random 7-digit address → TO (external target required — same-domain refused)
make mail-alias-del ALIAS=x@fxmq.net TO=target@example.com  # remove a target from an alias (DMS needs ALIAS + TO)
make mail-alias-list                   # list aliases
make clean-docker      # prune builder / image / container
make clean-apt         # apt autoremove + clean
make clean-backups     # keep latest 3 backups per pattern, delete older
make tmux-new TAG=<n>  # create a detached tmux session <n>
make tmux-open TAG=<n> # attach to session <n> (Ctrl-b d to detach)
make tmux-kill TAG=<n> # kill session <n>
make tmux-list         # list sessions (prints "No tmux sessions." when none)
```

When a recipe covers the task, use the recipe. Raw `git`, `docker compose`, `docker exec`, `systemctl restart`, and `tar` are reserved for cases no recipe covers (one-off diagnostics the operator asked for, log/file inspection, ad-hoc reads).

`make git-com MSG="…"` takes a single-sentence `MSG` only. Two quoting constraints: embedded newlines break the `git commit -m "..."` quoting through `bash -c` and fail with `unexpected EOF` before the commit lands, and embedded double-quote characters break the recipe's own `$(MSG)` substitution (the recipe's `[-z "$(MSG)"]` check sees word-split fragments and errors with `[: too many arguments]`, then `git commit -m` interprets the unquoted remainder as paths). If the message needs a quote mark, wrap the whole `MSG=` in single quotes (`make git-com MSG='…'`) — the shell does not interpolate inside single quotes, so the embedded `"` survives intact. The diff speaks for itself; the message only needs to round-trip through bash.

## Protected host resources

**Never delete or disable any of these without explicit operator approval.** Per `docs/AGENTS.md` safety rule 1, if a task seems to require removing any of them, stop and ask.

- `/etc/systemd/system/goose.service` — goose agent systemd unit (`enabled`, `Restart=always`).
- `/etc/systemd/system/ttyd.service` — ttyd web-terminal unit (`enabled`, `Restart=always`). Binds `172.22.0.1:7681` only (host bridge IP), gated by the Caddy tailnet match and the UFW INPUT allow from `172.22.0.0/16`.
- `/etc/dnsmasq.d/10-tailnet.conf` and `/etc/systemd/system/dnsmasq.service.d/override.conf` — host DNS resolver + systemd drop-in (`Restart=always`). Binds `100.117.144.0:53` (the Tailscale IP).
- `/var/www/custom/projects/homelab/certs/` — RETIRED. The wildcard Cloudflare Origin cert that used to live here is no longer referenced by any vhost (the per-vhost ACME certs serve every hostname). The directory and the files inside it are kept on disk for audit/history but can be deleted without breaking the running system.
- `/var/www/custom/projects/homelab/caddy_data/` — Caddy runtime data dir (LE certs under `caddy/acme/`, ACME account keys, OCSP staples) and the `CF_API_TOKEN` file used for per-vhost ACME DNS-01. The Caddy container bind-mounts this dir at `/data` so certs persist across container recreates. The `CF_API_TOKEN` file is created by the operator (see `docs/MIGRATE.md`); do not commit it.
- `/var/www/custom/projects/homelab/cloud/html/` and `/var/www/custom/projects/homelab/cloud/users/` — Nextcloud bind mounts (html root + datadirectory; both owned by uid 33 with a `.ncdata` marker in `users/`).
- `/var/www/custom/projects/homelab/download/` — file-browser drop folder, served read-only at `mc.fxmq.net/download` (Caddy bind mount `/download:ro`). Owned by `op`; anything dropped here is publicly readable.
- `/var/www/custom/projects/homelab/mailserver/` — mail platform data: `data/` (Maildirs), `state/`, `logs/`, `config/` (DMS config incl. DKIM keys), `roundcube/` (webmail sqlite). Owned 5000:5000 / 33:33 as noted in the compose file.
- `net` Docker network — user-defined bridge, `external: true`, subnet `172.22.0.0/16`. Reused by all inter-container services.
- SSH keys, Nextcloud data, Vaultwarden data, uploaded files — user-only (also `docs/AGENTS.md` safety rules 7 and 8).

## SSH access

SSH is restricted to the Tailscale network only — the public internet cannot reach port 22. Password auth is disabled; root login is key-only (`PermitRootLogin prohibit-password`); `AllowUsers op root`. Config: `/etc/ssh/sshd_config.d/50-cloud-init.conf`. The installer (`scripts/install.sh`) writes this file for user `op` and keeps root key access.

## Service reference

The compose files are the source of truth. This table is the one-line reference for each service.

| Service | Compose | Container | Edit mounted config | After compose / image change |
|---------|---------|-----------|---------------------|------------------------------|
| caddy   | `services/fxmq.net/docker-compose.yml` | `fxmq.net` | `make dok-restart-fxmq.net` | `make dok-recreate-fxmq.net` (rebuilds `fxmq.net:local` from `services/fxmq.net/Dockerfile`) |
| cloud   | `services/nextcloud/docker-compose.yml` | `nextcloud` | `make dok-restart-nextcloud` | `make dok-recreate-nextcloud` |
| vault   | `services/vaultwarden/docker-compose.yml` | `vaultwarden` | `make dok-restart-vaultwarden` | `make dok-recreate-vaultwarden` |
| kuma    | `services/uptimekuma/docker-compose.yml` | `uptimekuma` | `make dok-restart-uptimekuma` | `make dok-recreate-uptimekuma` |
| panel   | `services/pufferpanel/docker-compose.yml` | `pufferpanel` | `make dok-restart-pufferpanel` | `make dok-recreate-pufferpanel` |
| mailserver | `services/mailserver/docker-compose.yml` | `mailserver` + `roundcube` | `make dok-restart-mailserver` | `make dok-recreate-mailserver` |
| terminal | n/a (host systemd; see Protected host resources) | n/a | `make systemd-restart-ttyd` | `make install-config` (reinstall) |
| dnsmasq | n/a (host systemd) | n/a | `make systemd-restart-dnsmasq` | n/a |
| goose   | n/a (host systemd; see Protected host resources) | n/a | `systemctl restart goose` | n/a |

The `net` Docker network is `external: true` — create once on a fresh host with `docker network create net --subnet=172.22.0.0/16` (the compose files pin `172.22.0.x` bridge IPs; a default-subnet network rejects them). All inter-container services use `expose`, not `ports`. The exception is `fxmq.net`: it runs with `network_mode: host` so Caddy sees the real client source IP — without host networking, Docker DNAT rewrites every packet to `172.22.0.1` (the bridge gateway) before Caddy sees it, which breaks the `@not_tailnet` remote_ip matcher on `https://shell.fxmq.net`. The host network namespace is on the `net` bridge at `172.22.0.0/16`, so Caddy still dials upstream containers by their bridge IP (see Caddyfile). dnsmasq binds to the Tailscale IP only, not `0.0.0.0`.

### Per-service edit pointers

When you need to know "what does X do / where do I edit Y", read the file at the path below — the docs don't re-type the contents.

- **`fxmq.net`** (Caddy) — vhosts, snippets, header policy: `services/fxmq.net/Caddyfile` (top-level config + per-vhost imports) and `services/fxmq.net/vhosts/*.caddy` (one per hostname: `cloud`, `kuma`, `mc`, `shell`, `vault`, `www`). Compose + bind mounts + custom Dockerfile (Caddy built with the `caddy-dns/cloudflare` plugin for ACME DNS-01): `services/fxmq.net/docker-compose.yml`. Runs `network_mode: host` — see note above. Every vhost has its own `tls { dns cloudflare { env.CF_API_TOKEN } }` block; don't replace it with `tls internal` / `tls off` / `tls self_signed`. This dir is bind-mounted into the running container at `/etc/caddy` — vhost edits are live config and take effect on the next `docker restart fxmq.net`; after any such restart run `make smoke`. The pre-commit hook blocks bare `respond "ok"` stubs in the app vhosts (see `docs/AGENTS.md` "Edge guardrails").
- **`cloud`** — Nextcloud env, PHP-FPM pool tuning, bind mounts: `services/nextcloud/docker-compose.yml` + `services/nextcloud/php-fpm.d/zz-custom.conf`. Admin creds: `services/nextcloud/.env` (gitignored — read access only via the operator).
- **`vault`** — env, bind mount, admin token: `services/vaultwarden/docker-compose.yml`.
- **`kuma`** — image, bind mount, healthcheck: `services/uptimekuma/docker-compose.yml`. Monitor definitions live in Kuma's SQLite (`services/uptimekuma/seed-monitors.sql` seeds them; applied by the installer).
- **`panel`** — PufferPanel game panel: `services/pufferpanel/docker-compose.yml`. Served at `https://mc.fxmq.net/panel` (Caddy vhost `services/fxmq.net/vhosts/mc.fxmq.net.caddy`): `/panel` is prefix-stripped, and because the panel SPA has no subpath support (absolute history-mode routes), its baked root routes (API, auth pages, SPA pages + chunks at `/js` `/assets`, swagger, favicon/manifest) are proxied by the vhost's `@panel_infra` block — the exact path list lives in the vhost file. The vhost overrides PufferPanel's `max-age=60` on static chunks with 1-day cache headers (panel upgrades self-invalidate via hashed chunk names). SFTP on the bridge at `:5657`; mounts the Docker socket rw (required to start). Admin credentials: `/var/www/custom/projects/homelab/puffer/admin-pass.txt` (created at setup; update it after any password reset).
  **Registration lockdown (2026-08-30 incident — enforced by `make smoke`)**: public registration must stay closed on BOTH layers — the backend toggle `panel.registrationenabled` in the live config `/var/www/custom/projects/homelab/puffer/data/config.json` (the panel reads `/var/lib/pufferpanel/config.json`; the `puffer/config/` mount at `/etc/pufferpanel` is unused) AND the Caddy edge, which 403s `/panel/register*`, `/auth/register*` and `/panel/auth/register*` (the prefix-stripped API route — the incident left only the UI path blocked, so `POST /panel/auth/register` was live). `make smoke` asserts: UI + API register paths 403, config toggle `false`, admin account (id 1) exists with admin scope and a non-empty password hash.
  **Admin login recovery**: if the admin password stops working, reset it with `mkpasswd -m bcrypt <newpass>` on the host, then as root `UPDATE users SET password='<hash>' WHERE id=1` in `puffer/data/pufferpanel.db` (SQLite WAL — the panel holds it open; a short write lock is fine), then `make dok-restart-pufferpanel` (the daemon caches users at boot — a restart is required). Do NOT use `pufferpanel user edit` in-container: it fails with `group: unknown group pufferpanel` and hangs. Verify with `curl -X POST https://mc.fxmq.net/panel/auth/login -d '{"email":"admin@fxmq.net","password":"..."}'` → 200.
- **`mc.fxmq.net`** — PufferPanel at `/panel` (see `panel`); Caddy file browser at `/download` over the `homelab/download` drop folder (bind-mounted into the caddy container at `/download:ro`); `/` redirects to `/panel` (the `mc-home` homepage app was removed 2026-08-28). **`mc.fxmq.net` A record MUST be DNS-only at Cloudflare** (grey cloud): CF's proxy only carries 80/443, so a proxied record breaks the game ports. Caddy's 443 still works DNS-only (DNS-01 cert). After any CF record change, `make systemd-restart-dnsmasq`.

  **Template + portable backup**: the deployable PufferPanel server JSON is at `config/pufferpanel/servers/2ecfbe8c.json` (drop into `puffer/data/servers/<id>.json` to deploy). The server's custom config files — `server.properties`, `bukkit.yml`, `spigot.yml`, `config/paper-global.yml`, `config/paper-world-defaults.yml`, `whitelist.json`, `ops.json`, `server-icon.png`, `plugins/{Chunky,StackMob,Geyser-Spigot}/config.yml` (+ StackMob `entity-translation.yml`) — are the portable part for porting to other modloaders; taildrop them as a tarball to `macoslaptop:` (`sudo tailscale file cp <tar> macoslaptop:`).

  **Minecraft server (manual lifecycle — lazymc + mc-idle-sleeper removed 2026-08-28):** the Paper server (`2ecfbe8c`, host-net) binds directly on public Java port `25565` (`server.properties` `server-ip=0.0.0.0` / `server-port=25565`; no proxy in front). The daemon removes the game container on stop and creates a fresh one per start, so `docker start` can't restart a stopped game server — start/stop goes through the panel UI or API (`mc.fxmq.net/panel`, or `POST /api/servers/2ecfbe8c/start|stop` with a `puffer_auth` cookie from `POST /auth/login`). **Bedrock**: Geyser-Spigot plugin on UDP `19132` (default config); UDP 19132 only answers while the server is running. The server runs **online-mode** with **Floodgate** (`auth-type: online`): Bedrock players join as `.<xbox-name>` authenticated via Xbox (no Java account needed — Floodgate bridges them onto the online-mode server), Java players are Mojang session-verified with real skins (the 2026-08-25 offline-mode detour was based on a false Floodgate premise — see `docs/ISSUES.md` Lessons learned), anti-xray enabled (engine 2), `enforce-whitelist=true`. UFW allows `25565/tcp` + `19132/udp`; RCON is disabled. Server JSON: `memory` 3584 (3.5 GiB — live) + Aikar JVM flags, `simulation-distance 4` / `view-distance 8` / `spawn-protection 0`, culling with `keep-spawn-loaded: false`, item despawn 6000 ticks (5 min: `item-despawn-rate` / `arrow` / `trident` in spigot.yml, `alt-item-despawn-rate.items.cobblestone` in paper-world-defaults.yml), world autosave `auto-save-interval` 72000 ticks (1 h), despawn-ranges explicit vanilla (soft 32 / hard 128 blocks), plugins **Chunky** + **StackMob** + **Geyser-Spigot** + **Floodgate** (spark + bStats pre-existing). Whitelist kicks log as one line and show the username in the kick text (custom plugin **WhitelistMsg**; jar lives in the server's `plugins/` dir — the source is not in the repo, removed in the Aug 2026 cleanup).
- **`terminal`** — ttyd at `shell.fxmq.net/ttyd`, runs as a host systemd unit (not a container). Binary at `/usr/local/bin/ttyd`, unit at `/etc/systemd/system/ttyd.service` (reference copy in `config/ttyd/ttyd.service`). Runs with `-b /ttyd` — base-path aware, so Caddy's `handle /ttyd*` must proxy the full path (no `handle_path` strip). No systemd sandbox (operator preference: no permission hunts). Runs as `op` with NOPASSWD sudo, so full host control from the shell. Access control is at the network layer (Tailscale membership + Caddy `@not_tailnet`), not the unit sandbox. `make install-config` installs the binary (static 1.7.7 from upstream) and the unit; the step is idempotent. Caddy proxies to the host bridge IP `172.22.0.1:7681` with `transport http { versions 1.1 }` (ttyd only speaks HTTP/1.1); the UFW INPUT allow from `172.22.0.0/16 → 7681/tcp` is added by `make install-config`.
- **mail** — Docker Mailserver + Roundcube: `services/mailserver/docker-compose.yml` (mail at 172.22.0.9 publishes 25/465/587/993; roundcube at 172.22.0.10, webmail only). Both containers carry compose healthchecks (SMTP/IMAP ports via `ss`, web root via `curl`) — `docker ps` shows them `healthy`; `make smoke` covers the same ground from outside. TLS is the per-vhost LE cert for mail.fxmq.net from caddy_data, mounted read-only (SSL_TYPE=manual; DMS changedetector reloads on renewal). Mailbox management goes through the `make mail-*` recipes (see CMD sheet) — the recipes prompt for passwords, so nothing lands in shell history; never read `services/mailserver/.env` or the password hashes in `mailserver/config/postfix-accounts.cf` (see `docs/AGENTS.md` rule 9).
  **Disposable addresses**: `make mail-gen` creates a random 7-letter mailbox (local part always generated — no custom names; e.g. `qkzfwbc@fxmq.net`) with a random 16-char password fed via stdin — credentials print once and are stored nowhere; hand them out, then delete with `mail-del-user`. For pure forwarding without a mailbox, `make mail-alias-gen TO=<target>` — the alias is a random 7-digit address (e.g. `4839201@fxmq.net`) forwarding to TO; **TO must be an external address** — same-domain targets are refused by the script (an alias forwarding to an `@fxmq.net` mailbox would grant that mailbox send-as for the alias, and disposable forwarders are external-only by design; a custom internal forward, if ever truly needed, is a deliberate `setup alias add` decision); remove with `mail-alias-del` (needs ALIAS + TO; DMS aliases support multiple targets). `postmaster@fxmq.net` is a real mailbox (restored 2026-08-29) kept separate from `admin@fxmq.net` — RFC 5321 requires postmaster to be deliverable, and it's the conventional address for bounces/complaints. To make an *inbound-only* address: DMS has no receive-only flag, so create a mailbox with a password only you hold (`make mail-add-user USER=inbox@fxmq.net`) — anyone can send to it, nobody can log in or send from it without your password; or use an alias for pure forwarding.

  **Spoof-proofing**: `SPOOF_PROTECTION=1` on the mailserver (compose) — postfix runs `reject_authenticated_sender_login_mismatch` on submission, so each user may only send as their own address **plus any alias whose target is their mailbox** (the sender-login map is built from accounts + aliases; verified `postmap -q <alias>` returns the alias target — so an alias forwarding TO a mailbox grants that user send-as for the alias from external clients; an alias to an *external* address grants nobody, since no local account can authenticate as it). Roundcube `identities_level = 3` (in `roundcube-tls.inc.php`) locks the identity address to the login mailbox — the webmail From dropdown only ever shows the user's own address; users can't add an `admin@fxmq.net` identity, and can only edit name/signature. Roundcube's `users` table has no admin flag in this version, so no roundcube admin UI exists for anyone. Roundcube connects with STARTTLS over the bridge (dovecot/postfix reject plaintext auth) — the override file `services/mailserver/roundcube-tls.inc.php` + the compose `extra_hosts` entry map mail.fxmq.net to 172.22.0.9 so SNI/cert match. Mailboxes are managed with `docker exec mailserver setup email add|list|del <addr>`; credentials for admin@/postmaster@ are in `services/mailserver/.env` (gitignored). DKIM keys + generated DNS records live in `/var/www/custom/projects/homelab/mailserver/config/opendkim/keys/fxmq.net/`. DNS: MX + mail.fxmq.net A are DNS-only at Cloudflare; SPF/DMARC/DKIM TXT set (selector `mail`).
- **dnsmasq** — config: `config/dnsmasq/10-tailnet.conf` (live path: `/etc/dnsmasq.d/10-tailnet.conf`). systemd drop-in: `config/dnsmasq/dnsmasq.service.conf` (live path: `/etc/systemd/system/dnsmasq.service.d/override.conf`).
- **goose** — unit: `config/goose/goose.service` (live path: `/etc/systemd/system/goose.service`).

## File ownership

The repo is owned by `op:op` (the SSH/login user). Edit directly when signed in as `op`; use `sudo` only if acting as another user. Do not `chown` the repo to a different user.

## Git remotes

- `homelab` — SSH remote (`git@github.com:friedutch/homelab.git`). The only remote; use for pushes and pulls.

```bash
git push homelab main
```

## Operational gotchas

- A deliberate `systemctl stop dnsmasq` takes all tailnet-side `*.fxmq.net` resolution down. Restart with `make systemd-restart-dnsmasq`.
- **A panel container restart stops a running game server** — the daemon reconciles at boot: if the game container is running when the panel restarts, it gracefully stops and removes it; players are kicked (world saved) and the server stays stopped until started manually from the panel. Disruptive but clean.
- **Bedrock clients can't reach a stopped server** — Geyser lives inside the game server, so UDP 19132 only answers while the server is running.
- **Dovecot/postfix reject plaintext SMTP/IMAP auth** — Roundcube must use STARTTLS (`tls://mail.fxmq.net:143` / `:587`). The env-derived `ROUNDCUBEMAIL_*` settings in the compose file cannot express the TLS prefix; the override lives in `services/mailserver/roundcube-tls.inc.php` (included by the image entrypoint) and the compose `extra_hosts` maps the FQDN to the bridge IP.
- **Mail DNS records must stay DNS-only at Cloudflare** — MX and the `mail.fxmq.net` A record are grey-clouded; a proxied record breaks SMTP/IMAP (CF only proxies HTTP(S)).
- **PTR is provider-side** — the IP has no PTR record (inbound 25 is now open), so outbound mail reputation with Gmail/Outlook is blocked until the operator sets reverse DNS at the provider (see `docs/ISSUES.md`).
- New `*.fxmq.net` CF records can appear "down" on tailnet devices: dnsmasq negative-caches the NXDOMAIN if the hostname was queried before the record existed. After creating a CF record, `make systemd-restart-dnsmasq` (see Lessons learned in `docs/ISSUES.md`).
- The Makefile sets `SHELL := /bin/bash` explicitly. Without it, recipes run under `/bin/sh` (dash on Debian) and `set -eu` semantics differ — `dash` aborts on any unset variable reference, while `bash` only aborts on expansion failures. If you see `parameter not set` from a recipe, the Makefile shell setting is the first place to look.
- Cloudflare's free tier rate-limits rate-limit rules to a 10s min window. Plan ahead if a public endpoint ends up attracting more traffic than expected.
- **Every Caddy vhost has its own TLS block** — don't reintroduce a shared wildcard cert. The wildcard CF Origin cert at `$(REPO)/certs/` covered `*.fxmq.net`, so a vhost without its own `tls` directive would pick up the wildcard as a SNI fallback and the per-vhost ACME automation policy would never fire. Lesson: a vhost with no `tls` directive appears to "use ACME by default" but actually picks up any loaded cert that matches the SNI.
- **Caddy stock `caddy:2.x` doesn't include `caddy-dns/cloudflare`** — needs a custom `xcaddy` build (see `services/fxmq.net/Dockerfile`). Also: `caddy-dns/cloudflare` v0.2.3 rejects the new 53-char CF token format with a generic "API token appears invalid" error during plugin provisioning — pull from `caddy-dns/cloudflare@a8737d0` (master) until a tagged release ships the regex fix.
- **`caddy:2.11.4` requires Go ≥ 1.25.1** to build — the `golang:1.25-bookworm` image satisfies this. Older builder images (e.g. `golang:1.24-bookworm`) fail with `go: github.com/caddyserver/caddy/v2@v2.11.4 requires go >= 1.25.1`. If you bump Caddy, check the new `go.mod` `go` directive and bump the builder image too.
- **`network_mode: host` is required for `@not_tailnet` to work.** Docker DNAT rewrites every packet to `172.22.0.1` (the bridge gateway) before Caddy sees it. Without `network_mode: host`, the `100.64.0.0/10` matcher matches nothing and every tailnet request gets 403. This is set in `services/fxmq.net/docker-compose.yml` — do not "fix" it.
- **`docker compose env_file:` reads the file as the UID running `make`, NOT as the UID inside the container** — compose parses `env_file:` at the host side. The `CF_API_TOKEN` file must be readable by the user running the compose command (`op`), mode 0644; chowning it to the container's uid (201) breaks the read and Caddy ends up with no token.
- **`make dok-recreate-fxmq.net` (or `make dok-recreate-all`) takes ~3 minutes on a fresh VPS and prints zero progress** — `docker compose up --build` runs `docker build` in a streaming-tty mode that buffers until the step finishes. The build chain is `golang:1.25-bookworm` → `go install xcaddy` → `xcaddy build --with caddy-dns/cloudflare@a8737d0 v2.11.4` → `FROM caddy:2.11.4` + `COPY --from=builder`. `docker build --progress=plain` shows the steps.
- **The cert's issuer is the only reliable indicator of which path it took** — `curl -sk` returning 200 means "the listener responded", not "the right cert was served". Check `openssl x509 -noout -issuer` on a fresh `-no-keepalive` handshake. On CF-proxied hosts (every public vhost) the handshake sees Cloudflare's edge cert (issuer `Google Trust Services WE1`), not the origin's — check the origin cert with `openssl s_client -connect 127.0.0.1:443 -servername <host>` from the host instead (issuer should be `Let's Encrypt`).
- **Host performance tuning** — network stack (`config/sysctl/99-homelab.conf`): BBR + `fq` qdisc, `tcp_fastopen=3`, `tcp_slow_start_after_idle=0`; Docker (`config/docker/daemon.json`): pull concurrency 10/10, `userland-proxy: false` (no compose publishes ports, so no behavior change); dnsmasq (`config/dnsmasq/10-tailnet.conf`): `cache-size=10000`.
