# Project guide

How to operate `fxmq.net` — the project's repository layout, deployment commands, protected host resources, per-service edit-safe facts, and operational gotchas. Read this before editing anything.

For system architecture and design rationale, see `README.md`. For agent rules, see `docs/AGENTS.md`. For open problems and improvements, see `docs/ISSUES.md`.

## Repository layout

The repo splits into four directories. `ls` is the source of truth — what's described here is the intent, not the full inventory.

- `services/<ctn>/docker-compose.yml` — one per running container. Compose files are the source of truth for images, env vars, ports, volumes, healthchecks, and logging.
- `config/` — reference copies of host-level configs (goose systemd unit, SSH hardening, dnsmasq, ttyd, maintenance timer + script, sysctl, Claude Code deny-list). Restored to live paths by `make install-config`. For an offline copy of the whole `config/` tree, use `make bundle-config`.
- `content/` — app sources and static files mounted into containers. Currently empty after the migration trimmed the service set; the directory is kept for future app containers.
- `docs/` — `AGENTS.md`, `GUIDE.md` (this file), `ISSUES.md`, `MIGRATE.md` (runbook for moving to a new VPS; printed by `make migrate`).

## Deployment

Manual — no CI/CD, pushes to `main` trigger nothing. Use the `Makefile` recipes (canonical) rather than raw `docker compose`.

### First-time setup and migration

`scripts/install.sh` is the plug-and-play path: it prompts for the domain, Cloudflare API token, and Tailscale auth key, then runs unattended — host services, docker, tailscale, the four containers (Caddy, `nextcloud`, `vaultwarden`, `ut-kuma`), Cloudflare DNS records, and certs. `make migrate` prints the manual runbook (`docs/MIGRATE.md`).

### CMD Sheet

```bash
make                   # default: print help with categories
make d-recreate-all    # start/recreate all containers in order (fxmq.net, nextcloud, vaultwarden, ut-kuma)
make d-restart-all     # restart every container + dnsmasq + ttyd
make d-logs-all        # tail all container logs in one stream, each line prefixed with [container]
make bkp-all           # chain bkp-cloud + bkp-vault in order
make clean-all         # chain: clean-docker + clean-apt + clean-backups
make d-recreate-<ctn>  # force-recreate one container — d-recreate-fxmq.net (rebuilds) | d-recreate-nextcloud | d-recreate-vaultwarden | d-recreate-ut-kuma
make d-restart-<ctn>   # restart every container in the compose file — after editing a mounted config
make restart-dnsmasq   # restart the host dnsmasq resolver — after editing config/dnsmasq/10-tailnet.conf
make restart-ttyd      # restart the host ttyd service — after editing config/ttyd/ttyd.service
make d-logs-<ctn>      # follow one container's logs
make logs-dnsmasq      # follow the dnsmasq journal
make logs-ttyd         # follow the ttyd journal
make status            # show a table of all running containers + host systemd units
make update            # apt update/upgrade + pull all images + make d-recreate-all
make install-config    # one-shot host bootstrap: install ttyd, copy config/ to live, enable goose + ttyd + sshd + dnsmasq + daily maintenance timer, open UFW rule, restore Claude settings
make bundle-secrets    # collect live secrets into $(REPO)/backups/secrets-bundle-<date>.tar.gz (not chained into bkp-all)
make install-secrets   # extract a secrets bundle to live paths (BUNDLE=<path> to override)
make bundle-config     # snapshot $(REPO)/repo/config/ into $(REPO)/backups/config-bundle-<date>.tar.gz (offline copy)
make install-config-bundle  # extract a config bundle into $(REPO)/repo/config/ (BUNDLE=<path> to override)
make migrate           # cat docs/MIGRATE.md — the full VPS-to-VPS migration runbook
make git-add           # git add -A in $(REPO)/repo
make git-com MSG="…"   # git commit -m MSG (MSG required)
make git-push          # git push homelab main
make git-all MSG="…"   # shortcut: stage + commit + push
make bkp-cloud         # snapshot Nextcloud data (maintenance mode on during the copy)
make bkp-vault         # tar the Vaultwarden data dir to $(REPO)/backups/vault-backup-<date>.tar.gz
make bkp-list          # list every artifact under $(REPO)/backups/ + count per pattern
make clean-docker      # prune builder / image / container
make clean-apt         # apt autoremove + clean
make clean-backups     # keep latest 3 backups per pattern, delete older
make tmux-new NAME=<n> # create a detached tmux session <n>
make tmux-open NAME=<n># attach to session <n> (Ctrl-b d to detach)
make tmux-kill NAME=<n># kill session <n>
make tmux-list         # list sessions (prints "No tmux sessions." when none)
```

