# Migration (new VPS, new domain) — script-first

The primary path is `scripts/install.sh` — a plug-and-play installer. It prompts for three values (domain, Cloudflare API token, Tailscale auth key), then runs unattended. It creates the `op` user, installs host services (docker, tailscale, dnsmasq, ttyd, ssh hardening, ufw, sysctl), clones the repo (which already carries the canonical `<domain>` naming — no renames are applied), and brings up the full stack: Caddy (`$DOMAIN`), Nextcloud (app + PostgreSQL + Redis + Talk HPB/TURN), Vaultwarden, Uptime Kuma, PufferPanel, and Docker Mailserver + Roundcube. It also creates the Cloudflare A records (`cloud`/`vault`/`kuma`/`www` proxied, `turn`/`mail`/`mc` DNS-only), sets the zone SSL mode to full, triggers Let's Encrypt issuance, seeds Uptime Kuma, creates the Kuma + PufferPanel admin users automatically (passwords written to `kuma/admin-pass.txt` and `puffer/admin-pass.txt`), deploys the PufferPanel server templates, wires Nextcloud's Talk/SMTP/background-cron via `occ` (incl. `mail_smtpauth` so mail actually authenticates, trusted_proxies as an array, repair + DB indices so the setup check is clean, the updater-backup dir so the cleanup job stops warning, and the recovery manifests — users/groups/quotas/apps — from `make nc-capture`), publishes the mailserver's **DKIM TXT record via the Cloudflare API**, and opens the shared Minecraft port (UFW 25565 — both game servers bind it, one runs at a time). **Fully autonomous**: no manual confirmation steps block success — the only follow-ups are printed in the summary (Tailscale split-DNS, mailboxes, and the provider-side PTR record for external mail delivery).

## Run it

```
scp scripts/install.sh root@<new-vps>:
ssh root@<new-vps>
bash install.sh
```

Enter the domain, CF token, and TS auth key when prompted. The script hands off to user `op` and runs unattended; full log at `/var/log/homelab-install.log`. Errors are printed numbered at the end, then a success summary with credentials.

## What the script renames (nothing)

The installer's legacy `renames()` step — which transformed a pre-migration clone (`homelab.com` → `$DOMAIN`, `services/vhosts` → `services/$DOMAIN`, `debian` → `op`, trimming to 4 containers) — was removed 2026-08-31. The canonical repo already carries the final naming (fxmq.net / `op` / `shell.`), and `install.sh` deploys it as-is.

## Prerequisites (manual, unavoidable)

- Cloudflare zone `$DOMAIN` exists (checked up front — the script exits with a clear message if not); API token with `Zone > DNS > Edit` for that zone.
- Tailscale auth key (admin console → Settings → Keys).
- New VPS SSH key on GitHub — the script generates one and prints the pubkey; add it and re-run (state is saved, prompts are skipped).

## After the script finishes

1. Tailscale split-DNS (`$DOMAIN` → the new VPS Tailscale IP) is printed as a follow-up, not a blocking step — it cannot be set with just an auth key. Add it in the admin console so `tail.$DOMAIN` resolves for tailnet devices (dnsmasq on the VPS already answers it).
2. Optional: Cloudflare WAF rule skip for `cloud.$DOMAIN` — Nextcloud desktop sync is bot-challenged otherwise (rationale in `docs/GUIDE.md`).
3. Mailboxes are not scripted — create them with `make mail-gen [MAIL=…]` (or `mail-gen-alias TO=…` for a forwarder). The app SMTP sender mailboxes used for outbound mail are created automatically by the installer: `nextcloud@$DOMAIN` and `vaultwarden@$DOMAIN`.
4. Doc pass: done for the Aug 2026 migration — the canonical repo now carries the `fxmq.net` / `op` / `shell.` names in code, docs, and Makefile.

## Minecraft server (PufferPanel)

`install.sh` brings up the panel container itself (PufferPanel at `mc.$DOMAIN/panel`), creates its admin user automatically (password written to `puffer/admin-pass.txt`, same DB-insert pattern as GUIDE's admin-recovery), and drops both server templates into `puffer/data/servers/` (`07fd7727.json` browser-MC playground + `2ecfbe8c.json` the protected game server) — the daemon picks them up at boot. The game data dirs themselves stay operator-managed (no sleep/wake stack — lazymc and mc-idle-sleeper were removed 2026-08-28). To carry the servers to a new VPS:

1. The repo carries everything reproducible: the server templates `config/pufferpanel/servers/{2ecfbe8c,07fd7727}.json` and the UFW ports (already in `install.sh` — `25565/tcp` is shared by both servers; one runs at a time by design). After the base install, register the file-dropped servers in the panel DB (see `docs/GUIDE.md` "Registering a file-dropped server") so they're visible in the web UI, then start the protected server once from the panel UI so the daemon creates its container.
2. Operator-only (not in repo, copy from the old host): the game data dirs `puffer/data/servers/2ecfbe8c/` (world, jars, plugin jars, Geyser cache/locales) and `puffer/data/servers/07fd7727/` (the hand-placed `server.jar` — the paperdl build 1205 ships a broken old paperclip, see `docs/GUIDE.md` — plus plugins EaglerXServer/SkinsRestorer/Via family/Chunky, configs, worlds).
3. Gotchas that must hold on the new host: the panel template writes `server.properties` at install from its `ip`/`port` data fields (both templates bind `server-port=25565` — the servers share the port and must not run simultaneously); RCON disabled; the game domain's CF A record is DNS-only.

## Self-hosted mail (Docker Mailserver + Roundcube)

`install.sh` brings up the mail platform too (`make dok-recreate-mailserver` → `mailserver` at 172.22.0.9 + `roundcube` at 172.22.0.10; the UFW ports are opened by the installer). What is NOT scripted: mailbox accounts (create with `make mail-gen [MAIL=…]`). To carry existing mail to a new VPS:

1. Operator-only (copy from the old host): `/var/www/custom/projects/homelab/mailserver/` (Maildirs, DMS config + DKIM keys, roundcube sqlite), `services/mailserver/.env` (mailbox passwords), and the CF DNS records (MX, mail A DNS-only, SPF, DMARC, DKIM TXT).
2. Re-issue the mail.fxmq.net LE cert via the Caddy vhost; DMS reads it from caddy_data.

## Manual fallback

If the script can't be used, it automates exactly: host packages + `op` user + sshd hardening + docker daemon.json + `tailscale up` + ufw + repo clone + `docker network create net --subnet=172.22.0.0/16` + `make install-config` + `make dok-recreate-$DOMAIN|dok-recreate-nextcloud-db|dok-recreate-nextcloud|dok-recreate-vaultwarden|dok-recreate-uptimekuma|dok-recreate-pufferpanel|dok-recreate-mailserver` + CF DNS records + cert triggers. Optional data restore: `rsync` `cloud/users`, `vault/data`, `kuma/data` from the old host before first start (then `chown -R 33:33 cloud/users` and touch `cloud/users/.ncdata`).
