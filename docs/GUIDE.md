# Project guide

How to operate `jehpok.com` — the project's repository layout, deployment commands, protected host resources, per-service edit-safe facts, and operational gotchas. Read this before editing anything.

For system architecture and design rationale, see `README.md`. For agent rules, see `docs/AGENTS.md`. For open problems and improvements, see `docs/ISSUES.md`.

## Repository layout

The repo splits into four directories. `ls` is the source of truth — what's described here is the intent, not the full inventory.

- `services/<svc>/docker-compose.yml` — one per running service. Compose files are the source of truth for images, env vars, ports, volumes, healthchecks, and logging.
- `setup/` — reference copies of host-level configs (Ollama systemd unit, SSH hardening, dnsmasq, maintenance timer + script, Claude Code deny-list). Restored to live paths by `make setup`.
- `content/` — app sources and static files mounted into containers. Container app source lives here, not under `services/`, so edits take effect with `make restart-<svc>` and the image only carries the runtime.
- `docs/` — `AGENTS.md`, `GUIDE.md` (this file), `ISSUES.md`, `MIGRATE.md` (runbook for moving to a new VPS; printed by `make migrate`).

## Deployment

Manual — no CI/CD, pushes to `main` trigger nothing. Use the `Makefile` recipes (canonical) rather than raw `docker compose`.

### First-time setup and migration

`make migrate` prints the full step-by-step runbook.

### CMD Sheet

```bash
make                   # default: print help with categories
make restart-all       # restart every container + dnsmasq + ttyd — same order as up-all
make up-all            # start/recreate all containers in order (share, domain, cloud, vault, kuma, homer, minecraft)
make logs-all          # tail all container logs in one stream, each line prefixed with [container]
make backup-all        # run all five backup recipes in order (cloud, share, vault, secrets, minecraft)
make clean-all         # chain: clean-docker + clean-apt + clean-backups
make up-<service>      # force-recreate one container — up-domain | up-cloud | up-share | up-vault | up-kuma | up-homer | up-minecraft
make restart-<service> # restart every service in the compose file — after editing a mounted config; minecraft restarts both minecraft and minecraft-web
make restart-dnsmasq   # restart the host dnsmasq resolver — after editing setup/dnsmasq/10-tailnet.conf
make restart-ttyd      # restart the host ttyd service — after editing setup/ttyd/ttyd.service
make logs-<service>    # follow one container's logs — logs-domain | logs-cloud | logs-share | logs-vault | logs-kuma | logs-homer | logs-minecraft
make logs-dnsmasq      # follow the dnsmasq journal
make logs-ttyd         # follow the ttyd journal
make status            # show a table of all running containers + host systemd units
make refresh           # apt update/upgrade + pull all images + make up-all
make setup             # one-shot host bootstrap: install ttyd, copy reference configs, enable Ollama + ttyd + sshd + dnsmasq + daily maintenance timer, open UFW rule, restore Claude settings
make migrate           # cat docs/MIGRATE.md — the full VPS-to-VPS migration runbook
make git-add           # git add -A in $(REPO)/repo
make git-commit MSG="…"  # git commit -m MSG (MSG required)
make git-push          # git push jehpok.com main
make git-all MSG="…"   # shortcut: stage + commit + push
make backup-cloud      # snapshot Nextcloud data (maintenance mode on during the copy)
make backup-share      # copy the shortener SQLite DB to /var/www/custom/projects/jehpok/share-backup-<date>.db
make backup-vault      # tar the Vaultwarden data dir to /var/www/custom/projects/jehpok/vault-backup-<date>.tar.gz
make backup-secrets    # bundle certs, SSH keys, Ollama + ttyd units, dnsmasq config, and Tailscale state for off-VPS storage
make backup-minecraft  # tar just the Minecraft world folder to /var/www/custom/projects/jehpok/minecraft-backup-<date>.tar.gz (daily.sh stops the container first when chained through backup-all)
make clean-docker      # prune builder / image / container
make clean-apt         # apt autoremove + clean
make clean-backups     # keep latest 3 backups per pattern, delete older
```

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
| domain   | `services/domain/docker-compose.yml`    | `domain`  | `make restart-domain`        | `make up-domain` (builds `caddy-dns:local` from `services/domain/Dockerfile`) |
| cloud    | `services/cloud/docker-compose.yml`     | `cloud`   | `make restart-cloud`         | `make up-cloud`              |
| share    | `services/share/docker-compose.yml`     | `share`   | `make restart-share`         | `make up-share`              |
| vault    | `services/vault/docker-compose.yml`     | `vault`   | `make restart-vault`         | `make up-vault`              |
| kuma     | `services/kuma/docker-compose.yml`      | `kuma`    | `make restart-kuma`          | `make up-kuma`               |
| homer    | `services/homer/docker-compose.yml`     | `homer`   | `make restart-homer`         | `make up-homer`              |
| minecraft| `services/minecraft/docker-compose.yml` | `minecraft`+`minecraft-web` | `make restart-minecraft`    | `make up-minecraft` (builds `minecraft-web` locally) |
| terminal | n/a (host systemd; see Protected host resources) | n/a | `make restart-ttyd`          | `make setup` (reinstall)     |
| dnsmasq  | n/a (host systemd)                      | n/a       | `make restart-dns`           | n/a                          |
| ollama   | n/a (host systemd; see Protected host resources) | n/a | `systemctl restart ollama`   | n/a                          |

