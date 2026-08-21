# Project guide

How to operate `jehpok.com` — the project's repository layout, deployment commands, protected host resources, per-service edit-safe facts, and operational gotchas. Read this before editing anything.

For system architecture and design rationale, see `README.md`. For agent rules, see `docs/AGENTS.md`. For open problems and improvements, see `docs/ISSUES.md`.

## Repository layout

The repo splits into four directories. `ls` is the source of truth — what's described here is the intent, not the full inventory.

- `services/<ctn>/docker-compose.yml` — one per running container. Compose files are the source of truth for images, env vars, ports, volumes, healthchecks, and logging.
- `config/` — reference copies of host-level configs (Ollama systemd unit, SSH hardening, dnsmasq, maintenance timer + script, Claude Code deny-list). Restored to live paths by `make install-config`. For an offline copy of the whole `config/` tree, use `make bundle-config`.
- `content/` — app sources and static files mounted into containers. Container app source lives here, not under `services/`, so edits take effect with `make d-restart-<ctn>` and the image only carries the runtime.
- `docs/` — `AGENTS.md`, `GUIDE.md` (this file), `ISSUES.md`, `MIGRATE.md` (runbook for moving to a new VPS; printed by `make migrate`).

## Deployment

Manual — no CI/CD, pushes to `main` trigger nothing. Use the `Makefile` recipes (canonical) rather than raw `docker compose`.

### First-time setup and migration

`make migrate` prints the full step-by-step runbook.

### CMD Sheet

```bash
make                   # default: print help with categories
make d-restart-all     # restart every container + dnsmasq + ttyd — same order as recreate-all
make recreate-all      # start/recreate all containers in order (share, domain, cloud, vault, kuma, homer, mc)
make d-logs-all        # tail all container logs in one stream, each line prefixed with [container]
make bkp-all           # run all four bkp-* recipes in order (cloud, share, vault, mc)
make clean-all         # chain: clean-docker + clean-apt + clean-backups
make recreate-<ctn>    # force-recreate one container — recreate-domain | recreate-cloud | recreate-share | recreate-vault | recreate-kuma | recreate-homer | recreate-mc
make d-restart-<ctn>   # restart every container in the compose file — after editing a mounted config; mc restarts both mc and mc-web
make restart-dnsmasq   # restart the host dnsmasq resolver — after editing config/dnsmasq/10-tailnet.conf
make restart-ttyd      # restart the host ttyd service — after editing config/ttyd/ttyd.service
make d-logs-<ctn>      # follow one container's logs — d-logs-domain | d-logs-cloud | d-logs-share | d-logs-vault | d-logs-kuma | d-logs-homer | d-logs-mc
make logs-dnsmasq      # follow the dnsmasq journal
make logs-ttyd         # follow the ttyd journal
make status            # show a table of all running containers + host systemd units
make update            # apt update/upgrade + pull all images + make recreate-all
make install-config    # one-shot host bootstrap: install ttyd, copy config/ to live, enable Ollama + ttyd + sshd + dnsmasq + daily maintenance timer, open UFW rule, restore Claude settings
make bundle-secrets    # collect live secrets into $(REPO)/backups/secrets-bundle-<date>.tar.gz (not chained into bkp-all)
make install-secrets   # extract a secrets bundle to live paths (BUNDLE=<path> to override)
make bundle-config     # snapshot $(REPO)/repo/config/ into $(REPO)/backups/config-bundle-<date>.tar.gz (offline copy)
make install-config-bundle  # extract a config bundle into $(REPO)/repo/config/ (BUNDLE=<path> to override)
make migrate           # cat docs/MIGRATE.md — the full VPS-to-VPS migration runbook
make git-add           # git add -A in $(REPO)/repo
make git-com MSG="…"   # git commit -m MSG (MSG required)
make git-push          # git push jehpok.com main
make git-all MSG="…"   # shortcut: stage + commit + push
make bkp-cloud         # snapshot Nextcloud data (maintenance mode on during the copy)
make bkp-share         # copy the shortener SQLite DB to $(REPO)/backups/share-backup-<date>.db
make bkp-vault         # tar the Vaultwarden data dir to $(REPO)/backups/vault-backup-<date>.tar.gz
make bkp-mc            # tar just the Minecraft world folder to $(REPO)/backups/mc-backup-<date>.tar.gz (daily.sh stops the container first when chained through bkp-all)
make clean-docker      # prune builder / image / container
make clean-apt         # apt autoremove + clean
make clean-backups     # keep latest 3 backups per pattern, delete older
```

