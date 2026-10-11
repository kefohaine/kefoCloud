# kefoCloud

One repo that turns any Debian system into your own self-hosted server stack — cloud, mail, monitoring and more — with one command and a few prompts.

**[www.fxmq.net](https://www.fxmq.net/welcome) is the live demo**: the installed modules running on one box, built entirely from this repo. Fork it, run the installer, and the same board is yours — under your own domain, with no server but yours.

## Install

```bash
git clone https://github.com/kefohaine/kefoServer.git && cd kefoServer
bash scripts/install/install.sh
```

`scripts/install/uninstall.sh` reverses it in the same style — every prompt defaults to keep, operator data and the tailscale-only SSH path are never touched without an explicit confirm, and the tailnet membership goes last.

### Modules

| name | app | note |
|---|---|---|
| **Cloud** | Nextcloud | app choices in `config/cloud/apps.conf` |
| **Mail** | Docker Mailserver + Roundcube | SMTP/IMAPS, DKIM/SPF/DMARC on your own domain |
| **Vault** | Vaultwarden | any Bitwarden client, server included |
| **Monitor** | Uptime Kuma | watches public *and* tailnet-only doors |

### Tips

- `bash scripts/ops/optimize.sh` — automated performance optimization after install; useful for resource management
- `make nc-datadir-nfs` — make an external machine the PERMANENT live Nextcloud datadir host over the tailnet; the database stays on this machine; useful for bulky external storage
- `make backup TAILDROP=<device>` ships all modules as two sha256-verified bundles to a Tailscale device; restore with `make import-backups`; useful for safety & migration

## Documentation

- `docs/SKELETON.md` — the skeleton: placeholder tokens, values and rendering
- `docs/GUIDE.md` — the operator manual: layout, recipes, per-service facts, gotchas
- `docs/AGENTS.md` — agent operating rules
- `docs/ISSUES.md` — open problems, planned ideas, and resolved history
- `docs/DEBUG.md` — deep-scan diagnostics runbook

## Risks & Considerations
- System Requirements: minimum RAM is 4GB; minimum storage is 15GB; kefohaine recommends double the minimum for both specifications to avoid bottleneck.
- Single Point of Failure: Running your cloud, your passwords, your email and your monitoring on one operating system means that if the host crashes, goes offline, or gets compromised, your entire digital footprint goes dark simultaneously. If anything breaks when you install as intended, report it here as an issue; Please don't open an issue if it was caused from manual tweaks on your end.
- The Mail Server Headache: Operating a self-hosted mail server is notoriously difficult. Even if the project configures your DKIM and SPF records perfectly, large providers like Gmail, Yahoo, and Outlook frequently block or flag IP addresses originating from residential connections or cheap cloud host networks.
