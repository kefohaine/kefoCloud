# kefohaine/server

One repo that turns any Debian system into your own self-hosted server stack — cloud, mail, game servers and more — with one command and a few prompts.

**[www.fxmq.net](https://www.fxmq.net/welcome) is the live demo**: eight modules running on one box, built entirely from this repo. Fork it, run the installer, and the same board is yours — under your own domain, with no server but yours.

## Why

The point of the repo is that none of those doors needs a rented product: your files instead of Google/Dropbox, your mail instead of Gmail, your vault instead of a hosted password manager, your calls instead of Zoom.
You become the admin — which is the honest price of owning the server.

The upsides:
- High efficiency & density
- Maximum privacy & ownership
- Streamlined Automation
- Modular Setup

Perfect either for homelab hobbyists looking for a great learning tool to experiment with, or for critical production stacks overseen by advanced developers.
I emphasise on the quality of the framework's configuration, which comes close to entreprise-grade stacks while staying surprisingly lightweight and easy to setup.
This comes from daily use of this project as my personal stack, so put all my heart to deliver the most secure, healthy and functional framework.
Minimum RAM required: 3GB

## Install

```bash
git clone https://github.com/kefohaine/server && cd server
bash install.sh
```

The installer asks a few questions, then hardens the host, creates the DNS records, issues certificates and builds the selected stack unattended. Default is everything ON; opt out per module for a lean install.

### Modules (pick at install time)

| module | runs | notes |
|---|---|---|
| **Cloud** | Nextcloud | files, calendar, contacts, photos, Talk chat & video calls |
| **Mail** | Docker Mailserver + Roundcube | SMTP/IMAPS, DKIM/SPF/DMARC on your own domain |
| **Games** | PufferPanel + Paper/Minecraft | in-browser play (`/play`), Java server on `:25565` |
| **Vault** | Vaultwarden | any Bitwarden client, server included |
| **Monitor** | Uptime Kuma | watches public *and* tailnet-only doors |

### Secondary helpers

- `bash scripts/optimize.sh` — automated performance optimization after install
- `bash scripts/storage.sh` — automated external Nextcloud storage system over tailnet

## Documentation

- `docs/REF.md` — per-setup source of truth: adapt variables to yours in it
- `docs/GUIDE.md` — the operator manual: layout, recipes, per-service facts, gotchas
- `docs/AGENTS.md` — agent operating rules (how this repo is worked on)
- `docs/ISSUES.md` — open problems, planned ideas, and resolved history
- `scripts/defaults/` — per-script prompt defaults

## Risks & Considerations
- Single Point of Failure: Running your cloud, your passwords, your email, and a game server on one operating system means that if the host crashes, goes offline, or gets compromised, your entire digital footprint goes dark simultaneously.
- The "Mail Server" Headache: Operating a self-hosted mail server is notoriously difficult. Even if the project configures your DKIM and SPF records perfectly, large providers like Gmail, Yahoo, and Outlook frequently block or flag IP addresses originating from residential connections or cheap cloud VPS networks (like DigitalOcean or Linode).
- Maintenance: If anything breaks when you install as intended, report it here as an issue; Please don't open an issue if it was caused from manual tweaks on your end.