When a recipe covers the task, use the recipe. Raw `git`, `docker compose`, `docker exec`, `systemctl restart`, and `tar` are reserved for cases no recipe covers (one-off diagnostics the operator asked for, log/file inspection, ad-hoc reads).

`make git-com MSG="…"` and `make git-all MSG="…"` take a single-sentence `MSG` only. Two quoting constraints: embedded newlines break the `git commit -m "..."` quoting through `bash -c` and fail with `unexpected EOF` before the commit lands, and embedded double-quote characters break the recipe's own `$(MSG)` substitution (the recipe's `[-z "$(MSG)"]` check sees word-split fragments and errors with `[: too many arguments]`, then `git commit -m` interprets the unquoted remainder as paths). If the message needs a quote mark, wrap the whole `MSG=` in single quotes (`make git-com MSG='…'`) — the shell does not interpolate inside single quotes, so the embedded `"` survives intact. The diff speaks for itself; the message only needs to round-trip through bash.

## Protected host resources

**Never delete or disable any of these without explicit operator approval.** Per `docs/AGENTS.md` safety rule 1, if a task seems to require removing any of them, stop and ask.

- `/etc/systemd/system/ollama.service` — Ollama systemd unit (`enabled`, `Restart=always`).
- `/etc/systemd/system/ttyd.service` — ttyd web-terminal unit (`enabled`, `Restart=always`). Binds `172.22.0.1:7681` only (host bridge IP), gated by the Caddy tailnet match and the UFW INPUT allow from `172.22.0.0/16`.
- `/etc/dnsmasq.d/10-tailnet.conf` and `/etc/systemd/system/dnsmasq.service.d/override.conf` — host DNS resolver + systemd drop-in (`Restart=always`).
- `/var/www/custom/projects/jehpok/certs/` — RETIRED. The wildcard Cloudflare Origin cert that used to live here is no longer referenced by any vhost (the per-vhost ACME certs serve every hostname). The directory and the files inside it are kept on disk for audit/history but can be deleted without breaking the running system. Prefer removing the mount + the files together so the new design is preserved.
- `/var/www/custom/projects/jehpok/caddy_data/` — Caddy runtime data dir (LE certs under `caddy/acme/`, ACME account keys under `caddy/acme/`, OCSP staples under `caddy/certificates/`) and the `CF_API_TOKEN` file used for per-vhost ACME DNS-01. The Caddy container bind-mounts this dir at `/data` so certs persist across container recreates. The `CF_API_TOKEN` file is created by the operator (see `docs/MIGRATE.md`); do not commit it.
- `/var/www/custom/projects/jehpok/cloud/html/` and `/var/www/custom/projects/jehpok/cloud/users/` — Nextcloud bind mounts (html root + datadirectory; both owned by uid 33 with a `.ncdata` marker in `users/`).
- `net` Docker network — user-defined bridge, `external: true`. Reused by all inter-container services.
- SSH keys, Nextcloud data, Vaultwarden data, shortener DB, uploaded files — user-only (also `docs/AGENTS.md` safety rules 7 and 8).

## SSH access

SSH is restricted to the Tailscale network only — the public internet cannot reach port 22. Password auth is disabled, root login is disabled, `AllowUsers debian` only. Config: `/etc/ssh/sshd_config.d/50-cloud-init.conf`.

## Service reference

The compose files are the source of truth. This table is the one-line reference for each service.

