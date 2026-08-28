# fxmq.net

Self-hosted infrastructure on a Debian VPS, fronted by Caddy in Docker. Since 2026-08-28 the HTTP layer serves plain `ok` stubs: every vhost responds `ok` on every path except `shell.fxmq.net`, which serves the host ttyd terminal at `/ttyd` (Tailscale-only). The application containers (Nextcloud, Vaultwarden, Uptime Kuma, PufferPanel, Docker Mailserver + Roundcube) still run on the `net` bridge but are no longer routed through their hostnames; their compose files remain in `services/`. Open WebUI was removed entirely (container, image, data, routes). Six hostnames are public through Cloudflare (cloud, kuma, mc, mail, vault, www); one (`shell.fxmq.net`) is Tailscale-only. The mail records (`MX`, `mail.fxmq.net` A) are DNS-only at Cloudflare — SMTP/IMAP can't be proxied. Goose (the agent CLI) runs on the host as a systemd service (`goose serve`).

## High-level overview

```
                   ┌─────────────────────────────────────────────┐
    Public DNS ──► │            Cloudflare (proxy)               │
                   │       cloud / vault / kuma / www            │
                   └──────────────┬──────────────────────────────┘
                                  │ HTTPS (LE cert via DNS-01)
                                  ▼
                           ┌──────────────┐
                           │    Caddy     │  port 80 → 308 redirect
                           │  (fxmq.net)  │  port 443 (per-vhost LE)
                           └──────┬───────┘  custom image with the
                                  │          caddy-dns/cloudflare
                                  │          plugin
              every path of every public vhost → plain "ok"
              (mc + mail are DNS-only at CF; their vhosts
               still terminate TLS and answer "ok")

    shell.fxmq.net is tailnet-only (not in public DNS) — "/" serves
    plain "ok", "/ttyd" the host ttyd terminal; non-tailnet sources
    get 403.

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

One VPS, one host. Cloudflare fronts the public hostnames; the Tailscale-only hostname is invisible on the public internet. The stub behaviour is deliberate (see "Why the edge serves plain `ok` stubs"): the domains keep resolving, the per-vhost Let's Encrypt certs keep renewing, and no endpoint returns a broken 502/404. Deliberate non-public behaviours (`shell.fxmq.net` being unreachable off the tailnet, Cloudflare Bot Fight Mode) are documented under `Intended` in `docs/ISSUES.md` so future agents don't "correct" them.

## Domains and access model

| Domain            | Where DNS points            | Who can reach it                     | What is served                                  |
|-------------------|-----------------------------|--------------------------------------|-------------------------------------------------|
| cloud.fxmq.net    | Cloudflare (proxied) → VPS IP | Anyone on the internet             | Plain `ok` stub (Nextcloud decommissioned from the edge 2026-08-28) |
| vault.fxmq.net    | Cloudflare (proxied) → VPS IP | Anyone on the internet             | Plain `ok` stub (Vaultwarden decommissioned from the edge 2026-08-28) |
| kuma.fxmq.net     | Cloudflare (proxied) → VPS IP | Anyone on the internet             | Plain `ok` stub (Uptime Kuma decommissioned from the edge 2026-08-28) |
| mc.fxmq.net       | Cloudflare DNS-only → VPS IP | Anyone on the internet             | Plain `ok` stub (PufferPanel `/panel` + `/download` browser decommissioned from the edge 2026-08-28; game ports 25565/19132 still published directly on the VPS, DNS-only so the CF proxy doesn't break them) |
| www.fxmq.net      | Cloudflare (proxied) → VPS IP | Anyone on the internet             | Plain `ok` stub |
| mail.fxmq.net    | Cloudflare **DNS-only** (grey cloud) → VPS IP | Anyone on the internet             | Plain `ok` stub (webmail decommissioned from the edge 2026-08-28; SMTP/IMAP ports 25/465/587/993 still published by the mail container, DNS-only so SMTP/IMAP work) |
| shell.fxmq.net    | Not in Cloudflare, not in public DNS | Only devices on the Tailscale network | ttyd host shell at `/ttyd`; plain `ok` everywhere else. Caddy `@not_tailnet` returns 403 for any non-tailnet source IP, including forged Host headers against the public IP |

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
- The CF-proxy'd vhosts (`cloud`, `vault`, `kuma`, `www`) terminate TLS at the CF edge and re-encrypt to the origin with the LE cert that Caddy issues via DNS-01.

The trade-off: browser traffic is bot-challenged. For terminal `curl` or Nextcloud desktop sync clients that can't solve Cloudflare's Browser Integrity Check, the workaround is a per-hostname WAF rule skip on the affected hostname (`cloud.fxmq.net`) — see `Intended` in `docs/ISSUES.md`.

### Why Tailscale for shell.fxmq.net

- The VPS hostname should be reachable only from the user's devices.
- Public DNS would let any bot or attacker hit a port that isn't supposed to be public.
- Tailscale's split-DNS means the moment a Tailscale client joins the network, the hostname is reachable AND the resolver knows it. No port forwarding, no firewall holes.
- The `shell.fxmq.net` vhost in Caddy uses a LE cert just like every other vhost — tailnet clients get a clean HTTPS handshake instead of a self-signed cert warning.
- The VPS also advertises exit-node routes; IPv4+IPv6 forwarding is enabled in `config/sysctl/99-homelab.conf` so tailnet devices can route their internet traffic through it.

### Why the edge serves plain `ok` stubs

- The application containers were decommissioned from the edge on 2026-08-28 (Open WebUI removed entirely; the rest unreachable via their hostnames). The vhosts still answer `ok` so the domains keep working: DNS stays valid, per-vhost LE certs keep renewing, links and monitors don't break with 502/404, and no dead proxy config points at a container that no longer answers.
- `shell.fxmq.net` keeps the host terminal at `/ttyd` — the one service that was kept on purpose.
- The containers themselves were not removed (except Open WebUI): Nextcloud, Vaultwarden, Uptime Kuma, PufferPanel (and the game server it manages) and the mail platform still run on the bridge, ready to be re-routed by restoring a vhost file. Compose files are in `services/`.

### Why dnsmasq on the host and not CoreDNS in a container

- The Tailscale split DNS on the user side forwards queries for `shell.fxmq.net` to a resolver on the VPS.
- That resolver must return `100.117.144.0` for `shell.fxmq.net` and forward everything else.
- A small host `dnsmasq` instance does this in one config file. systemd-resolved could do it too, but binding systemd-resolved to `0.0.0.0:53` from the host namespace interferes with Docker's port mapping and complicates restart logic.
- Running it on the host (not in Docker) makes DNS independent of `docker stop`, image pulls, and `systemctl restart docker` — the failure modes a container `restart: unless-stopped` policy cannot cover. A `Restart=always` systemd unit is the only supervisor involved.
- dnsmasq binds port 53 **only to the Tailscale IP** (`100.117.144.0`), not `0.0.0.0`, so the VPS is not an open resolver on the public internet. Only tailnet devices can reach it.

### Why a docker network called `net`

- All inter-container DNS (e.g. Caddy reverse-proxying to `nextcloud:9000`) needs a user-defined bridge network.
- Docker's embedded DNS at `127.0.0.11` resolves container names on user-defined networks automatically — no Consul, no extra service registry.
- One network keeps Caddy and the other containers on the same subnet.
- Marked `external: true` with an explicit `--subnet=172.22.0.0/16` so the same network is reused across compose files and the pinned bridge IPs attach cleanly.
