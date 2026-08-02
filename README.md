# jehpok.com

Self-hosted infrastructure on a Debian VPS behind Docker and Caddy.

## Domains

| Domain             | Access    | Served by                       |
|--------------------|-----------|---------------------------------|
| www.jehpok.com     | Public    | Caddy → static (`/srv/containers/web/www`) |
| app.jehpok.com     | Public    | Caddy → static (`/srv/containers/web/app`) |
| api.jehpok.com     | Public    | Caddy → ai container (llama-cpp) + static downloads |
| vps.jehpok.com     | Tailscale | Caddy → static (`/srv/containers/web/vps`) |

Cloudflare proxies public domains; `vps.jehpok.com` is not registered in Cloudflare DNS and is resolved only inside the Tailscale network.

## Repository layout

```
config/
  web/
    Caddyfile           # Caddy vhost + reverse-proxy rules
    Corefile            # CoreDNS hosts + forwarders
    docker-compose.yml  # Caddy + CoreDNS ("tailscale") services
  ai/
    docker-compose.yml  # llama-cpp FastAPI service (name: ai)
containers/
  ai/
    Dockerfile          # python:3.12-slim + llama-cpp-python
    app.py              # FastAPI: POST /ai, GET /status
    requirements.txt
```

## Services

### web (Caddy 2)
- Listens on host ports 80/443.
- TLS terminated with a Cloudflare Origin Certificate at `/var/www/github/jehpok.com/certs/`.
- Volume-mounts the repo read-only at `/srv`.
- Routes:
  - `/ai*` and `/status` → reverse-proxy to `ai:8000` (docker network `net`).
  - `/download/*` → file server rooted at `/srv/containers/web/download`.
  - `www/`, `app/`, `vps/` → static file servers.
- Restart: `unless-stopped`.

### tailscale (CoreDNS)
- Container name `tailscale`, image `coredns/coredns:latest`.
- Binds host UDP/TCP 53.
- Corefile resolves `vps.jehpok.com` to the Tailscale IP `100.81.245.77` and forwards everything else to `1.1.1.1`.
- Required so that Tailscale clients on the VPN can resolve `vps.jehpok.com` to its Tailscale-only IP.
- Restart: `unless-stopped`.

### ai (llama-cpp FastAPI)
- Built from `containers/ai/Dockerfile` (context `../../containers/ai`).
- Container name `ai`, joined to docker network `net`.
- Env: `MODEL_PATH=/models/qwen2.5-1.5b-instruct-q4_k_m.gguf`.
- Volumes: `/var/www/github/jehpok.com/llm:/models:ro`.
- Endpoints:
  - `POST /ai` body `{ "prompt": str, "max_tokens": int=64 }` → plain-text completion.
  - `GET /status` → plain-text `online`.
- llama.cpp context: `n_ctx=2048`, `n_threads=2`.

## Docker network

Single external network `net`. `web` and `ai` attach to it so Caddy can resolve the `ai` container name. `tailscale` attaches only to expose DNS; nothing else depends on it internally.

## Tailscale + DNS behavior

- Normal (non-Tailscale) IP: all public domains resolve via Cloudflare; `vps.jehpok.com` does not resolve.
- Tailscale network, `tailscale` container running: `vps.jehpok.com` resolves to the Tailscale IP via CoreDNS.
- Tailscale network, `tailscale` container down: Tailscale DNS forwarding fails (`dns_forward_failing`) and all DNS resolution over the VPN breaks. Keep this container up at all times.

## Operational notes

- Host firewall must allow inbound 80/443 for public traffic and the Tailscale UDP range for VPN clients.
- Restart order does not matter; all services use `restart: unless-stopped`.
- Models live under `/var/www/github/jehpok.com/llm/` on the VPS and are mounted read-only into the `ai` container.
- TLS material lives under `/var/www/github/jehpok.com/certs/` and is mounted read-only into the `web` container.
