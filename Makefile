.RECIPEPREFIX = >
.SHELLFLAGS := -eu -c

REPO := /var/www/custom/projects/jehpok
COMPOSE := docker compose -f

.PHONY: up-domain up-cloud up-share up-vault up-kuma up-homer up-all
.PHONY: restart-domain restart-cloud restart-share restart-vault restart-kuma restart-homer restart-dns restart-ttyd
.PHONY: logs-domain logs-cloud logs-share logs-vault logs-kuma logs-homer logs-dns logs-ttyd
.PHONY: status push backup-cloud backup-share backup-vault backup-secrets clean setup-host

up-domain:
>$(COMPOSE) $(REPO)/repo/services/domain/docker-compose.yml up -d --force-recreate

up-cloud:
>$(COMPOSE) $(REPO)/repo/services/cloud/docker-compose.yml up -d --force-recreate

up-share:
>$(COMPOSE) $(REPO)/repo/services/share/docker-compose.yml up -d --force-recreate --build

up-vault:
>$(COMPOSE) $(REPO)/repo/services/vault/docker-compose.yml up -d --force-recreate

up-kuma:
>$(COMPOSE) $(REPO)/repo/services/kuma/docker-compose.yml up -d --force-recreate

up-homer:
>$(COMPOSE) $(REPO)/repo/services/homer/docker-compose.yml up -d --force-recreate

up-all: up-share up-domain up-cloud up-vault up-kuma up-homer

restart-domain:
>$(COMPOSE) $(REPO)/repo/services/domain/docker-compose.yml restart domain

restart-cloud:
>$(COMPOSE) $(REPO)/repo/services/cloud/docker-compose.yml restart cloud

restart-share:
>$(COMPOSE) $(REPO)/repo/services/share/docker-compose.yml restart share

restart-vault:
>$(COMPOSE) $(REPO)/repo/services/vault/docker-compose.yml restart vault

restart-kuma:
>$(COMPOSE) $(REPO)/repo/services/kuma/docker-compose.yml restart kuma

restart-homer:
>$(COMPOSE) $(REPO)/repo/services/homer/docker-compose.yml restart homer

restart-dns:
>sudo systemctl restart dnsmasq

restart-ttyd:
>sudo systemctl restart ttyd

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

logs-ttyd:
>sudo journalctl -u ttyd -n 50 -f

status:
>docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
>sudo systemctl --no-pager status ttyd dnsmasq ollama --lines=0 2>/dev/null | grep -E '●|Active'

push:
>cd $(REPO)/repo && git add -A && git commit -m "$(MSG)" && git push jehpok.com main

backup-cloud:
>docker exec -w /var/www/html cloud php occ maintenance:mode --on
>cp -a $(REPO)/cloud/users $(REPO)/cloud-backup-$$(date +%Y%m%d)
>docker exec -w /var/www/html cloud php occ maintenance:mode --off
>@echo "Backup at $(REPO)/cloud-backup-$$(date +%Y%m%d)"

backup-share:
>cp $(REPO)/share/db/links.db $(REPO)/share-backup-$$(date +%Y%m%d).db
>@echo "Backup at $(REPO)/share-backup-$$(date +%Y%m%d).db"

backup-vault:
>tar czf $(REPO)/vault-backup-$$(date +%Y%m%d).tar.gz -C $(REPO)/vault data
>@echo "Backup at $(REPO)/vault-backup-$$(date +%Y%m%d).tar.gz"

backup-secrets:
>mkdir -p $(REPO)/secrets-backup
>tar czf $(REPO)/secrets-backup/secrets-$$(date +%Y%m%d).tar.gz \
  $(REPO)/certs \
  /home/debian/.ssh/github_key \
  /home/debian/.ssh/github_key.pub \
  /home/debian/.ssh/config \
  /home/debian/.ssh/authorized_keys \
  /etc/systemd/system/ollama.service \
  /etc/systemd/system/ttyd.service \
  /etc/ssh/sshd_config.d/50-cloud-init.conf \
  /etc/dnsmasq.d/10-tailnet.conf \
  /etc/systemd/system/dnsmasq.service.d/override.conf \
  /var/lib/tailscale
>@echo "Secrets bundle at $(REPO)/secrets-backup/secrets-$$(date +%Y%m%d).tar.gz"
>@echo "Download this file OFF the VPS. It contains private keys and Tailscale identity."

clean:
>docker builder prune -af
>sudo apt-get clean

