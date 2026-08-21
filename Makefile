.RECIPEPREFIX = >
# Use bash explicitly so SHELLFLAGS go to bash, not /bin/sh (dash on Debian).
# Without this, `dash -eu -c '<recipe>'` runs the recipe with `set -eu` and
# bites any line that references an unset variable — see docs/GUIDE.md
# "Operational gotchas" for the symptom and the fix.
SHELL := /bin/bash
.SHELLFLAGS := -eu -c

REPO     := /var/www/custom/projects/jehpok
COMPOSE  := docker compose -f
CONTAINERS := vhosts homer ut-kuma share-flask nextcloud vaultwarden mc mc-flask
HOST     := ttyd dnsmasq ollama

# Per-container compose file map. Default is `services/<ctn>/docker-compose.yml`;
# overrides list each `<ctn>:path` for compose files that live alongside the
# default name (e.g. mc-flask's dashboard is in services/mc/docker-compose.mc-flask.yml
# so the game container and the dashboard can be recreated independently).
COMPOSE_FILES := mc-flask:services/mc/docker-compose.mc-flask.yml

# ─────────────────────────────────────────────────────────────────────────────
# Per-container: recreate / d-restart / d-logs
# `d-` prefix marks container (docker) actions so they don't collide
# visually with host systemd actions (restart-ttyd, restart-dnsmasq,
# logs-ttyd, logs-dnsmasq below).
# One set of rules, expanded across $(CONTAINERS).
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: $(addprefix recreate-,$(CONTAINERS)) recreate-all
.PHONY: $(addprefix d-restart-,$(CONTAINERS)) d-restart-all
.PHONY: $(addprefix d-logs-,$(CONTAINERS)) d-logs-all

# share-flask + vhosts (and mc-flask) rebuild their image locally; the rest just pull.
# share-flask = custom Dockerfile for the link shortener.
# vhosts = custom Dockerfile adds caddy-dns/cloudflare so the
#   mc.jehpok.com vhost can use ACME DNS-01 (HTTP-01 is blocked because
#   the game ports require CF proxy to stay off, but CF proxy is what
#   would carry the HTTP-01 challenge traffic from the public internet).
# mc-flask = custom Dockerfile for the Flask+rcon dashboard.

# Set per-container compose file paths. Default is `services/<ctn>/docker-compose.yml`;
# overrides from COMPOSE_FILES above take precedence.
$(foreach s,$(CONTAINERS),$(eval COMPOSE_FILE_$s := services/$s/docker-compose.yml))
$(foreach m,$(COMPOSE_FILES),$(eval COMPOSE_FILE_$(word 1,$(subst :, ,$(m))) := $(word 2,$(subst :, ,$(m)))))

# Helper: $(compose-file-of $1) returns the absolute compose file path for
# the named service. Recipes use this directly instead of $(COMPOSE_FILE_$1)
# so the expansion happens at recipe-expansion time, not recipe-execution time.
compose-file-of = $(REPO)/repo/$(COMPOSE_FILE_$1)

define recreate_rule
recreate-$1:
>$(COMPOSE) $(call compose-file-of,$1) up -d --force-recreate$(if $(filter share-flask vhosts mc-flask,$1), --build)
endef
$(foreach s,$(CONTAINERS),$(eval $(call recreate_rule,$s)))

define drestart_rule
d-restart-$1:
># Restart every container declared in this service's compose file. mc and
# mc-flask live in separate compose files now (see COMPOSE_FILES), so
# `d-restart-mc` only restarts the game server and `d-restart-mc-flask` only
# restarts the dashboard — no surprise side-effects on the other container.
>$(COMPOSE) $(call compose-file-of,$1) restart
endef
$(foreach s,$(CONTAINERS),$(eval $(call drestart_rule,$s)))

define dlogs_rule
d-logs-$1:
># Tail the container named after the service. mc + mc-flask have their own
# recipes (`d-logs-mc`, `d-logs-mc-flask`) since they live in separate compose
# files now; this generic rule only sees the primary container.
>docker logs $1 --tail 50 -f
endef
$(foreach s,$(CONTAINERS),$(eval $(call dlogs_rule,$s)))

recreate-all: $(addprefix recreate-,$(CONTAINERS))
d-restart-all: $(addprefix d-restart-,$(CONTAINERS)) restart-dnsmasq restart-ttyd

