# Migration (new VPS, new domain, 4 containers)

Runbook for moving the setup to a fresh Debian VPS with a **new domain** and a reduced container set — **Nextcloud, Vaultwarden, Uptime Kuma, Caddy** only (no Homer, share-flask, Minecraft, or mc-flask). Nothing is copied from the old host's config files: the repo is cloned, the domain is swapped with `sed`, and every host service is written fresh. Data restore (Nextcloud files, Vaultwarden DB, Kuma DB) is optional and done with `rsync` — see §10.

Placeholders: `$DOMAIN` = new domain, `$TS_IP` = new Tailscale IP, `$VPS_IP` = public IP, `$REPO=/var/www/custom/projects/jehpok`. Run the root sections as root, everything else as `debian`.

## 0. Cloudflare prep (browser)

- Add `$DOMAIN` as a new zone in Cloudflare.
- Create an API token with `Zone > DNS > Edit` permission for that zone only (the `caddy-dns/cloudflare` plugin needs it for ACME DNS-01; the new 53-char `cfut_*` token format works with the pinned plugin commit in `services/vhosts/Dockerfile`).
- Keep the token for §5.

## 1. New VPS base (root)

```
apt update && apt upgrade -y
apt install -y docker.io docker-compose-plugin git curl make sudo dnsmasq ufw
adduser debian && usermod -aG sudo,docker debian
echo 'debian ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/debian-passwordless && chmod 0440 /etc/sudoers.d/debian-passwordless
mkdir -p /home/debian/.ssh && echo '<your-pubkey>' > /home/debian/.ssh/authorized_keys
printf 'PasswordAuthentication no\nPermitRootLogin no\nAllowUsers debian\n' > /etc/ssh/sshd_config.d/50-cloud-init.conf
systemctl restart sshd
```

Log out and back in as `debian`.

## 2. Docker

```
sudo systemctl enable --now docker
sudo mkdir -p /etc/docker
cat | sudo tee /etc/docker/daemon.json <<'EOF'
{
    "log-driver": "json-file",
    "log-opts": {"max-size": "10m", "max-file": "3"},
    "storage-driver": "overlayfs",
    "default-runtime": "runc",
    "live-restore": true
}
EOF
sudo systemctl restart docker
```

## 3. Tailscale

```
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
tailscale ip -4          # note it → $TS_IP
```

In the Tailscale admin console: name the node, and add split-DNS for `$DOMAIN` → `$TS_IP`. This is what resolves `*.example.com` for tailnet devices; the VPS's own dnsmasq answers `server.$DOMAIN` (§6).

## 4. Repo clone + domain swap (as debian)

Add the new VPS SSH key to GitHub, then:

```
sudo mkdir -p /var/www/custom/projects/jehpok && sudo chown debian:debian /var/www/custom/projects/jehpok
git clone git@github.com:friedutch/jehpok.com.git /var/www/custom/projects/jehpok/repo
cd /var/www/custom/projects/jehpok/repo
mkdir -p cloud/html cloud/users vault/data kuma/data
```

Swap the domain in every config (Caddy vhosts + imports, dnsmasq, compose envs, Kuma seed SQL):

```
grep -rl 'jehpok\.com' services/ config/ | xargs sed -i 's/jehpok\.com/example.com/g'
```

Trim to the 4 containers — delete the services that are no longer run and their vhosts, then rename the surviving vhost files to match the sed'd imports:

```
rm -rf services/homer services/share-flask services/mc content/share content/minecraft
rm services/vhosts/vhosts/www.jehpok.com.caddy services/vhosts/vhosts/share.jehpok.com.caddy services/vhosts/vhosts/api.jehpok.com.caddy services/vhosts/vhosts/mc.jehpok.com.caddy
cd services/vhosts/vhosts && for f in *.jehpok.com.caddy; do mv "$f" "${f/jehpok.com/example.com}"; done && cd ../../..
```

Manual edits after the sed:
- `services/vhosts/Caddyfile` — remove the `import` lines of the deleted vhosts (server/cloud/vault/kuma stay).
- `services/vhosts/docker-compose.yml` — remove the dead `../..:/srv:ro` and `$(REPO)/share/files:/files:ro` mounts (share container is gone).
- `Makefile` — `CONTAINERS := vhosts ut-kuma nextcloud vaultwarden`; remove the `bkp-share` / `bkp-mc` recipes (their data dirs are gone) and drop them from `bkp-all`.
- `config/maintenance/daily.sh` — remove the mc-server stop/start block and the `bkp-share`/`bkp-mc` calls (harmless to leave, but they reference deleted paths and fail in `make bkp-all`).