| Service  | Compose                                 | Container | Edit mounted config          | After compose / image change |
|----------|-----------------------------------------|-----------|------------------------------|------------------------------|
| domain   | `services/domain/docker-compose.yml`    | `domain`  | `make d-restart-domain`      | `make recreate-domain` (builds `caddy-dns:local` from `services/domain/Dockerfile`) |
| cloud    | `services/cloud/docker-compose.yml`     | `cloud`   | `make d-restart-cloud`       | `make recreate-cloud`        |
| share    | `services/share/docker-compose.yml`     | `share`   | `make d-restart-share`       | `make recreate-share`        |
| vault    | `services/vault/docker-compose.yml`     | `vault`   | `make d-restart-vault`       | `make recreate-vault`        |
| kuma     | `services/kuma/docker-compose.yml`      | `kuma`    | `make d-restart-kuma`        | `make recreate-kuma`         |
| homer    | `services/homer/docker-compose.yml`     | `homer`   | `make d-restart-homer`       | `make recreate-homer`        |
| mc-game | `services/mc/docker-compose.yml`        | `mc`                      | `make d-restart-mc`         | `make recreate-mc`         |
| mc-web  | `services/mc/docker-compose.mc-web.yml` | `mc-web`                  | `make d-restart-mc-web`     | `make recreate-mc-web` (builds `mc-web` locally) |
| terminal | n/a (host systemd; see Protected host resources) | n/a | `make restart-ttyd`          | `make install-config` (reinstall)     |
| dnsmasq  | n/a (host systemd)                      | n/a       | `make restart-dnsmasq`       | n/a                          |
| ollama   | n/a (host systemd; see Protected host resources) | n/a | `systemctl restart ollama`   | n/a                          |

The `net` Docker network is `external: true` — create once with `docker network create net` on a fresh host. All inter-container services use `expose`, not `ports`. The exception is `domain`: it runs with `network_mode: host` so Caddy sees the real client source IP — without host networking, Docker DNAT rewrites every packet to `172.22.0.1` (the bridge gateway) before Caddy sees it, which breaks the `@not_tailnet` remote_ip matcher on `https://server.jehpok.com`. The host network namespace is on the `net` bridge at `172.22.0.0/16`, so Caddy still dials upstream containers by their bridge IP (see Caddyfile). dnsmasq binds to the Tailscale IP only, not `0.0.0.0`.

### Per-service edit pointers

When you need to know "what does X do / where do I edit Y", read the file at the path below — the docs don't re-type the contents.

