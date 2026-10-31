# kefoCloud

![Repository Title](.github/images/title.png)

One repo that turns any Debian system into your own self-hosted server stack — cloud, mail, monitoring and more — with one command and a few prompts.
Fork it, run the installer, and the same board is yours — under your own domain, with no server but yours.

## Install

```bash
git clone https://github.com/kefohaine/kefoCloud.git
cd kefoCloud && bash scripts/install/wizard.sh
```

Prompts once then runs unattended — errors are listed with a hint each and re-checked until resolved, and success is only granted when the smoke check passes

`scripts/install/uninstall.sh` reverses it in the same style — no prompt has a default (only `yes`/`no` are accepted), operator data and the tailscale-only SSH path are never touched without an explicit confirm, and the tailnet membership goes last. Removal is the operator's call, never the installer's.

### Modules

![Repository Banner](.github/images/modules.png)

Nextcloud (app + PostgreSQL + Redis + Talk HPB/TURN), Caddy, Vaultwarden, Uptime Kuma, the Mailu + Roundcube platform, a Homarr dashboard, WriteFreely and Immich photos — public doors behind Cloudflare, admin doors (Nextcloud, Vaultwarden, the Mailu platform, the shell) tailnet-only, with tailscale, ttyd, dnsmasq and goose as host services. A poster welcome page and per-app `make` commands for accounts and maintenance ship with it.

| name | app | note |
|---|---|---|
| **Cloud** | Nextcloud | its own `nextcloud.` vhost, tailnet-only; app choices in `config/cloud/apps.conf` (untracked, empty by default; `spreed`/`app_api` are enforced in code, never asked) |
| **Mail** | Mailu + Roundcube | SMTP/IMAPS, DKIM/SPF/DMARC on your own domain — public webmail, tailnet-only platform door |
| **Vault** | Vaultwarden | any Bitwarden client, server included — tailnet-only door |
| **Monitor** | Uptime Kuma | watches public *and* tailnet-only doors |
| **Home** | Homarr | the dashboard on its own `home.` vhost (the welcome page's Home link) |
| **Blog** | WriteFreely | its own `blog.` vhost, SQLite, pinned upstream release |
| **Photos** | Immich | DNS-only vhost, its own PostgreSQL + Redis |

### Tips

- `bash scripts/ops/optimize.sh` — automated performance optimization after install; useful for resource management
- `make nc-datadir-nfs` — make an external machine the PERMANENT live Nextcloud datadir host over the tailnet; the database stays on this machine; useful for bulky external storage
- `make backup TAILDROP=<device>` ships all modules to a Tailscale device as verified bundles (default) or raw datadirectories (`BACKUP_MODE=raw`); restore with `make import-backups`; useful for safety & migration

## Documentation

- `docs/SKELETON.md` — the skeleton: placeholder tokens, values and rendering
- `docs/GUIDE.md` — the operator manual: layout, recipes, per-service facts, gotchas
- `docs/AGENTS.md` — agent operating rules
- `docs/ISSUES.md` — frozen archive of resolved problems (open problems live in the Issues tab)
- `docs/DEBUG.md` — deep-scan diagnostics runbook
- `docs/MIGRATE.md` — moving the stack to a new machine

## Risks & Considerations
- System Requirements: minimum RAM is 4GB; minimum storage is 15GB; kefohaine recommends double the minimum for both specifications to avoid bottleneck.
- Single Point of Failure: Running your cloud, your passwords, your email and your monitoring on one operating system means that if the host crashes, goes offline, or gets compromised, your entire digital footprint goes dark simultaneously. If anything breaks when you install as intended, report it here as an issue; Please don't open an issue if it was caused from manual tweaks on your end.
- The Mail Server Headache: Operating a self-hosted mail server is notoriously difficult. Even if the project configures your DKIM and SPF records perfectly, large providers like Gmail, Yahoo, and Outlook frequently block or flag IP addresses originating from residential connections or cheap cloud host networks.
