# jehpok.com

Self-hosted infrastructure on a Debian VPS, fronted by Caddy in Docker, serving four subdomains over public internet and Tailscale.

This document describes the full system: what runs where, why each piece exists, how requests flow, and what to know when something breaks.

## High-level overview

```
                  ┌─────────────────────────────────────────────┐
   Public DNS ──► │            Cloudflare (proxy)              │
                  │   www / app / api       (orange cloud)      │
                  └──────────────┬──────────────────────────────┘
                                 │ HTTPS (Origin Cert)
                                 ▼
                          ┌──────────────┐
                          │    Caddy     │  port 443 (web container)
                          │  (web)       │
                          └──────┬───────┘
                  ┌──────────────┼──────────────┐
                  │ /ai /status  │              │ /download/*
                  ▼              │              ▼
              ┌───────┐     static files    /srv/content/web/
              │  ai   │     (/srv/content)  api/download/
              │ FastAPI
              │ llama.cpp
              └────────┘

   Tailscale network: clients also reach 100.81.245.77 (the VPS's tailnet IP)
                       directly. To resolve vps.jehpok.com they use:

                  ┌─────────────────────────────────────────────┐
                  │ Tailscale MagicDNS / split DNS             │
                  │ forwards *.jehpok.com queries to the VPS    │
                  │ resolver                                   │
                  └──────────────┬──────────────────────────────┘
                                 │ UDP/TCP :53
                                 ▼
                          ┌──────────────┐
                          │  CoreDNS     │  container "tailnet"
                          │  (tailnet)   │
                          │  - hosts { vps.jehpok.com → 100.81.245.77 }
                          │  - forward . 1.1.1.1
                          └──────────────┘
```

Only one VPS, one host. Cloudflare fronts three of the four hostnames; the Tailscale-only hostname is invisible on the public internet.

## Domains and access model

| Domain             | Where DNS points            | Who can reach it                            | What is served                                  |
|--------------------|-----------------------------|---------------------------------------------|-------------------------------------------------|
| www.jehpok.com     | Cloudflare → VPS IP         | Anyone on the internet                      | Static site from `content/web/www`              |
| app.jehpok.com     | Cloudflare → VPS IP         | Anyone on the internet                      | Static site from `content/web/app`              |
| api.jehpok.com     | Cloudflare → VPS IP         | Anyone on the internet                      | `POST /ai`, `GET /status` → LLM; `GET /download/*` → static files |
| vps.jehpok.com     | **Not in Cloudflare**       | Only devices on the Tailscale network       | Static site from `content/web/vps`              |

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

### Why a docker network called `net`

- All inter-container DNS (e.g. Caddy reverse-proxying to `ai:8000`) needs a user-defined bridge network.
- Docker's embedded DNS at `127.0.0.11` resolves container names on user-defined networks automatically — no Consul, no extra service registry.
- One network keeps Caddy, the AI backend, and Tailscale-DNS on the same subnet.
- Marked `external: true` so the same network is reused across `web` and `ai` compose files (Compose would otherwise create a private one).

## Repository layout

```
config/
  web/
    Caddyfile                # Caddy vhosts + reverse-proxy rules
    Corefile                 # CoreDNS hosts + forwarders
    docker-compose.yml       # Caddy + CoreDNS ("tailnet") services
  ai/
    Dockerfile               # python:3.12-slim + llama-cpp-python
    docker-compose.yml       # llama-cpp FastAPI service (name: ai)
    requirements.txt         # Python deps for the AI container
content/
  ai/
    app.py                   # FastAPI: POST /ai, GET /status
  web/
    www/                     # static files for www.jehpok.com
    app/                     # static files for app.jehpok.com
    vps/                     # static files for vps.jehpok.com (Tailscale-only)
    api/
      download/              # static files served under api.jehpok.com/download/*
```

`config/` holds everything that describes the running services. `content/` holds the data they serve. The split lets the same `config/` be checked into git while large or versioned content can live elsewhere on disk (mirrored into the repo for portability).

On the VPS, the cloned repo sits at `/var/www/github/jehpok.com/repo/`. Caddy mounts it as `/srv`, so an `app` vhost with `root * /srv/content/web/app` resolves to `/var/www/github/jehpok.com/repo/content/web/app`.

