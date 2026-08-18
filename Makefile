.RECIPEPREFIX = >
.SHELLFLAGS := -eu -c

REPO := /var/www/github/jehpok.com/repo
COMPOSE := docker compose -f

.PHONY: up-domain up-cloud up-share up-vault up-kuma up-homer up-all
.PHONY: restart-domain restart-cloud restart-share restart-vault restart-kuma restart-homer restart-dns
.PHONY: logs-domain logs-cloud logs-share logs-vault logs-kuma logs-homer logs-dns
.PHONY: status push backup-cloud backup-share backup-vault clean setup-host

up-domain:
>$(COMPOSE) $(REPO)/services/domain/docker-compose.yml up -d --force-recreate

up-cloud:
>$(COMPOSE) $(REPO)/services/cloud/docker-compose.yml up -d --force-recreate

up-share:
>$(COMPOSE) $(REPO)/services/share/docker-compose.yml up -d --force-recreate --build

up-vault:
>$(COMPOSE) $(REPO)/services/vault/docker-compose.yml up -d --force-recreate

up-kuma:
>$(COMPOSE) $(REPO)/services/kuma/docker-compose.yml up -d --force-recreate

up-homer:
>$(COMPOSE) $(REPO)/services/homer/docker-compose.yml up -d --force-recreate

up-all: up-share up-domain up-cloud up-vault up-kuma up-homer

restart-domain:
>$(COMPOSE) $(REPO)/services/domain/docker-compose.yml restart domain

restart-cloud:
>$(COMPOSE) $(REPO)/services/cloud/docker-compose.yml restart cloud

restart-share:
>$(COMPOSE) $(REPO)/services/share/docker-compose.yml restart share

restart-vault:
>$(COMPOSE) $(REPO)/services/vault/docker-compose.yml restart vault

restart-kuma:
>$(COMPOSE) $(REPO)/services/kuma/docker-compose.yml restart kuma

restart-homer:
>$(COMPOSE) $(REPO)/services/homer/docker-compose.yml restart homer

restart-dns:
>sudo systemctl restart dnsmasq

logs-domain:
>docker logs domain --tail 50 -f

logs-cloud:
>docker logs cloud --tail 50 -f

logs-share:
>docker logs share --tail 50 -f

logs-vault:
>docker logs vault --tail 50 -f

logs-kuma:
>docker logs kuma --tail 50 -f

logs-homer:
>docker logs homer --tail 50 -f

logs-dns:
>sudo journalctl -u dnsmasq -n 50 -f

status:
>docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

push:
>cd $(REPO) && git add -A && git commit -m "$(MSG)" && git push jehpok.com main

backup-cloud:
>docker exec -w /var/www/html cloud php occ maintenance:mode --on
>cp -a /var/www/github/jehpok.com/cloud/users /var/www/github/jehpok.com/cloud-backup-$$(date +%Y%m%d)
>docker exec -w /var/www/html cloud php occ maintenance:mode --off
>@echo "Backup at /var/www/github/jehpok.com/cloud-backup-$$(date +%Y%m%d)"

backup-share:
>cp /var/www/github/jehpok.com/share/db/links.db /var/www/github/jehpok.com/share-backup-$$(date +%Y%m%d).db
>@echo "Backup at /var/www/github/jehpok.com/share-backup-$$(date +%Y%m%d).db"

backup-vault:
>tar czf /var/www/github/jehpok.com/vault-backup-$$(date +%Y%m%d).tar.gz -C /var/www/github/jehpok.com/vault data
>@echo "Backup at /var/www/github/jehpok.com/vault-backup-$$(date +%Y%m%d).tar.gz"

clean:
>docker builder prune -af
>sudo apt-get clean

setup-host:
>sudo cp $(REPO)/setup/ollama/ollama.service /etc/systemd/system/ollama.service
>sudo cp $(REPO)/setup/ssh/50-cloud-init.conf /etc/ssh/sshd_config.d/50-cloud-init.conf
>sudo cp $(REPO)/setup/dnsmasq/10-tailnet.conf /etc/dnsmasq.d/10-tailnet.conf
>sudo mkdir -p /etc/systemd/system/dnsmasq.service.d
>sudo cp $(REPO)/setup/dnsmasq/dnsmasq.service.conf /etc/systemd/system/dnsmasq.service.d/override.conf
>sudo cp $(REPO)/setup/maintenance/daily.sh /usr/local/bin/jehpok-daily.sh
>sudo chmod +x /usr/local/bin/jehpok-daily.sh
>sudo cp $(REPO)/setup/maintenance/daily.service /etc/systemd/system/jehpok-daily.service
>sudo cp $(REPO)/setup/maintenance/daily.timer /etc/systemd/system/jehpok-daily.timer
>sudo touch /var/log/jehpok-daily.log
>sudo chown debian:debian /var/log/jehpok-daily.log
>sudo systemctl daemon-reload
>sudo systemctl enable --now ollama jehpok-daily.timer
>sudo systemctl restart sshd dnsmasq
>@echo "Host setup complete: Ollama enabled, SSH hardened, dnsmasq resolver installed, daily maintenance timer enabled."