When a recipe covers the task, use the recipe. Raw `git`, `docker compose`, `docker exec`, `systemctl restart`, and `tar` are reserved for cases no recipe covers (one-off diagnostics the operator asked for, log/file inspection, ad-hoc reads).

`make git-com MSG="…"` and `make git-all MSG="…"` take a single-sentence `MSG` only. Two quoting constraints: embedded newlines break the `git commit -m "..."` quoting through `bash -c` and fail with `unexpected EOF` before the commit lands, and embedded double-quote characters break the recipe's own `$(MSG)` substitution (the recipe's `[-z "$(MSG)"]` check sees word-split fragments and errors with `[: too many arguments]`, then `git commit -m` interprets the unquoted remainder as paths). If the message needs a quote mark, wrap the whole `MSG=` in single quotes (`make git-com MSG='…'`) — the shell does not interpolate inside single quotes, so the embedded `"` survives intact. The diff speaks for itself; the message only needs to round-trip through bash.

## Protected host resources

**Never delete or disable any of these without explicit operator approval.** Per `docs/AGENTS.md` safety rule 1, if a task seems to require removing any of them, stop and ask.

- `/etc/systemd/system/goose.service` — goose agent systemd unit (`enabled`, `Restart=always`).
- `/etc/systemd/system/ttyd.service` — ttyd web-terminal unit (`enabled`, `Restart=always`). Binds `172.22.0.1:7681` only (host bridge IP), gated by the Caddy tailnet match and the UFW INPUT allow from `172.22.0.0/16`.
- `/etc/dnsmasq.d/10-tailnet.conf` and `/etc/systemd/system/dnsmasq.service.d/override.conf` — host DNS resolver + systemd drop-in (`Restart=always`). Binds `100.117.144.0:53` (the Tailscale IP).
- `/var/www/custom/projects/homelab/certs/` — RETIRED. The wildcard Cloudflare Origin cert that used to live here is no longer referenced by any vhost (the per-vhost ACME certs serve every hostname). The directory and the files inside it are kept on disk for audit/history but can be deleted without breaking the running system.
- `/var/www/custom/projects/homelab/caddy_data/` — Caddy runtime data dir (LE certs under `caddy/acme/`, ACME account keys, OCSP staples) and the `CF_API_TOKEN` file used for per-vhost ACME DNS-01. The Caddy container bind-mounts this dir at `/data` so certs persist across container recreates. The `CF_API_TOKEN` file is created by the operator (see `docs/MIGRATE.md`); do not commit it.
- `/var/www/custom/projects/homelab/cloud/html/` and `/var/www/custom/projects/homelab/cloud/users/` — Nextcloud bind mounts (html root + datadirectory; both owned by uid 33 with a `.ncdata` marker in `users/`).
- `net` Docker network — user-defined bridge, `external: true`, subnet `172.22.0.0/16`. Reused by all inter-container services.
- SSH keys, Nextcloud data, Vaultwarden data, uploaded files — user-only (also `docs/AGENTS.md` safety rules 7 and 8).

## SSH access

SSH is restricted to the Tailscale network only — the public internet cannot reach port 22. Password auth is disabled; root login is key-only (`PermitRootLogin prohibit-password`); `AllowUsers op root`. Config: `/etc/ssh/sshd_config.d/50-cloud-init.conf`. The installer (`scripts/install.sh`) writes this file for user `op` and keeps root key access.

## Service reference

The compose files are the source of truth. This table is the one-line reference for each service.