- **`domain`** — vhosts, snippets, header policy: `services/domain/Caddyfile` (top-level config + per-vhost imports) and `services/domain/vhosts/*.caddy` (one per hostname). Compose + bind mounts + custom Dockerfile (Caddy built with the caddy-dns/cloudflare plugin for ACME DNS-01): `services/domain/docker-compose.yml`. Runs `network_mode: host` — see note above.
- **`cloud`** — Nextcloud env, PHP-FPM pool tuning, bind mounts: `services/cloud/docker-compose.yml` + `services/cloud/php-fpm.d/zz-custom.conf`. Admin creds: `services/cloud/.env` (gitignored — read access only via the operator).
- **`share`** — Flask routes: `content/share/app.py`. Compose + DB bind mount: `services/share/docker-compose.yml`.
- **`vault`** — env, bind mount, admin token: `services/vault/docker-compose.yml`.
- **`kuma`** — image, bind mount, healthcheck: `services/kuma/docker-compose.yml`. Monitor definitions live in Kuma's SQLite, edited via the UI on first run.
- **`homer`** — dashboard YAML: `services/homer/config/config.yml` (in-repo, bind-mounted live). Homer doesn't auto-reload: edit the YAML, then `make d-restart-homer` and refresh the browser.
- **`mc`** (game) — Paper server (Java) with Geyser + Floodgate so Bedrock clients can join the same instance. Game ports `25565` (Java) + `19132` TCP+UDP (Bedrock) are published directly on the host (see compose) and bypass Cloudflare at the port layer — Caddy only serves `:80`/`:443`. Compose: `services/mc/docker-compose.yml` (just the game container; `mc-web` lives in its own file). World data: `/var/www/custom/projects/jehpok/mc/data` (bind-mounted at `/data` inside the game container; uid 1000). `make recreate-mc` rebuilds only this container.
- **`mc-web`** (dashboard) — tabbed Flask app at `server.jehpok.com/mc` (tailnet-only, no auth beyond Tailscale): Status / Console / Players / Settings / Files / World; styled with a Bedrock-inspired design system (Press Start 2P for headings/buttons/pills, VT323 for body/logs, 3D beveled block primitives, color-coded emphasis cards — `.nether` wraps Container actions and Regenerate; `.end` wraps Backups and Player Roster). Status shows `booting` (gold pill) until Paper logs `[Server thread/INFO]: Thread RCON Listener started` for the current session (validated against the container `StartedAt` to ignore previous sessions' lines that may still sit in `latest.log`) — uptime is anchored to that moment, so Paper's startup time isn't counted. The Settings tab has a `Filter fields…` search bar above the `server.properties` table for quickly narrowing the field list. The font showcase at `server.jehpok.com/mc/fonts` lets the operator compare pixel-font candidates before committing to a swap. The dashboard polls rcon every 2 s while the page is visible — no page reloads between updates. It edits `server.properties`, the Paper/Bukkit/Spigot YAML configs (PyYAML-validated before save), and `/plugins/` (`.jar` upload), and it handles world download / upload / regenerate (refuses all world writes while the game container is running). Rcon uses an in-process persistent connection pool (thread-safe, 30 s idle timeout, auto-reconnect) to avoid the per-poll log spam of open/close pairs; `/version` is cached keyed on the container `StartedAt` so the version string is fetched once per game-container restart. Player cards show source IP parsed from `latest.log` join/leave lines; per-player stats + actions expand inline (no side drawer). Container-actions endpoint tolerates the `mc` container being absent (`NotFound` → friendly `mc container is not running` instead of a raw 404 500). Compose + bind mount: `services/mc/docker-compose.mc-web.yml` (split from the game compose so dashboard-only changes don't restart the game). Source: `content/minecraft/` (Flask; rcon implemented inline with `socket` + `struct` rather than the `mcrcon` PyPI package, which uses `signal.alarm` and breaks under Flask's worker threads). Dashboard snapshots land at `/backups` (env var `BACKUP_DIR`), bind-mounted from `/var/www/custom/projects/jehpok/backups` so they share `make bkp-mc`'s dir. After every successful snapshot or regenerate the dashboard silently runs `_prune_mc_backups()` to keep the latest 3 `mc-backup-*.tar.gz` files and delete older ones by mtime (same policy as host-side `make clean-backups`, reimplemented in Python since mc-web has no `make`/sudo — prune failures are isolated so they never break a snapshot response). `make recreate-mc-web` rebuilds only this container; game server is untouched.
- **`terminal`** — ttyd at `server.jehpok.com/shell`, runs as a host systemd unit (not a container). Binary at `/usr/local/bin/ttyd`, unit at `/etc/systemd/system/ttyd.service` (reference copy in `config/ttyd/ttyd.service`). No systemd sandbox: `ProtectSystem`, `PrivateTmp`, `MemoryDenyWriteExecute`, `PrivateDevices`, `RestrictAddressFamilies`, `LockPersonality`, `RestrictRealtime`, `ProtectControlGroups` are all unset — the operator can write anywhere on the host without a permission hunt. Runs as `debian` (uid 1000) with NOPASSWD sudo, so full host control from the shell. Access control is at the network layer (Tailscale membership + Caddy `@not_tailnet`), not the unit sandbox. Tailscale-only like the rest of `server.jehpok.com`. `make install-config` installs the binary (static 1.7.7 from upstream) and the unit; the unit-restoration step is idempotent so re-running `make install-config` doesn't break it. Caddy proxies to the host bridge IP `172.22.0.1:7681` with `transport http { versions 1.1 }` (ttyd only speaks HTTP/1.1); the UFW INPUT allow from `172.22.0.0/16 → 7681/tcp` is added by `make install-config` and is what makes the bridge → host reach work. ttyd itself binds `172.22.0.1:7681` (host bridge IP, not `0.0.0.0`), so the port is unreachable even from the host's public IP — only via the bridge.
- **dnsmasq** — config: `config/dnsmasq/10-tailnet.conf` (live path: `/etc/dnsmasq.d/10-tailnet.conf`). systemd drop-in: `config/dnsmasq/dnsmasq.service.conf` (live path: `/etc/systemd/system/dnsmasq.service.d/override.conf`).
- **ollama** — unit: `config/ollama/ollama.service` (live path: `/etc/systemd/system/ollama.service`).

## Daily maintenance

A systemd timer (`jehpok-daily.timer`, enabled) runs the script in `config/maintenance/daily.sh` once per day. The script chains three `make` recipes: `make update` (apt + image pull + `make recreate-all`), `make bkp-all` (all four bkp-* recipes in order, with the mc container stopped before the run and restarted after), then `make clean-all` (docker prune + apt autoremove + prune old backups). Run manually with `sudo systemctl start jehpok-daily.service`. Logs to `/var/log/jehpok-daily.log`.

## File ownership

The repo is owned by `debian:debian` (the SSH/login user). Edit directly when signed in as `debian`; use `sudo` only if acting as another user. Do not `chown` the repo to a different user.

## Git remotes

- `jehpok.com` — SSH remote (`git@github.com:friedutch/jehpok.com.git`). The only remote; use for pushes and pulls.

```bash
git push jehpok.com main
```

## Operational gotchas

- A deliberate `systemctl stop dnsmasq` takes all tailnet-side `*.jehpok.com` resolution down. Restart with `make restart-dnsmasq`.
- The Makefile sets `SHELL := /bin/bash` explicitly. Without it, recipes run under `/bin/sh` (dash on Debian) and `set -eu` semantics differ — `dash` aborts on any unset variable reference, while `bash` only aborts on expansion failures. If you see `parameter not set` from a recipe, the Makefile shell setting is the first place to look.
- Cloudflare's free tier rate-limits rate-limit rules to a 10s min window. Plan ahead if a public endpoint ends up attracting more traffic than expected.
- **Every Caddy vhost has its own TLS block** — don't reintroduce a shared wildcard cert. The wildcard CF Origin cert at `$(REPO)/certs/` covered `*.jehpok.com`, so when the `mc.jehpok.com` vhost didn't declare its own `tls` directive, Caddy served the wildcard as a SNI fallback and the per-vhost ACME automation policy never had a reason to fire. Lesson: a vhost with no `tls` directive appears to "use ACME by default" but actually picks up any loaded cert that matches the SNI.
- **Caddy stock `caddy:2.x` doesn't include `caddy-dns/cloudflare`** — needs a custom `xcaddy` build (see `services/domain/Dockerfile`). Also: `caddy-dns/cloudflare` v0.2.3 rejects the new 53-char CF token format with a generic "API token appears invalid" error during plugin provisioning — pull from `caddy-dns/cloudflare@a8737d0` (master) until a tagged release ships the regex fix.
- **`mc.jehpok.com` is DNS-only at Cloudflare** — the game ports (25565 Java, 19132 Bedrock) are published directly on the VPS and bypass the CF proxy at the port layer. Turning the CF proxy on for `mc.jehpok.com` would break the game ports. Because the host name is DNS-only, HTTP-01 ACME can't reach the origin over port 80 from the public internet — DNS-01 via the CF API token is the only path. This is the only vhost that *had* to use DNS-01; the others use DNS-01 now for consistency.
- **`caddy:2.11.4` requires Go ≥ 1.25.1** to build — the `golang:1.25-bookworm` image satisfies this. Older builder images (e.g. `golang:1.24-bookworm`) fail with `go: github.com/caddyserver/caddy/v2@v2.11.4 requires go >= 1.25.1`. If you bump Caddy, check the new `go.mod` `go` directive and bump the builder image too.
- **`network_mode: host` is required for `@not_tailnet` to work.** Docker DNAT rewrites every packet to `172.22.0.1` (the bridge gateway) before Caddy sees it. Without `network_mode: host`, the `100.64.0.0/10` matcher matches nothing and every tailnet request gets 403.
