.RECIPEPREFIX = >
.SHELLFLAGS := -eu -c

REPO := /var/www/github/jehpok.com/repo
COMPOSE := docker compose -f

.PHONY: up-domain up-cloud up-tailnet up-all
.PHONY: restart-domain restart-cloud restart-tailnet
.PHONY: logs-domain logs-cloud logs-tailnet
.PHONY: status push backup-cloud clean setup-host

up-domain:
>$(COMPOSE) $(REPO)/services/domain/docker-compose.yml up -d --force-recreate

up-cloud:
>$(COMPOSE) $(REPO)/services/cloud/docker-compose.yml up -d --force-recreate

up-tailnet:
>$(COMPOSE) $(REPO)/services/tailnet/docker-compose.yml up -d --force-recreate

up-all: up-tailnet up-domain up-cloud

restart-domain:
>$(COMPOSE) $(REPO)/services/domain/docker-compose.yml restart domain

restart-cloud:
>$(COMPOSE) $(REPO)/services/cloud/docker-compose.yml restart cloud

restart-tailnet:
>$(COMPOSE) $(REPO)/services/tailnet/docker-compose.yml restart tailnet

logs-domain:
>docker logs domain --tail 50 -f

logs-cloud:
>docker logs cloud --tail 50 -f

logs-tailnet:
>docker logs tailnet --tail 50 -f

status:
>docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

push:
>cd $(REPO) && git add -A && git commit -m "$(MSG)" && git push jehpok.com main

backup-cloud:
>docker exec -w /var/www/html cloud php occ maintenance:mode --on
>cp -a /var/www/github/jehpok.com/cloud/users /var/www/github/jehpok.com/cloud-backup-$$(date +%Y%m%d)
>docker exec -w /var/www/html cloud php occ maintenance:mode --off
>@echo "Backup at /var/www/github/jehpok.com/cloud-backup-$$(date +%Y%m%d)"

clean:
>docker builder prune -af
>sudo apt-get clean

setup-host:
>sudo cp $(REPO)/setup/ollama/ollama.service /etc/systemd/system/ollama.service
>sudo cp $(REPO)/setup/ssh/50-cloud-init.conf /etc/ssh/sshd_config.d/50-cloud-init.conf
>sudo systemctl daemon-reload
>sudo systemctl enable --now ollama
>sudo systemctl restart sshd
>@echo "Host setup complete: Ollama enabled, SSH hardened."

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
  /var/lib/tailscale
>@echo "Secrets bundle at /var/www/github/jehpok.com/secrets-backup/secrets-$$(date +%Y%m%d).tar.gz"
>@echo "Download this file OFF the VPS. It contains private keys and Tailscale identity."

migrate:
>@echo "=== Full migration to a new VPS ==="
>@echo ""
>@echo "1. On the OLD VPS:"
>@echo "   make backup-cloud    # snapshot Nextcloud data"
>@echo "   make backup-secrets  # bundle certs, keys, Tailscale state"
>@echo ""
>@echo "2. Download these OFF the old VPS:"
>@echo "   /var/www/github/jehpok.com/secrets-backup/secrets-*.tar.gz"
>@echo "   /var/www/github/jehpok.com/cloud-backup-*"
>@echo ""
>@echo "3. On the NEW VPS (Debian), as root then debian:"
>@echo "   apt update && apt install -y docker.io docker-compose-plugin git curl make sudo"
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