# fxmq.net

Self-hosted infrastructure on a Debian VPS, fronted by Caddy in Docker. Four containers: Caddy (`fxmq.net`, host-network reverse proxy), Nextcloud, Vaultwarden, and Uptime Kuma. Three of the four hostnames are public through Cloudflare; one (`shell.fxmq.net`) is Tailscale-only. Goose (the agent CLI) runs on the host as a systemd service (`goose serve`).

## High-level overview

```
                   ┌─────────────────────────────────────────────┐
    Public DNS ──► │            Cloudflare (proxy)               │
                   │       cloud / vault / kuma                  │
                   └──────────────┬──────────────────────────────┘
                                  │ HTTPS (LE cert via DNS-01)
                                  ▼
                           ┌──────────────┐
                           │    Caddy     │  port 80 → 308 redirect
                           │  (fxmq.net)  │  port 443 (per-vhost LE)
                           └──────┬───────┘  custom image with the
                ┌─────────────────┼─────────────────┐     caddy-dns/
                │                 │                 │     cloudflare
                ▼                 ▼                 ▼     plugin
           reverse_proxy    reverse_proxy      php_fastcgi
           vaultwarden      uptime-kuma        nextcloud:9000
           (172.22.0.4:80)  (172.22.0.6:3001)  (Nextcloud FPM)

    shell.fxmq.net is tailnet-only (not in public DNS) — "/" replies
    "ok", "/shell" proxies to the host ttyd, non-tailnet sources get 403.

                     ┌─────────────────────────────────────────────┐
                     │ Tailscale MagicDNS / split DNS              │
                     │ forwards shell.fxmq.net queries to the VPS   │
                     │ resolver (bound to Tailscale IP only)       │
                     └──────────────┬──────────────────────────────┘
                                    │ UDP/TCP 100.117.144.0:53
                                    ▼
                             ┌──────────────┐
                             │   dnsmasq    │  host systemd service
                             │  (host)      │  (not a container)
                             │  - address=/shell.fxmq.net/100.117.144.0
                             │  - forward . 1.1.1.1 1.0.0.1 9.9.9.9
                             └──────────────┘
```

One VPS, one host. Cloudflare fronts the three public hostnames; the Tailscale-only hostname is invisible on the public internet. Deliberate non-public behaviours (`shell.fxmq.net` being unreachable off the tailnet, Cloudflare Bot Fight Mode blocking `curl`/desktop sync against `cloud.fxmq.net`) are documented under `Intended` in `docs/ISSUES.md` so future agents don't "correct" them.

## Domains and access model

| Domain            | Where DNS points            | Who can reach it                     | What is served                                  |
|-------------------|-----------------------------|--------------------------------------|-------------------------------------------------|
| cloud.fxmq.net    | Cloudflare (proxied) → VPS IP | Anyone on the internet             | Nextcloud (file sync, calendar, photos); PHP-FPM behind Caddy |
| vault.fxmq.net    | Cloudflare (proxied) → VPS IP | Anyone on the internet             | Vaultwarden (Bitwarden-compatible password manager) |
| kuma.fxmq.net     | Cloudflare (proxied) → VPS IP | Anyone on the internet             | Uptime Kuma monitor dashboard |
| shell.fxmq.net    | Not in Cloudflare, not in public DNS | Only devices on the Tailscale network | Responds `ok` on `/`; ttyd host shell at `/shell`. Caddy `@not_tailnet` returns 403 for any non-tailnet source IP, including forged Host headers against the public IP |

The asymmetry on `shell.fxmq.net` is deliberate. By keeping it out of public DNS, the only way anyone can know its IP is by being inside the Tailscale network. Even a DNS leak on the user's device cannot reveal an address that public resolvers don't serve. As defense-in-depth, Caddy also rejects any request to the vhost whose source IP is not on the tailnet (`100.64.0.0/10`), so reaching it via the public IP with a forged Host header returns 403 on every path.

## Why this layout exists

### Why Caddy and not nginx / Traefik

- Caddyfile syntax maps cleanly to "one vhost per subdomain" — each `services/fxmq.net/vhosts/<host>.caddy` file owns its own TLS block independently.
- Caddy handles ACME renewal automatically via the built-in issuer; the `caddy-dns/cloudflare` plugin adds DNS-01 challenge support so certs are issued independently of the proxy (the public vhosts terminate TLS at the CF edge, and DNS-01 works whether or not port 80 reaches the origin).
- Certs persist under `/data` (bind-mounted) so container recreates don't restart the 90-day clock.
- Supports HTTP/3 with one line.

### Why Cloudflare in front

- Hides the VPS IP from clients (a small amount of obfuscation).
- Provides DDoS protection, bot challenge, rate limiting at the edge.
- The CF-proxy'd vhosts (`cloud`, `vault`, `kuma`) terminate TLS at the CF edge and re-encrypt to the origin with the LE cert that Caddy issues via DNS-01.

The trade-off: browser traffic is bot-challenged. For terminal `curl` or Nextcloud desktop sync clients that can't solve Cloudflare's Browser Integrity Check, the workaround is a per-hostname WAF rule skip on the affected hostname (`cloud.fxmq.net`) — see `Intended` in `docs/ISSUES.md`.

### Why Tailscale for shell.fxmq.net

- The VPS hostname should be reachable only from the user's devices.
- Public DNS would let any bot or attacker hit a port that isn't supposed to be public.
- Tailscale's split-DNS means the moment a Tailscale client joins the network, the hostname is reachable AND the resolver knows it. No port forwarding, no firewall holes.
- The `shell.fxmq.net` vhost in Caddy uses a LE cert just like every other vhost — tailnet clients get a clean HTTPS handshake instead of a self-signed cert warning.
- The VPS also advertises exit-node routes; IPv4+IPv6 forwarding is enabled in `config/sysctl/99-homelab.conf` so tailnet devices can route their internet traffic through it.

### Why dnsmasq on the host and not CoreDNS in a container

- The Tailscale split DNS on the user side forwards queries for `shell.fxmq.net` to a resolver on the VPS.
- That resolver must return `100.117.144.0` for `shell.fxmq.net` and forward everything else.
- A small host `dnsmasq` instance does this in one config file. systemd-resolved could do it too, but binding systemd-resolved to `0.0.0.0:53` from the host namespace interferes with Docker's port mapping and complicates restart logic.
- Running it on the host (not in Docker) makes DNS independent of `docker stop`, image pulls, and `systemctl restart docker` — the failure modes a container `restart: unless-stopped` policy cannot cover. A `Restart=always` systemd unit is the only supervisor involved.
- dnsmasq binds port 53 **only to the Tailscale IP** (`100.117.144.0`), not `0.0.0.0`, so the VPS is not an open resolver on the public internet. Only tailnet devices can reach it.

### Why a docker network called `net`

- All inter-container DNS (e.g. Caddy reverse-proxying to `nextcloud:9000`) needs a user-defined bridge network.
- Docker's embedded DNS at `127.0.0.11` resolves container names on user-defined networks automatically — no Consul, no extra service registry.
- One network keeps Caddy and Nextcloud on the same subnet.
- Marked `external: true` with an explicit `--subnet=172.22.0.0/16` so the same network is reused across compose files and the pinned bridge IPs (`172.22.0.4` vault, `.5` cloud, `.6` kuma) attach cleanly.
