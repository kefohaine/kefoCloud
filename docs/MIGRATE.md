# Migration

Step-by-step runbook for moving jehpok.com to a new VPS. The five `make backup-*` recipes and `make install-config` are the only recipes this runbook calls; everything else is operator-issued shell. Run `make migrate` to print this file.

## 1. On the OLD VPS

Run all five backups in one shot:

```
make bkp-all
```

This produces five artifacts at the project root (`$(REPO)`): a `cloud-backup-<date>` directory, a `share-backup-<date>.db` file, a `vault-backup-<date>.tar.gz` archive, a `secrets-bundle-<date>.tar.gz` bundle, and a `mc-backup-<date>.tar.gz` world archive.

## 2. Download OFF the old VPS

Move the five artifacts off the VPS — the secrets bundle contains private keys and the Tailscale identity state:

- `$(REPO)/secrets-bundle-<date>.tar.gz`
- `$(REPO)/cloud-backup-<date>`
- `$(REPO)/share-backup-<date>.db`
- `$(REPO)/vault-backup-<date>.tar.gz`
- `$(REPO)/mc-backup-<date>.tar.gz`

The CF API token is **not** in any backup — it lives at `$(REPO)/caddy_data/CF_API_TOKEN` on the active VPS. It's a single line `CF_API_TOKEN=<token>` (mode 0600, owner `debian`). Caddy renews certs from the token, so transferring it is the only thing needed to skip the first 0–90-day issuance window on the new host.

## 3. On the NEW VPS (Debian)

Become root for system installs and unit restoration, then drop to `debian` for the rest. Run as root:

Install Debian packages, Ollama, and Tailscale:

```
apt update && apt install -y docker.io docker-compose-plugin git curl make sudo dnsmasq ufw
curl -fsSL https://ollama.com/install.sh | sh
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up
```

Restore the secrets bundle (drops unit files, SSH keys, dnsmasq config, and Tailscale state into place):

```
sudo tar xzf secrets-<date>.tar.gz -C /
sudo chown -R debian:debian /home/debian/.ssh
sudo chmod 600 /home/debian/.ssh/github_key
```

Restore the Nextcloud data directory to the host bind-mount path the `cloud` compose file expects (see `services/cloud/docker-compose.yml` for the bind source; the destination inside the container is `/data`):

```
sudo mkdir -p $(REPO)/cloud/html $(REPO)/cloud/users
sudo cp -a cloud-backup-<date>/html/* $(REPO)/cloud/html/
sudo cp -a cloud-backup-<date>/users/* $(REPO)/cloud/users/
echo '# Nextcloud data directory' | sudo tee $(REPO)/cloud/users/.ncdata
sudo chown -R 33:33 $(REPO)/cloud/html $(REPO)/cloud/users
```

Restore the shortener SQLite DB:

```
sudo mkdir -p $(REPO)/share/db
sudo cp share-backup-<date>.db $(REPO)/share/db/links.db
```

Restore the Vaultwarden data dir:

```
sudo mkdir -p $(REPO)/vault
sudo tar xzf vault-backup-<date>.tar.gz -C $(REPO)/vault
sudo chown -R 1000:1000 $(REPO)/vault/data
```

Drop to the `debian` user, clone the repo, drop the Nextcloud `.env` in place, create the external Docker network, and bootstrap:

```
git clone git@github.com:friedutch/jehpok.com.git $(REPO)/repo
cp <your-.env> $(REPO)/repo/services/cloud/.env
docker network create net
make -C $(REPO)/repo setup
```

`make install-config` is idempotent: it installs ttyd, copies reference configs into host paths, enables the systemd units (ollama, ttyd, dnsmasq, sshd, jehpok-daily.timer), opens the UFW rule for ttyd, and deploys the project-level Claude Code safety rail from `config/claude/settings.local.json`.

Now create the Caddy data dir + restore the CF API token (so the per-vhost ACME certs can be issued on first request):

```
sudo mkdir -p $(REPO)/caddy_data
sudo chown -R 201:201 $(REPO)/caddy_data
sudo install -m 0644 -o debian -g debian /dev/null $(REPO)/caddy_data/CF_API_TOKEN
printf 'CF_API_TOKEN=%s\n' '<paste token here>' | sudo tee $(REPO)/caddy_data/CF_API_TOKEN > /dev/null
sudo chmod 0644 $(REPO)/caddy_data/CF_API_TOKEN
```

Then bring up the containers:

```
make -C $(REPO)/repo up-all
```

`make up-all` brings up the six containers in dependency order. The `domain` container is built locally from `services/domain/Dockerfile` (Caddy + caddy-dns/cloudflare plugin) — that adds ~3 minutes the first time.

## 4. Update Cloudflare DNS

Point `jehpok.com` (and any subdomains serving traffic) at the new VPS IP. Each vhost will issue its own LE cert via DNS-01 — no CF Origin CA to copy.

## 5. Verify

Tail each container's logs to confirm clean startup:

```
make logs-all
```

Hit each public vhost to trigger ACME issuance (one cert per hit, ~seconds total):

```
for h in www share vault cloud kuma api mc; do
  curl -sk -o /dev/null -w "$h.jehpok.com: HTTP %{http_code}\n" https://$h.jehpok.com/
done
```

Verify the cert issuer is Let's Encrypt on every vhost:

```
for h in www share vault cloud kuma api mc; do
  echo -n "$h.jehpok.com: "
  echo | openssl s_client -connect $h.jehpok.com:443 -servername $h.jehpok.com 2>/dev/null | openssl x509 -noout -issuer 2>&1 | cut -d'=' -f2-
done
```

The tailnet routes (`server.jehpok.com/{,/share,/mc,/shell}`) are unreachable from a fresh VPS without Tailscale; verify those after `make install-config` from a tailnet-joined device, not from the VPS host itself.
