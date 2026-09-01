# fxmq.net

Self-hosted infrastructure on a Debian VPS, fronted by Caddy in Docker. Eleven containers: Caddy (`fxmq.net`, host-network reverse proxy), the Nextcloud stack (app FPM, PostgreSQL, Redis cache, Talk signaling + TURN), Vaultwarden, Uptime Kuma, PufferPanel, and the mail platform (Docker Mailserver + Roundcube webmail). PostgreSQL stays on fxmq (DB latency local, 11 GB RAM); a second **1 TB / 2 GB storage VPS** ("storage", on the tailnet) is the off-host backup target (nightly `pg_dump` → `storage:/backups/nc`) and the intended home for user files (Garage S3 installed, migration pending). Seven hostnames are public through Cloudflare (cloud, kuma, mail, mc, turn, vault, www); one (`shell.fxmq.net`) is Tailscale-only. The mail records (`MX`, `mail.fxmq.net` A) are DNS-only at Cloudflare — SMTP/IMAP can't be proxied; `turn.fxmq.net` is DNS-only too (TURN media bypasses the proxy). Goose (the agent CLI) runs on the host as a systemd service (`goose serve`).

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
           (also: pufferpanel 172.22.0.8:8080,
            roundcube webmail 172.22.0.10:80 —
            mail platform Postfix/Dovecot at 172.22.0.9, ports 25/465/587/993)

    shell.fxmq.net is tailnet-only (not in public DNS) — "/" serves
    a plain "ok" landing and "/ttyd"
    the host ttyd; non-tailnet sources get 403.

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

One VPS, one host. Cloudflare fronts the seven public hostnames (three proxied — cloud, vault, kuma — four DNS-only); the Tailscale-only hostname is invisible on the public internet. Deliberate non-public behaviours (`shell.fxmq.net` being unreachable off the tailnet, Cloudflare Bot Fight Mode blocking `curl`/desktop sync against `cloud.fxmq.net`) are documented under `Intended` in `docs/ISSUES.md` so future agents don't "correct" them.

## Domains and access model

| Domain            | Where DNS points            | Who can reach it                     | What is served                                  |
|-------------------|-----------------------------|--------------------------------------|-------------------------------------------------|
| cloud.fxmq.net    | Cloudflare (proxied) → VPS IP | Anyone on the internet             | Nextcloud (file sync, calendar, photos, Talk, Mail); PHP-FPM behind Caddy |
| turn.fxmq.net     | Cloudflare **DNS-only** (grey cloud) → VPS IP | Anyone on the internet | Talk High Performance Backend websocket at `/signaling` + TURN/STUN on 3478/5349. DNS-only because WebRTC media bypasses the CF proxy (same constraint as mail) |
| vault.fxmq.net    | Cloudflare (proxied) → VPS IP | Anyone on the internet             | Vaultwarden (Bitwarden-compatible password manager) |
| kuma.fxmq.net     | Cloudflare (proxied) → VPS IP | Anyone on the internet             | Uptime Kuma monitor dashboard |
| mc.fxmq.net       | Cloudflare DNS-only → VPS IP | Anyone on the internet             | PufferPanel at `/panel`; Caddy file browser at `/download` over the `download/` drop folder; in-browser Minecraft 1.8.8 (EaglercraftX, no install/login) at `/play` with websocket at `/server` (Java players: `mc.fxmq.net:25565`, any Java client 1.7.10–latest via the Via family); `/` redirects to `/panel`. DNS-only (grey cloud) so the game ports bypass the CF proxy |
| www.fxmq.net      | Cloudflare (proxied) → VPS IP | Anyone on the internet             | Stub: responds `ok` on `/` |
| mail.fxmq.net    | Cloudflare **DNS-only** (grey cloud) → VPS IP | Anyone on the internet             | Roundcube webmail; Docker Mailserver platform (SMTP 25/465/587, IMAP 993). Inbound port 25 is open; PTR record still pending at the VPS provider — see `docs/ISSUES.md` |
| shell.fxmq.net    | Not in Cloudflare, not in public DNS | Only devices on the Tailscale network | Plain `ok` landing at `/`; ttyd host shell at `/ttyd`. Caddy `@not_tailnet` returns 403 for any non-tailnet source IP, including forged Host headers against the public IP |

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

### Why Docker Mailserver for mail

- The mail platform is Docker Mailserver (one Postfix + Dovecot container, active monthly releases, DKIM/DMARC/fail2ban/Rspamd built in) plus the official Roundcube image as webmail. Chosen over Mailu (~8 containers) and Mailcow (~12, 6-8 GB RAM) because it is the lightest trusted option — one container serving SMTP/IMAP.
- TLS reuses Caddy's per-vhost Let's Encrypt cert for mail.fxmq.net: the mail container mounts caddy_data read-only (SSL_TYPE=manual) and DMS's changedetector reloads postfix + dovecot when the cert renews, so there is one cert path for web + mail.
- The mail records (MX fxmq.net, mail.fxmq.net A) are DNS-only at Cloudflare — a proxied record would break SMTP/IMAP, which only speaks TCP on 25/465/587/993. SPF, DMARC, and DKIM (mail._domainkey) TXT records are set on the zone; DKIM keys live in the mail config dir.
- Roundcube talks to the mail container over the bridge with STARTTLS (dovecot/postfix reject plaintext auth), resolving mail.fxmq.net to the bridge IP via extra_hosts so SNI + cert verification match the LE cert.
- Provider-side blocker that no host config can fix is tracked in docs/ISSUES.md: the IP has no PTR record yet (inbound port 25 is open). Set reverse DNS at the VPS provider for external deliverability.

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

### Why the Nextcloud stack is split the way it is

- **PostgreSQL instead of the stock SQLite** — SQLite's file-level locking caused intermittent 504s under concurrent sync and made consistent backups hard. Postgres (tuned via `-c` flags in `services/nextcloud/docker-compose.db.yml`, data in the repo-sibling `pgdata/`) is the "strong database" the app deserves; the data dir is deliberately portable because the operator plans to relocate it to a 1 TB / 2 GB VPS over Tailscale (see `docs/ISSUES.md`).
- **Redis for caching + locking** (`redis` container, 128 MB LRU, no persistence — a pure cache) — `memcache.distributed` + `memcache.locking` land in `config.php` automatically from `REDIS_HOST`; APCu stays as the local cache.
- **Talk HPB + self-hosted TURN** — the official Go signaling server (`talk-hpb`) gives Talk a websocket backend at `wss://turn.fxmq.net/signaling`; coturn (container `talk-relay`) provides TURN/STUN so calls work from restrictive NATs without handing call media to a public STUN/TURN service. The 3 GB RAM ceiling for the whole stack (app + cache + HPB + TURN + DB = 2.02 GB of hard caps) is enforced with `mem_limit`/`memswap_limit` per container.
- **The mail ecosystem is reciprocal** — Nextcloud's Mail app and its own outbound SMTP talk to the same Docker Mailserver on the bridge (`extra_hosts` maps `mail.fxmq.net` → 172.22.0.9 so the LE cert matches); NC sends notifications/resets from a `nextcloud@fxmq.net` mailbox, and user emails (e.g. `admin@fxmq.net`) are both the account recovery channel and a valid login (NC resolves a unique email to its user natively). Vaultwarden sends verification/invite/notification email the same way from a `vaultwarden@fxmq.net` mailbox (STARTTLS 587 over the bridge).