d-logs-all:
>@stdbuf -oL bash -c 'for c in $(CONTAINERS); do \
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

.PHONY: status clean-docker clean-apt clean-backups clean-all update install-config help

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
# The mc-backup pattern also matches the old minecraft-backup-* names so
# artifacts orphaned by the rename age out instead of accumulating forever.
# All backups live under $(REPO)/backups/ since the bkp-<src> recipes were
# moved there; pre-migration top-level artifacts were also moved there.
clean-backups:
>@for pattern in cloud-backup-* share-backup-*.db vault-backup-*.tar.gz secrets-bundle-*.tar.gz 'mc-backup-*.tar.gz minecraft-backup-*.tar.gz'; do \
    sudo ls -1dt $(REPO)/backups/$$pattern 2>/dev/null | tail -n +4 | sudo xargs -r rm -rf; \
  done
>@echo "Pruned backups older than the 3 most recent per pattern."

clean-all: clean-docker clean-apt clean-backups

# Pull every image that isn't built locally, then bring everything up.
update:
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

# ─────────────────────────────────────────────────────────────────────────────
# config/ (live <-> repo)
# config/ holds tracked copies of every host-level config. install-config
# pushes them to live.
# ─────────────────────────────────────────────────────────────────────────────

# One-shot bootstrap: install ttyd, copy config/ to live, enable units,
# restore Claude settings, open the UFW rule for ttyd. Idempotent.
install-config:
>@if ! command -v ttyd >/dev/null 2>&1; then \
    echo "Installing ttyd..."; \
    curl -fsSL -o /tmp/ttyd.tar.gz https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.x86_64-linux-gnu-static.tar.gz; \
    tar xzf /tmp/ttyd.tar.gz -C /tmp ttyd; \
    sudo install -m 0755 /tmp/ttyd /usr/local/bin/ttyd; \
    rm -f /tmp/ttyd /tmp/ttyd.tar.gz; \
  else \
    echo "ttyd already installed at $$(command -v ttyd)"; \
  fi
>sudo cp $(REPO)/repo/config/ollama/ollama.service /etc/systemd/system/ollama.service
>sudo cp $(REPO)/repo/config/ssh/50-cloud-init.conf /etc/ssh/sshd_config.d/50-cloud-init.conf
>sudo cp $(REPO)/repo/config/dnsmasq/10-tailnet.conf /etc/dnsmasq.d/10-tailnet.conf
>sudo mkdir -p /etc/systemd/system/dnsmasq.service.d
>sudo cp $(REPO)/repo/config/dnsmasq/dnsmasq.service.conf /etc/systemd/system/dnsmasq.service.d/override.conf
>sudo cp $(REPO)/repo/config/sysctl/99-jehpok.conf /etc/sysctl.d/99-jehpok.conf
>sudo sysctl --system >/dev/null
>@if ! diff -q /etc/docker/daemon.json $(REPO)/repo/config/docker/daemon.json >/dev/null 2>&1; then \
    echo "Installing /etc/docker/daemon.json (Docker daemon restart required to take effect)."; \
    sudo mkdir -p /etc/docker; \
    sudo cp $(REPO)/repo/config/docker/daemon.json /etc/docker/daemon.json; \
    echo "Run: sudo systemctl restart docker  (containers stay up via live-restore)."; \
  else \
    echo "Docker daemon config already up to date."; \
  fi
>sudo cp $(REPO)/repo/config/maintenance/daily.sh /usr/local/bin/jehpok-daily.sh
>sudo chmod +x /usr/local/bin/jehpok-daily.sh
>sudo cp $(REPO)/repo/config/maintenance/daily.service /etc/systemd/system/jehpok-daily.service
>sudo cp $(REPO)/repo/config/maintenance/daily.timer /etc/systemd/system/jehpok-daily.timer
>sudo touch /var/log/jehpok-daily.log
>sudo chown debian:debian /var/log/jehpok-daily.log
>sudo cp $(REPO)/repo/config/ttyd/ttyd.service /etc/systemd/system/ttyd.service
>mkdir -p $(REPO)/repo/.claude
>cp $(REPO)/repo/config/claude/settings.local.json $(REPO)/repo/.claude/settings.local.json
>chmod 0644 $(REPO)/repo/.claude/settings.local.json
>sudo ufw allow from 172.22.0.0/16 to any port 7681 proto tcp
>sudo systemctl daemon-reload
>sudo systemctl enable --now ollama jehpok-daily.timer ttyd
>sudo systemctl restart sshd dnsmasq
>@echo "Host install-config complete: ollama + ttyd + dnsmasq + sshd + daily timer enabled, Claude settings restored."

