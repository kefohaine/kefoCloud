# fxmq.net — one command, your own cloud, mail and game servers

A self-hosting kit that turns a single Debian VPS into a private stack of
**cloud, mail, passwords, monitoring and Minecraft** — behind one edge, one
domain, one Tailscale tailnet. Every service is a pre-made, plug-and-use
container: no setup beyond the answers you type into the installer. This is
the exact repo that runs [fxmq.net](https://www.fxmq.net) today.

## The whole thing is one command

```
bash install.sh
```

That's the only way in. `install.sh` asks for your domain, a Cloudflare API
token and a Tailscale auth key, then walks you through **which modules you
want** — include or skip each one — and builds the stack unattended: host
hardening, Docker, DNS records, Let's Encrypt certs and admin accounts.

## Modules — pick what you run

| module | what you get | door |
|---|---|---|
| **Cloud** | Nextcloud — files, calendar, contacts, Talk (self-hosted TURN), PostgreSQL + Redis | `cloud.` |
| **Mail** | Docker Mailserver + Roundcube — SMTP/IMAP, DKIM/SPF/DMARC | `mail.` |
| **Games** | Minecraft via PufferPanel — browser play included, no install, no sign-up | `mc.` |
| **Vault** | Vaultwarden — Bitwarden-compatible password manager | `vault.` |
| **Monitor** | Uptime Kuma — uptime dashboard for anything you run | `kuma.` |
| **Edge** | Caddy — one vhost file per subdomain, per-hostname certs via Cloudflare DNS-01 | `www.` |

Each module is a self-contained compose unit under `services/`, wired to its
own subdomain the moment you pick it. Nothing to configure afterwards.

## Secondary helpers

- **`scripts/optimize.sh`** — after the install, squeeze the box: kernel and
  memory tuning, swap, THP, noatime, fstrim, log caps and cleanup. One
  idempotent script, safe to re-run.
- **`scripts/storage.sh`** — add a cheap second VPS as live Nextcloud storage
  (NFS over the tailnet); the database stays on the main box, the files live
  elsewhere.

## Built the boring way

Everything is committed and documented — one compose file per service, a
`Makefile` wrapping every operation (`make help`), `make smoke` testing the
live edge before each push, and pre-commit hooks that refuse an invalid
Caddyfile. Fork it, run `install.sh`, and the stack is yours.

- `docs/GUIDE.md` — operator manual: layout, commands, architecture, gotchas
- `docs/ISSUES.md` — open problems, tracked
