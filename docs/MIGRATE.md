# Migration (new VPS, new domain) — script-first

The primary path is `scripts/install.sh` — a plug-and-play installer. It prompts for three values (domain, Cloudflare API token, Tailscale auth key), then runs unattended. It creates the `op` user, installs host services (docker, tailscale, dnsmasq, ttyd, daily timer, ssh hardening, ufw, sysctl), clones the repo, renames it for the new domain, and brings up exactly four containers: Caddy (renamed `vhosts` → `$DOMAIN`), `nextcloud`, `vaultwarden`, `uptimekuma`. It also creates the Cloudflare A records (`cloud`/`vault`/`kuma`, proxied), sets the zone SSL mode to full, triggers Let's Encrypt issuance, and seeds Uptime Kuma (admin account included).

## Run it

```
scp scripts/install.sh root@<new-vps>:
ssh root@<new-vps>
bash install.sh
```

Enter the domain, CF token, and TS auth key when prompted. The script hands off to user `op` and runs unattended; full log at `/var/log/homelab-install.log`. Errors are printed numbered at the end, then a success summary with credentials.

## What the script renames (expects a pre-migration clone)

The installer's `renames()` step transforms a clone that still carries the old names. The canonical repo has already been migrated (fxmq.net / `op` / `shell.` since Aug 2026), so re-running `install.sh` against a current clone fails at `mv services/vhosts services/$DOMAIN` — the rename steps are not yet idempotent (tracked in `docs/ISSUES.md`).

- `homelab.com` → `$DOMAIN` — every Caddy vhost, dnsmasq, compose env, Kuma seed
- `server.$DOMAIN` → `shell.$DOMAIN` — the tailnet-only vhost and the dnsmasq `address=` line
- `debian` → `op` — user, sudoers, sshd `AllowUsers`, ttyd/daily units, Makefile ownership
- `services/vhosts` → `services/$DOMAIN` — caddy container + image renamed to `$DOMAIN`
- Container set trimmed to 4 — homer, share-flask, mc, mc-flask removed (their Caddy vhosts, Makefile recipes, daily.sh mc block, and Kuma monitors too)

## Prerequisites (manual, unavoidable)

- Cloudflare zone `$DOMAIN` exists; API token with `Zone > DNS > Edit` for that zone.
- Tailscale auth key (admin console → Settings → Keys).
- New VPS SSH key on GitHub — the script generates one and prints the pubkey; add it and re-run (state is saved, prompts are skipped).

## After the script finishes

1. The installer lists the Tailscale split-DNS entry (`$DOMAIN` → the new VPS Tailscale IP) as an **expected** manual step in its error/re-check loop — it cannot be set with just an auth key. Confirm it in the admin console and the loop clears it; without it `shell.$DOMAIN` won't resolve for tailnet devices.
2. Optional: Cloudflare WAF rule skip for `cloud.$DOMAIN` — Nextcloud desktop sync is bot-challenged otherwise (see `Intended` in `docs/ISSUES.md`).
3. Doc pass: done for the Aug 2026 migration — the canonical repo now carries the `fxmq.net` / `op` / `shell.` names in code, docs, and Makefile.

## Minecraft server (PufferPanel + LazyMC + Geyser)

The Minecraft stack is **not** part of `install.sh`'s container set — the panel (`services/pufferpanel/`), lazymc, and mc-idle-sleeper are added post-install. To carry it to a new VPS:

1. The repo carries everything reproducible: the server template `config/pufferpanel/servers/2ecfbe8c.json`, the lazymc unit/config/script (`config/lazymc/`), the idle sleeper (`config/mc-idle-sleeper/`), and the UFW ports (already in `install.sh`). After the base install: create the panel server from the template JSON (copy into `puffer/data/servers/<id>.json`), `make install-mc-idle-sleeper`, and `make install-lazymc` (after the game has been started once by the panel so the daemon has created a container).
2. Operator-only (not in repo, copy from the old host): the game server data dir `puffer/data/servers/2ecfbe8c/` (world, jars, plugin jars, Geyser cache/locales) and `/etc/lazymc/panel-cred` (credentials of the panel API user `lazymc`; on the new host recreate the user in the panel container via `/pufferpanel/bin/pufferpanel user add --name lazymc --password <pw> --admin --email lazymc@fxmq.net` and rewrite the file).
3. Gotchas that must hold on the new host: the server MOTD stays plain text (no `§` codes) and a 64×64 `server-icon.png` exists in the server dir (lazymc v0.2.11's status decoder fails otherwise); `server.properties` `server-ip=127.0.0.1` / `server-port=25566` (lazymc rewrites these at start); RCON disabled; the game domain's CF A record is DNS-only; restarting lazymc requires the game server stopped (see `docs/ISSUES.md` lessons).

## Manual fallback

If the script can't be used, it automates exactly: host packages + `op` user + sshd hardening + docker daemon.json + `tailscale up` + ufw + repo clone + the renames above + `docker network create net --subnet=172.22.0.0/16` + `make install-config` + `make d-recreate-$DOMAIN|d-recreate-nextcloud|d-recreate-vaultwarden|d-recreate-uptimekuma` + CF DNS records + cert triggers. Optional data restore: `rsync` `cloud/users`, `vault/data`, `kuma/data` from the old host before first start (then `chown -R 33:33 cloud/users` and touch `cloud/users/.ncdata`).
