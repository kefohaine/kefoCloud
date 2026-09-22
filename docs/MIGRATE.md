# Migration (new VPS, new domain) — script-first

The primary path is `scripts/install.sh` — a plug-and-play, **root-only** installer. It prompts for three values (domain, Cloudflare API token, Tailscale auth key), then runs unattended. `root@{{HOSTNAME}}` is the only entry point; no sudo user is created and there is no hand-off. It installs host services (docker, tailscale, dnsmasq, ttyd, ssh hardening, ufw, sysctl), clones the repo over **HTTPS** (public repo — no GitHub SSH key), and brings up the full stack: Caddy (`$DOMAIN`), Nextcloud (app + PostgreSQL + Redis + Talk HPB/TURN), Vaultwarden, Uptime Kuma and Docker Mailserver + Roundcube. It also creates the Cloudflare A records (`cloud`/`vault`/`kuma`/`www` proxied, `talk`/`mail` DNS-only), sets the zone SSL mode to full, triggers Let's Encrypt issuance, seeds Uptime Kuma, creates the Kuma admin user automatically (password printed once in the final summary), wires Nextcloud's Talk/SMTP/background-cron via `occ` (incl. `mail_smtpauth` so mail actually authenticates, trusted_proxies as an array, repair + DB indices so the setup check is clean, the updater-backup dir so the cleanup job stops warning, and the recovery manifests — users/groups/quotas/apps — from `make nc-capture`), publishes the mailserver's **DKIM TXT record via the Cloudflare API**, **Fully autonomous**: no manual confirmation steps block success — the only follow-ups are printed in the summary (Tailscale split-DNS, mailboxes, and the provider-side PTR record for external mail delivery).

## Run it

```
scp scripts/install.sh root@<new-vps>:
ssh root@<new-vps>
bash install.sh
```

Enter the domain, CF token, and TS auth key when prompted. The script runs unattended as root; full log at `/var/log/{{HOSTNAME}}-install.log`. Errors are printed numbered at the end, then a success summary with credentials.

## What the script renames (nothing)

The installer's legacy `renames()` step — which transformed a pre-migration clone (`homelab.com` → `$DOMAIN`, `services/vhosts` → `services/$DOMAIN`, `debian` → `root`, trimming to 4 containers) — was removed 2026-08-31. The canonical repo already carries the final naming ($DOMAIN / `root` / `tail.`), and `install.sh` deploys it as-is.

## Prerequisites (manual, unavoidable)

- Cloudflare zone `$DOMAIN` exists (checked up front — the script exits with a clear message if not); API token with `Zone > DNS > Edit` for that zone.
- Tailscale auth key (admin console → Settings → Keys).
- Nothing GitHub-side: the repo is public and cloned over HTTPS (state is saved, so prompts are skipped on re-runs).

## After the script finishes

1. Tailscale split-DNS (`$DOMAIN` → the new VPS Tailscale IP) is printed as a follow-up, not a blocking step — it cannot be set with just an auth key. Add it in the admin console so `tail.$DOMAIN` resolves for tailnet devices (dnsmasq on the VPS already answers it).
2. Optional: Cloudflare WAF rule skip for `cloud.$DOMAIN` — Nextcloud desktop sync is bot-challenged otherwise (rationale in `docs/GUIDE.md`).
3. Mailboxes are not scripted — create them with `make mail-gen [MAIL=…]` (or `mail-gen-alias TO=…` for a forwarder). The app SMTP sender mailboxes used for outbound mail are created automatically by the installer: `nextcloud@$DOMAIN` and `vaultwarden@$DOMAIN`.
4. Doc pass: done for the Aug 2026 migration — the canonical repo now carries the `$DOMAIN` / `root` / `tail.` names in code, docs, and Makefile.

## Minecraft server (PufferPanel) — moved out

The `games` module (PufferPanel + the browser Minecraft client) is no longer
part of this repo. It lives at `git@github.com:{{GITHUB_USER}}/kefoMC.git` and
installs itself against this edge (`make install` there). The base install
below therefore no longer brings up a panel, deploys no server templates and
opens no Minecraft port; `docs/GOTCHAS.md` in that repo carries the
server-side knowledge.
## Self-hosted mail (Docker Mailserver + Roundcube)

`install.sh` brings up the mail platform too (`make dok-recreate-mailserver` → `mailserver` at 172.22.0.9 + `roundcube` at 172.22.0.10; the UFW ports are opened by the installer). What is NOT scripted: mailbox accounts (create with `make mail-gen [MAIL=…]`). To carry existing mail to a new VPS:

1. Operator-only (copy from the old host): `$DATA_DIR/mailserver/` (Maildirs, DMS config + DKIM keys, roundcube sqlite), `services/mailserver/.env` (mailbox passwords), and the CF DNS records (MX, mail A DNS-only, SPF, DMARC, DKIM TXT).
2. Re-issue the mail.$DOMAIN LE cert via the Caddy vhost; DMS reads it from caddy_data.

## Manual fallback

If the script can't be used, it automates exactly: host packages + `root` user + sshd hardening + docker daemon.json + `tailscale up` + ufw + repo clone + `docker network create net --subnet=172.22.0.0/16` + `make install-config` + `make dok-recreate-caddy|dok-recreate-nextcloud-db|dok-recreate-nextcloud|dok-recreate-vaultwarden|dok-recreate-uptimekuma|dok-recreate-mailserver` + CF DNS records + cert triggers. Optional data restore: `rsync` `cloud/users`, `vault/data`, `kuma/data` from the old host before first start (then `chown -R 33:33 cloud/users` and touch `cloud/users/.ncdata`).
