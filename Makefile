.RECIPEPREFIX = >
# Use bash explicitly so SHELLFLAGS go to bash, not /bin/sh (dash on Debian).
# Without this, `dash -eu -c '<recipe>'` runs the recipe with `set -eu` and
# bites any line that references an unset variable — see docs/GUIDE.md
# "Operational gotchas" for the symptom and the fix.
SHELL := /bin/bash
.SHELLFLAGS := -eu -c

REPO     := /var/www/custom/projects/homelab
COMPOSE  := docker compose -f
CONTAINERS := fxmq.net uptimekuma nextcloud vaultwarden pufferpanel mailserver roundcube
HOST     := ttyd dnsmasq goose

# ─────────────────────────────────────────────────────────────────────────────
# Docker containers: dok-<action>-<ctn>
# `dok-` prefix marks container (docker) actions so they don't collide
# visually with host systemd actions (systemd-restart/systemd-log below).
# One set of rules, expanded across $(CONTAINERS); append -<ctn> for one
# container, -all for every container. mailserver and roundcube share one
# compose file (services/mailserver/docker-compose.yml), so a compose-unit
# action on either affects both.
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: $(addprefix dok-recreate-,$(CONTAINERS)) dok-recreate-all dok-recreate
.PHONY: $(addprefix dok-restart-,$(CONTAINERS)) dok-restart-all dok-restart
.PHONY: $(addprefix dok-stop-,$(CONTAINERS)) dok-stop-all dok-stop
.PHONY: $(addprefix dok-logs-,$(CONTAINERS)) dok-logs-all dok-logs

# fxmq.net (Caddy) rebuilds its image locally; the rest just pull.
# fxmq.net = custom Dockerfile adds caddy-dns/cloudflare for ACME DNS-01
#   on every vhost; DNS-01 keeps cert issuance independent of the proxy.

# Per-container compose file paths: services/<ctn>/docker-compose.yml.
# roundcube lives in the mailserver compose file (no own compose).
$(foreach s,$(CONTAINERS),$(eval COMPOSE_FILE_$s := services/$s/docker-compose.yml))
COMPOSE_FILE_roundcube := services/mailserver/docker-compose.yml

# Helper: $(compose-file-of $1) returns the absolute compose file path for
# the named service. Recipes use this directly instead of $(COMPOSE_FILE_$1)
# so the expansion happens at recipe-expansion time, not recipe-execution time.
compose-file-of = $(REPO)/repo/$(COMPOSE_FILE_$1)

# fxmq.net needs a local image build; compose v5.5.0 on Debian trixie ships
# buildx 0.13.1, which is too old for `compose ... --build` (needs >= 0.17).
# Try the compose build first and fall back to plain `docker build` + compose
# up (the install.sh pattern) so `make dok-recreate-fxmq.net` works everywhere.
define dok_recreate_rule
dok-recreate-$1:
>@if [ "$1" = "fxmq.net" ]; then \
    if ! $(COMPOSE) $(call compose-file-of,$1) up -d --force-recreate --build; then \
      echo "compose build unavailable (buildx < 0.17 on trixie) — falling back to docker build + compose up"; \
      docker build -t fxmq.net:local $(REPO)/repo/services/fxmq.net \
        && $(COMPOSE) $(call compose-file-of,$1) up -d --force-recreate; \
    fi; \
  else \
    $(COMPOSE) $(call compose-file-of,$1) up -d --force-recreate; \
  fi
endef
$(foreach s,$(CONTAINERS),$(eval $(call dok_recreate_rule,$s)))

define dok_restart_rule
dok-restart-$1:
># Restart every container declared in this service's compose file.
>$(COMPOSE) $(call compose-file-of,$1) restart
endef
$(foreach s,$(CONTAINERS),$(eval $(call dok_restart_rule,$s)))

define dok_stop_rule
dok-stop-$1:
>$(COMPOSE) $(call compose-file-of,$1) stop
endef
$(foreach s,$(CONTAINERS),$(eval $(call dok_stop_rule,$s)))