| Service | Compose | Container | Edit mounted config | After compose / image change |
|---------|---------|-----------|---------------------|------------------------------|
| caddy   | `services/fxmq.net/docker-compose.yml` | `fxmq.net` | `make d-restart-fxmq.net` | `make d-recreate-fxmq.net` (rebuilds `fxmq.net:local` from `services/fxmq.net/Dockerfile`) |
| cloud   | `services/nextcloud/docker-compose.yml` | `nextcloud` | `make d-restart-nextcloud` | `make d-recreate-nextcloud` |
| vault   | `services/vaultwarden/docker-compose.yml` | `vaultwarden` | `make d-restart-vaultwarden` | `make d-recreate-vaultwarden` |
| kuma    | `services/ut-kuma/docker-compose.yml` | `ut-kuma` | `make d-restart-ut-kuma` | `make d-recreate-ut-kuma` |
| terminal | n/a (host systemd; see Protected host resources) | n/a | `make restart-ttyd` | `make install-config` (reinstall) |
| dnsmasq | n/a (host systemd) | n/a | `make restart-dnsmasq` | n/a |
| goose   | n/a (host systemd; see Protected host resources) | n/a | `systemctl restart goose` | n/a |

The `net` Docker network is `external: true` — create once on a fresh host with `docker network create net --subnet=172.22.0.0/16` (the compose files pin `172.22.0.x` bridge IPs; a default-subnet network rejects them). All inter-container services use `expose`, not `ports`. The exception is `fxmq.net`: it runs with `network_mode: host` so Caddy sees the real client source IP — without host networking, Docker DNAT rewrites every packet to `172.22.0.1` (the bridge gateway) before Caddy sees it, which breaks the `@not_tailnet` remote_ip matcher on `https://shell.fxmq.net`. The host network namespace is on the `net` bridge at `172.22.0.0/16`, so Caddy still dials upstream containers by their bridge IP (see Caddyfile). dnsmasq binds to the Tailscale IP only, not `0.0.0.0`.

### Per-service edit pointers

When you need to know "what does X do / where do I edit Y", read the file at the path below — the docs don't re-type the contents.

- **`fxmq.net`** (Caddy) — vhosts, snippets, header policy: `services/fxmq.net/Caddyfile` (top-level config + per-vhost imports) and `services/fxmq.net/vhosts/*.caddy` (one per hostname: `cloud`, `kuma`, `shell`, `vault`). Compose + bind mounts + custom Dockerfile (Caddy built with the `caddy-dns/cloudflare` plugin for ACME DNS-01): `services/fxmq.net/docker-compose.yml`. Runs `network_mode: host` — see note above. Every vhost has its own `tls { dns cloudflare { env.CF_API_TOKEN } }` block; don't replace it with `tls internal` / `tls off` / `tls self_signed`.
- **`cloud`** — Nextcloud env, PHP-FPM pool tuning, bind mounts: `services/nextcloud/docker-compose.yml` + `services/nextcloud/php-fpm.d/zz-custom.conf`. Admin creds: `services/nextcloud/.env` (gitignored — read access only via the operator).
- **`vault`** — env, bind mount, admin token: `services/vaultwarden/docker-compose.yml`.
- **`kuma`** — image, bind mount, healthcheck: `services/ut-kuma/docker-compose.yml`. Monitor definitions live in Kuma's SQLite (`services/ut-kuma/seed-monitors.sql` seeds them; applied by the installer).
- **`terminal`** — ttyd at `shell.fxmq.net/shell`, runs as a host systemd unit (not a container). Binary at `/usr/local/bin/ttyd`, unit at `/etc/systemd/system/ttyd.service` (reference copy in `config/ttyd/ttyd.service`). No systemd sandbox (operator preference: no permission hunts). Runs as `op` with NOPASSWD sudo, so full host control from the shell. Access control is at the network layer (Tailscale membership + Caddy `@not_tailnet`), not the unit sandbox. `make install-config` installs the binary (static 1.7.7 from upstream) and the unit; the step is idempotent. Caddy proxies to the host bridge IP `172.22.0.1:7681` with `transport http { versions 1.1 }` (ttyd only speaks HTTP/1.1); the UFW INPUT allow from `172.22.0.0/16 → 7681/tcp` is added by `make install-config`.
- **dnsmasq** — config: `config/dnsmasq/10-tailnet.conf` (live path: `/etc/dnsmasq.d/10-tailnet.conf`). systemd drop-in: `config/dnsmasq/dnsmasq.service.conf` (live path: `/etc/systemd/system/dnsmasq.service.d/override.conf`).
- **goose** — unit: `config/goose/goose.service` (live path: `/etc/systemd/system/goose.service`).