# ─────────────────────────────────────────────────────────────────────────────
# Per-file install (config/<file> → live path)
# One-file sync when install-config's blanket copy is more than needed.
# Each recipe just copies + applies any post-step (daemon-reload, restart,
# chmod). Run `systemctl daemon-reload` manually if you stack systemd
# units in one batch and want one reload at the end.
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: install-ollama install-ttyd install-ssh \
        install-dnsmasq-conf install-dnsmasq-override \
        install-docker install-sysctl \
        install-daily-sh install-daily-service install-daily-timer \
        install-claude

install-ollama:
>@echo "install-ollama: ollama.service"
>@sudo cp $(REPO)/repo/config/ollama/ollama.service /etc/systemd/system/ollama.service
>@sudo systemctl daemon-reload
>@sudo systemctl restart ollama

install-ttyd:
>@echo "install-ttyd: ttyd.service"
>@sudo cp $(REPO)/repo/config/ttyd/ttyd.service /etc/systemd/system/ttyd.service
>@sudo systemctl daemon-reload
>@sudo systemctl restart ttyd

install-ssh:
>@echo "install-ssh: 50-cloud-init.conf"
>@sudo cp $(REPO)/repo/config/ssh/50-cloud-init.conf /etc/ssh/sshd_config.d/50-cloud-init.conf
>@sudo sshd -t && sudo systemctl restart sshd

install-dnsmasq-conf:
>@echo "install-dnsmasq-conf: 10-tailnet.conf"
>@sudo cp $(REPO)/repo/config/dnsmasq/10-tailnet.conf /etc/dnsmasq.d/10-tailnet.conf
>@sudo systemctl restart dnsmasq

install-dnsmasq-override:
>@echo "install-dnsmasq-override: dnsmasq.service.d/override.conf"
>@sudo mkdir -p /etc/systemd/system/dnsmasq.service.d
>@sudo cp $(REPO)/repo/config/dnsmasq/dnsmasq.service.conf /etc/systemd/system/dnsmasq.service.d/override.conf
>@sudo systemctl daemon-reload
>@sudo systemctl restart dnsmasq

install-docker:
>@echo "install-docker: /etc/docker/daemon.json (Docker daemon restart required)"
>@sudo mkdir -p /etc/docker
>@sudo cp $(REPO)/repo/config/docker/daemon.json /etc/docker/daemon.json
>@echo "Run: sudo systemctl restart docker  (containers stay up via live-restore)."

install-sysctl:
>@echo "install-sysctl: 99-jehpok.conf"
>@sudo cp $(REPO)/repo/config/sysctl/99-jehpok.conf /etc/sysctl.d/99-jehpok.conf
>@sudo sysctl --system >/dev/null

install-daily-sh:
>@echo "install-daily-sh: /usr/local/bin/jehpok-daily.sh"
>@sudo cp $(REPO)/repo/config/maintenance/daily.sh /usr/local/bin/jehpok-daily.sh
>@sudo chmod +x /usr/local/bin/jehpok-daily.sh

install-daily-service:
>@echo "install-daily-service: jehpok-daily.service"
>@sudo cp $(REPO)/repo/config/maintenance/daily.service /etc/systemd/system/jehpok-daily.service
>@sudo systemctl daemon-reload

install-daily-timer:
>@echo "install-daily-timer: jehpok-daily.timer"
>@sudo cp $(REPO)/repo/config/maintenance/daily.timer /etc/systemd/system/jehpok-daily.timer
>@sudo systemctl daemon-reload
>@sudo systemctl enable --now jehpok-daily.timer

install-claude:
>@echo "install-claude: .claude/settings.local.json"
>@mkdir -p $(REPO)/repo/.claude
>@cp $(REPO)/repo/config/claude/settings.local.json $(REPO)/repo/.claude/settings.local.json
>@chmod 0644 $(REPO)/repo/.claude/settings.local.json

