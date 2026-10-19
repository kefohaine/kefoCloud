# Migration (new machine, new domain)

`make migrate` prints this runbook. The primary path is the installer: a **root-only**,
prompt-once-unattended script. For the full prompt order and the run's behaviour see
`docs/GUIDE.md` "First-time setup and migration"; this file is the migration procedure.

## Run it

```bash
scp scripts/install/wizard.sh root@<new-machine>:
ssh root@<new-machine>
bash wizard.sh
```

Every input is collected before any work and persisted to `data/wizard.state` as it is
given, so an interrupted run resumes instead of re-asking. Then the run is unattended:
host services (docker, tailscale, dnsmasq, ttyd, goose, fail2ban, ufw, sysctl), the full
stack from `config/modules.conf` (Nextcloud app + PostgreSQL + Redis + Talk HPB/TURN,
Caddy, Vaultwarden, Uptime Kuma, Mailu + Roundcube), the Cloudflare A/MX/SPF/DKIM/DMARC
records, the certificates, and the module setup steps (`occ` wiring, Mailu mailboxes,
Kuma seed). The run ends with `write_state` (`finished=true`) → one `make smoke`, whose
exit code is the verdict; a failure records `finished=false`. Log: `$DATA_DIR/logs/wizard.log`.

Re-running the installer on a finished install offers **repair** after a yes/no
confirmation (idempotent, add-only, never removes anything; answer `no` and it exits
without touching the box). To rebuild from scratch, run `scripts/install/uninstall.sh`
first, then the installer again.

## What the script does not do

- **Tailscale split DNS** — add `$DOMAIN` → this node's `100.x` in the admin console (the
  host's dnsmasq already answers `tail.$DOMAIN`). Printed as a follow-up.
- **Mailboxes** — create them with `make mail-gen [MAIL=…]` / `make mail-gen-alias TO=…`.
  The installer creates only the app sender addresses (`nextcloud@`, `vaultwarden@`).
- **Provider-side PTR** — only the machine provider can set reverse DNS. Printed as
  follow-up 1 when the mail module is on.
- **Cloudflare WAF rule skip for `cloud.$DOMAIN`** — optional; desktop/mobile sync is
  bot-challenged otherwise (rationale in `docs/GUIDE.md`).

## Prerequisites (manual, unavoidable)

- Cloudflare zone `$DOMAIN` exists (checked up front; the installer fails fast if not) and
  an API token with `Zone > DNS > Edit` for it.
- Tailscale auth key.
- The device's public SSH key (ssh hardening is applied in the same run).
- Nothing GitHub-side to type: the repo is public and cloned over HTTPS; the optional
  collaborator step mints `/root/.ssh/github_key` and switches `origin` to SSH only once
  GitHub accepts the key.

## Carrying existing data to a new machine

1. `make backup TAILDROP=<device>` on the old host — ships `nextcloud-backup-*.tar.gz`
   (PostgreSQL DB + datadir) and `other-backup-*.tar.gz` (vault / mailserver / kuma
   datadirs) to a tailnet device.
2. Install on the new machine, then `make import-backups TAILDROP=<device>` — it previews
   the bundles and requires a typed `yes`.
3. Copy `modules/*/.env` (gitignored secrets) from the old checkout, then `make render`
   and recreate the affected units.
4. Mail: the bundles carry `mailserver/mail`, `mailserver/data`, `mailserver/dkim` and
   `mailserver/roundcube`; re-publish the DKIM TXT from the carried keys (the installer's
   `dkim_setup` reads Mailu's own public key) and keep the domain's MX/SPF/DMARC records.
5. Data-only restore is safe; the database stays on the main machine unless
   `make nc-datadir-nfs` moved the datadirectory (the DB never moves with it).

## Manual fallback

If the script cannot be used, it automates exactly: host packages + `root` login +
sshd hardening + `/etc/docker/daemon.json` + `tailscale up` + ufw + dnsmasq + the repo
clone + `docker network create net --subnet=172.22.0.0/16` + `make install-config`, then
the Nextcloud DB and app in ONE invocation (`docker compose -f
modules/nextcloud/docker-compose.db.yml -f modules/nextcloud/docker-compose.yml up -d
--force-recreate --remove-orphans` — running either file alone orphans and deletes the
other's containers), then `make dok-recreate-caddy`, `make dok-recreate-vaultwarden`,
`make dok-recreate-uptimekuma`, `make dok-recreate-mailserver`, the CF records, the
certificates and `make smoke`.
