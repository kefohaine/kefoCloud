# Migration

Step-by-step runbook for moving jehpok.com to a new VPS. The five `make backup-*` recipes and `make setup` are the only recipes this runbook calls; everything else is operator-issued shell. Run `make migrate` to print this file.

## 1. On the OLD VPS

Run all five backups in one shot:

```
make backup-all
```

This produces five artifacts at the project root (`$(REPO)`): a `cloud-backup-<date>` directory, a `share-backup-<date>.db` file, a `vault-backup-<date>.tar.gz` archive, a `secrets-backup/secrets-<date>.tar.gz` bundle, and a `minecraft-backup-<date>.tar.gz` world archive.

## 2. Download OFF the old VPS

Move the five artifacts off the VPS — the secrets bundle contains private keys and the Tailscale identity state:

- `$(REPO)/secrets-backup/secrets-<date>.tar.gz`
- `$(REPO)/cloud-backup-<date>`
- `$(REPO)/share-backup-<date>.db`
- `$(REPO)/vault-backup-<date>.tar.gz`
- `$(REPO)/minecraft-backup-<date>.tar.gz`

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
make -C $(REPO)/repo up-all
```

`make setup` is idempotent: it installs ttyd, copies reference configs into host paths, enables the systemd units (ollama, ttyd, dnsmasq, sshd, jehpok-daily.timer), opens the UFW rule for ttyd, and deploys the project-level Claude Code safety rail from `setup/claude/settings.local.json`. `make up-all` brings up the six containers in dependency order.

## 4. Update Cloudflare DNS

Point `jehpok.com` (and any subdomains serving traffic) at the new VPS IP.

## 5. Verify

Tail each container's logs to confirm clean startup:

```
make logs-all
```

And hit the public landing page to confirm Caddy is serving:

```
curl -sk --resolve www.jehpok.com:443:127.0.0.1 https://www.jehpok.com/
```

The tailnet routes (`server.jehpok.com/{,/share,/mc,/shell}`) are unreachable from a fresh VPS without Tailscale; verify those after `make setup` from a tailnet-joined device, not from the VPS host itself.