# ─────────────────────────────────────────────────────────────────────────────
# Bundles (live <-> tarball)
# bundle-secrets collects live secrets into a tar.gz; install-secrets
# extracts one back over the live paths. bundle-config snapshots the
# whole config/ tree into a tarball — useful as an offline copy when
# moving to a fresh host that doesn't have the repo cloned yet (the
# git-tracked copy is the canonical one when the repo is present).
# Neither chained into bkp-all — both need a deliberate operator
# decision each time.
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: bundle-secrets install-secrets bundle-config install-config-bundle

bundle-secrets:
>@dest=$(BKP_DIR)/secrets-bundle-$$(date +%Y%m%d).tar.gz; \
  sudo mkdir -p "$(BKP_DIR)"; \
  sudo tar czf "$$dest" \
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
>@echo "Secrets bundle at $$dest"

# Extract a secrets bundle tar.gz to the live paths. Defaults to the
# newest secrets-bundle-*.tar.gz under $(BKP_DIR); override with BUNDLE=<path>.
install-secrets:
>@if [ -z "$(BUNDLE)" ]; then \
    BUNDLE="$$(ls -1t $(BKP_DIR)/secrets-bundle-*.tar.gz 2>/dev/null | head -1)"; \
    if [ -z "$$BUNDLE" ]; then \
      echo "No secrets-bundle-*.tar.gz found in $(BKP_DIR)."; \
      exit 1; \
    fi; \
    echo "Using latest bundle: $$BUNDLE"; \
  fi
>sudo tar xzf "$$BUNDLE" -C / --warning=no-absolute-names
>@echo "Installed $$BUNDLE to live paths."

# Snapshot the whole config/ tree into a single tarball under backups/.
# The git-tracked copy is canonical when the repo is present; this
# exists for offline handoff (cold VPS, no clone yet). Symmetric to
# bundle-secrets: collect → tarball; install-config-bundle → extract.
bundle-config:
>@dest=$(BKP_DIR)/config-bundle-$$(date +%Y%m%d).tar.gz; \
  sudo mkdir -p "$(BKP_DIR)"; \
  sudo tar czf "$$dest" -C $(REPO)/repo config; \
  sudo chown debian:debian "$$dest"; \
  echo "Config bundle at $$dest"

# Extract a config bundle tarball over $(REPO)/repo/config/. Defaults
# to the newest config-bundle-*.tar.gz under $(BKP_DIR); override with
# BUNDLE=<path>. Use when bootstrapping a fresh host: clone the repo
# (or just create the dir), then `make install-config-bundle` to
# populate config/ before running `make install-config`.
install-config-bundle:
>@if [ -z "$(BUNDLE)" ]; then \
    BUNDLE="$$(ls -1t $(BKP_DIR)/config-bundle-*.tar.gz 2>/dev/null | head -1)"; \
    if [ -z "$$BUNDLE" ]; then \
      echo "No config-bundle-*.tar.gz found in $(BKP_DIR)."; \
      exit 1; \
    fi; \
    echo "Using latest bundle: $$BUNDLE"; \
  fi
>@if [ ! -d "$(REPO)/repo" ]; then \
    echo "$(REPO)/repo does not exist. Create it first (clone the repo, or mkdir)."; \
    exit 1; \
  fi
>@tar xzf "$$BUNDLE" -C $(REPO)/repo
>@echo "Installed $$BUNDLE into $(REPO)/repo/config/"

# ─────────────────────────────────────────────────────────────────────────────
# Backups (rename: backup-* → bkp-*)
# bkp-all chains the four bkp-* recipes in order (no bundle-secrets —
# secrets need a deliberate decision).
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: bkp-cloud bkp-share bkp-vault bkp-mc bkp-all bkp-list

# All bkp-* recipes write under $(REPO)/backups/. bkp-list enumerates that
# dir so the operator has one place to see what's been snapshotted.
BKP_DIR := $(REPO)/backups

bkp-cloud:
>@dest=$(BKP_DIR)/cloud-backup-$$(date +%Y%m%d-%H%M%S); \
  sudo mkdir -p "$(BKP_DIR)" "$$dest"; \
  sudo chown debian:debian "$$dest"; \
  docker exec -w /var/www/html nextcloud php occ maintenance:mode --on; \
  trap 'docker exec -w /var/www/html nextcloud php occ maintenance:mode --off' EXIT; \
  docker exec -i nextcloud tar cf - -C /data . | sudo tar xf - -C "$$dest"; \
  sudo chown -R 33:33 "$$dest"; \
  trap - EXIT; \
  docker exec -w /var/www/html nextcloud php occ maintenance:mode --off; \
  echo "Backup at $$dest"

