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
make up-all            # start/recreate all containers in order (share, domain, cloud, vault, kuma, homer, minecraft)
make backup-all        # run all four backup recipes in order (cloud, share, vault, secrets)
make clean-all         # chain: clean-docker + clean-apt + clean-backups
make up-<service>      # force-recreate one container — up-domain | up-cloud | up-share | up-vault | up-kuma | up-homer | up-minecraft
make restart-<service> # reload one container without recreating — after editing a mounted config
make restart-all       # restart every container + dnsmasq + ttyd — same order as up-all
make restart-dnsmasq   # restart the host dnsmasq resolver — after editing setup/dnsmasq/10-tailnet.conf
make restart-ttyd      # restart the host ttyd service — after editing setup/ttyd/ttyd.service
make logs-all          # tail all container logs in one stream, each line prefixed with [container]
make logs-<service>    # follow one container's logs — logs-domain | logs-cloud | logs-share | logs-vault | logs-kuma | logs-homer | logs-minecraft
make logs-dnsmasq      # follow the dnsmasq journal
make logs-ttyd         # follow the ttyd journal
make status            # show a table of all running containers + host systemd units
make refresh           # apt update/upgrade + pull all images + make up-all
make setup             # one-shot host bootstrap: install ttyd, copy reference configs, enable Ollama + ttyd + sshd + dnsmasq + daily maintenance timer, open UFW rule, restore Claude settings
make migrate           # cat docs/MIGRATE.md — the full VPS-to-VPS migration runbook
make push MSG="..."    # stage, commit, and push to the jehpok.com remote
make backup-cloud      # snapshot Nextcloud data (maintenance mode on during the copy)
make backup-share      # copy the shortener SQLite DB to /var/www/custom/projects/jehpok/share-backup-<date>.db
make backup-vault      # tar the Vaultwarden data dir to /var/www/custom/projects/jehpok/vault-backup-<date>.tar.gz
make backup-secrets    # bundle certs, SSH keys, Ollama + ttyd units, dnsmasq config, and Tailscale state for off-VPS storage
make clean-docker      # prune builder / image / container
make clean-apt         # apt autoremove + clean
make clean-backups     # keep latest 3 backups per pattern, delete older
```

## Protected host resources

**Never delete or disable any of these without explicit operator approval.** Per `docs/AGENTS.md` safety rule 1, if a task seems to require removing any of them, stop and ask.

- `/etc/systemd/system/ollama.service` — Ollama systemd unit (`enabled`, `Restart=always`).
- `/etc/systemd/system/ttyd.service` — ttyd web-terminal unit (`enabled`, `Restart=always`). Binds `172.22.0.1:7681` only (host bridge IP), gated by the Caddy tailnet match and the UFW INPUT allow from `172.22.0.0/16`.
- `/etc/dnsmasq.d/10-tailnet.conf` and `/etc/systemd/system/dnsmasq.service.d/override.conf` — host DNS resolver + systemd drop-in (`Restart=always`).
- `/var/www/custom/projects/jehpok/certs/` — Cloudflare Origin cert + key (wildcard `*.jehpok.com`).
- `/var/www/custom/projects/jehpok/cloud/html/` and `/var/www/custom/projects/jehpok/cloud/users/` — Nextcloud bind mounts (html root + datadirectory; both owned by uid 33 with a `.ncdata` marker in `users/`).
- `net` Docker network — user-defined bridge, `external: true`. Reused by all inter-container services.
- SSH keys, Nextcloud data, Vaultwarden data, shortener DB, uploaded files — user-only (also `docs/AGENTS.md` safety rules 7 and 8).

## SSH access

SSH is restricted to the Tailscale network only — the public internet cannot reach port 22. Password auth is disabled, root login is disabled, `AllowUsers debian` only. Config: `/etc/ssh/sshd_config.d/50-cloud-init.conf`.

## Service reference

The compose files are the source of truth. This table is the one-line reference for each service.

| Service  | Compose                                 | Container | Edit mounted config          | After compose / image change |
|----------|-----------------------------------------|-----------|------------------------------|------------------------------|
| domain   | `services/domain/docker-compose.yml`    | `domain`  | `make restart-domain`        | `make up-domain`             |
| cloud    | `services/cloud/docker-compose.yml`     | `cloud`   | `make restart-cloud`         | `make up-cloud`              |
| share    | `services/share/docker-compose.yml`     | `share`   | `make restart-share`         | `make up-share`              |
| vault    | `services/vault/docker-compose.yml`     | `vault`   | `make restart-vault`         | `make up-vault`              |
| kuma     | `services/kuma/docker-compose.yml`      | `kuma`    | `make restart-kuma`          | `make up-kuma`               |
| homer    | `services/homer/docker-compose.yml`     | `homer`   | `make restart-homer`         | `make up-homer`              |
| minecraft| `services/minecraft/docker-compose.yml` | `minecraft`+`minecraft-web` | `make restart-minecraft`    | `make up-minecraft` (builds `minecraft-web` locally) |
| terminal | n/a (host systemd; see Protected host resources) | n/a | `make restart-ttyd`          | `make setup` (reinstall)     |
| dnsmasq  | n/a (host systemd)                      | n/a       | `make restart-dns`           | n/a                          |
| ollama   | n/a (host systemd; see Protected host resources) | n/a | `systemctl restart ollama`   | n/a                          |

The `net` Docker network is `external: true` — create once with `docker network create net` on a fresh host. All inter-container services use `expose`, not `ports`. Only `domain` (80/443) publishes host ports; dnsmasq binds to the Tailscale IP only, not `0.0.0.0`.

### Per-service edit pointers

When you need to know "what does X do / where do I edit Y", read the file at the path below — the docs don't re-type the contents.

- **`domain`** — vhosts, snippets, header policy: `services/domain/Caddyfile`. Bind mounts and TLS cert path: `services/domain/docker-compose.yml`.
- **`cloud`** — Nextcloud env, PHP-FPM pool tuning, bind mounts: `services/cloud/docker-compose.yml` + `services/cloud/php-fpm.d/zz-custom.conf`. Admin creds: `services/cloud/.env` (gitignored — read access only via the operator).
- **`share`** — Flask routes: `content/share/app.py`. Compose + DB bind mount: `services/share/docker-compose.yml`.
- **`vault`** — env, bind mount, admin token: `services/vault/docker-compose.yml`.
- **`kuma`** — image, bind mount, healthcheck: `services/kuma/docker-compose.yml`. Monitor definitions live in Kuma's SQLite, edited via the UI on first run.
- **`homer`** — dashboard YAML: `services/homer/config/config.yml` (in-repo, bind-mounted live). Homer doesn't auto-reload: edit the YAML, then `make restart-homer` and refresh the browser.
- **`minecraft`** — Paper server (Java) with Geyser + Floodgate so Bedrock clients can join the same instance. Game ports `25565` (Java) + `19132` TCP+UDP (Bedrock) are published directly on the host (see compose) and bypass Cloudflare at the port layer — Caddy only serves `:80`/`:443`. The dashboard at `server.jehpok.com/mc` (tailnet-only, no auth beyond Tailscale) talks to the server over rcon on `127.0.0.1:25575`. Compose + bind mount: `services/minecraft/docker-compose.yml`. Dashboard source: `content/minecraft/` (Flask + mcrcon). World data: `/var/www/custom/projects/jehpok/minecraft/data` (bind-mounted at `/data` inside the container; uid 1000).
- **`terminal`** — ttyd at `server.jehpok.com/shell`, runs as a host systemd unit (not a container). Binary at `/usr/local/bin/ttyd`, unit at `/etc/systemd/system/ttyd.service` (reference copy in `setup/ttyd/ttyd.service`). No systemd sandbox: `ProtectSystem`, `PrivateTmp`, `MemoryDenyWriteExecute`, `PrivateDevices`, `RestrictAddressFamilies`, `LockPersonality`, `RestrictRealtime`, `ProtectControlGroups` are all unset — the operator can write anywhere on the host without a permission hunt. Runs as `debian` (uid 1000) with NOPASSWD sudo, so full host control from the shell. Access control is at the network layer (Tailscale membership + Caddy `@not_tailnet`), not the unit sandbox. Tailscale-only like the rest of `server.jehpok.com`. `make setup` installs the binary (static 1.7.7 from upstream) and the unit; the unit-restoration step is idempotent so re-running `make setup` doesn't break it. Caddy proxies to the host bridge IP `172.22.0.1:7681` with `transport http { versions 1.1 }` (ttyd only speaks HTTP/1.1); the UFW INPUT allow from `172.22.0.0/16 → 7681/tcp` is added by `make setup` and is what makes the bridge → host reach work. ttyd itself binds `172.22.0.1:7681` (host bridge IP, not `0.0.0.0`), so the port is unreachable even from the host's public IP — only via the bridge.
- **dnsmasq** — config: `setup/dnsmasq/10-tailnet.conf` (live path: `/etc/dnsmasq.d/10-tailnet.conf`). systemd drop-in: `setup/dnsmasq/dnsmasq.service.conf` (live path: `/etc/systemd/system/dnsmasq.service.d/override.conf`).
- **ollama** — unit: `setup/ollama/ollama.service` (live path: `/etc/systemd/system/ollama.service`).

## Daily maintenance

A systemd timer (`jehpok-daily.timer`, enabled) runs the script in `setup/maintenance/daily.sh` once per day. The script chains three `make` recipes: `make refresh` (apt + image pull + `make up-all`), `make backup-all` (all four backup recipes in order), then `make clean-all` (docker prune + apt autoremove + prune old backups). Run manually with `sudo systemctl start jehpok-daily.service`. Logs to `/var/log/jehpok-daily.log`.

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
