.RECIPEPREFIX = >
# Use bash explicitly so SHELLFLAGS go to bash, not /bin/sh (dash on Debian).
# Without this, `dash -eu -c '<recipe>'` runs the recipe with `set -eu` and
# bites any line that references an unset variable — see docs/GUIDE.md
# "Operational gotchas" for the symptom and the fix.
SHELL := /bin/bash
.SHELLFLAGS := -eu -c

REPO     := /var/www/custom/projects/jehpok
COMPOSE  := docker compose -f
SERVICES := domain homer kuma share cloud vault minecraft
HOST     := ttyd dnsmasq ollama

# ─────────────────────────────────────────────────────────────────────────────
# Per-container: up / restart / logs
# One set of rules, expanded across $(SERVICES).
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: $(addprefix up-,$(SERVICES)) up-all
.PHONY: $(addprefix restart-,$(SERVICES)) restart-all
.PHONY: $(addprefix logs-,$(SERVICES)) logs-all

# share + domain rebuild their image locally; the rest just pull.
# share = custom Dockerfile for the link shortener.
# domain = custom Dockerfile adds caddy-dns/cloudflare so the
#   mc.jehpok.com vhost can use ACME DNS-01 (HTTP-01 is blocked because
#   the game ports require CF proxy to stay off, but CF proxy is what
#   would carry the HTTP-01 challenge traffic from the public internet).
define up_rule
up-$1:
>$(COMPOSE) $(REPO)/repo/services/$1/docker-compose.yml up -d --force-recreate$(if $(filter share domain,$1), --build)
endef
$(foreach s,$(SERVICES),$(eval $(call up_rule,$s)))

define restart_rule
restart-$1:
># Some compose files declare more than one service (e.g. minecraft has
# `minecraft` + `minecraft-web`). Restarting the named service alone would
# leave the other untouched and surprise the next edit, so restart every
# service in the file.
>$(COMPOSE) $(REPO)/repo/services/$1/docker-compose.yml restart
endef
$(foreach s,$(SERVICES),$(eval $(call restart_rule,$s)))

define logs_rule
logs-$1:
># Tail the service container named after the directory; for compose files
# with multiple services (minecraft: minecraft + minecraft-web), tail both
# with a [container] prefix so they don't interleave silently.
>if [ "$1" = "minecraft" ]; then \
    docker logs minecraft --tail 50 -f 2>&1 | stdbuf -oL sed "s/^/[minecraft] /" & \
    docker logs minecraft-web --tail 50 -f 2>&1 | stdbuf -oL sed "s/^/[minecraft-web] /" & \
    wait; \
  else \
    docker logs $1 --tail 50 -f; \
  fi
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

.PHONY: status clean-docker clean-apt clean-backups clean-all refresh setup help

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

clean-docker:
>@docker builder prune -af
>@docker image prune -af
>@docker container prune -f

clean-apt:
>@sudo apt-get -qq autoremove -y

# Keep the 3 most recent artifacts per backup pattern; delete older.
clean-backups:
>@for pattern in cloud-backup-* share-backup-*.db vault-backup-*.tar.gz secrets-backup/secrets-*.tar.gz minecraft-backup-*.tar.gz; do \
    sudo ls -1dt $(REPO)/$$pattern 2>/dev/null | tail -n +4 | sudo xargs -r rm -rf; \
  done
>@echo "Pruned backups older than the 3 most recent."

clean-all: clean-docker clean-apt clean-backups

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
>sudo cp $(REPO)/repo/setup/sysctl/99-jehpok.conf /etc/sysctl.d/99-jehpok.conf
>sudo sysctl --system >/dev/null
>@if ! diff -q /etc/docker/daemon.json $(REPO)/repo/setup/docker/daemon.json >/dev/null 2>&1; then \
    echo "Installing /etc/docker/daemon.json (Docker daemon restart required to take effect)."; \
    sudo mkdir -p /etc/docker; \
    sudo cp $(REPO)/repo/setup/docker/daemon.json /etc/docker/daemon.json; \
    echo "Run: sudo systemctl restart docker  (containers stay up via live-restore)."; \
  else \
    echo "Docker daemon config already up to date."; \
  fi