bkp-share:
>@sudo mkdir -p "$(BKP_DIR)"; \
  sudo cp $(REPO)/share/db/links.db $(BKP_DIR)/share-backup-$$(date +%Y%m%d-%H%M%S).db
>@echo "Backup at $(BKP_DIR)/share-backup-$$(date +%Y%m%d-%H%M%S).db"

bkp-vault:
>@sudo mkdir -p "$(BKP_DIR)"; \
  sudo bash -c 'tar czf $(BKP_DIR)/vault-backup-$$(date +%Y%m%d-%H%M%S).tar.gz -C $(REPO)/vault data'
>@echo "Backup at $(BKP_DIR)/vault-backup-$$(date +%Y%m%d-%H%M%S).tar.gz"

# Snapshot just the Minecraft world data folder as a timestamped .tar.gz.
# Differs from `bkp-all` (which snapshots everything): this one is for
# world data only, intended to be run before destructive ops (regenerate,
# world import) so a recovery path exists. Does NOT auto-run by itself.
# When run from `bkp-all`, daily.sh stops the mc container first
# so tar reads a quiescent filesystem; running this standalone while the
# server is up is unsafe (regions may be partially written).
bkp-mc:
>@dest=$(BKP_DIR)/mc-backup-$$(date +%Y%m%d-%H%M%S).tar.gz; \
  sudo mkdir -p "$(BKP_DIR)"; \
  sudo tar czf "$$dest" -C $(REPO)/mc/data world; \
  sudo chown debian:debian "$$dest"; \
  echo "World backup at $$dest"

bkp-all: bkp-cloud bkp-share bkp-vault bkp-mc

# Show every backup artifact currently on disk, newest first. Includes
# secrets bundles — the names/contents are not enumerated, just listed.
bkp-list:
>@if [ ! -d "$(BKP_DIR)" ]; then \
    echo "$(BKP_DIR) does not exist yet. Run any bkp-* recipe first."; \
    exit 0; \
  fi
>@ls -lht "$(BKP_DIR)" 2>&1
>@echo ""
>@echo "Counts per pattern:"
# Use -1d so directory matches (cloud-backup-*) are counted alongside files.
# Without -d, `ls -1 <dir>` returns the directory itself as a single entry
# (and `wc -l` then counts 0), so cloud backups silently disappear from the
# count even though the directory is sitting on disk.
>@for p in cloud-backup-* share-backup-*.db vault-backup-*.tar.gz secrets-bundle-*.tar.gz config-bundle-*.tar.gz 'mc-backup-*.tar.gz minecraft-backup-*.tar.gz'; do \
    n="$$(ls -1d $(BKP_DIR)/$$p 2>/dev/null | wc -l)"; \
    printf "  %-45s %d\n" "$$p" "$$n"; \
  done

# ─────────────────────────────────────────────────────────────────────────────
# Tmux sessions
# Persistent terminal sessions on the host — detach (Ctrl-b d) and the
# shell + whatever's running inside it stays alive; reattach from any
# terminal with `make tmux-open NAME=<n>` (or `tmux attach -t <n>`).
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: tmux-new tmux-open tmux-kill tmux-list

tmux-new:
>@if [ -z "$(NAME)" ]; then \
    echo "Usage: make tmux-new NAME=<session>   (NAME is required)"; \
    exit 1; \
  fi
>@if tmux has-session -t "$(NAME)" 2>/dev/null; then \
    echo "Session '$(NAME)' already exists. Attach with: make tmux-open NAME=$(NAME)"; \
    exit 1; \
  fi
>@tmux new -s "$(NAME)" -d
>@echo "Created detached session '$(NAME)'. Attach with: make tmux-open NAME=$(NAME)"
>@echo "  (or: tmux attach -t $(NAME))"

tmux-open:
>@if [ -z "$(NAME)" ]; then \
    echo "Usage: make tmux-open NAME=<session>"; \
    exit 1; \
  fi
>@tmux attach -t "$(NAME)"

tmux-kill:
>@if [ -z "$(NAME)" ]; then \
    echo "Usage: make tmux-kill NAME=<session>"; \
    exit 1; \
  fi
>@tmux kill-session -t "$(NAME)"
>@echo "Killed session '$(NAME)'"

tmux-list:
>@tmux ls

# ─────────────────────────────────────────────────────────────────────────────
# Migration
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: migrate

