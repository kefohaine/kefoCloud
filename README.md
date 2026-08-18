# jehpok.com

Self-hosted infrastructure on a Debian VPS, fronted by Caddy in Docker. Six public subdomains and one Tailscale-only subdomain. Ollama runs on the host as a systemd service for local LLM serving.

## High-level overview

```
                   ┌─────────────────────────────────────────────┐
    Public DNS ──► │            Cloudflare (proxy)               │
                    │  www / share / api / vault / cloud / status│
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
           reverse_proxy      reverse_proxy       php_fastcgi
           vps / api          share / vault       cloud:9000
                              / status            (Nextcloud FPM)
                              / www (Homer)

                     ┌─────────────────────────────────────────────┐
                     │ Tailscale MagicDNS / split DNS              │
                     │ forwards *.jehpok.com queries to the VPS    │
                     │ resolver (bound to Tailscale IP only)       │
                     └──────────────┬──────────────────────────────┘
                                    │ UDP/TCP 100.81.245.77:53
                                    ▼
                             ┌──────────────┐
                             │   dnsmasq    │  host systemd service
                             │  (host)      │  (not a container)
                             │  - address=/vps.jehpok.com/100.81.245.77
                             │  - forward . 1.1.1.1 1.0.0.1 9.9.9.9
                             └──────────────┘
```

One VPS, one host. Cloudflare fronts six of the seven hostnames; the Tailscale-only hostname is invisible on the public internet. Deliberate non-public behaviours (`vps.jehpok.com` being unreachable off the tailnet, Cloudflare Bot Fight Mode blocking `curl`/desktop sync, the retired cheyou page) are documented under `Intended` in `docs/ISSUES.md` so future agents don't "correct" them.

## Domains and access model

| Domain             | Where DNS points            | Who can reach it                            | What is served                                  |
|--------------------|-----------------------------|---------------------------------------------|-------------------------------------------------|
| www.jehpok.com     | Cloudflare → VPS IP         | Anyone on the internet                      | Homer dashboard — landing page listing every public self-hosted service; reverse-proxied to the `homer` container |
| share.jehpok.com   | Cloudflare → VPS IP         | Anyone on the internet                      | URL shortener + file sharing (Flask); reverse-proxied to the `share` container |
| api.jehpok.com     | Cloudflare → VPS IP         | Anyone on the internet                      | Placeholder vhost (no backend currently wired)  |
| vault.jehpok.com   | Cloudflare → VPS IP         | Anyone on the internet                      | Vaultwarden (self-hosted Bitwarden-compatible password manager); reverse-proxied to the `vault` container |
| cloud.jehpok.com   | Cloudflare → VPS IP         | Anyone on the internet                      | Nextcloud (file sync, calendar, photos); PHP-FPM behind Caddy |
| status.jehpok.com  | Cloudflare → VPS IP         | Anyone on the internet                      | Uptime Kuma monitor dashboard; reverse-proxied to the `kuma` container |
| vps.jehpok.com     | **Not in Cloudflare**       | Only devices on the Tailscale network       | Responds `ok`; admin UI for the shortener at `/share` |

The asymmetry on `vps.jehpok.com` is deliberate. By keeping it out of public DNS, the only way anyone can know its IP is by being inside the Tailscale network. Even a DNS leak on the user's device cannot reveal an address that public resolvers don't serve. As defense-in-depth, Caddy also rejects any request to the vhost whose source IP is not on the tailnet (`100.64.0.0/10`), so reaching it via the public IP with a forged Host header returns 403 on every path.

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

The trade-off: browser traffic is bot-challenged. For terminal `curl` or Nextcloud desktop sync clients that can't solve Cloudflare's Browser Integrity Check, the workaround is a per-hostname WAF rule skip on the affected hostname (`api.jehpok.com`, `cloud.jehpok.com`) — see `Intended` in `docs/ISSUES.md`.

### Why Tailscale for vps.jehpok.com

- The VPS hostname should be reachable only from the user's devices.
- Public DNS would let any bot or attacker hit a port that isn't supposed to be public.
- Tailscale's split-DNS means the moment a Tailscale client joins the network, the hostname is reachable AND the resolver knows it. No port forwarding, no firewall holes.

### Why dnsmasq on the host and not CoreDNS in a container

- The Tailscale split DNS on the user side forwards queries for `*.jehpok.com` to a resolver on the VPS.
- That resolver must return `100.81.245.77` for `vps.jehpok.com` and forward everything else.
- A small host `dnsmasq` instance does this in one config file. systemd-resolved could do it too, but binding systemd-resolved to `0.0.0.0:53` from the host namespace interferes with Docker's port mapping and complicates restart logic.
- Running it on the host (not in Docker) makes DNS independent of `docker stop`, image pulls, and `systemctl restart docker` — the failure modes a container `restart: unless-stopped` policy cannot cover. A `Restart=always` systemd unit is the only supervisor involved.
- dnsmasq binds port 53 **only to the Tailscale IP** (`100.81.245.77`), not `0.0.0.0`, so the VPS is not an open resolver on the public internet. Only tailnet devices can reach it.

### Why a docker network called `net`

- All inter-container DNS (e.g. Caddy reverse-proxying to `cloud:9000`) needs a user-defined bridge network.
- Docker's embedded DNS at `127.0.0.11` resolves container names on user-defined networks automatically — no Consul, no extra service registry.
- One network keeps Caddy and Nextcloud on the same subnet.
- Marked `external: true` so the same network is reused across compose files (Compose would otherwise create a private one).
