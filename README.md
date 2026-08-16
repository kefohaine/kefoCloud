# jehpok.com

Self-hosted infrastructure on a Debian VPS, fronted by Caddy in Docker, serving four public subdomains and one Tailscale-only subdomain. Ollama runs on the host as a systemd service for local LLM serving.

This document describes the full system: what runs where, why each piece exists, how requests flow, and what to know when something breaks.

## High-level overview

```
                  ┌─────────────────────────────────────────────┐
   Public DNS ──► │            Cloudflare (proxy)               │
                   │   www / app / api / cloud  (orange cloud)   │
                   └──────────────┬──────────────────────────────┘
                                  │ HTTPS (Origin Cert)
                                  ▼
                           ┌──────────────┐
                           │    Caddy     │  port 80 → 308 redirect
                           │  (domain)    │  port 443 (TLS + vhosts)
                           └──────┬───────┘
              ┌──────────────────┼──────────────────┐
              │                  │                  │
              ▼                  ▼                  ▼
         static files       static files      php_fastcgi
         www / app / vps    api → "ok"        cloud:9000
         (/srv/content/)    (placeholder)     (Nextcloud FPM)

                   ┌─────────────────────────────────────────────┐
                   │ Tailscale MagicDNS / split DNS              │
                   │ forwards *.jehpok.com queries to the VPS    │
                   │ resolver (bound to Tailscale IP only)       │
                   └──────────────┬──────────────────────────────┘
                                  │ UDP/TCP 100.81.245.77:53
                                  ▼
                           ┌──────────────┐
                           │  CoreDNS     │  container "tailnet"
                           │  (tailnet)   │  (not on net bridge)
                           │  - hosts { vps.jehpok.com → 100.81.245.77 }
                           │  - forward . 1.1.1.1
                           └──────────────┘
```

Only one VPS, one host. Cloudflare fronts four of the five hostnames; the Tailscale-only hostname is invisible on the public internet.

## Domains and access model

| Domain             | Where DNS points            | Who can reach it                            | What is served                                  |
|--------------------|-----------------------------|---------------------------------------------|-------------------------------------------------|
| www.jehpok.com     | Cloudflare → VPS IP         | Anyone on the internet                      | Static site from `content/domain/www`              |
| app.jehpok.com     | Cloudflare → VPS IP         | Anyone on the internet                      | Static site from `content/domain/app`              |
| api.jehpok.com     | Cloudflare → VPS IP         | Anyone on the internet                      | Placeholder vhost (no backend currently wired)  |
| cloud.jehpok.com   | Cloudflare → VPS IP         | Anyone on the internet                      | Nextcloud (file sync, calendar, photos)         |
| vps.jehpok.com     | **Not in Cloudflare**       | Only devices on the Tailscale network       | Static site from `content/domain/vps`              |

The asymmetry on `vps.jehpok.com` is deliberate. By keeping it out of public DNS, the only way anyone can know its IP is by being inside the Tailscale network. Even a DNS leak on the user's device cannot reveal an address that public resolvers don't serve.

## Why this layout exists

### Why Caddy and not nginx / Traefik

- Caddy reads TLS certs directly from a directory, no ceremony for renewal.
- Caddyfile syntax maps cleanly to "one vhost per subdomain".
- Supports HTTP/3 with one line.
- Can keep the same cert path across restarts because the certs directory is bind-mounted read-only.

### Why Cloudflare in front

- Hides the VPS IP from clients (a small amount of obfuscation).
- Provides DDoS protection, bot challenge, rate limiting at the edge.
- Origin TLS only needs a long-lived Origin Certificate that Cloudflare signs for the whole `jehpok.com` zone — no ACME challenge, no rate limits.