backup-secrets:
>mkdir -p /var/www/github/jehpok.com/secrets-backup
>tar czf /var/www/github/jehpok.com/secrets-backup/secrets-$$(date +%Y%m%d).tar.gz \
  /var/www/github/jehpok.com/certs \
  /home/debian/.ssh/github_key \
  /home/debian/.ssh/github_key.pub \
  /home/debian/.ssh/config \
  /home/debian/.ssh/authorized_keys \
  /etc/systemd/system/ollama.service \
  /etc/ssh/sshd_config.d/50-cloud-init.conf \
  /etc/dnsmasq.d/10-tailnet.conf \
  /etc/systemd/system/dnsmasq.service.d/override.conf \
  /var/lib/tailscale
>@echo "Secrets bundle at /var/www/github/jehpok.com/secrets-backup/secrets-$$(date +%Y%m%d).tar.gz"
>@echo "Download this file OFF the VPS. It contains private keys and Tailscale identity."

migrate:
>@echo "=== Full migration to a new VPS ==="
>@echo ""
>@echo "1. On the OLD VPS:"
>@echo "   make backup-cloud    # snapshot Nextcloud data"
>@echo "   make backup-share    # snapshot shortener DB"
>@echo "   make backup-vault    # snapshot Vaultwarden data"
>@echo "   make backup-secrets  # bundle certs, keys, Tailscale state"
>@echo ""
>@echo "2. Download these OFF the old VPS:"
>@echo "   /var/www/github/jehpok.com/secrets-backup/secrets-*.tar.gz"
>@echo "   /var/www/github/jehpok.com/cloud-backup-*"
>@echo "   /var/www/github/jehpok.com/share-backup-*.db"
>@echo "   /var/www/github/jehpok.com/vault-backup-*.tar.gz"
>@echo ""
>@echo "3. On the NEW VPS (Debian), as root then debian:"
>@echo "   apt update && apt install -y docker.io docker-compose-plugin git curl make sudo dnsmasq"
>@echo "   curl -fsSL https://ollama.com/install.sh | sh"
>@echo "   curl -fsSL https://tailscale.com/install.sh | sh"
>@echo "   tailscale up"
>@echo ""
>@echo "   # restore secrets:"
>@echo "   sudo tar xzf secrets-*.tar.gz -C /"
>@echo "   sudo chown -R debian:debian /home/debian/.ssh"
>@echo "   sudo chmod 600 /home/debian/.ssh/github_key"
>@echo ""
>@echo "   # restore Nextcloud data:"
>@echo "   sudo mkdir -p /var/www/github/jehpok.com/cloud/html /var/www/github/jehpok.com/cloud/users"
>@echo "   sudo cp -a cloud-backup-*/html/* /var/www/github/jehpok.com/cloud/html/"
>@echo "   sudo cp -a cloud-backup-*/users/* /var/www/github/jehpok.com/cloud/users/"
>@echo "   echo '# Nextcloud data directory' | sudo tee /var/www/github/jehpok.com/cloud/users/.ncdata"
>@echo "   sudo chown -R 33:33 /var/www/github/jehpok.com/cloud/html /var/www/github/jehpok.com/cloud/users"
>@echo ""
>@echo "   # restore share DB:"
>@echo "   sudo mkdir -p /var/www/github/jehpok.com/share/db"
>@echo "   sudo cp share-backup-*.db /var/www/github/jehpok.com/share/db/links.db"
>@echo ""
>@echo "   # restore vault data:"
>@echo "   sudo mkdir -p /var/www/github/jehpok.com/vault"
>@echo "   sudo tar xzf vault-backup-*.tar.gz -C /var/www/github/jehpok.com/vault"
>@echo "   sudo chown -R 1000:1000 /var/www/github/jehpok.com/vault/data"
>@echo ""
>@echo "   # clone and bootstrap:"
>@echo "   git clone git@github.com:friedutch/jehpok.com.git /var/www/github/jehpok.com/repo"
>@echo "   cp <your-.env> /var/www/github/jehpok.com/repo/services/cloud/.env"
>@echo "   docker network create net"
>@echo "   make -C /var/www/github/jehpok.com/repo setup-host"
>@echo "   make -C /var/www/github/jehpok.com/repo up-all"
>@echo ""
>@echo "4. Update Cloudflare DNS to point to the new VPS IP."
>@echo "5. Verify: curl -sk https://www.jehpok.com/cheyou --resolve www.jehpok.com:443:127.0.0.1"
>@echo ""
>@echo "=== Done. ==="