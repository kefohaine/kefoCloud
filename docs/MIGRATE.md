# Migration (new VPS, new domain) — script-first

The primary path is `scripts/install.sh` — a plug-and-play installer. It prompts for three values (domain, Cloudflare API token, Tailscale auth key), then runs unattended. It creates the `op` user, installs host services (docker, tailscale, dnsmasq, ttyd, ssh hardening, ufw, sysctl), clones the repo (which already carries the canonical `<domain>` naming — no renames are applied), and brings up the full stack: Caddy (`$DOMAIN`), Nextcloud (app + PostgreSQL + Redis + Talk HPB/TURN), Vaultwarden, Uptime Kuma, PufferPanel, and Docker Mailserver + Roundcube. It also creates the Cloudflare A records (`cloud`/`vault`/`kuma`/`www` proxied, `turn`/`mail`/`mc` DNS-only), sets the zone SSL mode to full, triggers Let's Encrypt issuance, and seeds Uptime Kuma (admin account included).

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

- Cloudflare zone `$DOMAIN` exists; API token with `Zone > DNS > Edit` for that zone.
- Tailscale auth key (admin console → Settings → Keys).
- New VPS SSH key on GitHub — the script generates one and prints the pubkey; add it and re-run (state is saved, prompts are skipped).

## After the script finishes

1. The installer lists the Tailscale split-DNS entry (`$DOMAIN` → the new VPS Tailscale IP) as an **expected** manual step in its error/re-check loop — it cannot be set with just an auth key. Confirm it in the admin console and the loop clears it; without it `shell.$DOMAIN` won't resolve for tailnet devices.
2. Optional: Cloudflare WAF rule skip for `cloud.$DOMAIN` — Nextcloud desktop sync is bot-challenged otherwise (see `Intended` in `docs/ISSUES.md`).
3. Doc pass: done for the Aug 2026 migration — the canonical repo now carries the `fxmq.net` / `op` / `shell.` names in code, docs, and Makefile.

## Minecraft server (PufferPanel + Geyser)

`install.sh` brings up the panel container itself (PufferPanel at `mc.$DOMAIN/panel`; the first-run admin wizard is an **expected** manual step in its error loop). The game server, however, stays operator-managed (no sleep/wake stack — lazymc and mc-idle-sleeper were removed 2026-08-28). To carry it to a new VPS:

1. The repo carries everything reproducible: the server template `config/pufferpanel/servers/2ecfbe8c.json` and the UFW ports (already in `install.sh`). After the base install: create the panel server from the template JSON (copy into `puffer/data/servers/<id>.json`) and start the game once from the panel UI so the daemon creates the container.
2. Operator-only (not in repo, copy from the old host): the game server data dir `puffer/data/servers/2ecfbe8c/` (world, jars, plugin jars, Geyser cache/locales).
3. Gotchas that must hold on the new host: the panel template writes `server.properties` at install from its `ip`/`port` data fields (the live server currently binds `server-ip=0.0.0.0` / `server-port=25565`); RCON disabled; the game domain's CF A record is DNS-only.

## Self-hosted mail (Docker Mailserver + Roundcube)

`install.sh` brings up the mail platform too (`make dok-recreate-mailserver` → `mailserver` at 172.22.0.9 + `roundcube` at 172.22.0.10; the UFW ports are opened by the installer). What is NOT scripted: mailbox accounts (create with `make mail-add-user`/`mail-gen`). To carry existing mail to a new VPS:

1. Operator-only (copy from the old host): `/var/www/custom/projects/homelab/mailserver/` (Maildirs, DMS config + DKIM keys, roundcube sqlite), `services/mailserver/.env` (mailbox passwords), and the CF DNS records (MX, mail A DNS-only, SPF, DMARC, DKIM TXT).
2. Re-issue the mail.fxmq.net LE cert via the Caddy vhost; DMS reads it from caddy_data.

## Manual fallback

If the script can't be used, it automates exactly: host packages + `op` user + sshd hardening + docker daemon.json + `tailscale up` + ufw + repo clone + `docker network create net --subnet=172.22.0.0/16` + `make install-config` + `make dok-recreate-$DOMAIN|dok-recreate-nextcloud-db|dok-recreate-nextcloud|dok-recreate-vaultwarden|dok-recreate-uptimekuma|dok-recreate-pufferpanel|dok-recreate-mailserver` + CF DNS records + cert triggers. Optional data restore: `rsync` `cloud/users`, `vault/data`, `kuma/data` from the old host before first start (then `chown -R 33:33 cloud/users` and touch `cloud/users/.ncdata`).
