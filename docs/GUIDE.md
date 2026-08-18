# Project guide

How to operate `jehpok.com` — the project's repository layout, deployment commands, protected host resources, per-service edit-safe facts, and operational gotchas. Read this before editing anything.

For system architecture and design rationale, see `README.md`. For agent rules, see `docs/AGENTS.md`. For open problems and improvements, see `docs/ISSUES.md`.

## Repository layout

The repo splits into four directories. `ls` is the source of truth — what's described here is the intent, not the full inventory.

- `services/<svc>/docker-compose.yml` — one per running service. Compose files are the source of truth for images, env vars, ports, volumes, healthchecks, and logging.
- `setup/` — reference copies of host-level configs (Ollama systemd unit, SSH hardening, dnsmasq, maintenance timer + script). Restored to live paths by `make setup-host`.
- `content/` — app sources and static files mounted into containers. Container app source lives here, not under `services/`, so edits take effect with `make restart-<svc>` and the image only carries the runtime.
- `docs/` — `AGENTS.md`, `GUIDE.md` (this file), `ISSUES.md`.

`temp/` at the repo root holds one-time scratch backups (currently the retired static `www` page). It is gitignored.

## Deployment

Manual — no CI/CD, pushes to `main` trigger nothing. Use the `Makefile` recipes (canonical) rather than raw `docker compose`.

### First-time setup and migration

`make migrate` prints the full step-by-step runbook.

### Backups

| Recipe             | What it does                                                                 |
|--------------------|------------------------------------------------------------------------------|
| `make backup-cloud` | Snapshot Nextcloud data (maintenance mode on during the copy).               |
| `make backup-share` | Copy the shortener SQLite DB.                                                |
| `make backup-vault` | Tar the Vaultwarden data dir.                                                |
| `make backup-secrets` | Bundle certs, SSH keys, Ollama unit, dnsmasq config + drop-in, Tailscale state. Download off the VPS — the bundle contains private keys and identity. |

### CMD Sheet

```bash
make up-all            # start/recreate all six containers in order (share, domain, cloud, vault, kuma, homer)
make up-<service>      # force-recreate one container — up-domain | up-cloud | up-share | up-vault | up-kuma | up-homer
make restart-<service> # reload one container without recreating — after editing a mounted config
make restart-dns       # restart the host dnsmasq resolver — after editing setup/dnsmasq/10-tailnet.conf
make logs-<service>    # follow one container's logs — logs-domain | logs-cloud | logs-share | logs-vault | logs-kuma | logs-homer
make logs-dns          # follow the dnsmasq journal
make status            # show a table of all running containers
make push MSG="..."    # stage, commit, and push to the jehpok.com remote
make backup-cloud      # snapshot Nextcloud data (maintenance mode on during the copy)
make backup-share      # copy the shortener SQLite DB to /var/www/github/jehpok.com/share-backup-<date>.db
make backup-vault      # tar the Vaultwarden data dir to /var/www/github/jehpok.com/vault-backup-<date>.tar.gz
make backup-secrets    # bundle certs, SSH keys, Ollama unit, dnsmasq config, and Tailscale state for off-VPS storage
make setup-host        # install reference configs to live paths and enable Ollama + sshd + dnsmasq + daily maintenance timer
make migrate           # print the full VPS-to-VPS migration runbook
make clean             # free disk: prune the Docker build cache and clear the apt cache
```

## Protected host resources

**Never delete or disable any of these without explicit operator approval.** Per `docs/AGENTS.md` safety rule 1, if a task seems to require removing any of them, stop and ask.

- `/etc/systemd/system/ollama.service` — Ollama systemd unit (`enabled`, `Restart=always`).
- `/etc/dnsmasq.d/10-tailnet.conf` and `/etc/systemd/system/dnsmasq.service.d/override.conf` — host DNS resolver + systemd drop-in (`Restart=always`).
- `/var/www/github/jehpok.com/certs/` — Cloudflare Origin cert + key (wildcard `*.jehpok.com`).
- `/var/www/github/jehpok.com/cloud/html/` and `/var/www/github/jehpok.com/cloud/users/` — Nextcloud bind mounts (html root + datadirectory; both owned by uid 33 with a `.ncdata` marker in `users/`).
- `net` Docker network — user-defined bridge, `external: true`. Reused by all inter-container services.
- SSH keys, Nextcloud data, Vaultwarden data, shortener DB, uploaded files — user-only (also `docs/AGENTS.md` safety rules 7 and 8).

## SSH access

SSH is restricted to the Tailscale network only — the public internet cannot reach port 22. Password auth is disabled, root login is disabled, `AllowUsers debian` only. Config: `/etc/ssh/sshd_config.d/50-cloud-init.conf`. The `runner` user has no key and is not allowed.

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
- **`homer`** — dashboard YAML: `services/homer/config/config.yml` (in-repo, bind-mounted live).
- **dnsmasq** — config: `setup/dnsmasq/10-tailnet.conf` (live path: `/etc/dnsmasq.d/10-tailnet.conf`). systemd drop-in: `setup/dnsmasq/dnsmasq.service.conf` (live path: `/etc/systemd/system/dnsmasq.service.d/override.conf`).
- **ollama** — unit: `setup/ollama/ollama.service` (live path: `/etc/systemd/system/ollama.service`).

## Daily maintenance

A systemd timer (`jehpok-daily.timer`, enabled) runs the script in `setup/maintenance/daily.sh` once per day. Run manually with `sudo systemctl start jehpok-daily.service`. Logs to `/var/log/jehpok-daily.log`.

## File ownership

The repo is owned by `debian:debian` (the SSH/login user). Edit directly when signed in as `debian`; use `sudo` only if acting as another user. Do not `chown` the repo to a different user.

## Git remotes

- `jehpok.com` — SSH remote (`git@github.com:friedutch/jehpok.com.git`). The only remote; use for pushes and pulls.

```bash
git push jehpok.com main
```

## Operational gotchas

- A deliberate `systemctl stop dnsmasq` takes all tailnet-side `*.jehpok.com` resolution down. Restart with `make restart-dns`.
- Cloudflare's free tier rate-limits rate-limit rules to a 10s min window. Plan ahead if a public endpoint ends up attracting more traffic than expected.