define dok_logs_rule
dok-logs-$1:
># Tail the container named after the service.
>docker logs $1 --tail 50 -f
endef
$(foreach s,$(CONTAINERS),$(eval $(call dok_logs_rule,$s)))

# Shared loop: force-recreate every compose unit under services/ (fxmq.net
# builds locally, with the buildx fallback). Used by dok-recreate-all and
# update — each keeps a self-contained recipe (no chained make targets).
define dok_recreate_all_cmds
@for f in $(REPO)/repo/services/*/docker-compose.yml; do \
    if [ "$$f" = "$(REPO)/repo/services/fxmq.net/docker-compose.yml" ]; then \
      if ! $(COMPOSE) "$$f" up -d --force-recreate --build; then \
        echo "compose build unavailable (buildx < 0.17 on trixie) — falling back to docker build + compose up"; \
        docker build -t fxmq.net:local $(REPO)/repo/services/fxmq.net \
          && $(COMPOSE) "$$f" up -d --force-recreate; \
      fi; \
    else \
      $(COMPOSE) "$$f" up -d --force-recreate; \
    fi; \
  done
endef

dok-recreate-all:
>$(dok_recreate_all_cmds)

dok-restart-all:
>@for f in $(REPO)/repo/services/*/docker-compose.yml; do \
    $(COMPOSE) "$$f" restart; \
  done