## Service details

### web (Caddy 2)

`config/web/docker-compose.yml` defines the `web` and `tailnet` services. Key points:

- `web` and `tailnet` are the only containers in this compose file.
- Caddy terminates TLS using a Cloudflare Origin Certificate loaded from `/certs/cert.pem` + `/certs/key.pem`.
- Caddy routes:
  - `https://www.jehpok.com` → static fileserver from `/srv/content/web/www`.
  - `https://app.jehpok.com` → static fileserver from `/srv/content/web/app`.
  - `https://api.jehpok.com`:
    - `handle /ai*` → reverse-proxy `ai:8000`.
    - `handle /status` → reverse-proxy `ai:8000`.
    - `handle /download/*` → static fileserver from `/srv/content/web/api/download`.
  - `https://vps.jehpok.com` → static fileserver from `/srv/content/web/vps`.

### tailnet (CoreDNS)

The `tailnet` service is defined alongside `web` in `config/web/docker-compose.yml` and uses `config/web/Corefile` for its zone data:

- On a query for `vps.jehpok.com`, CoreDNS returns the Tailscale IP from the embedded hosts file.
- `fallthrough` means "if the host isn't in my hosts file, hand the query to the next plugin."
- `forward . 1.1.1.1` then forwards anything else to Cloudflare's public DNS.
- `log` keeps a per-query log for debugging.

### ai (llama-cpp FastAPI)

`config/ai/docker-compose.yml` defines the `ai` service. Key points:

- Builds from `config/ai/Dockerfile`, with the build context at the repo root. That gives `COPY ../../content/ai/app.py .` access to the live `content/ai/app.py` without duplicating source into the Dockerfile's directory.
- Attaches to the same external `net` network so Caddy can resolve `ai` to its container IP.
- Reads the model from a read-only bind mount at `/models`. The model itself lives on the host at `/var/www/github/jehpok.com/llm/`.
- Exposes port 8000 only inside the docker network (`expose`, not `ports`), so the LLM is not directly reachable from outside the VPS — only via Caddy.

`config/ai/Dockerfile` does two layered installs — base requirements first, then `llama-cpp-python` from the project's pre-built CPU wheels — so the heavy wheel isn't refetched unless `requirements.txt` changes.

## Docker network plumbing

A single user-defined bridge network named `net`:

```
docker network create net
```

Both compose files reference it as `external: true`. Without that, each compose would create its own private network and `web` would not be able to resolve `ai`.

Docker's embedded DNS at `127.0.0.11` resolves container names on this network. So Caddy's `reverse_proxy ai:8000` resolves to `ai`'s container IP via this DNS — no explicit IP needed.

## Tailscale + DNS behavior in detail

### Without Tailscale (any device)

- `www`, `app`, `api` resolve to Cloudflare IPs, then to the VPS via Cloudflare's proxy.
- `vps.jehpok.com` doesn't resolve at all — there's no public DNS record for it.

### With Tailscale + `tailnet` container up

- Tailscale's MagicDNS knows `vps.jehpok.com` only by the global DNS state. By default it asks public resolvers, which don't have the record. To make the split DNS behave correctly, Tailscale's admin console has a "DNS" setting that forwards queries for `*.jehpok.com` to a custom resolver. That resolver is the VPS's CoreDNS container (`100.x.x.x:53` on the tailnet).
- The CoreDNS `hosts` block then returns `100.81.245.77` for `vps.jehpok.com`. The connection goes device → Tailnet → VPS on its tailnet IP.

### With Tailscale + `tailnet` container down

- Tailscale's split DNS now forwards to an unresponsive resolver.
- The client surfaces this as `dns_forward_failing` errors.
- Every `jehpok.com` query fails because Tailscale is treating `*.jehpok.com` as "ask the split-DNS server." Even `www.jehpok.com` (which would normally fall through to public DNS) is held hostage because the resolver never returns NXDOMAIN, it just times out.
- Fix: keep the `tailnet` container running. `restart: unless-stopped` already handles crashes; the only way to take it down is a deliberate `docker stop` while editing it.