migrate:
>@cat $(REPO)/repo/docs/MIGRATE.md

# ─────────────────────────────────────────────────────────────────────────────
# Git
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: git-add git-com git-push git-all

git-add:
>cd $(REPO)/repo && git add -A

git-com:
>@if [ -z "$(MSG)" ]; then \
    echo "Usage: make git-com MSG=\"...\"  (MSG is required)"; \
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
>@echo "  Docker containers  (one of: $(CONTAINERS))"
>@echo "    make recreate-<ctn>   force-recreate container (share-flask, vhosts, mc-flask rebuild)"
>@echo "    make d-restart-<ctn>  reload container without recreating"
>@echo "    make d-logs-<ctn>     follow container logs"
>@echo ""
>@echo "  Bulk"
>@echo "    make d-restart-all    restart all containers + dnsmasq + ttyd"
>@echo "    make recreate-all     recreate all containers in order"
>@echo "    make d-logs-all       tail all container logs in one stream"
>@echo "    make bkp-all          run all four bkp-* recipes (no bundle-secrets)"
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
>@echo "    make git-com MSG=\"…\"  git commit -m MSG (MSG required)"
>@echo "    make git-push         git push jehpok.com main"
>@echo ""
>@echo "  Maintenance"
>@echo "    make status           containers + host services + disk + memory"
>@echo "    make update           apt update/upgrade + pull images + recreate-all"
>@echo "    make install-config   copy all of config/ to live"
>@echo "    make migrate          cat docs/MIGRATE.md (full VPS-to-VPS runbook)"
>@echo ""
>@echo "  Per-file install (one file from config/ → live)"
>@echo "    make install-ollama             /etc/systemd/system/ollama.service"
>@echo "    make install-ttyd               /etc/systemd/system/ttyd.service"
>@echo "    make install-ssh                /etc/ssh/sshd_config.d/50-cloud-init.conf"
>@echo "    make install-dnsmasq-conf       /etc/dnsmasq.d/10-tailnet.conf"
>@echo "    make install-dnsmasq-override   /etc/systemd/system/dnsmasq.service.d/override.conf"
>@echo "    make install-docker             /etc/docker/daemon.json (restart docker to apply)"
>@echo "    make install-sysctl             /etc/sysctl.d/99-jehpok.conf"
>@echo "    make install-daily-sh           /usr/local/bin/jehpok-daily.sh"
>@echo "    make install-daily-service      /etc/systemd/system/jehpok-daily.service"
>@echo "    make install-daily-timer        /etc/systemd/system/jehpok-daily.timer"
>@echo "    make install-claude             \$$REPO/repo/.claude/settings.local.json"
>@echo ""
>@echo "  Backups (bkp-*) — all artifacts land in \$$REPO/backups/"
>@echo "    make bkp-cloud        Nextcloud snapshot (maintenance mode during copy)"
>@echo "    make bkp-share        shortener SQLite DB"
>@echo "    make bkp-vault        Vaultwarden data tar"
>@echo "    make bkp-mc           Minecraft world tar (stops the container via daily.sh when chained)"
>@echo "    make bkp-list         list every artifact under \$$REPO/backups/ + count per pattern"
>@echo ""
>@echo "  Bundles"
>@echo "    make bundle-secrets   collect live secrets into \$$REPO/backups/secrets-bundle-<date>.tar.gz"
>@echo "    make install-secrets  extract a secrets bundle to live paths (BUNDLE=<path> to override)"
>@echo "    make bundle-config    snapshot \$$REPO/repo/config/ into \$$REPO/backups/config-bundle-<date>.tar.gz"
>@echo "    make install-config-bundle  extract a config bundle into \$$REPO/repo/config/ (BUNDLE=<path> to override)"
>@echo ""
>@echo "  Tmux sessions"
>@echo "    make tmux-new NAME=<n>    create detached session <n>"
>@echo "    make tmux-open NAME=<n>   attach to session <n> (Ctrl-b d to detach)"
>@echo "    make tmux-kill NAME=<n>   kill session <n>"
>@echo "    make tmux-list            list sessions"
>@echo ""
>@echo "  Cleanup"
>@echo "    make clean-docker     prune builder / image / container"
>@echo "    make clean-apt        apt autoremove + clean"
>@echo "    make clean-backups    keep latest 3 per pattern, delete older"
>@echo ""