dok-stop-all:
>@for f in $(REPO)/repo/services/*/docker-compose.yml; do \
    $(COMPOSE) "$$f" stop; \
  done

dok-logs-all:
>@stdbuf -oL bash -c 'for c in $(CONTAINERS); do \
    docker logs $$c --tail 50 -f 2>&1 | stdbuf -oL sed "s/^/[$$c] /" & \
  done; wait'

dok-recreate:
>@echo "Usage: make dok-recreate-<ctn>  (one of: $(CONTAINERS))"
>@echo "       make dok-recreate-all"
dok-restart:
>@echo "Usage: make dok-restart-<ctn>  (one of: $(CONTAINERS))"
>@echo "       make dok-restart-all"
dok-stop:
>@echo "Usage: make dok-stop-<ctn>  (one of: $(CONTAINERS))"
>@echo "       make dok-stop-all"
dok-logs:
>@echo "Usage: make dok-logs-<ctn>  (one of: $(CONTAINERS))"
>@echo "       make dok-logs-all"

# ─────────────────────────────────────────────────────────────────────────────
# Host services (systemd): systemd-restart / systemd-log
# Append -<svc> for one service (one of: $(HOST)) or -all for every service.
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: $(addprefix systemd-restart-,$(HOST)) systemd-restart-all systemd-restart
.PHONY: $(addprefix systemd-log-,$(HOST)) systemd-log-all systemd-log

define systemd_restart_rule
systemd-restart-$1:
>sudo systemctl restart $1
endef
$(foreach s,$(HOST),$(eval $(call systemd_restart_rule,$s)))

define systemd_log_rule
systemd-log-$1:
>sudo journalctl -u $1 -n 50 -f
endef
$(foreach s,$(HOST),$(eval $(call systemd_log_rule,$s)))

systemd-restart-all:
>sudo systemctl restart $(HOST)

systemd-log-all:
>@stdbuf -oL bash -c 'for u in $(HOST); do \
    sudo journalctl -u $$u -n 50 -f 2>&1 | stdbuf -oL sed "s/^/[$$u] /" & \
  done; wait'

systemd-restart:
>@echo "Usage: make systemd-restart-<svc>  (one of: $(HOST))"
>@echo "       make systemd-restart-all"
systemd-log:
>@echo "Usage: make systemd-log-<svc>  (one of: $(HOST))"
>@echo "       make systemd-log-all"

# ─────────────────────────────────────────────────────────────────────────────
# Maintenance
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: status smoke install-hooks clean-docker clean-apt clean-backups update install-config kuma-import help
.PHONY: deploy backup cleanup

# One-shot overview per the help line: git; systemd; docker; tmux; backups; mails.
status:
>@echo "--- git ---"
>@cd $(REPO)/repo && git status -sb
>@echo ""
>@echo "--- systemd services ---"
>@for u in $(HOST); do printf "  %-30s %s\n" "$$u" "$$(systemctl is-active $$u)"; done
>@echo ""
>@echo "--- containers ---"
>@docker ps --format 'table {{.Names}}\t{{.Status}}'
>@echo ""
>@echo "--- tmux sessions ---"
>@tmux ls 2>/dev/null || echo "  (none)"
>@echo ""
>@echo "--- backups ---"
>@if [ -d "$(REPO)/backups" ]; then ls -1t "$(REPO)/backups" | head -10; else echo "  (none yet — run make backup)"; fi
>@echo ""
>@echo "--- mailboxes ---"
>@docker exec mailserver setup email list 2>/dev/null || echo "  (mailserver not running)"

# Shared bodies for the granular clean-* recipes. cleanup is the umbrella
# recipe and inlines all three bodies — no chained make targets.
define clean_docker_cmds
@docker builder prune -af
@docker image prune -af
@docker container prune -f
endef

define clean_apt_cmds
@sudo apt-get -qq autoremove -y
@sudo apt-get clean
endef

define clean_backups_cmds
@for pattern in cloud-backup-* share-backup-*.db vault-backup-*.tar.gz secrets-bundle-*.tar.gz 'mc-backup-*.tar.gz minecraft-backup-*.tar.gz'; do \
    sudo ls -1dt $(REPO)/backups/$$pattern 2>/dev/null | tail -n +4 | sudo xargs -r rm -rf; \
  done
@echo "Pruned backups older than the 3 most recent per pattern."
endef

clean-docker:
>$(clean_docker_cmds)

clean-apt:
>$(clean_apt_cmds)

clean-backups:
>$(clean_backups_cmds)

# Help-line umbrella: apt autoremove+clean; docker prune builder/images/
# containers; backups keep latest 3 per pattern. Self-contained recipe.
cleanup:
>$(clean_docker_cmds)
>$(clean_apt_cmds)
>$(clean_backups_cmds)

# Pull every image that isn't built locally, then bring everything up
# (self-contained: no sub-make, the recreate loop is inline).
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
>$(dok_recreate_all_cmds)

# Live edge smoke test — every vhost must serve its real app (see
# scripts/smoke-vhosts.sh). Run after any services/fxmq.net/ change or
# `docker restart fxmq.net`. The pre-push hook runs this automatically.
smoke:
>@bash scripts/smoke-vhosts.sh

# Install the repo's git hooks (pre-commit: Caddy validate + app-vhost stub
# guard; pre-push: live vhost smoke test). Re-run after cloning.
install-hooks:
>@mkdir -p .git/hooks
>@cp scripts/hooks/pre-commit scripts/hooks/pre-push .git/hooks/
>@chmod +x .git/hooks/pre-commit .git/hooks/pre-push
>@echo "Installed git hooks: pre-commit (Caddy validate + app-vhost stub guard), pre-push (live vhost smoke)."

# ─────────────────────────────────────────────────────────────────────────────
# Mail accounts (Docker Mailserver CLI). USER=<addr> required; add/passwd
# prompt via `read -s` so the password never lands in shell history or the
# process list. Friends log in at https://mail.fxmq.net with just the local
# part (ROUNDCUBEMAIL_USERNAME_DOMAIN=fxmq.net).
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: mail-add-user mail-passwd mail-del-user mail-list-users mail-gen mail-alias-gen mail-alias-del mail-alias-list

mail-add-user:
>@[ -n "$(USER)" ] || { echo "Usage: make mail-add-user USER=name@fxmq.net"; exit 1; }
>@read -s -p "Password for $(USER): " pass; echo; \
  docker exec mailserver setup email add "$(USER)" "$$pass"

mail-passwd:
>@[ -n "$(USER)" ] || { echo "Usage: make mail-passwd USER=name@fxmq.net"; exit 1; }
>@read -s -p "New password for $(USER): " pass; echo; \
  docker exec mailserver setup email update "$(USER)" "$$pass"

mail-del-user:
>@[ -n "$(USER)" ] || { echo "Usage: make mail-del-user USER=name@fxmq.net"; exit 1; }
>@docker exec mailserver setup email del "$(USER)"

mail-list-users:
>@docker exec mailserver setup email list

# Disposable mailbox: random 7-letter local part + random 16-char password
# (see scripts/mail-gen.sh). Local part is always generated — no custom
# names. Credentials printed once, stored nowhere.
mail-gen:
>@bash scripts/mail-gen.sh

# Disposable forwarding alias: random 7-digit local part forwarding to TO
# (see scripts/mail-alias-gen.sh). No mailbox is consumed; delete with
# mail-alias-del (needs ALIAS + TO).
mail-alias-gen:
>@[ -n "$(TO)" ] || { echo "Usage: make mail-alias-gen TO=target@example.com"; exit 1; }
>@bash scripts/mail-alias-gen.sh "$(TO)"

mail-alias-del:
>@[ -n "$(ALIAS)" ] && [ -n "$(TO)" ] || { echo "Usage: make mail-alias-del ALIAS=x@fxmq.net TO=target@example.com"; exit 1; }
>@docker exec mailserver setup alias del "$(ALIAS)" "$(TO)"

mail-alias-list:
>@docker exec mailserver setup alias list

# Import an adapted Uptime Kuma db from another host (KUMA_DB=/path).
kuma-import:
>sudo scripts/kuma-import.sh $(KUMA_DB)

# ─────────────────────────────────────────────────────────────────────────────
# config/ (live <-> repo)
# config/ holds tracked copies of every host-level config. install-config
# pushes them to live.
# ─────────────────────────────────────────────────────────────────────────────

# Shared body: push config/ → live (install-config). deploy inlines this
# body plus the secrets extraction so it never chains another make target.
define install_config_cmds
@if ! command -v ttyd >/dev/null 2>&1; then \
    echo "Installing ttyd..."; \
    curl -fsSL -o /tmp/ttyd https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.x86_64; \
    chmod +x /tmp/ttyd; \
    sudo install -m 0755 /tmp/ttyd /usr/local/bin/ttyd; \
    rm -f /tmp/ttyd; \
  else \
    echo "ttyd already installed at $$(command -v ttyd)"; \
  fi
sudo cp $(REPO)/repo/config/goose/goose.service /etc/systemd/system/goose.service
sudo cp $(REPO)/repo/config/ssh/50-cloud-init.conf /etc/ssh/sshd_config.d/50-cloud-init.conf
sudo cp $(REPO)/repo/config/dnsmasq/10-tailnet.conf /etc/dnsmasq.d/10-tailnet.conf
sudo mkdir -p /etc/systemd/system/dnsmasq.service.d
sudo cp $(REPO)/repo/config/dnsmasq/dnsmasq.service.conf /etc/systemd/system/dnsmasq.service.d/override.conf
sudo cp $(REPO)/repo/config/sysctl/99-homelab.conf /etc/sysctl.d/99-homelab.conf
sudo sysctl --system >/dev/null
@if ! diff -q /etc/docker/daemon.json $(REPO)/repo/config/docker/daemon.json >/dev/null 2>&1; then \
    echo "Installing /etc/docker/daemon.json (Docker daemon restart required to take effect)."; \
    sudo mkdir -p /etc/docker; \
    sudo cp $(REPO)/repo/config/docker/daemon.json /etc/docker/daemon.json; \
    echo "Run: sudo systemctl restart docker  (containers stay up via live-restore)."; \
  else \
    echo "Docker daemon config already up to date."; \
  fi
sudo cp $(REPO)/repo/config/ttyd/ttyd.service /etc/systemd/system/ttyd.service
sudo cp $(REPO)/repo/config/fail2ban/jail.d/sshd.conf /etc/fail2ban/jail.d/sshd.conf
sudo systemctl enable --now fail2ban
sudo ufw allow from 172.22.0.0/16 to any port 7681 proto tcp
sudo systemctl daemon-reload
sudo systemctl enable --now goose ttyd
sudo systemctl restart sshd dnsmasq
@echo "Host install-config complete: goose + ttyd + dnsmasq + fail2ban + sshd enabled."
endef

install-config:
>$(install_config_cmds)

# Help-line name for a full restore: config/ → live + the latest secrets
# bundle → live. Self-contained recipe; fails with a clear message if no
# secrets-bundle-*.tar.gz exists yet.
deploy:
>$(install_config_cmds)
>$(install_secrets_cmds)

# ─────────────────────────────────────────────────────────────────────────────
# Per-file install (config/<file> → live path)
# One-file sync when install-config's blanket copy is more than needed.
# Each recipe just copies + applies any post-step (daemon-reload, restart,
# chmod). Run `systemctl daemon-reload` manually if you stack systemd
# units in one batch and want one reload at the end.
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: install-goose install-ttyd install-ssh \
        install-dnsmasq-conf install-dnsmasq-override \
        install-docker install-sysctl

install-goose:
>@echo "install-goose: goose.service"
>@sudo cp $(REPO)/repo/config/goose/goose.service /etc/systemd/system/goose.service
>@sudo systemctl daemon-reload
>@sudo systemctl restart goose

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
>@echo "install-sysctl: 99-homelab.conf"
>@sudo cp $(REPO)/repo/config/sysctl/99-homelab.conf /etc/sysctl.d/99-homelab.conf
>@sudo sysctl --system >/dev/null

# ─────────────────────────────────────────────────────────────────────────────
# Bundles (live <-> tarball)
# bundle-secrets collects live secrets into a tar.gz; install-secrets
# extracts one back over the live paths. bundle-config snapshots the
# whole config/ tree into a tarball — useful as an offline copy when
# moving to a fresh host that doesn't have the repo cloned yet (the
# git-tracked copy is the canonical one when the repo is present).
# The bodies are shared defines: `make backup` and `make deploy` inline
# them so the umbrella recipes never chain another make target.
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: bundle-secrets install-secrets bundle-config install-config-bundle

define bundle_secrets_cmds
@dest=$(BKP_DIR)/secrets-bundle-$$(date +%Y%m%d).tar.gz; \
  sudo mkdir -p "$(BKP_DIR)"; \
  sudo tar czf "$$dest" \
    /home/op/.ssh/github_key \
    /home/op/.ssh/github_key.pub \
    /home/op/.ssh/config \
    /home/op/.ssh/authorized_keys \
    /etc/systemd/system/goose.service \
    /etc/systemd/system/ttyd.service \
    /etc/ssh/sshd_config.d/50-cloud-init.conf \
    /etc/dnsmasq.d/10-tailnet.conf \
    /etc/systemd/system/dnsmasq.service.d/override.conf \
    /var/lib/tailscale; \
  echo "Secrets bundle at $$dest"
endef

bundle-secrets:
>$(bundle_secrets_cmds)

# Extract a secrets bundle tar.gz to the live paths. Defaults to the
# newest secrets-bundle-*.tar.gz under $(BKP_DIR); override with BUNDLE=<path>.
define install_secrets_cmds
@if [ -z "$(BUNDLE)" ]; then \
    BUNDLE="$$(ls -1t $(BKP_DIR)/secrets-bundle-*.tar.gz 2>/dev/null | head -1)"; \
    if [ -z "$$BUNDLE" ]; then \
      echo "No secrets-bundle-*.tar.gz found in $(BKP_DIR)."; \
      exit 1; \
    fi; \
    echo "Using latest bundle: $$BUNDLE"; \
  else \
    BUNDLE="$(BUNDLE)"; \
  fi; \
  sudo tar xzf "$$BUNDLE" -C /; \
  echo "Installed $$BUNDLE to live paths."
endef

install-secrets:
>$(install_secrets_cmds)

# Snapshot the whole config/ tree into a single tarball under backups/.
# The git-tracked copy is canonical when the repo is present; this
# exists for offline handoff (cold VPS, no clone yet). Symmetric to
# bundle-secrets: collect → tarball; install-config-bundle → extract.
bundle-config:
>@dest=$(BKP_DIR)/config-bundle-$$(date +%Y%m%d).tar.gz; \
  sudo mkdir -p "$(BKP_DIR)"; \
  sudo tar czf "$$dest" -C $(REPO)/repo config; \
  sudo chown op:op "$$dest"; \
  echo "Config bundle at $$dest"

# Extract a config bundle tarball over $(REPO)/repo/config/. Defaults
# to the newest config-bundle-*.tar.gz under $(BKP_DIR); override with
# BUNDLE=<path>. Use when bootstrapping a fresh host: clone the repo
# (or just create the dir), then `make install-config-bundle` to
# populate config/ before running `make install-config`.
install-config-bundle:
>@if [ ! -d "$(REPO)/repo" ]; then \
    echo "$(REPO)/repo does not exist. Create it first (clone the repo, or mkdir)."; \
    exit 1; \
  fi; \
  if [ -z "$(BUNDLE)" ]; then \
    BUNDLE="$$(ls -1t $(BKP_DIR)/config-bundle-*.tar.gz 2>/dev/null | head -1)"; \
    if [ -z "$$BUNDLE" ]; then \
      echo "No config-bundle-*.tar.gz found in $(BKP_DIR)."; \
      exit 1; \
    fi; \
    echo "Using latest bundle: $$BUNDLE"; \
  else \
    BUNDLE="$(BUNDLE)"; \
  fi; \
  tar xzf "$$BUNDLE" -C $(REPO)/repo; \
  echo "Installed $$BUNDLE into $(REPO)/repo/config/"

# ─────────────────────────────────────────────────────────────────────────────
# Backups (rename: backup-* → bkp-*)
# bkp-cloud/bkp-vault stay granular; `make backup` (help-line umbrella)
# inlines them plus the secrets bundle and the live-config pull into
# repo/config/.
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: bkp-cloud bkp-vault bkp-list backup

# All bkp-* recipes write under $(REPO)/backups/. bkp-list enumerates that
# dir so the operator has one place to see what's been snapshotted.
BKP_DIR := $(REPO)/backups

# Shared bodies: `make backup` inlines them so it stays one self-contained
# recipe (no chained make targets).
define bkp_cloud_cmds
@dest=$(BKP_DIR)/cloud-backup-$$(date +%Y%m%d-%H%M%S); \
  sudo mkdir -p "$(BKP_DIR)" "$$dest"; \
  sudo chown op:op "$$dest"; \
  docker exec -w /var/www/html nextcloud php occ maintenance:mode --on; \
  trap 'docker exec -w /var/www/html nextcloud php occ maintenance:mode --off' EXIT; \
  docker exec -i nextcloud tar cf - -C /data . | sudo tar xf - -C "$$dest"; \
  sudo chown -R 33:33 "$$dest"; \
  trap - EXIT; \
  docker exec -w /var/www/html nextcloud php occ maintenance:mode --off; \
  echo "Backup at $$dest"
endef

define bkp_vault_cmds
@dest=$(BKP_DIR)/vault-backup-$$(date +%Y%m%d-%H%M%S).tar.gz; \
  sudo mkdir -p "$(BKP_DIR)"; \
  sudo tar czf "$$dest" -C $(REPO)/vault data; \
  echo "Backup at $$dest"
endef

bkp-cloud:
>$(bkp_cloud_cmds)

bkp-vault:
>$(bkp_vault_cmds)

# Help-line name for the full snapshot — one self-contained recipe:
# every container database + live secrets land compressed in $(REPO)/backups/,
# and the live server config is pulled into $(REPO)/repo/config/ subdirectories
# (the one non-compressed exception). The config-pull mirrors the file list
# install-config pushes, reversed; git add/commit the config/ changes.
backup:
>$(bkp_cloud_cmds)
>$(bkp_vault_cmds)
>$(bundle_secrets_cmds)
>@echo "--- pulling live config into repo/config/ ---"
>@sudo mkdir -p $(REPO)/repo/config
>@sudo cp /etc/systemd/system/goose.service $(REPO)/repo/config/goose/goose.service
>@sudo cp /etc/systemd/system/ttyd.service $(REPO)/repo/config/ttyd/ttyd.service
>@sudo cp /etc/ssh/sshd_config.d/50-cloud-init.conf $(REPO)/repo/config/ssh/50-cloud-init.conf
>@sudo cp /etc/dnsmasq.d/10-tailnet.conf $(REPO)/repo/config/dnsmasq/10-tailnet.conf
>@sudo cp /etc/systemd/system/dnsmasq.service.d/override.conf $(REPO)/repo/config/dnsmasq/dnsmasq.service.conf
>@sudo cp /etc/sysctl.d/99-homelab.conf $(REPO)/repo/config/sysctl/99-homelab.conf
>@sudo cp /etc/docker/daemon.json $(REPO)/repo/config/docker/daemon.json
>@sudo cp /etc/fail2ban/jail.d/sshd.conf $(REPO)/repo/config/fail2ban/jail.d/sshd.conf
>@sudo chown -R op:op $(REPO)/repo/config
>@echo "Live config pulled into $(REPO)/repo/config/ — git add/commit to sync the repo."

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
# terminal with `make tmux-open TAG=<n>` (or `tmux attach -t <n>`).
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: tmux-new tmux-open tmux-kill tmux-list

tmux-new:
>@if [ -z "$(TAG)" ]; then \
    echo "Usage: make tmux-new TAG=<session>   (TAG is required)"; \
    exit 1; \
  fi
>@if tmux has-session -t "$(TAG)" 2>/dev/null; then \
    echo "Session '$(TAG)' already exists. Attach with: make tmux-open TAG=$(TAG)"; \
    exit 1; \
  fi
>@tmux new -s "$(TAG)" -d
>@echo "Created detached session '$(TAG)'. Attach with: make tmux-open TAG=$(TAG)"
>@echo "  (or: tmux attach -t $(TAG))"

tmux-open:
>@if [ -z "$(TAG)" ]; then \
    echo "Usage: make tmux-open TAG=<session>"; \
    exit 1; \
  fi
>@if ! tmux has-session -t "$(TAG)" 2>/dev/null; then \
    echo "Session '$(TAG)' does not exist. Create it with: make tmux-new TAG=$(TAG)"; \
    exit 1; \
  fi
>@tmux attach -t "$(TAG)"

tmux-kill:
>@if [ -z "$(TAG)" ]; then \
    echo "Usage: make tmux-kill TAG=<session>"; \
    exit 1; \
  fi
>@if ! tmux has-session -t "$(TAG)" 2>/dev/null; then \
    echo "Session '$(TAG)' does not exist."; \
    exit 1; \
  fi
>@tmux kill-session -t "$(TAG)"
>@echo "Killed session '$(TAG)'"

tmux-list:
>@tmux ls 2>/dev/null || echo "No tmux sessions."

# ─────────────────────────────────────────────────────────────────────────────
# Migration
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: migrate

migrate:
>@cat $(REPO)/repo/docs/MIGRATE.md

# ─────────────────────────────────────────────────────────────────────────────
# Git
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: git-pull git-add git-com git-push

git-pull:
>cd $(REPO)/repo && git pull homelab main

git-add:
>cd $(REPO)/repo && git add -A

git-com:
>@if [ -z "$(MSG)" ]; then \
    echo "Usage: make git-com MSG=\"...\"  (MSG is required)"; \
    exit 1; \
  fi
>cd $(REPO)/repo && git commit -m "$(MSG)"

git-push:
>cd $(REPO)/repo && git push homelab main

# ─────────────────────────────────────────────────────────────────────────────
# Help (default goal)
# ─────────────────────────────────────────────────────────────────────────────

.DEFAULT_GOAL := help
.PHONY: help

help:
>@echo ""
>@echo ""
>@echo "  List of Make Recipes"
>@echo ""
>@echo "  Global"
>@echo "  │  make migrate          │migrate to another server"
>@echo "  │  make deploy           │copy config/ & secrets to this server"
>@echo "  │  make update           │[apt -> update/upgrade; docker -> pull/recreate]"
>@echo "  │  make backup           │[all container databases & secrets to homelab/backups/; live server config to repo/config/]"
>@echo "  │  make cleanup          │[apt -> autoremove/clean; docker -> prune builder/images/containers; backups -> keep latest 3 of each]"
>@echo "  └  make status           │list [git; systemd; docker; tmux; backups; mails]"
>@echo ""
>@echo "    Granular actions — per-file / primitive commands behind the Global recipes"
>@echo "    │  make smoke                 │live edge test: every vhost must serve its real app (pre-push hook runs it)"
>@echo "    │  make install-hooks         │install git hooks (pre-commit edge guard + pre-push smoke)"
>@echo "    │  make kuma-import           │import an adapted Uptime Kuma db (KUMA_DB=/path)"
>@echo "    │  make install-config        │one-shot host bootstrap: copy config/ to live paths"
>@echo "    │  make install-<file>        │per-file install from config/ → live (goose, ttyd, ssh, dnsmasq-conf, dnsmasq-override, docker, sysctl)"
>@echo "    │  make bkp-cloud             │Nextcloud snapshot (maintenance mode during copy)"
>@echo "    │  make bkp-vault             │Vaultwarden data tar"
>@echo "    │  make bkp-list              │list backup artifacts + count per pattern"
>@echo "    │  make bundle-secrets        │collect live secrets into backups/secrets-bundle-<date>.tar.gz"
>@echo "    │  make install-secrets       │extract a secrets bundle to live paths (BUNDLE=<path> to override)"
>@echo "    │  make bundle-config         │snapshot config/ into backups/config-bundle-<date>.tar.gz"
>@echo "    │  make install-config-bundle │extract a config bundle into repo/config/ (BUNDLE=<path> to override)"
>@echo "    │  make clean-docker          │prune builder / image / container"
>@echo "    │  make clean-apt             │apt autoremove + clean"
>@echo "    │  make clean-backups         │keep latest 3 per pattern, delete older"
>@echo "    │  make tmux-list             │list tmux sessions"
>@echo "    └  make help                  │print this help (default goal)"
>@echo ""
>@echo "  GitHub Actions"
>@echo "  │  make git-pull         │pull remote changes     │"
>@echo "  │  make git-add          │stage changes           │"
>@echo "  │  make git-com MSG=     │commit staged changes   │MSG= required commit message"
>@echo "  └  make git-push         │push committed changes  │"
>@echo ""
>@echo "  Systemd Services"
>@echo "  │  make systemd-restart  │restart host target     │for one specific service, append -<svc>"
>@echo "  └  make systemd-log      │tail target journal     │for all known services, append -all"
>@echo ""
>@echo "  Docker Containers"
>@echo "  │  make dok-recreate     │force-recreate target   │for one specific container, append -<ctn>"
>@echo "  │  make dok-restart      │restart target          │for all known containers, append -all"
>@echo "  │  make dok-stop         │stop target             │"
>@echo "  └  make dok-logs         │tail target logs        │"
>@echo ""
>@echo "  Tmux Sessions"
>@echo "  │  make tmux-new TAG=    │create detached target  │TAG= required session name"
>@echo "  │  make tmux-open TAG=   │attach to target        │Ctrl-B + D to detach from it"
>@echo "  └  make tmux-kill TAG=   │kill target             │can also kill with 'exit'"
>@echo ""
>@echo "  Mail (Docker Mailserver — details in docs/GUIDE.md)"
>@echo "  │  make mail-gen                disposable mailbox: random 7-letter address + random 16-char password (printed once)"
>@echo "  │  make mail-alias-gen TO=…     disposable forwarding alias: random 7-digit address → TO (external only — same-domain refused)"
>@echo "  │  make mail-alias-del ALIAS=… TO=…   remove a target from an alias (DMS needs both)"
>@echo "  │  make mail-alias-list         list aliases"
>@echo "  │  make mail-add-user USER=…    named mailbox (password prompted via read -s)"
>@echo "  │  make mail-passwd USER=…      rotate a mailbox password (prompted)"
>@echo "  │  make mail-del-user USER=…    delete a mailbox"
>@echo "  └  make mail-list-users         list mailboxes"
>@echo ""
>@echo ""
