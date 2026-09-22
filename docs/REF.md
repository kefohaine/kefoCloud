# REF.md — per-setup reference (source of the docs' variables)

The docs reference this demo's values as variables (`$DOMAIN`, `$PROJECT_DIR`, …)
instead of hardcoding them. This file is the source of truth: **edit it for your
own setup** — docs stay neutral and portable.

## Variables

```bash
DOMAIN='fxmq.net'                                   # demo domain (Cloudflare zone)
GITHUB_USER='kefohaine'
GITHUB_REPO="$GITHUB_USER/kefoserver"               # upstream repo (public, HTTPS clone)
REPO_DIR='/root/github/kefoserver'                  # this repo's checkout (make REPO)
DATA_DIR="$REPO_DIR/data"                           # all external/untracked state
OPERATOR_USER='root'                                # only entry point: root@kefoserver
HOSTNAME='server'                                   # local machine name (tailnet name: kefoserver)
MAIL_IDENT="vaultwarden@$DOMAIN"                    # SMTP sender mailbox (Vaultwarden)
WWW_WELCOME="https://www.$DOMAIN/welcome"           # the welcome page
VHOST_PROXIED='cloud vault kuma www'                # Cloudflare orange-cloud records
VHOST_DNSONLY='mail mc talk'                        # Cloudflare grey-cloud records
TAILNET_SUBNET='100.117.144.0/24'                   # tailnet CIDR
STORAGE_HOST='root@<storage-box>'                   # second Debian system (sshpass)
```

## Notes

- `docs/` prose and commands use these names as placeholders; substitute per setup.
- Live values (public IP, container names, tailnet peers) are still **auto-detected**
  by scripts — never read from this file.
- `$DATA_DIR/installed-modules.conf` (written by `scripts/install.sh`) records
  which modules this deployment *declared*; `installed-modules.detected.conf` +
  `installed-modules.report.txt` are the independent-probe confirmation
  (containers / compose / on-disk data / vhost). `make smoke` + `make fetch`
  read the declared file.
- Secrets never belong here nor in `scripts/defaults/` (AGENTS rule 9).
- `scripts/defaults/*.conf` hold *prompt defaults* — a different purpose than this
  file (see ISSUES Planned ideas for the split rationale).
- `docs/ISSUES.md` deliberately keeps concrete demo values: it is the tracker plus
  solved history, not a portability doc.