>sudo cp $(REPO)/repo/setup/maintenance/daily.sh /usr/local/bin/jehpok-daily.sh
>sudo chmod +x /usr/local/bin/jehpok-daily.sh
>sudo cp $(REPO)/repo/setup/maintenance/daily.service /etc/systemd/system/jehpok-daily.service
>sudo cp $(REPO)/repo/setup/maintenance/daily.timer /etc/systemd/system/jehpok-daily.timer
>sudo touch /var/log/jehpok-daily.log
>sudo chown debian:debian /var/log/jehpok-daily.log
>sudo cp $(REPO)/repo/setup/ttyd/ttyd.service /etc/systemd/system/ttyd.service
>mkdir -p $(REPO)/repo/.claude
>cp $(REPO)/repo/setup/claude/settings.local.json $(REPO)/repo/.claude/settings.local.json
>chmod 0644 $(REPO)/repo/.claude/settings.local.json
>sudo ufw allow from 172.22.0.0/16 to any port 7681 proto tcp
>sudo systemctl daemon-reload
>sudo systemctl enable --now ollama jehpok-daily.timer ttyd
>sudo systemctl restart sshd dnsmasq
>@echo "Host setup complete: ollama + ttyd + dnsmasq + sshd + daily timer enabled, Claude settings restored."

# ─────────────────────────────────────────────────────────────────────────────
# Backups
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: backup-cloud backup-share backup-vault backup-secrets backup-minecraft backup-all

backup-cloud:
>@dest=$(REPO)/cloud-backup-$$(date +%Y%m%d); \
  sudo mkdir -p "$$dest"; \
  sudo chown debian:debian "$$dest"; \
  docker exec -w /var/www/html cloud php occ maintenance:mode --on; \
  trap 'docker exec -w /var/www/html cloud php occ maintenance:mode --off' EXIT; \
  docker exec -i cloud tar cf - -C /data . | sudo tar xf - -C "$$dest"; \
  sudo chown -R 33:33 "$$dest"; \
  trap - EXIT; \
  docker exec -w /var/www/html cloud php occ maintenance:mode --off; \
  echo "Backup at $$dest"

backup-share:
>@sudo cp $(REPO)/share/db/links.db $(REPO)/share-backup-$$(date +%Y%m%d).db
>@echo "Backup at $(REPO)/share-backup-$$(date +%Y%m%d).db"

backup-vault:
>@sudo bash -c 'tar czf $(REPO)/vault-backup-$$(date +%Y%m%d).tar.gz -C $(REPO)/vault data'
>@echo "Backup at $(REPO)/vault-backup-$$(date +%Y%m%d).tar.gz"

backup-secrets:
>@sudo mkdir -p $(REPO)/secrets-backup
>@sudo tar czf $(REPO)/secrets-backup/secrets-$$(date +%Y%m%d).tar.gz \
  --warning=no-absolute-names \
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

# Snapshot just the Minecraft world data folder as a timestamped .tar.gz.
# Differs from `backup-all` (which snapshots everything): this one is for
# world data only, intended to be run before destructive ops (regenerate,
# world import) so a recovery path exists. Does NOT auto-run by itself.
# When run from `backup-all`, daily.sh stops the minecraft container first
# so tar reads a quiescent filesystem; running this standalone while the
# server is up is unsafe (regions may be partially written).
backup-minecraft:
>@dest=$(REPO)/minecraft-backup-$$(date +%Y%m%d-%H%M%S).tar.gz; \
  sudo tar czf "$$dest" -C $(REPO)/minecraft/data world; \
  sudo chown debian:debian "$$dest"; \
  echo "World backup at $$dest"