Create the Nextcloud admin env (gitignored, used only on first install):

```
cat > services/nextcloud/.env <<'EOF'
NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=<choose-a-strong-one>
EOF
```

## 5. Docker network + Caddy data

The compose files pin bridge IPs `172.22.0.4/.5/.6` and the Caddyfile hardcodes the upstreams — the `net` network must be created with that subnet or the containers fail to attach:

```
docker network create net --subnet=172.22.0.0/16
```

Caddy data dir + CF token. The token file is read by `docker compose` as the `debian` user (mode 0644, owner `debian`); the dir itself is uid 201 (Caddy's `/data`):

```
mkdir -p caddy_data && sudo chown -R 201:201 caddy_data
printf 'CF_API_TOKEN=%s\n' '<token>' | sudo tee caddy_data/CF_API_TOKEN > /dev/null
sudo chmod 0644 caddy_data/CF_API_TOKEN
```

## 6. Host services

Point dnsmasq at the new Tailscale IP (the domain was already sed'd in §4):

```
sed -i "s/100\.81\.245\.77/$TS_IP/g" config/dnsmasq/10-tailnet.conf
```

Open the firewall, then run the one-shot host bootstrap — installs ttyd, copies `config/` to live, enables dnsmasq/sshd/daily timer, applies sysctl, and opens the ttyd UFW rule:

```
sudo ufw allow from 100.64.0.0/10 to any port 22 proto tcp
sudo ufw allow 80/tcp && sudo ufw allow 443/tcp
sudo ufw enable
make install-config
```

`make install-config` also enables the ollama unit — if you don't want the LLM service: `sudo systemctl disable --now ollama`.

## 7. Containers

Bring up Caddy first (the custom `caddy-dns:local` image builds locally, ~3 min on a cold cache), then the three upstreams:

```
make recreate-vhosts
make recreate-nextcloud
make recreate-vaultwarden
make recreate-ut-kuma
```

Nextcloud finishes its install on first boot (admin from `.env`). If the datadirectory landed in `/var/www/html/data` instead of the `/data` bind (fresh install default), repoint it:

```
docker exec -w /var/www/html nextcloud php occ config:system:set datadirectory --value /data
docker exec -w /var/www/html nextcloud php occ maintenance:repair
```

Kuma: create the admin account in the UI, then optionally seed monitors — `services/ut-kuma/seed-monitors.sql` was sed'd for the domain but still references deleted containers (`docker: share`, `docker: homer`, `docker: domain`), so edit it first or seed only the HTTP rows:

```
docker exec -i ut-kuma sqlite3 /app/data/kuma.db < services/ut-kuma/seed-monitors.sql
```

## 8. Cloudflare DNS

Add proxied A records for the public vhosts → `$VPS_IP`: `cloud.$DOMAIN`, `vault.$DOMAIN`, `kuma.$DOMAIN`. Do **not** add `server.$DOMAIN` to public DNS — it is tailnet-only by design (see the access model in `README.md`).

## 9. Verify

Trigger ACME issuance (one cert per vhost) and check the issuer:

```
for h in cloud vault kuma; do
  curl -sk -o /dev/null -w "$h.$DOMAIN: HTTP %{http_code}\n" https://$h.$DOMAIN/
done
for h in cloud vault kuma; do
  echo -n "$h.$DOMAIN: "
  echo | openssl s_client -connect $h.$DOMAIN:443 -servername $h.$DOMAIN 2>/dev/null | openssl x509 -noout -issuer | cut -d'=' -f2-
done
```

Every issuer must be Let's Encrypt, not Cloudflare Origin CA. From a tailnet device: `https://server.$DOMAIN/` → 200, `/shell` → ttyd. From the public internet: `server.$DOMAIN` must not resolve, and a forged `Host:` header against `$VPS_IP` must get 403.

## 10. Optional: restore data

If you want the old data (not required for the services to run), rsync it from the old VPS before first container start:

```
rsync -a debian@<old-vps>:$(REPO)/cloud/users/ cloud/users/
rsync -a debian@<old-vps>:$(REPO)/vault/data/ vault/data/
rsync -a debian@<old-vps>:$(REPO)/kuma/data/ kuma/data/
sudo chown -R 33:33 cloud/users
echo '# Nextcloud data directory' > cloud/users/.ncdata
```

Then recreate `nextcloud` and `ut-kuma` so they pick up the restored data. If the old Nextcloud `config.php` (in `cloud/html/config/`) is restored too, its `datadirectory`/`trusted_domains`/`overwrite.cli.url` still point at the old domain — fix with `occ config:system:set` or accept the fresh-install defaults instead.