## End-to-end request examples

### Browser hits `https://api.jehpok.com/ai`

1. Browser resolves `api.jehpok.com` via the system resolver → Cloudflare IP.
2. TLS handshake terminates at Cloudflare. Cloudflare opens a second TLS connection to the origin (VPS :443), presenting the Origin Certificate.
3. Caddy's `web` container accepts the connection, matches the `https://api.jehpok.com` host block.
4. The `handle /ai*` block proxies to `ai:8000`. Docker's embedded DNS resolves `ai` on the `net` bridge.
5. FastAPI accepts the JSON body, runs inference via llama.cpp, returns a plain-text answer.
6. Caddy adds `text/plain` content type and the response travels back through Cloudflare to the browser.

If Cloudflare's bot challenge is active on the API hostname, a curl request will get the JS challenge page rather than the LLM response. That's expected; the API is being hit from a non-browser client. Mitigation lives in Cloudflare's WAF, not in this repo.

### Browser hits `https://api.jehpok.com/download/setup.sh`

1. Cloudflare → Caddy → `handle /download/*` → `file_server` rooted at `/srv/content/web/api/download`.
2. Caddy serves whatever file matches the URL path. Listing is disabled by default; missing files return 404.

### Tailscale device hits `https://vps.jehpok.com`

1. Tailscale split DNS routes the query to the VPS tailnet IP, port 53 — the `tailnet` CoreDNS container.
2. CoreDNS returns `100.81.245.77`.
3. The browser connects to `100.81.245.77:443`. Caddy accepts, matches `https://vps.jehpok.com`, serves static files from `/srv/content/web/vps`.

### curl on the local Mac hits `https://api.jehpok.com/ai`

```bash
curl -s -X POST https://api.jehpok.com/ai \
  -H "Content-Type: application/json" \
  -d '{"prompt":"hello","max_tokens":128}'
```

Same path as the browser, but Cloudflare's Browser Integrity Check / Bot Fight Mode may show a JS challenge page. Either use a real User-Agent header, solve the challenge once with a cookie jar, or add a service-auth token via Cloudflare Access.

## Deployment

On the VPS:

```bash
# One-time
docker network create net
mkdir -p /var/www/github/jehpok.com/{llm,certs}
# Drop Cloudflare Origin cert + key at:
#   /var/www/github/jehpok.com/certs/cert.pem
#   /var/www/github/jehpok.com/certs/key.pem
# Clone the repo to:
git clone <repo-url> /var/www/github/jehpok.com/repo

# Pull / start services
docker compose -f /var/www/github/jehpok.com/repo/config/web/docker-compose.yml up -d --force-recreate
docker compose -f /var/www/github/jehpok.com/repo/config/ai/docker-compose.yml up -d --build
```

`--force-recreate` on the web compose is intentional: because both `web` and `tailnet` live in the same file, this guarantees a fresh container spec on each deploy.

After changing the Caddyfile or Corefile:

```bash
docker compose -f /var/www/github/jehpok.com/repo/config/web/docker-compose.yml restart web
```

After changing `app.py` or the AI Dockerfile:

```bash
docker compose -f /var/www/github/jehpok.com/repo/config/ai/docker-compose.yml up -d --build
```

## Operational notes and gotchas

- `vps.jehpok.com` will appear "down" from non-Tailscale networks. That's by design. Don't add it to Cloudflare DNS to "fix" it — that defeats the only access control.
- The `api.jehpok.com/download/*` route is public. Anything dropped into `content/web/api/download/` is downloadable by anyone. Use `vps.jehpok.com` for private files (Tailscale only).
- The `tailnet` container is the SPOF for VPN-side DNS. Two ways to harden it: (a) add a second CoreDNS instance pointed to the same Corefile, both on `net`; (b) move DNS onto the host namespace (systemd-resolved or dnsmasq) so it's independent of Docker restarts.
- llama.cpp loads the entire GGUF into RAM at startup. The 1.5B Q4_K_M model is ~1.1 GB; the container must have at least that much headroom.
- Cloudflare's free tier rate-limits you at 10s min window for rate-limit rules. Plan ahead if the LLM endpoint ends up attracting more traffic than expected.