## Daily maintenance

A systemd timer (`homelab-daily.timer`, enabled) runs the script in `config/maintenance/daily.sh` once per day. The script chains three `make` recipes: `make update` (apt + image pull + `make d-recreate-all`), `make bkp-all` (bkp-cloud + bkp-vault), then `make clean-all` (docker prune + apt autoremove + prune old backups). Run manually with `sudo systemctl start homelab-daily.service`. Logs to `/var/log/homelab-daily.log`.

## File ownership

The repo is owned by `op:op` (the SSH/login user). Edit directly when signed in as `op`; use `sudo` only if acting as another user. Do not `chown` the repo to a different user.

## Git remotes

- `homelab` — SSH remote (`git@github.com:friedutch/homelab.git`). The only remote; use for pushes and pulls.

```bash
git push homelab main
```

## Operational gotchas

- A deliberate `systemctl stop dnsmasq` takes all tailnet-side `*.fxmq.net` resolution down. Restart with `make restart-dnsmasq`.
- The Makefile sets `SHELL := /bin/bash` explicitly. Without it, recipes run under `/bin/sh` (dash on Debian) and `set -eu` semantics differ — `dash` aborts on any unset variable reference, while `bash` only aborts on expansion failures. If you see `parameter not set` from a recipe, the Makefile shell setting is the first place to look.
- Cloudflare's free tier rate-limits rate-limit rules to a 10s min window. Plan ahead if a public endpoint ends up attracting more traffic than expected.
- **Every Caddy vhost has its own TLS block** — don't reintroduce a shared wildcard cert. The wildcard CF Origin cert at `$(REPO)/certs/` covered `*.fxmq.net`, so a vhost without its own `tls` directive would pick up the wildcard as a SNI fallback and the per-vhost ACME automation policy would never fire. Lesson: a vhost with no `tls` directive appears to "use ACME by default" but actually picks up any loaded cert that matches the SNI.
- **Caddy stock `caddy:2.x` doesn't include `caddy-dns/cloudflare`** — needs a custom `xcaddy` build (see `services/fxmq.net/Dockerfile`). Also: `caddy-dns/cloudflare` v0.2.3 rejects the new 53-char CF token format with a generic "API token appears invalid" error during plugin provisioning — pull from `caddy-dns/cloudflare@a8737d0` (master) until a tagged release ships the regex fix.
- **`caddy:2.11.4` requires Go ≥ 1.25.1** to build — the `golang:1.25-bookworm` image satisfies this. Older builder images (e.g. `golang:1.24-bookworm`) fail with `go: github.com/caddyserver/caddy/v2@v2.11.4 requires go >= 1.25.1`. If you bump Caddy, check the new `go.mod` `go` directive and bump the builder image too.
- **`network_mode: host` is required for `@not_tailnet` to work.** Docker DNAT rewrites every packet to `172.22.0.1` (the bridge gateway) before Caddy sees it. Without `network_mode: host`, the `100.64.0.0/10` matcher matches nothing and every tailnet request gets 403. This is set in `services/fxmq.net/docker-compose.yml` — do not "fix" it.
- **`docker compose env_file:` reads the file as the UID running `make`, NOT as the UID inside the container** — compose parses `env_file:` at the host side. The `CF_API_TOKEN` file must be readable by the user running the compose command (`op`), mode 0644; chowning it to the container's uid (201) breaks the read and Caddy ends up with no token.
- **`make d-recreate-fxmq.net` (or `make d-recreate-all`) takes ~3 minutes on a fresh VPS and prints zero progress** — `docker compose up --build` runs `docker build` in a streaming-tty mode that buffers until the step finishes. The build chain is `golang:1.25-bookworm` → `go install xcaddy` → `xcaddy build --with caddy-dns/cloudflare@a8737d0 v2.11.4` → `FROM caddy:2.11.4` + `COPY --from=builder`. `docker build --progress=plain` shows the steps.
- **The cert's issuer is the only reliable indicator of which path it took** — `curl -sk` returning 200 means "the listener responded", not "the right cert was served". Check `openssl x509 -noout -issuer` on a fresh `-no-keepalive` handshake.
