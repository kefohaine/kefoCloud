# kefohaine/server

One repo that turns any Debian system (VPS, mini-PC, homelab box) into your own
stack — cloud, mail, game servers and more — with one command and a few prompts.

**[fxmq.net](https://www.fxmq.net/welcome) is the live demo**: eight doors
running on one box, built entirely from this repo. Fork it, run the installer,
and the same board is yours — under your own domain, with no server but yours.

## Install

```bash
git clone https://github.com/kefohaine/server && cd server
bash install.sh
```

The installer asks a few questions (domain, Cloudflare API token, Tailscale key,
and which modules to include — defaults in `scripts/defaults/install.conf`). It
then hardens the host, creates the DNS records, issues certificates and builds
the selected stack unattended. Default is everything ON; opt out per module for
a lean install.

### Modules (pick at install time)

| module | runs | notes |
|---|---|---|
| **Cloud** | Nextcloud | files, calendar, contacts, photos, Talk chat & video calls |
| **Mail** | Docker Mailserver + Roundcube | SMTP/IMAPS, DKIM/SPF/DMARC on your own domain |
| **Games** | PufferPanel + Paper/Minecraft | in-browser play (`/play`), Java server on `:25565` |
| **Vault** | Vaultwarden | any Bitwarden client, server included |
| **Monitor** | Uptime Kuma | watches public *and* tailnet-only doors |

### Secondary helpers

- `bash scripts/optimize.sh` — optional tuning after install (kernel/memory/network, swap, cleanup)
- `bash scripts/storage.sh` — optional second box as live Nextcloud storage over the tailnet
- `make perf` — one-shot live system performance + status overview (no arguments)
- `make taildrop-file FILE=…` / `make taildrop-folder DIR=…` — send a file/folder to a tailnet device

## Documentation

- `REF.md` — the demo's public terms (domain, hosts, naming); adapt your own setup from here
- `docs/GUIDE.md` — the operator manual: layout, recipes, per-service facts, gotchas
- `docs/AGENTS.md` — agent operating rules (how this repo is worked on)
- `docs/ISSUES.md` — open problems, planned ideas, and resolved history
- `scripts/defaults/` — per-script prompt defaults

## Why

fxmq.net is only a showcase. The point of the repo is that none of those doors
needs a rented product: your files instead of Google/Dropbox, your mail instead
of Gmail, your vault instead of a hosted password manager, your calls instead of
Zoom. You become the admin — that is the honest price of owning the server.