setup-host:
>sudo cp $(REPO)/repo/setup/ollama/ollama.service /etc/systemd/system/ollama.service
>sudo cp $(REPO)/repo/setup/ssh/50-cloud-init.conf /etc/ssh/sshd_config.d/50-cloud-init.conf
>sudo cp $(REPO)/repo/setup/dnsmasq/10-tailnet.conf /etc/dnsmasq.d/10-tailnet.conf
>sudo mkdir -p /etc/systemd/system/dnsmasq.service.d
>sudo cp $(REPO)/repo/setup/dnsmasq/dnsmasq.service.conf /etc/systemd/system/dnsmasq.service.d/override.conf
>sudo cp $(REPO)/repo/setup/maintenance/daily.sh /usr/local/bin/jehpok-daily.sh
>sudo chmod +x /usr/local/bin/jehpok-daily.sh
>sudo cp $(REPO)/repo/setup/maintenance/daily.service /etc/systemd/system/jehpok-daily.service
>sudo cp $(REPO)/repo/setup/maintenance/daily.timer /etc/systemd/system/jehpok-daily.timer
>sudo touch /var/log/jehpok-daily.log
>sudo chown debian:debian /var/log/jehpok-daily.log
># ttyd — web terminal at ops.jehpok.com/terminal (host systemd, not Docker)
>if ! command -v ttyd >/dev/null 2>&1; then \
  echo "Installing ttyd..."; \
  curl -fsSL -o /tmp/ttyd.tar.gz https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.x86_64-linux-gnu-static.tar.gz; \
  tar xzf /tmp/ttyd.tar.gz -C /tmp ttyd; \
  sudo install -m 0755 /tmp/ttyd /usr/local/bin/ttyd; \
  rm -f /tmp/ttyd /tmp/ttyd.tar.gz; \
fi
>sudo cp $(REPO)/repo/setup/ttyd/ttyd.service /etc/systemd/system/ttyd.service
>sudo ufw allow from 172.22.0.0/16 to any port 7681 proto tcp
>sudo systemctl daemon-reload
>sudo systemctl enable --now ollama jehpok-daily.timer ttyd
>sudo systemctl restart sshd dnsmasq
>@echo "Host setup complete: Ollama enabled, SSH hardened, dnsmasq resolver installed, daily maintenance timer enabled, ttyd web terminal enabled."

migrate:
>@echo "=== Full migration to a new VPS ==="
>@echo ""
>@echo "1. On the OLD VPS:"
>@echo "   make backup-cloud    # snapshot Nextcloud data"
>@echo "   make backup-share    # snapshot shortener DB"
>@echo "   make backup-vault    # snapshot Vaultwarden data"
>@echo "   make backup-secrets  # bundle certs, keys, Tailscale state, ttyd unit"
>@echo ""
>@echo "2. Download these OFF the old VPS:"
>@echo "   $(REPO)/secrets-backup/secrets-*.tar.gz"
>@echo "   $(REPO)/cloud-backup-*"
>@echo "   $(REPO)/share-backup-*.db"
>@echo "   $(REPO)/vault-backup-*.tar.gz"
>@echo ""
>@echo "3. On the NEW VPS (Debian), as root then debian:"
>@echo "   apt update && apt install -y docker.io docker-compose-plugin git curl make sudo dnsmasq ufw"
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
>@echo "   sudo mkdir -p $(REPO)/cloud/html $(REPO)/cloud/users"
>@echo "   sudo cp -a cloud-backup-*/html/* $(REPO)/cloud/html/"
>@echo "   sudo cp -a cloud-backup-*/users/* $(REPO)/cloud/users/"
>@echo "   echo '# Nextcloud data directory' | sudo tee $(REPO)/cloud/users/.ncdata"
>@echo "   sudo chown -R 33:33 $(REPO)/cloud/html $(REPO)/cloud/users"
>@echo ""
>@echo "   # restore share DB:"
>@echo "   sudo mkdir -p $(REPO)/share/db"
>@echo "   sudo cp share-backup-*.db $(REPO)/share/db/links.db"
>@echo ""
>@echo "   # restore vault data:"
>@echo "   sudo mkdir -p $(REPO)/vault"
>@echo "   sudo tar xzf vault-backup-*.tar.gz -C $(REPO)/vault"
>@echo "   sudo chown -R 1000:1000 $(REPO)/vault/data"
>@echo ""
>@echo "   # clone and bootstrap:"
>@echo "   git clone git@github.com:friedutch/jehpok.com.git $(REPO)/repo"
>@echo "   cp <your-.env> $(REPO)/repo/services/cloud/.env"
>@echo "   docker network create net"
>@echo "   make -C $(REPO)/repo setup-host"
>@echo "   make -C $(REPO)/repo up-all"
>@echo ""
>@echo "4. Update Cloudflare DNS to point to the new VPS IP."
>@echo "5. Verify: curl -sk https://www.jehpok.com/cheyou --resolve www.jehpok.com:443:127.0.0.1"
>@echo ""
>@echo "=== Done. ==="