The `net` Docker network is `external: true` — create once with `docker network create net` on a fresh host. All inter-container services use `expose`, not `ports`. The exception is `domain`: it runs with `network_mode: host` so Caddy sees the real client source IP — without host networking, Docker DNAT rewrites every packet to `172.22.0.1` (the bridge gateway) before Caddy sees it, which breaks the `@not_tailnet` remote_ip matcher on `https://server.jehpok.com`. The host network namespace is on the `net` bridge at `172.22.0.0/16`, so Caddy still dials upstream containers by their bridge IP (see Caddyfile). dnsmasq binds to the Tailscale IP only, not `0.0.0.0`.

### Per-service edit pointers

When you need to know "what does X do / where do I edit Y", read the file at the path below — the docs don't re-type the contents.

- **`domain`** — vhosts, snippets, header policy: `services/domain/Caddyfile` (top-level config + per-vhost imports) and `services/domain/vhosts/*.caddy` (one per hostname). Compose + bind mounts + custom Dockerfile (Caddy built with the caddy-dns/cloudflare plugin for ACME DNS-01): `services/domain/docker-compose.yml`. Runs `network_mode: host` — see note above.
- **`cloud`** — Nextcloud env, PHP-FPM pool tuning, bind mounts: `services/cloud/docker-compose.yml` + `services/cloud/php-fpm.d/zz-custom.conf`. Admin creds: `services/cloud/.env` (gitignored — read access only via the operator).
- **`share`** — Flask routes: `content/share/app.py`. Compose + DB bind mount: `services/share/docker-compose.yml`.
- **`vault`** — env, bind mount, admin token: `services/vault/docker-compose.yml`.
- **`kuma`** — image, bind mount, healthcheck: `services/kuma/docker-compose.yml`. Monitor definitions live in Kuma's SQLite, edited via the UI on first run.
- **`homer`** — dashboard YAML: `services/homer/config/config.yml` (in-repo, bind-mounted live). Homer doesn't auto-reload: edit the YAML, then `make restart-homer` and refresh the browser.
- **`minecraft`** — Paper server (Java) with Geyser + Floodgate so Bedrock clients can join the same instance. Game ports `25565` (Java) + `19132` TCP+UDP (Bedrock) are published directly on the host (see compose) and bypass Cloudflare at the port layer — Caddy only serves `:80`/`:443`. The dashboard at `server.jehpok.com/mc` (tailnet-only, no auth beyond Tailscale) is a tabbed Flask app (Status / Console / Players / Settings / Files / World) styled with a Bedrock-inspired design system — Press Start 2P for headings/buttons/pills, VT323 for body/logs, 3D beveled block primitives (no smoothing, hard 90° corners), and color-coded emphasis cards: `.nether` (obsidian + lava) wraps Container actions and the Regenerate zone; `.end` (end-stone + purple) wraps Backups and the Player Roster. Status shows `booting` (gold pill) until the rcon listener accepts its first client — uptime is anchored to that moment, so Paper's startup time isn't counted. The font showcase at `server.jehpok.com/mc/fonts` lets the operator compare pixel-font candidates before committing to a swap. The dashboard polls rcon every 2 s while the page is visible — no page reloads between updates. It edits `server.properties`, the Paper/Bukkit/Spigot YAML configs (PyYAML-validated before save), and `/plugins/` (`.jar` upload), and it handles world download / upload / regenerate (refuses all world writes while the game container is running). Rcon uses an in-process persistent connection pool (thread-safe, 30 s idle timeout, auto-reconnect) to avoid the per-poll log spam of open/close pairs; `/version` is cached keyed on the container `StartedAt` so the version string is fetched once per game-container restart. Player cards show source IP parsed from `latest.log` join/leave lines; per-player stats + actions expand inline (no side drawer). Compose + bind mount: `services/minecraft/docker-compose.yml`. Dashboard source: `content/minecraft/` (Flask; rcon implemented inline with `socket` + `struct` rather than the `mcrcon` PyPI package, which uses `signal.alarm` and breaks under Flask's worker threads). World data: `/var/www/custom/projects/jehpok/minecraft/data` (bind-mounted at `/data` inside the game container; uid 1000).
- **`terminal`** — ttyd at `server.jehpok.com/shell`, runs as a host systemd unit (not a container). Binary at `/usr/local/bin/ttyd`, unit at `/etc/systemd/system/ttyd.service` (reference copy in `setup/ttyd/ttyd.service`). No systemd sandbox: `ProtectSystem`, `PrivateTmp`, `MemoryDenyWriteExecute`, `PrivateDevices`, `RestrictAddressFamilies`, `LockPersonality`, `RestrictRealtime`, `ProtectControlGroups` are all unset — the operator can write anywhere on the host without a permission hunt. Runs as `debian` (uid 1000) with NOPASSWD sudo, so full host control from the shell. Access control is at the network layer (Tailscale membership + Caddy `@not_tailnet`), not the unit sandbox. Tailscale-only like the rest of `server.jehpok.com`. `make setup` installs the binary (static 1.7.7 from upstream) and the unit; the unit-restoration step is idempotent so re-running `make setup` doesn't break it. Caddy proxies to the host bridge IP `172.22.0.1:7681` with `transport http { versions 1.1 }` (ttyd only speaks HTTP/1.1); the UFW INPUT allow from `172.22.0.0/16 → 7681/tcp` is added by `make setup` and is what makes the bridge → host reach work. ttyd itself binds `172.22.0.1:7681` (host bridge IP, not `0.0.0.0`), so the port is unreachable even from the host's public IP — only via the bridge.
- **dnsmasq** — config: `setup/dnsmasq/10-tailnet.conf` (live path: `/etc/dnsmasq.d/10-tailnet.conf`). systemd drop-in: `setup/dnsmasq/dnsmasq.service.conf` (live path: `/etc/systemd/system/dnsmasq.service.d/override.conf`).
- **ollama** — unit: `setup/ollama/ollama.service` (live path: `/etc/systemd/system/ollama.service`).

## Daily maintenance

A systemd timer (`jehpok-daily.timer`, enabled) runs the script in `setup/maintenance/daily.sh` once per day. The script chains three `make` recipes: `make refresh` (apt + image pull + `make up-all`), `make backup-all` (all five backup recipes in order, with the `minecraft` container stopped before the run and restarted after), then `make clean-all` (docker prune + apt autoremove + prune old backups). Run manually with `sudo systemctl start jehpok-daily.service`. Logs to `/var/log/jehpok-daily.log`.

## File ownership

The repo is owned by `debian:debian` (the SSH/login user). Edit directly when signed in as `debian`; use `sudo` only if acting as another user. Do not `chown` the repo to a different user.

## Git remotes

- `jehpok.com` — SSH remote (`git@github.com:friedutch/jehpok.com.git`). The only remote; use for pushes and pulls.

```bash
git push jehpok.com main
```

## Operational gotchas

- A deliberate `systemctl stop dnsmasq` takes all tailnet-side `*.jehpok.com` resolution down. Restart with `make restart-dns`.
- The Makefile sets `SHELL := /bin/bash` explicitly. Without it, recipes run under `/bin/sh` (dash on Debian) and `set -eu` semantics differ — `dash` aborts on any unset variable reference, while `bash` only aborts on expansion failures. If you see `parameter not set` from a recipe, the Makefile shell setting is the first place to look.
- Cloudflare's free tier rate-limits rate-limit rules to a 10s min window. Plan ahead if a public endpoint ends up attracting more traffic than expected.
- **Every Caddy vhost has its own TLS block** — don't reintroduce a shared wildcard cert. The wildcard CF Origin cert at `$(REPO)/certs/` covered `*.jehpok.com`, so when the `mc.jehpok.com` vhost didn't declare its own `tls` directive, Caddy served the wildcard as a SNI fallback and the per-vhost ACME automation policy never had a reason to fire. Lesson: a vhost with no `tls` directive appears to "use ACME by default" but actually picks up any loaded cert that matches the SNI.
- **Caddy stock `caddy:2.x` doesn't include `caddy-dns/cloudflare`** — needs a custom `xcaddy` build (see `services/domain/Dockerfile`). Also: `caddy-dns/cloudflare` v0.2.3 rejects the new 53-char CF token format with a generic "API token appears invalid" error during plugin provisioning — pull from `caddy-dns/cloudflare@a8737d0` (master) until a tagged release ships the regex fix.
- **`mc.jehpok.com` is DNS-only at Cloudflare** — the game ports (25565 Java, 19132 Bedrock) are published directly on the VPS and bypass the CF proxy at the port layer. Turning the CF proxy on for `mc.jehpok.com` would break the game ports. Because the host name is DNS-only, HTTP-01 ACME can't reach the origin over port 80 from the public internet — DNS-01 via the CF API token is the only path. This is the only vhost that *had* to use DNS-01; the others use DNS-01 now for consistency.
- **`caddy:2.11.4` requires Go ≥ 1.25.1** to build — the `golang:1.25-bookworm` image satisfies this. Older builder images (e.g. `golang:1.24-bookworm`) fail with `go: github.com/caddyserver/caddy/v2@v2.11.4 requires go >= 1.25.1`. If you bump Caddy, check the new `go.mod` `go` directive and bump the builder image too.
- **`network_mode: host` is required for `@not_tailnet` to work.** Docker DNAT rewrites every packet to `172.22.0.1` (the bridge gateway) before Caddy sees it. Without `network_mode: host`, the `100.64.0.0/10` matcher matches nothing and every tailnet request gets 403.
