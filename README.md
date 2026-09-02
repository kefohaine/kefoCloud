# fxmq.net — your own cloud, mail and game server on one box

A complete, working self-hosted homelab, shipped as infrastructure: one compose file per
service, a Makefile that wraps every operation, and an installer that turns a fresh Debian
VPS into the whole stack. This repo is the exact setup running at fxmq.net today - not a
template, not a tutorial. The real thing, committed.

## What you get

- **Nextcloud** - files, calendar, contacts, Talk (self-hosted TURN/STUN), Mail - on
  PostgreSQL + Redis, RAM-capped to a 3 GB ceiling
- **Mail** - Docker Mailserver + Roundcube: SMTP/IMAP, DKIM/SPF/DMARC, one-command
  disposable addresses
- **Vaultwarden** - Bitwarden-compatible password manager
- **Uptime Kuma** - uptime monitoring dashboard
- **PufferPanel + Minecraft** - a game panel, plus browser Minecraft that needs no
  install and no sign-up
- **Caddy edge** - one vhost file per subdomain, per-hostname Let's Encrypt certs via
  Cloudflare DNS-01
- **Tailscale** - private hostnames that exist only on your devices

## Why this repo

Everything is committed and documented. Services live one per directory under `services/`,
host configs under `config/`, the whole command surface in the `Makefile` (`make help`
lists it all). Pre-commit hooks refuse a Caddyfile that doesn't validate, and `make smoke`
tests the live edge before every push - the same checks that keep the production site up.

## Deploy

On a fresh Debian VPS, run `scripts/install.sh`. It asks for your domain, your Cloudflare
API token and a Tailscale auth key, then runs unattended: host setup, Docker, Tailscale,
all containers, DNS records, certificates and admin accounts. Day-to-day operations are
`make` recipes - no raw `docker compose` needed.

## Docs

- `docs/GUIDE.md` - the operator manual: layout, commands, architecture, gotchas
- `docs/AGENTS.md` - the rules an AI agent follows when working in this repo
- `docs/ISSUES.md` - open problems, tracked

Your data, your box, your rules. Fork it, run `install.sh`, and you own the stack.