The trade-off: browser traffic is bot-challenged. For an API endpoint that is hit by terminal `curl` (Cloudflare's Browser Integrity Check rejects that), the workaround is either to lower WAF strictness for the API hostname or to put the API behind Cloudflare Access with a Service Auth token. Both have been considered; the goal is to keep Cloudflare's full protection on, so a Per-Hostname / Bot Fight Mode rule skip on `api.jehpok.com` is the minimum change.

### Why Tailscale for vps.jehpok.com

- The VPS hostname should be reachable only from the user's devices.
- Public DNS would let any bot or attacker hit a port that isn't supposed to be public.
- Tailscale's split-DNS means the moment a Tailscale client joins the network, the hostname is reachable AND the resolver knows it. No port forwarding, no firewall holes.

### Why CoreDNS in a container

- The Tailscale split DNS on the user side forwards queries for `*.jehpok.com` to a resolver on the VPS.
- That resolver must return `100.81.245.77` for `vps.jehpok.com` and forward everything else.
- A small CoreDNS container does this in one Corefile. systemd-resolved could do it too, but binding systemd-resolved to `0.0.0.0:53` from the host namespace interferes with Docker's port mapping and complicates restart logic. A container with port 53 exposed is cleaner.
- The container binds port 53 **only to the Tailscale IP** (`100.81.245.77`), not `0.0.0.0`, so the VPS is not an open resolver on the public internet. Only tailnet devices can reach it.

### Why a docker network called `net`

- All inter-container DNS (e.g. Caddy reverse-proxying to `cloud:9000`) needs a user-defined bridge network.
- Docker's embedded DNS at `127.0.0.11` resolves container names on user-defined networks automatically — no Consul, no extra service registry.
- One network keeps Caddy and Nextcloud on the same subnet.
- Marked `external: true` so the same network is reused across `domain` and `cloud` compose files (Compose would otherwise create a private one).
- `tailnet` (CoreDNS) is intentionally **not** on `net` — it has no inter-container dependencies, only host port mapping to the Tailscale IP.

## Repository layout

```
services/
  domain/
    Caddyfile                # Caddy vhosts + reverse-proxy rules
    docker-compose.yml       # Caddy service
  tailnet/
    Corefile                 # CoreDNS hosts + forwarders
    docker-compose.yml       # CoreDNS ("tailnet") service
  cloud/
    docker-compose.yml       # Nextcloud (name: cloud)
    php-fpm.d/zz-custom.conf # PHP-FPM pool config
    .env                     # NEXTCLOUD_ADMIN_USER / NEXTCLOUD_ADMIN_PASSWORD (gitignored)
setup/
  ollama/ollama.service      # Reference copy of the host systemd unit
  ssh/50-cloud-init.conf     # Reference copy of SSH hardening config
content/
  domain/
    www/                     # static files for www.jehpok.com
    app/                     # static files for app.jehpok.com
    vps/                     # static files for vps.jehpok.com (Tailscale-only)
Makefile                     # Recipes: up-all, setup-host, backup-cloud, backup-secrets, migrate, etc.
docs/AGENTS.md                    # Operating guide for agents
docs/ISSUES.md                    # Known problems and improvements
```

`services/` holds everything that describes the running services (Docker). `setup/` holds reference copies of host-level configs (Ollama, SSH) — used by `make setup-host` to restore them to live paths on a fresh VPS. `content/` holds the data the services serve. The split lets `services/` and `setup/` be checked into git while large or versioned content can live elsewhere on disk (mirrored into the repo for portability).

On the VPS, the cloned repo sits at `/var/www/github/jehpok.com/repo/`. Caddy mounts it as `/srv`, so an `app` vhost with `root * /srv/content/domain/app` resolves to `/var/www/github/jehpok.com/repo/content/domain/app`. Per-service configuration details (images, ports, env, timeouts, gotchas) live in `docs/AGENTS.md` under "Service details".

## Deployment

Deployment is manual — no CI/CD, pushes to `main` trigger nothing. Besides editing files on the VPS, use 'make' commands to control your workflow effortlessly.

### First-time setup and migration

Run `make migrate` for the full step-by-step runbook. It assumes: the `net` bridge exists (`docker network create net`), the Cloudflare Origin cert/key are at `/var/www/github/jehpok.com/certs/`, and Nextcloud's two bind mounts (`cloud/html`, `cloud/users`) are owned by uid 33 with a `.ncdata` marker in `cloud/users` before first start.

### Backups

`make backup-cloud` snapshots Nextcloud data (maintenance mode on during the copy) to `/var/www/github/jehpok.com/cloud-backup-<date>`. `make backup-secrets` bundles certs, SSH keys, the Ollama unit, and Tailscale state to `/var/www/github/jehpok.com/secrets-backup/secrets-<date>.tar.gz`. Download both off the VPS — the secrets bundle contains private keys and Tailscale identity.

### CMD Sheet

Use the `Makefile` recipes (canonical) rather than raw `docker compose`:

```bash
make up-all            # start/recreate all three containers in order (tailnet, domain, cloud)
make up-<service>      # force-recreate one container — up-domain | up-cloud | up-tailnet
make restart-<service> # reload one container without recreating — after editing a mounted config
make logs-<service>    # follow one container's logs — logs-domain | logs-cloud | logs-tailnet
make status            # show a table of all running containers
make push MSG="..."    # stage, commit, and push to the jehpok.com remote
make backup-cloud      # snapshot Nextcloud data (maintenance mode on during the copy)
make backup-secrets    # bundle certs, SSH keys, Ollama unit, and Tailscale state for off-VPS storage
make setup-host        # install reference configs to live paths and enable Ollama + sshd
make migrate           # print the full VPS-to-VPS migration runbook
make clean             # free disk: prune the Docker build cache and clear the apt cache
```

Nextcloud runs its own database migrations on first request after an upgrade, so no manual migration step is needed after `make up-cloud`.

## SSH access

SSH is restricted to the Tailscale network only. The public internet cannot reach port 22.

| Setting | Value |
|---------|-------|
| Port | 22 |
| Interface | `tailscale0` only (ufw: `22/tcp on tailscale0 ALLOW`, `22 DENY` elsewhere) |
| Password auth | **Disabled** (key-only) |
| Root login | **Disabled** |
| Allowed users | `debian` only |
| Config | `/etc/ssh/sshd_config` + `/etc/ssh/sshd_config.d/50-cloud-init.conf` |

The only way to SSH into the VPS is:
1. Be on the Tailscale network.
2. Have the `debian` user's private key (`ed25519`, authorized in `/home/debian/.ssh/authorized_keys`).

The `runner` user (legacy GitHub Actions) has no SSH key and is not in `AllowUsers` — it cannot SSH in.

## Operational notes and gotchas

- `vps.jehpok.com` will appear "down" from non-Tailscale networks. That's by design. Don't add it to Cloudflare DNS to "fix" it — that defeats the only access control.
- The `tailnet` container is the SPOF for VPN-side DNS. It is bound only to the Tailscale IP so it's not an open resolver, but if it stops, every `*.jehpok.com` query on Tailscale times out. Two ways to harden: (a) add a second CoreDNS instance pointed to the same Corefile; (b) move DNS onto the host namespace (dnsmasq) so it's independent of Docker restarts.
- Cloudflare's free tier rate-limits you at 10s min window for rate-limit rules. Plan ahead if the API endpoint ends up attracting more traffic than expected.
- `cloud.jehpok.com` is reached by Nextcloud desktop / mobile clients that cannot solve Cloudflare's Browser Integrity Check or Bot Fight Mode JS challenge. Disable Bot Fight Mode (or set a per-hostname WAF rule skip) for `cloud.jehpok.com` in Cloudflare, otherwise desktop sync will hang on the first request. This is the same mitigation already noted for `api.jehpok.com`.
