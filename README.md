# kefoServer

One repo that turns any Debian system into your own self-hosted server stack — cloud, mail, monitoring and more — with one command and a few prompts.

**[www.fxmq.net](https://www.fxmq.net/welcome) is the live demo**: the installed modules running on one box, built entirely from this repo. Fork it, run the installer, and the same board is yours — under your own domain, with no server but yours.

## Install

```bash
git clone https://github.com/kefohaine/kefoServer.git && cd kefoServer
bash scripts/install/install.sh
```

`scripts/install/uninstall.sh` reverses it in the same style — every prompt defaults to keep, operator data and the tailscale-only SSH path are never touched without an explicit confirm, and the tailnet membership goes last.

### Modules (pick at install time)

| module | runs | notes |
|---|---|---|
| **Cloud** | Nextcloud | files, calendar, contacts, photos, Talk chat & video calls |
| **Mail** | Docker Mailserver + Roundcube | SMTP/IMAPS, DKIM/SPF/DMARC on your own domain |
| **Vault** | Vaultwarden | any Bitwarden client, server included |
| **Monitor** | Uptime Kuma | watches public *and* tailnet-only doors |

### Secondary helpers

- `bash scripts/ops/optimize.sh` — automated performance optimization after install
- `make connect` — join a module to another server (link an existing database there, or overwrite it with this host's data)

## Documentation

- `docs/SKELETON.md` — the skeleton: tokens, values and rendering (what each placeholder means, where the real values live)
- `docs/GUIDE.md` — the operator manual: layout, recipes, per-service facts, gotchas
- `docs/AGENTS.md` — agent operating rules (how this repo is worked on)
- `docs/ISSUES.md` — open problems, planned ideas, and resolved history
- `docs/DEBUG.md` — deep-scan / debugging runbook (read-only first, layer ladder, verification probes)
- `scripts/install/` — `install.sh` (prompts every value, never a pre-filled default) and `uninstall.sh`

## Risks & Considerations
- System requirements: minimum RAM is 4GB; minimum storage is 15GB; i recommend double the minimum for both specs to avoid bottleneck.
- Single Point of Failure: Running your cloud, your passwords, your email and your monitoring on one operating system means that if the host crashes, goes offline, or gets compromised, your entire digital footprint goes dark simultaneously.
- The Mail Server Headache: Operating a self-hosted mail server is notoriously difficult. Even if the project configures your DKIM and SPF records perfectly, large providers like Gmail, Yahoo, and Outlook frequently block or flag IP addresses originating from residential connections or cheap cloud VPS networks.
- Maintenance: If anything breaks when you install as intended, report it here as an issue; Please don't open an issue if it was caused from manual tweaks on your end.