backup-all: backup-cloud backup-share backup-vault backup-secrets backup-minecraft

# ─────────────────────────────────────────────────────────────────────────────
# Migration
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: migrate

migrate:
>@cat $(REPO)/repo/docs/MIGRATE.md

# ─────────────────────────────────────────────────────────────────────────────
# Git
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: git-add git-commit git-push git-all

git-add:
>cd $(REPO)/repo && git add -A

git-commit:
>@if [ -z "$(MSG)" ]; then \
    echo "Usage: make git-commit MSG=\"...\"  (MSG is required)"; \
    exit 1; \
  fi
>cd $(REPO)/repo && git commit -m "$(MSG)"

git-push:
>cd $(REPO)/repo && git push jehpok.com main

# Bulk: stage + commit (MSG required) + push in one shot. Same as the
# old 'make push', kept as a shortcut for the common case.
git-all: git-add
>@if [ -z "$(MSG)" ]; then \
    echo "Usage: make git-all MSG=\"...\"  (MSG is required)"; \
    exit 1; \
  fi
>cd $(REPO)/repo && git commit -m "$(MSG)" && git push jehpok.com main

# ─────────────────────────────────────────────────────────────────────────────
# Help (default goal)
# ─────────────────────────────────────────────────────────────────────────────

.DEFAULT_GOAL := help
.PHONY: help

help:
>@echo ""
>@echo "  jehpok.com — make recipes"
>@echo ""
>@echo "  Docker Containers  (one of: $(SERVICES))"
>@echo "    make up-<svc>         force-recreate container (share also rebuilds)"
>@echo "    make restart-<svc>    reload container without recreating"
>@echo "    make logs-<svc>       follow container logs"
>@echo ""
>@echo "  Bulk"
>@echo "    make restart-all      restart all containers + dnsmasq + ttyd"
>@echo "    make up-all           recreate all containers in order"
>@echo "    make logs-all         tail all container logs in one stream"
>@echo "    make backup-all       run all five backup recipes in order (stops the mc container via daily.sh)"
>@echo "    make clean-all        chain: clean-docker + clean-apt + clean-backups"
>@echo "    make git-all MSG=\"…\"  stage + commit + push (shortcut for the 3 below)"
>@echo ""
>@echo "  Host services (systemd)"
>@echo "    make restart-ttyd     restart host ttyd"
>@echo "    make restart-dnsmasq  restart host dnsmasq"
>@echo "    make logs-ttyd        follow ttyd journal"
>@echo "    make logs-dnsmasq     follow dnsmasq journal"
>@echo ""
>@echo "  Git"
>@echo "    make git-add          git add -A in $(REPO)/repo"
>@echo "    make git-commit MSG=\"…\" git commit -m MSG (MSG required)"
>@echo "    make git-push         git push jehpok.com main"
>@echo ""
>@echo "  Maintenance"
>@echo "    make status           containers + host services + disk + memory"
>@echo "    make refresh          apt update/upgrade + pull images + up-all"
>@echo "    make setup            one-shot host bootstrap (configs, units, UFW, Claude)"
>@echo "    make migrate          cat docs/MIGRATE.md (full VPS-to-VPS runbook)"
>@echo ""
>@echo "  Backups"
>@echo "    make backup-cloud     Nextcloud snapshot (maintenance mode during copy)"
>@echo "    make backup-share     shortener SQLite DB"
>@echo "    make backup-vault     Vaultwarden data tar"
>@echo "    make backup-secrets   bundle certs + keys + Tailscale state"
>@echo "    make backup-minecraft Minecraft world tar (stops the container via daily.sh when chained)"
>@echo ""
>@echo "  Cleanup"
>@echo "    make clean-docker     prune builder / image / container"
>@echo "    make clean-apt        apt autoremove + clean"
>@echo "    make clean-backups    keep latest 3 backups per pattern, delete older"
>@echo ""
