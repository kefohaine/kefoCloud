.RECIPEPREFIX = >
.SHELLFLAGS := -eu -c

REPO     := /var/www/custom/projects/jehpok
COMPOSE  := docker compose -f
SERVICES := share domain cloud vault kuma homer
HOST     := ttyd dnsmasq ollama

# ─────────────────────────────────────────────────────────────────────────────
# Per-container: up / restart / logs
# One set of rules, expanded across $(SERVICES).
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: $(addprefix up-,$(SERVICES)) up-all
.PHONY: $(addprefix restart-,$(SERVICES)) restart-all
.PHONY: $(addprefix logs-,$(SERVICES)) logs-all

# share rebuilds its image locally; the rest just pull.
define up_rule
up-$1:
>$(COMPOSE) $(REPO)/repo/services/$1/docker-compose.yml up -d --force-recreate$(if $(filter share,$1), --build)
endef
$(foreach s,$(SERVICES),$(eval $(call up_rule,$s)))

define restart_rule
restart-$1:
>$(COMPOSE) $(REPO)/repo/services/$1/docker-compose.yml restart $1
endef
$(foreach s,$(SERVICES),$(eval $(call restart_rule,$s)))

define logs_rule
logs-$1:
>docker logs $1 --tail 50 -f
endef
$(foreach s,$(SERVICES),$(eval $(call logs_rule,$s)))

up-all: $(addprefix up-,$(SERVICES))
restart-all: $(addprefix restart-,$(SERVICES)) restart-dnsmasq restart-ttyd

logs-all:
>@stdbuf -oL bash -c 'for c in $(SERVICES); do \
    docker logs $$c --tail 50 -f 2>&1 | stdbuf -oL sed "s/^/[$$c] /" & \
  done; wait'

# ─────────────────────────────────────────────────────────────────────────────
# Host services (systemd): ttyd, dnsmasq
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: restart-ttyd restart-dnsmasq logs-ttyd logs-dnsmasq

restart-ttyd:
>sudo systemctl restart ttyd

restart-dnsmasq:
>sudo systemctl restart dnsmasq

logs-ttyd:
>sudo journalctl -u ttyd -n 50 -f

logs-dnsmasq:
>sudo journalctl -u dnsmasq -n 50 -f

# ─────────────────────────────────────────────────────────────────────────────
# Maintenance
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: status clean refresh setup help

status:
>@echo "--- containers ---"
>@docker ps --format 'table {{.Names}}\t{{.Status}}'
>@echo ""
>@echo "--- host services ---"
>@for u in $(HOST); do printf "  %-30s %s\n" "$$u" "$$(systemctl is-active $$u)"; done
>@echo ""
>@echo "--- disk ---"
>@df -h /
>@echo ""
>@echo "--- memory ---"
>@free -h

clean:
>docker builder prune -af
>docker image prune -af
>docker container prune -f
>sudo apt-get autoremove -y
>sudo apt-get clean

# Pull every image that isn't built locally, then bring everything up.
refresh:
>sudo apt-get update
>sudo apt-get upgrade -y
>@for f in $(REPO)/repo/services/*/docker-compose.yml; do \
    if grep -qE '^[[:space:]]*build:' "$$f"; then \
      echo "skip pull (built locally): $$f"; \
    else \
      $(COMPOSE) "$$f" pull; \
    fi; \
  done
>cd $(REPO)/repo && $(MAKE) up-all

# One-shot bootstrap: install ttyd, install reference configs, enable units,
# restore Claude settings, open the UFW rule for ttyd. Idempotent.
setup:
>@if ! command -v ttyd >/dev/null 2>&1; then \
    echo "Installing ttyd..."; \
    curl -fsSL -o /tmp/ttyd.tar.gz https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.x86_64-linux-gnu-static.tar.gz; \
    tar xzf /tmp/ttyd.tar.gz -C /tmp ttyd; \
    sudo install -m 0755 /tmp/ttyd /usr/local/bin/ttyd; \
    rm -f /tmp/ttyd /tmp/ttyd.tar.gz; \
  else \
    echo "ttyd already installed at $$(command -v ttyd)"; \
  fi
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
>sudo cp $(REPO)/repo/setup/ttyd/ttyd.service /etc/systemd/system/ttyd.service
>mkdir -p $(REPO)/repo/.claude
>cp -n $(REPO)/repo/setup/claude/settings.local.json $(REPO)/repo/.claude/settings.local.json
>sudo ufw allow from 172.22.0.0/16 to any port 7681 proto tcp
>sudo systemctl daemon-reload
>sudo systemctl enable --now ollama jehpok-daily.timer ttyd
>sudo systemctl restart sshd dnsmasq
>@echo "Host setup complete: ollama + ttyd + dnsmasq + sshd + daily timer enabled, Claude settings restored."

# ─────────────────────────────────────────────────────────────────────────────
# Backups
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: backup-cloud backup-share backup-vault backup-secrets

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

# ─────────────────────────────────────────────────────────────────────────────
# Git
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: push

push:
>cd $(REPO)/repo && git add -A && git commit -m "$(MSG)" && git push jehpok.com main

# ─────────────────────────────────────────────────────────────────────────────
# Help (default goal)
# ─────────────────────────────────────────────────────────────────────────────

.DEFAULT_GOAL := help
.PHONY: help

help:
>@echo ""
>@echo "  jehpok.com — make recipes"
>@echo ""
>@echo "  Per-container  (one of: $(SERVICES))"
>@echo "    make up-<svc>         force-recreate container (share also rebuilds)"
>@echo "    make restart-<svc>    reload container without recreating"
>@echo "    make logs-<svc>       follow container logs"
>@echo ""
>@echo "  Bulk"
>@echo "    make up-all           recreate all 6 containers in order"
>@echo "    make restart-all      restart all 6 containers + dnsmasq + ttyd"
>@echo "    make logs-all         tail all 6 container logs in one stream"
>@echo ""
>@echo "  Host services (systemd)"
>@echo "    make restart-ttyd     restart host ttyd"
>@echo "    make restart-dnsmasq  restart host dnsmasq"
>@echo "    make logs-ttyd        follow ttyd journal"
>@echo "    make logs-dnsmasq     follow dnsmasq journal"
>@echo ""
>@echo "  Maintenance"
>@echo "    make status           containers + host services + disk + memory"
>@echo "    make refresh          apt update/upgrade + pull images + up-all"
>@echo "    make clean            prune docker builder/image/container + apt"
>@echo "    make setup            one-shot host bootstrap (configs, units, UFW, Claude)"
>@echo ""
>@echo "  Backups"
>@echo "    make backup-cloud     Nextcloud snapshot (maintenance mode during copy)"
>@echo "    make backup-share     shortener SQLite DB"
>@echo "    make backup-vault     Vaultwarden data tar"
>@echo "    make backup-secrets   bundle certs + keys + Tailscale state (download off VPS)"
>@echo ""
>@echo "  Migration / git"
>@echo "    make migrate          print full VPS-to-VPS migration runbook"
>@echo "    make push MSG=\"...\"   commit + push to jehpok.com main"
>@echo ""
