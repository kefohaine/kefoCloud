.RECIPEPREFIX = >
# Use bash explicitly so SHELLFLAGS go to bash, not /bin/sh (dash on Debian).
# Without this, `dash -eu -c '<recipe>'` runs the recipe with `set -eu` and
# bites any line that references an unset variable — see docs/GUIDE.md
# "Operational gotchas" for the symptom and the fix.
SHELL := /bin/bash
.SHELLFLAGS := -eu -c

# The repo path is DERIVED from this Makefile's own location — never hardcoded.
# That is what lets the checkout be renamed or moved without editing the
# Makefile, and it is why every other path below hangs off $(REPO).
REPO       := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
# The single untracked source of instance values (see config/instance.defaults).
CONF       := $(REPO)/data/instance.conf
DOMAIN     := $(shell sed -n 's/^DOMAIN=//p' $(CONF) 2>/dev/null | head -1)
RENDER_DIR := $(REPO)/data/rendered
COMPOSE  := docker compose -f
CONTAINERS := caddy uptimekuma nextcloud vaultwarden mailserver roundcube
HOST     := ttyd dnsmasq goose

# ─────────────────────────────────────────────────────────────────────────────
# Docker containers: dok-<action>-<ctn>
# `dok-` prefix marks container (docker) actions so they don't collide
# visually with host systemd actions (systemd-restart/systemd-log below).
# One set of rules, expanded across $(CONTAINERS); append -<ctn> for one
# container, -all for every container. mailserver and roundcube share one
# compose file (modules/mailserver/docker-compose.yml), so a compose-unit
# action on either affects both.
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: $(addprefix dok-recreate-,$(CONTAINERS)) dok-recreate-all dok-recreate
.PHONY: $(addprefix dok-restart-,$(CONTAINERS)) dok-restart-all dok-restart
.PHONY: $(addprefix dok-stop-,$(CONTAINERS)) dok-stop-all dok-stop
.PHONY: $(addprefix dok-logs-,$(CONTAINERS)) dok-logs-all dok-logs

# $(DOMAIN) (Caddy) rebuilds its image locally; the rest just pull.
# $(DOMAIN) = custom Dockerfile adds caddy-dns/cloudflare for ACME DNS-01
#   on every vhost; DNS-01 keeps cert issuance independent of the proxy.

# Per-container compose file paths: modules/<ctn>/docker-compose.yml.
# roundcube lives in the mailserver compose file (no own compose).
$(foreach s,$(CONTAINERS),$(eval COMPOSE_FILE_$s := modules/$s/docker-compose.yml))
COMPOSE_FILE_roundcube := modules/mailserver/docker-compose.yml

# Helper: $(compose-file-of $1) returns the absolute compose file path for
# the named service. Recipes use this directly instead of $(COMPOSE_FILE_$1)
# so the expansion happens at recipe-expansion time, not recipe-execution time.
compose-file-of = $(REPO)/$(COMPOSE_FILE_$1)

# $(DOMAIN) needs a local image build; compose v5.5.0 on Debian trixie ships
# buildx 0.13.1, which is too old for `compose ... --build` (needs >= 0.17).
# Try the compose build first and fall back to plain `docker build` + compose
# up (the install.sh pattern) so `make dok-recreate-caddy` works everywhere.
define dok_recreate_rule
dok-recreate-$1:
>@if [ "$1" = "caddy" ]; then \
    if ! $(COMPOSE) $(call compose-file-of,$1) up -d --force-recreate --build; then \
      scripts/lib/mklog warn "compose build unavailable (buildx < 0.17 on trixie) — falling back to docker build + compose up"; \
      docker build -t caddy:local $(REPO)/modules/caddy \
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

# Shared loop: force-recreate every compose unit under modules/ ($(DOMAIN)
# builds locally, with the buildx fallback). Used by dok-recreate-all and
# update — each keeps a self-contained recipe (no chained make targets).
define dok_recreate_all_cmds
@for f in $(REPO)/modules/*/docker-compose.yml; do \
    if [ "$$f" = "$(REPO)/modules/caddy/docker-compose.yml" ]; then \
      if ! $(COMPOSE) "$$f" up -d --force-recreate --build; then \
        scripts/lib/mklog warn "compose build unavailable (buildx < 0.17 on trixie) — falling back to docker build + compose up"; \
        docker build -t caddy:local $(REPO)/modules/caddy \
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
>@for f in $(REPO)/modules/*/docker-compose.yml; do \
    $(COMPOSE) "$$f" restart; \
  done

dok-stop-all:
>@for f in $(REPO)/modules/*/docker-compose.yml; do \
    $(COMPOSE) "$$f" stop; \
  done

dok-logs-all:
>@stdbuf -oL bash -c 'for c in $(CONTAINERS); do \
    docker logs $$c --tail 50 -f 2>&1 | stdbuf -oL sed "s/^/[$$c] /" & \
  done; wait'

TARGET ?=

# Container actions, TARGET= style: make dok-recreate TARGET=caddy
# (the -<ctn> suffixed targets stay as thin aliases).
.PHONY: dok-action
dok-action:
>@if [ -z "$(TARGET)" ]; then \
    scripts/lib/mklog error "usage: make $(ACTION) TARGET=<ctn>  (one of: $(CONTAINERS))"; \
  else \
    $(MAKE) --no-print-directory $(ACTION)-$(TARGET); \
  fi

dok-recreate:
>@$(MAKE) --no-print-directory ACTION=dok-recreate dok-action
dok-restart:
>@$(MAKE) --no-print-directory ACTION=dok-restart dok-action
dok-stop:
>@$(MAKE) --no-print-directory ACTION=dok-stop dok-action
dok-logs:
>@$(MAKE) --no-print-directory ACTION=dok-logs dok-action

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
>@scripts/lib/mklog error "Usage: make systemd-restart-<svc>  (one of: $(HOST))"
>@echo "       make systemd-restart-all"
systemd-log:
>@scripts/lib/mklog error "Usage: make systemd-log-<svc>  (one of: $(HOST))"
>@echo "       make systemd-log-all"

# ─────────────────────────────────────────────────────────────────────────────
# Maintenance
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: fetch fetch-more render ttyd-devices ttyd-add ttyd-rm smoke gh-web-health install-hooks clean-docker clean-apt clean-backups update apt-upgrade install-config kuma-import help talk-gen
.PHONY: deploy backup cleanup connect

# Per-tailnet-device web-terminal sessions: one named tmux session each, served
# by the SINGLE ttyd listener as /ttyd?arg=<name> and listed on the tail page.
# No new port, no new vhost — see scripts/access/ttyd-devices.sh for why that matters.
ttyd-devices:
>@bash scripts/access/ttyd-devices.sh list

ttyd-add:
>@[ "$(origin NAME)" = "command line" ] || { scripts/lib/mklog error "usage: make ttyd-add NAME=<device>"; exit 1; }
>@bash scripts/access/ttyd-devices.sh add "$(NAME)"

ttyd-rm:
>@[ "$(origin NAME)" = "command line" ] || { scripts/lib/mklog error "usage: make ttyd-rm NAME=<device>"; exit 1; }
>@bash scripts/access/ttyd-devices.sh rm "$(NAME)"

# AIO dashboard (scripts/info/fetch.sh): host perf (uptime, load, cpu, memory,
# swap, disk), all available modules (installed green / uninstalled red),
# git, units, failed units (+ their targets), docker, tmux, backups, mail,
# tailnet — one aligned colored read; module-aware (installed-modules.conf).
# Render the skeleton into data/rendered/ (Caddy tree + config/) and refresh the
# instance block in every service .env. Everything that lands on the host or in
# a container comes from here, never from the tracked files directly.
render:
>@bash scripts/render/render-all.sh

fetch:
>@bash scripts/info/fetch.sh

# Deep dive (scripts/info/fetch-more.sh): the same system with the depth needed to
# answer "why isn't it okay" — memory breakdown, per-core busy, top cpu/mem/rss
# processes, zombies+threads, every listening socket, all units (active, failed,
# enabled-but-dead), timers, cron, journald caps, the docker engine's EFFECTIVE
# log caps with per-container cpu/mem/net/pids + restart counts + per-container
# log sizes and mount drift, image/volume/network inventory, per-mount disk +
# inodes + reboot-required, data/ growth, tailnet prefs/peers, dnsmasq + live
# DNS probes, ufw, git, module/vhost truth and TLS expiry. Read-only.
fetch-more:
>@bash scripts/info/fetch-more.sh

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
    sudo ls -1dt $(REPO)/data/backups/$$pattern 2>/dev/null | tail -n +4 | sudo xargs -r rm -rf; \
  done
@scripts/lib/mklog info "pruned backups older than the 3 most recent per pattern"
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

# apt is its own recipe, on purpose. A full `apt-get upgrade` is the
# riskiest line in the toolbox — a debconf/postinst/needrestart hiccup exits
# non-zero mid-upgrade, and under this Makefile's `-eu` that used to abort
# `make update` before a single container was touched (leaving a half-upgraded
# host and nothing recreated). Run it deliberately, on its own.
apt-upgrade:
>sudo apt-get update
>sudo apt-get upgrade -y
>@scripts/lib/mklog info "apt upgrade done — if the kernel/libc moved, reboot, then run: make update"

# Pull every image that isn't built locally, then recreate every DEPLOYED unit
# through scripts/stack/stack-up.sh: failures are COLLECTED so one broken unit can no
# longer abort the run, the Caddy edge goes LAST behind a config validate + a
# health gate with an automatic image rollback, and the PostgreSQL unit
# (docker-compose.db.yml) is included. Ends with the live edge smoke test.
update:
>@scripts/stack/stack-up.sh --update
>@bash scripts/stack/smoke-vhosts.sh || scripts/lib/mklog warn "smoke reported failures — see above"

# Live edge smoke test — every vhost must serve its real app (see
# scripts/stack/smoke-vhosts.sh). Run after any modules/caddy/ change or
# `docker restart caddy`. The pre-push hook runs this automatically.
smoke:
>@bash scripts/stack/smoke-vhosts.sh

# GitHub web git-data health (see scripts/info/gh-web-health.sh). Run after any
# full-history rewrite + force-push: a rewritten history can leave the GitHub
# web page 404/500 while git stays healthy (2026-09-03 incident); the remedy
# is a nudge commit, which triggers GitHub's rebuild. The pre-push hook
# warns whenever a push replaces remote history.
gh-web-health:
>@bash scripts/info/gh-web-health.sh

# Install the repo's git hooks (pre-commit: Caddy validate + app-vhost stub
# guard; pre-push: live vhost smoke test + history-rewrite warning). Re-run
# after cloning or after editing a hook.
install-hooks:
>@mkdir -p .git/hooks
>@cp scripts/hooks/pre-commit scripts/hooks/pre-push .git/hooks/
>@chmod +x .git/hooks/pre-commit .git/hooks/pre-push
>@scripts/lib/mklog info "installed git hooks: pre-commit (Caddy validate + app-vhost stub guard), pre-push (live vhost smoke + history-rewrite warning)"

# ─────────────────────────────────────────────────────────────────────────────
# Mailserver Registry (Docker Mailserver CLI — see `make help` > Mailserver
# Registry). Passwords never land in shell history or the process list.
# Friends log in at https://mail.$(DOMAIN) with just the local part
# (ROUNDCUBEMAIL_USERNAME_DOMAIN=$(DOMAIN)).
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: mail-gen mail-gen-alias mail-del mail-del-alias mail-quota mail-password mail-card

# Mailbox with everything auto-generated when the field is empty: MAIL =
# custom address or local part (empty = random 7-letter), PWD = custom
# password (empty = random 16-char, printed once), QUOTA = custom quota
# (empty = default from modules/mailserver/default-quota).
mail-gen:
>@bash scripts/modules/mail-gen.sh "$(MAIL)" "$(if $(filter command line,$(origin PWD)),$(PWD))" "$(QUOTA)"

# Disposable forwarding alias: random 7-digit local part forwarding to TO
# (see scripts/modules/mail-alias-gen.sh). No mailbox is consumed; same-domain
# targets are refused by the script (see docs/GUIDE.md).
mail-gen-alias:
>@[ -n "$(TO)" ] || { scripts/lib/mklog error "usage: make mail-gen-alias TO=target@example.com"; exit 1; }
>@bash scripts/modules/mail-alias-gen.sh "$(TO)"

# Delete an address AND all its stored mailbox data (DMS never deletes
# Maildirs on its own — this removes the folder under
# mailserver/data/$(DOMAIN)/<local>/ too). One merged info line.
mail-del:
>@[ -n "$(MAIL)" ] || { scripts/lib/mklog error "usage: make mail-del MAIL=name@$(DOMAIN)"; exit 1; }
>@if docker exec mailserver setup email del "$(MAIL)" >/dev/null 2>&1; then \
    local=$${MAIL%@*}; \
    if [ -d "$(REPO)/data/mailserver/data/$(DOMAIN)/$$local" ]; then \
      sudo rm -rf "$(REPO)/data/mailserver/data/$(DOMAIN)/$$local" && scripts/lib/mklog info "$(MAIL) deleted — account, aliases, quota and stored mail"; \
    else scripts/lib/mklog info "$(MAIL) deleted — account, aliases, quota (no stored mail)"; fi \
  else scripts/lib/mklog error "$(MAIL) not found — nothing deleted"; exit 1; fi

# Remove one target from an alias (DMS needs both).
mail-del-alias:
>@[ -n "$(FROM)" ] && [ -n "$(TO)" ] || { scripts/lib/mklog error "usage: make mail-del-alias FROM=x@$(DOMAIN) TO=target@example.com"; exit 1; }
>@docker exec mailserver setup alias del "$(FROM)" "$(TO)" >/dev/null && scripts/lib/mklog info "alias $(FROM) -> $(TO) removed"

# Quota setter: with MAIL = per-mailbox quota; without MAIL = the default
# quota that mail-gen applies (persisted in modules/mailserver/default-quota).
# B/k/M/G/T suffix or 0 (no limit).
mail-quota:
>@[ -n "$(QUOTA)" ] || { scripts/lib/mklog error "usage: make mail-quota [MAIL=name@$(DOMAIN)] QUOTA=2G (MAIL empty = set the default for mail-gen)"; exit 1; }
>@echo "$(QUOTA)" | grep -qE '^([0-9]+(B|k|M|G|T)|0)$$' || { scripts/lib/mklog error "invalid QUOTA '$(QUOTA)' — B/k/M/G/T suffix, or 0 (no limit)"; exit 1; }
>@if [ -n "$(MAIL)" ]; then docker exec mailserver setup quota set "$(MAIL)" "$(QUOTA)" >/dev/null && scripts/lib/mklog info "quota for $(MAIL) set to $(QUOTA)"; \
  else printf '%s\n' "$(QUOTA)" > modules/mailserver/default-quota && scripts/lib/mklog info "default quota for mail-gen set to $(QUOTA) (modules/mailserver/default-quota) — git add/commit to keep it"; fi

# Rotate a mailbox password. PWD empty = auto-generate a 16-char password and
# print it once. (PWD is make's cwd builtin — only a command-line PWD= is used.)
mail-password:
>@[ -n "$(MAIL)" ] || { scripts/lib/mklog error "usage: make mail-password MAIL=name@$(DOMAIN) [PWD=…]"; exit 1; }
>@if [ "$(origin PWD)" = "command line" ] && [ -n "$(PWD)" ]; then \
    docker exec mailserver setup email update "$(MAIL)" "$(PWD)" >/dev/null && scripts/lib/mklog info "password updated for $(MAIL)"; \
  else p=$$(openssl rand -base64 12 | tr -d '\n'); \
    docker exec mailserver setup email update "$(MAIL)" "$$p" >/dev/null && scripts/lib/mklog info "password for $(MAIL) updated — new password: $$p"; fi

# Card for one address: existence, quota (dovecot-quotas.cf), webmail URL.
# The password is a hash and cannot be shown — rotate with mail-password.
mail-card:
>@[ -n "$(MAIL)" ] || { scripts/lib/mklog error "usage: make mail-card MAIL=name@$(DOMAIN)"; exit 1; }
>@local=$${MAIL%@*}; \
  if docker exec mailserver setup email list | grep -q "^[* ]*$$local@"; then \
    q=$$(grep "^$(MAIL):" "$(REPO)/data/mailserver/config/dovecot-quotas.cf" 2>/dev/null | cut -d: -f2); \
    scripts/lib/mklog info "address $(MAIL) — exists, quota $${q:-unlimited}, webmail https://mail.$(DOMAIN) (login with '$$local')"; \
    scripts/lib/mklog warn "password is hashed — rotate with make mail-password MAIL=$(MAIL)"; \
  else scripts/lib/mklog error "$(MAIL) not found — create with make mail-gen [MAIL=…]"; exit 1; fi


tail-auth:
>@bash scripts/access/tail-auth.sh set "$(if $(USER),$(USER),{{GITHUB_USER}})" "$(PASS)"

# Regenerate the tail terminal's navigation catalogue from the Caddy vhost
# files (modules/*/www/targets.json — GENERATED, do not hand-edit). Run after
# adding a vhost or a public path; `make install-config` runs it too.
tail-targets:
>@bash scripts/access/tail-targets.sh

# ─────────────────────────────────────────────────────────────────────────────
# Uptime Kuma accounts (no CLI — scripts/modules/kuma-user.sh: bcryptjs hash in the
# container + host sqlite3 on kuma/data/kuma.db; plaintext never crosses)
# ─────────────────────────────────────────────────────────────────────────────
kuma-list-users:
>@bash scripts/modules/kuma-user.sh list

kuma-add-user:
>@[ -n "$(USER)" ] && [ -n "$(PASS)" ] || { scripts/lib/mklog error "Usage: make kuma-add-user USER=<name> PASS=<password>"; exit 1; }
>@bash scripts/modules/kuma-user.sh add "$(USER)" "$(PASS)"

kuma-passwd:
>@[ -n "$(USER)" ] && [ -n "$(PASS)" ] || { scripts/lib/mklog error "Usage: make kuma-passwd USER=<name> PASS=<newpassword>"; exit 1; }
>@bash scripts/modules/kuma-user.sh passwd "$(USER)" "$(PASS)"

kuma-del-user:
>@[ -n "$(USER)" ] || { scripts/lib/mklog error "Usage: make kuma-del-user USER=<name>"; exit 1; }
>@bash scripts/modules/kuma-user.sh del "$(USER)"

# Import an adapted Uptime Kuma db from another host (KUMA_DB=/path).
kuma-import:
>sudo scripts/modules/kuma-import.sh $(KUMA_DB)

# Generate the Nextcloud-stack secrets + Talk service configs (idempotent).
# Creates modules/nextcloud/.env entries (DB, Redis, signaling, TURN, SMTP)
# if missing and renders $(REPO)/data/talk/{server,turnserver}.conf.
talk-gen:
>@bash scripts/modules/talk-gen.sh

# Snapshot the live NC users/groups/quotas into cloud/recovery/ outside the
# repo (generated recovery manifests — install.sh recreates exactly this
# state on fresh installs; re-run after any user/group change).
nc-capture:
>@bash scripts/modules/nc-capture.sh

# Connect this host's modules to another server. Prompts: which module, which
# server, and what to do with the data — 'link' (use the database that already
# lives there) or 'overwrite' (copy this host's database there, replacing it),
# plus the NFS datadirectory move (the old `make storage`). It refuses to
# re-point a module until the target database answers a test query, and it
# always dumps locally before an overwrite.
connect:
>@bash scripts/ops/connect.sh

# ─────────────────────────────────────────────────────────────────────────────
# config/ (live <-> repo)
# config/ holds tracked copies of every host-level config. install-config
# pushes them to live.
# ─────────────────────────────────────────────────────────────────────────────

# Shared body: push config/ → live (install-config). deploy inlines this
# body plus the secrets extraction so it never chains another make target.
define install_config_cmds
# Templates carry {{TOKENS}}; scripts carry no instance values at all. Render
# the tracked skeleton into data/rendered/ first, then install from THERE — the
# repo checkout is never a source of live config.
@bash $(REPO)/scripts/render/render-all.sh
@if ! command -v ttyd >/dev/null 2>&1; then \
    scripts/lib/mklog info "installing ttyd..."; \
    curl -fsSL -o /tmp/ttyd https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.x86_64; \
    chmod +x /tmp/ttyd; \
    sudo install -m 0755 /tmp/ttyd /usr/local/bin/ttyd; \
    rm -f /tmp/ttyd; \
  else \
    scripts/lib/mklog info "ttyd already installed at $$(command -v ttyd)"; \
  fi
sudo test -s /etc/goose/goose.env || { sudo install -d -m 0755 /etc/goose; echo "GOOSE_SERVER__SECRET_KEY=$$(openssl rand -hex 32)" | sudo tee /etc/goose/goose.env >/dev/null; sudo chown root:root /etc/goose/goose.env; sudo chmod 0640 /etc/goose/goose.env; }
sudo cp $(RENDER_DIR)/config/goose/goose.service /etc/systemd/system/goose.service
bash $(REPO)/scripts/info/goose-tokens.sh
sudo cp $(RENDER_DIR)/config/ssh/50-cloud-init.conf /etc/ssh/sshd_config.d/50-cloud-init.conf
# The tracked copy keeps a PLACEHOLDER tailnet address; the live IP is rendered
# in at deploy time so an instance-specific address never lands in a tracked
# file (AGENTS rule 12). The old plain `cp` here silently overwrote the live
# 10-tailnet.conf with the placeholder — dnsmasq then fail-looped on
# "Cannot assign requested address" and tailnet DNS died with it.
@TS_IP=$$(tailscale ip -4 2>/dev/null | head -n1); \
    TS_ADDR=$$(sed -n 's/^TAILNET_SUBNET=//p' $(CONF) 2>/dev/null | head -1 | cut -d/ -f1); \
    [ -n "$$TS_IP" ] || { scripts/lib/mklog error "no tailscale IP — cannot render 10-tailnet.conf"; exit 1; }; \
    sed "s/$$TS_ADDR/$$TS_IP/g" $(RENDER_DIR)/config/dnsmasq/10-tailnet.conf | sudo tee /etc/dnsmasq.d/10-tailnet.conf >/dev/null
sudo mkdir -p /etc/systemd/system/dnsmasq.service.d
sudo cp $(RENDER_DIR)/config/dnsmasq/dnsmasq.service.conf /etc/systemd/system/dnsmasq.service.d/override.conf
sudo cp $(RENDER_DIR)/config/sysctl/99-kefo.conf /etc/sysctl.d/99-kefo.conf
sudo sysctl --system >/dev/null
@if ! diff -q /etc/docker/daemon.json $(REPO)/config/docker/daemon.json >/dev/null 2>&1; then \
    scripts/lib/mklog info "installing /etc/docker/daemon.json (Docker daemon restart required to take effect)"; \
    sudo mkdir -p /etc/docker; \
    sudo cp $(REPO)/config/docker/daemon.json /etc/docker/daemon.json; \
    scripts/lib/mklog info "run: sudo systemctl restart docker (containers stay up via live-restore)"; \
  else \
    scripts/lib/mklog info "docker daemon config already up to date"; \
  fi
sudo cp $(RENDER_DIR)/config/ttyd/ttyd.service /etc/systemd/system/ttyd.service
sudo cp $(RENDER_DIR)/config/bash/banner.sh /etc/kefo-banner.sh
sudo chmod 0644 /etc/kefo-banner.sh
@grep -qxF '. /etc/kefo-banner.sh' "$$HOME/.bashrc" || printf '%s\n' '. /etc/kefo-banner.sh' >> "$$HOME/.bashrc"
bash $(REPO)/scripts/access/tail-targets.sh
sudo cp $(RENDER_DIR)/config/fail2ban/jail.d/sshd.conf /etc/fail2ban/jail.d/sshd.conf
sudo cp $(RENDER_DIR)/config/cron/nextcloud /etc/cron.d/nextcloud
sudo chmod 0644 /etc/cron.d/nextcloud
# Logging: ONE namespace ({{LOG_DIR}}) for every log this project writes,
# bounded by ONE logrotate rule. Docker output is capped globally in
# config/docker/daemon.json (10m x3) and journald in config/systemd/journald
# caps — nothing here logs unboundedly, and nothing uses chronicle-style
# per-event logging.
sudo install -d -m 0755 {{LOG_DIR}}
sudo install -d -m 0700 {{STATE_DIR}}
sudo cp $(RENDER_DIR)/config/logrotate/instance /etc/logrotate.d/instance
sudo chmod 0644 /etc/logrotate.d/instance
sudo systemctl enable --now fail2ban
sudo ufw allow from 172.22.0.0/16 to any port 7681 proto tcp
sudo cp $(RENDER_DIR)/config/systemd/kefo-stack.service /etc/systemd/system/kefo-stack.service
sudo cp $(RENDER_DIR)/config/systemd/tmux-main.service /etc/systemd/system/tmux-main.service
sudo systemctl daemon-reload
sudo systemctl enable --now goose ttyd
# The boot unit was renamed (kefoserver-stack -> kefo-stack) so no machine
# name is baked into a unit name: retire the old one if it is still around.
sudo systemctl disable --now kefoserver-stack.service >/dev/null 2>&1 || true
sudo rm -f /etc/systemd/system/kefoserver-stack.service
sudo systemctl enable kefo-stack.service
@scripts/lib/mklog info "boot unit installed + enabled: kefo-stack.service (every deployed compose unit comes up on boot)"
sudo systemctl enable --now tmux-main.service
@scripts/lib/mklog info "tmux 'main' session ensured + enabled (make tmux-open TAG=main to attach)"
sudo systemctl restart sshd dnsmasq
@scripts/lib/mklog info "host install-config complete: goose + ttyd + dnsmasq + fail2ban + sshd + cron installed"
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
        install-docker install-sysctl install-cron
.PHONY: dok-recreate-nextcloud-db dok-restart-nextcloud-db dok-stop-nextcloud-db dok-logs-nextcloud-db

install-goose:
>@echo "install-goose: goose.service"
>@sudo test -s /etc/goose/goose.env || { sudo install -d -m 0755 /etc/goose; echo "GOOSE_SERVER__SECRET_KEY=$$(openssl rand -hex 32)" | sudo tee /etc/goose/goose.env >/dev/null; sudo chown root:root /etc/goose/goose.env; sudo chmod 0640 /etc/goose/goose.env; }
>@sudo cp $(RENDER_DIR)/config/goose/goose.service /etc/systemd/system/goose.service
>@sudo systemctl daemon-reload
>@sudo systemctl restart goose

install-ttyd:
>@echo "install-ttyd: ttyd.service"
>@if grep -qs 'ttyd.service' /proc/self/cgroup; then \
    scripts/lib/mklog error "This shell runs inside ttyd (web terminal) — restarting ttyd now would kill this shell and anything under it (agent sessions, tmux). Run install-ttyd from SSH or a local terminal instead."; \
    exit 1; \
  fi
>@sudo cp $(RENDER_DIR)/config/ttyd/ttyd.service /etc/systemd/system/ttyd.service
>@sudo systemctl daemon-reload
>@sudo systemctl restart ttyd

install-ssh:
>@echo "install-ssh: 50-cloud-init.conf"
>@sudo cp $(RENDER_DIR)/config/ssh/50-cloud-init.conf /etc/ssh/sshd_config.d/50-cloud-init.conf
>@sudo sshd -t && sudo systemctl restart sshd

install-dnsmasq-conf:
>@echo "install-dnsmasq-conf: 10-tailnet.conf"
>@TS_IP=$$(tailscale ip -4 2>/dev/null | head -n1); \
    TS_ADDR=$$(sed -n 's/^TAILNET_SUBNET=//p' $(CONF) 2>/dev/null | head -1 | cut -d/ -f1); \
    [ -n "$$TS_IP" ] || { scripts/lib/mklog error "no tailscale IP — cannot render 10-tailnet.conf"; exit 1; }; \
    sed "s/$$TS_ADDR/$$TS_IP/g" $(RENDER_DIR)/config/dnsmasq/10-tailnet.conf | sudo tee /etc/dnsmasq.d/10-tailnet.conf >/dev/null; \
    scripts/lib/mklog info "dnsmasq split-DNS rendered for $$TS_IP"
>@sudo systemctl restart dnsmasq

install-dnsmasq-override:
>@echo "install-dnsmasq-override: dnsmasq.service.d/override.conf"
>@sudo mkdir -p /etc/systemd/system/dnsmasq.service.d
>@sudo cp $(RENDER_DIR)/config/dnsmasq/dnsmasq.service.conf /etc/systemd/system/dnsmasq.service.d/override.conf
>@sudo systemctl daemon-reload
>@sudo systemctl restart dnsmasq

install-docker:
>@echo "install-docker: /etc/docker/daemon.json (Docker daemon restart required)"
>@sudo mkdir -p /etc/docker
>@sudo cp $(REPO)/config/docker/daemon.json /etc/docker/daemon.json
>@echo "Run: sudo systemctl restart docker  (containers stay up via live-restore)."

install-sysctl:
>@echo "install-sysctl: 99-kefo.conf"
>@sudo cp $(RENDER_DIR)/config/sysctl/99-kefo.conf /etc/sysctl.d/99-kefo.conf
>@sudo sysctl --system >/dev/null

install-cron:
>@echo "install-cron: /etc/cron.d/nextcloud (Nextcloud occ cron, every 5 min)"
>@sudo cp $(RENDER_DIR)/config/cron/nextcloud /etc/cron.d/nextcloud
>@sudo chmod 0644 /etc/cron.d/nextcloud

# ─────────────────────────────────────────────────────────────────────────────
# Nextcloud database (modules/nextcloud/docker-compose.db.yml)
# Runs on the fxmq host for now; migrates to the operator's 1 TB VPS later
# (see docs/GUIDE.md "Nextcloud DB"). Deliberately NOT in $(CONTAINERS) —
# the -all loops glob modules/*/docker-compose.yml only, and this file is
# named docker-compose.db.yml so they never see it.
# ─────────────────────────────────────────────────────────────────────────────

dok-recreate-nextcloud-db:
>$(COMPOSE) $(REPO)/modules/nextcloud/docker-compose.db.yml up -d --force-recreate

dok-restart-nextcloud-db:
>$(COMPOSE) $(REPO)/modules/nextcloud/docker-compose.db.yml restart

dok-stop-nextcloud-db:
>$(COMPOSE) $(REPO)/modules/nextcloud/docker-compose.db.yml stop

dok-logs-nextcloud-db:
>docker logs postgresql --tail 50 -f

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
    /root/.ssh/github_key \
    /root/.ssh/github_key.pub \
    /root/.ssh/config \
    /root/.ssh/authorized_keys \
    /etc/systemd/system/goose.service \
    /etc/goose/goose.env \
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
      scripts/lib/mklog error "no secrets-bundle-*.tar.gz found in $(BKP_DIR)"; \
      exit 1; \
    fi; \
    scripts/lib/mklog info "using latest bundle: $$BUNDLE"; \
  else \
    BUNDLE="$(BUNDLE)"; \
  fi; \
  sudo tar xzf "$$BUNDLE" -C /; \
  scripts/lib/mklog info "installed $$BUNDLE to live paths"
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
  sudo tar czf "$$dest" -C $(REPO) config; \
  sudo chown root:root "$$dest"; \
  scripts/lib/mklog info "config bundle at $$dest"

# Extract a config bundle tarball over $(REPO)/config/. Defaults
# to the newest config-bundle-*.tar.gz under $(BKP_DIR); override with
# BUNDLE=<path>. Use when bootstrapping a fresh host: clone the repo
# (or just create the dir), then `make install-config-bundle` to
# populate config/ before running `make install-config`.
install-config-bundle:
>@if [ ! -d "$(REPO)" ]; then \
    scripts/lib/mklog error "$(REPO) does not exist — clone the repo first"; \
    exit 1; \
  fi; \
  if [ -z "$(BUNDLE)" ]; then \
    BUNDLE="$$(ls -1t $(BKP_DIR)/config-bundle-*.tar.gz 2>/dev/null | head -1)"; \
    if [ -z "$$BUNDLE" ]; then \
      scripts/lib/mklog error "no config-bundle-*.tar.gz found in $(BKP_DIR)"; \
      exit 1; \
    fi; \
    scripts/lib/mklog info "using latest bundle: $$BUNDLE"; \
  else \
    BUNDLE="$(BUNDLE)"; \
  fi; \
  tar xzf "$$BUNDLE" -C $(REPO); \
  scripts/lib/mklog info "installed $$BUNDLE into $(REPO)/config/"

# ─────────────────────────────────────────────────────────────────────────────
# Backups (rename: backup-* → bkp-*)
# bkp-cloud/bkp-vault stay granular; `make backup` (help-line umbrella)
# inlines them plus the secrets bundle and the live-config pull into
# repo/config/.
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: bkp-cloud bkp-vault bkp-list backup

# All bkp-* recipes write under $(REPO)/data/backups/. bkp-list enumerates that
# dir so the operator has one place to see what's been snapshotted.
BKP_DIR := $(REPO)/data/backups

# Shared bodies: `make backup` inlines them so it stays one self-contained
# recipe (no chained make targets).
define bkp_cloud_cmds
@dest=$(BKP_DIR)/cloud-backup-$$(date +%Y%m%d); \
  sudo mkdir -p "$(BKP_DIR)" "$$dest"; \
  sudo chown root:root "$$dest"; \
  docker exec -w /var/www/html nextcloud php occ maintenance:mode --on; \
  trap 'docker exec -w /var/www/html nextcloud php occ maintenance:mode --off' EXIT; \
  docker exec -i nextcloud tar cf - -C /data . | sudo tar xf - -C "$$dest"; \
  sudo chown -R 33:33 "$$dest"; \
  trap - EXIT; \
  docker exec -w /var/www/html nextcloud php occ maintenance:mode --off; \
  scripts/lib/mklog info "backup at $$dest"
endef

define bkp_vault_cmds
@dest=$(BKP_DIR)/vault-backup-$$(date +%Y%m%d).tar.gz; \
  sudo mkdir -p "$(BKP_DIR)"; \
  sudo tar czf "$$dest" -C $(REPO)/data/vault data; \
  scripts/lib/mklog info "backup at $$dest"
endef

bkp-cloud:
>$(bkp_cloud_cmds)

bkp-vault:
>$(bkp_vault_cmds)

# Help-line name for the full snapshot — one self-contained recipe:
# every container database + live secrets land compressed in $(REPO)/data/backups/,
# and the live server config is pulled into $(REPO)/config/ subdirectories
# (the one non-compressed exception). The config-pull mirrors the file list
# install-config pushes, reversed; git add/commit the config/ changes. These files
# must never carry secrets — the goose unit reads its key from /etc/goose/goose.env
# (outside the repo) for exactly that reason.
backup:
>$(bkp_cloud_cmds)
>$(bkp_vault_cmds)
>$(bundle_secrets_cmds)
>@scripts/lib/mklog info "pulling live config into repo/config/ — reverse-rendered, so it lands as {{TOKENS}} not as this instance's values"
>@sudo mkdir -p $(REPO)/config
>@bash $(REPO)/scripts/render/render.sh --reverse /etc/systemd/system/goose.service $(REPO)/config/goose/goose.service
>@bash $(REPO)/scripts/render/render.sh --reverse /etc/systemd/system/ttyd.service $(REPO)/config/ttyd/ttyd.service
>@bash $(REPO)/scripts/render/render.sh --reverse /etc/ssh/sshd_config.d/50-cloud-init.conf $(REPO)/config/ssh/50-cloud-init.conf
>@TS_IP=$$(tailscale ip -4 2>/dev/null | head -n1); \
TS_ADDR=$$(sed -n 's/^TAILNET_SUBNET=//p' $(CONF) 2>/dev/null | head -1 | cut -d/ -f1);     sed "s/$${TS_IP:-__none__}/$$TS_ADDR/g" /etc/dnsmasq.d/10-tailnet.conf | sudo tee $(REPO)/config/dnsmasq/10-tailnet.conf >/dev/null; \
    scripts/lib/mklog info "10-tailnet.conf pulled back with the placeholder restored (never the live IP)"
>@bash $(REPO)/scripts/render/render.sh --reverse /etc/systemd/system/dnsmasq.service.d/override.conf $(REPO)/config/dnsmasq/dnsmasq.service.conf
>@bash $(REPO)/scripts/render/render.sh --reverse /etc/sysctl.d/99-kefo.conf $(REPO)/config/sysctl/99-kefo.conf
>@sudo cp /etc/docker/daemon.json $(REPO)/config/docker/daemon.json
>@bash $(REPO)/scripts/render/render.sh --reverse /etc/fail2ban/jail.d/sshd.conf $(REPO)/config/fail2ban/jail.d/sshd.conf
>@bash $(REPO)/scripts/render/render.sh --reverse /etc/cron.d/nextcloud $(REPO)/config/cron/nextcloud
>@sudo chown -R root:root $(REPO)/config
>@scripts/lib/mklog info "live config pulled into $(REPO)/config/ — git add/commit to sync the repo"

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
    scripts/lib/mklog error "Usage: make tmux-new TAG=<session>   (TAG is required)"; \
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
    scripts/lib/mklog error "Usage: make tmux-open TAG=<session>"; \
    exit 1; \
  fi
>@if ! tmux has-session -t "$(TAG)" 2>/dev/null; then \
    echo "Session '$(TAG)' does not exist. Create it with: make tmux-new TAG=$(TAG)"; \
    exit 1; \
  fi
>@tmux attach -t "$(TAG)"

tmux-kill:
>@if [ -z "$(TAG)" ]; then \
    scripts/lib/mklog error "Usage: make tmux-kill TAG=<session>"; \
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
# Nextcloud (occ) — every recipe wraps `docker exec -u www-data nextcloud
# php occ` (the container is named nextcloud; the FPM user owns occ).
# Generic escape hatch: make nc-occ CMD='<any occ command + args>'.
# Secrets never go into argv: passwords use OC_PASS (occ prompts otherwise)
# and occ config:system:set output is left as-is (never echoed to logs).
# ─────────────────────────────────────────────────────────────────────────────

NC_OCC := docker exec -u www-data nextcloud php occ

.PHONY: nc-occ nc-status nc-check nc-update-check nc-upgrade nc-cron nc-cron-run \
	nc-maintenance-on nc-maintenance-off nc-repair nc-db-indices nc-db-columns \
	nc-db-primary-keys nc-db-bigint nc-apps nc-app-enable nc-app-disable \
	nc-config-get nc-config-set nc-users nc-user-add nc-user-del nc-user-password \
	nc-user-setting nc-scan nc-groups nc-jobs nc-talk-signaling nc-talk-signaling-add \
	nc-talk-signaling-del nc-talk-turn nc-talk-turn-add nc-talk-turn-del \
	nc-2fa-enforce nc-logs

nc-occ:
>@if [ -z "$(CMD)" ]; then \
    scripts/lib/mklog error "Usage: make nc-occ CMD='<occ command + args>'  (e.g. CMD='status' or CMD='app:list')"; \
    exit 1; \
  fi
>$(NC_OCC) $(CMD)

nc-status:
>$(NC_OCC) status

nc-check:
>$(NC_OCC) check

nc-update-check:
>$(NC_OCC) update:check

nc-upgrade:
>$(NC_OCC) upgrade

nc-cron:
>$(NC_OCC) background:cron

nc-cron-run:
>docker exec -u www-data nextcloud php -f /var/www/html/cron.php

nc-maintenance-on:
>$(NC_OCC) maintenance:mode --on

nc-maintenance-off:
>$(NC_OCC) maintenance:mode --off

nc-repair:
>$(NC_OCC) maintenance:repair --include-expensive

nc-db-indices:
>$(NC_OCC) db:add-missing-indices

nc-db-columns:
>$(NC_OCC) db:add-missing-columns

nc-db-primary-keys:
>$(NC_OCC) db:add-missing-primary-keys

nc-db-bigint:
>$(NC_OCC) db:convert-filecache-bigint

nc-apps:
>$(NC_OCC) app:list

nc-app-enable:
>@if [ -z "$(APP)" ]; then scripts/lib/mklog error "Usage: make nc-app-enable APP=<app-id>"; exit 1; fi
>$(NC_OCC) app:enable $(APP)

nc-app-disable:
>@if [ -z "$(APP)" ]; then scripts/lib/mklog error "Usage: make nc-app-disable APP=<app-id>"; exit 1; fi
>$(NC_OCC) app:disable $(APP)

nc-config-get:
>@if [ -z "$(KEY)" ]; then scripts/lib/mklog error "Usage: make nc-config-get KEY=<config-key>"; exit 1; fi
>$(NC_OCC) config:system:get $(KEY)

nc-config-set:
>@if [ -z "$(KEY)" ] || [ -z "$(VALUE)" ]; then \
    scripts/lib/mklog error "Usage: make nc-config-set KEY=<key> VALUE=<value> [TYPE=string|integer|boolean|array]"; \
    exit 1; \
  fi
>$(NC_OCC) config:system:set $(KEY) --value "$(VALUE)" $(TYPE:%=--type %)

# Set the default storage quota for NEW users (files app 'default_quota' —
# an APP config, so nc-config-set (system config) is the wrong tool) and sync
# the recovery manifest so a fresh install reproduces it.
nc-default-user-quota:
>@if [ -z "$(VALUE)" ]; then \
    scripts/lib/mklog error "Usage: make nc-default-user-quota VALUE='100 GB'  (or 'none' for unlimited)"; \
    exit 1; \
  fi
>$(NC_OCC) config:app:set files default_quota --value "$(VALUE)"
>@printf '# GENERATED by make nc-default-user-quota (%s) — do not edit; re-run to refresh.\n# Default storage quota for NEW users (files app '\''default_quota'\'').\n%s\n' "$$(date -Is)" "$(VALUE)" > $(REPO)/data/cloud/recovery/default-quota

nc-users:
>$(NC_OCC) user:list

nc-user-add:
>@if [ -z "$(USER)" ]; then scripts/lib/mklog error "Usage: make nc-user-add USER=<uid> [PASS=<password>]"; exit 1; fi
>@if [ -n "$(PASS)" ]; then \
    OC_PASS="$(PASS)" $(NC_OCC) user:add --password-from-env "$(USER)"; \
  else \
    $(NC_OCC) user:add "$(USER)"; \
  fi

nc-user-del:
>@if [ -z "$(USER)" ]; then scripts/lib/mklog error "Usage: make nc-user-del USER=<uid>"; exit 1; fi
>$(NC_OCC) user:delete "$(USER)"

nc-user-password:
>@if [ -z "$(USER)" ]; then scripts/lib/mklog error "Usage: make nc-user-password USER=<uid> [PASS=<password>]"; exit 1; fi
>@if [ -n "$(PASS)" ]; then \
    OC_PASS="$(PASS)" $(NC_OCC) user:resetpassword --password-from-env "$(USER)"; \
  else \
    $(NC_OCC) user:resetpassword "$(USER)"; \
  fi

nc-user-setting:
>@if [ -z "$(USER)" ] || [ -z "$(KEY)" ] || [ -z "$(VALUE)" ]; then \
    scripts/lib/mklog error "Usage: make nc-user-setting USER=<uid> KEY=<setting-key> VALUE=<value>  (e.g. KEY=email)"; \
    exit 1; \
  fi
>$(NC_OCC) user:setting "$(USER)" settings "$(KEY)" "$(VALUE)"

nc-scan:
>@if [ -n "$(USER)" ]; then \
    $(NC_OCC) files:scan "$(USER)"; \
  else \
    $(NC_OCC) files:scan --all; \
  fi

nc-groups:
>$(NC_OCC) group:list

nc-jobs:
>$(NC_OCC) background-job:list

nc-talk-signaling:
>$(NC_OCC) talk:signaling:list

nc-talk-signaling-add:
>@if [ -z "$(URL)" ] || [ -z "$(SECRET)" ]; then \
    scripts/lib/mklog error "Usage: make nc-talk-signaling-add URL=<server-url> SECRET=<shared-secret>"; \
    exit 1; \
  fi
>$(NC_OCC) talk:signaling:add "$(URL)" "$(SECRET)"

nc-talk-signaling-del:
>@if [ -z "$(URL)" ]; then scripts/lib/mklog error "Usage: make nc-talk-signaling-del URL=<server-url>"; exit 1; fi
>$(NC_OCC) talk:signaling:delete "$(URL)"

nc-talk-turn:
>$(NC_OCC) talk:turn:list

nc-talk-turn-add:
>@if [ -z "$(SERVER)" ] || [ -z "$(SECRET)" ]; then \
    scripts/lib/mklog error "Usage: make nc-talk-turn-add SERVER='scheme host:port [--udp] [--tcp]' SECRET=<shared-secret>"; \
    exit 1; \
  fi
>$(NC_OCC) talk:turn:add $(SERVER) --secret "$(SECRET)"

nc-talk-turn-del:
>@if [ -z "$(SERVER)" ]; then scripts/lib/mklog error "Usage: make nc-talk-turn-del SERVER='scheme host:port'"; exit 1; fi
>$(NC_OCC) talk:turn:delete $(SERVER)

nc-2fa-enforce:
>@if [ -z "$(USER)" ]; then scripts/lib/mklog error "Usage: make nc-2fa-enforce USER=<uid>"; exit 1; fi
>$(NC_OCC) twofactorauth:enforce "$(USER)"

nc-logs:
>$(NC_OCC) log:tail $(or $(N),100)

# ─────────────────────────────────────────────────────────────────────────────
# Migration
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: migrate

migrate:
>@cat $(REPO)/docs/MIGRATE.md

# ─────────────────────────────────────────────────────────────────────────────
# Git
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: git-pull git-add git-com git-push

git-pull:
>cd $(REPO) && git pull --ff-only

git-add:
>cd $(REPO) && git add -A

git-com:
>@if [ -z "$(MSG)" ]; then \
    scripts/lib/mklog error "Usage: make git-com MSG=\"...\"  (MSG is required)"; \
    exit 1; \
  fi
>cd $(REPO) && git commit -m "$(MSG)"

git-push:
>cd $(REPO) && git push

# ─────────────────────────────────────────────────────────────────────────────
# Help (default goal) — scripts/info/help.sh renders both lists in the
# scripts/info/fetch.sh house style (aligned colored rows, colors off when
# piped). help = the common daily surface; help-more = the granular /
# technical recipes; each points at the other.
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: goose-tokens

# Token policy → the live goose settings store (config/goose/token-policy.yaml
# → ~/.config/goose/config.yaml). Idempotent, no restart needed: goose reads
# the store when a session starts, so running sessions are untouched.
goose-tokens:
>@bash $(REPO)/scripts/info/goose-tokens.sh

.DEFAULT_GOAL := help
.PHONY: help help-more

help:
>@bash scripts/info/help.sh core

help-more:
>@bash scripts/info/help.sh more
# ─────────────────────────────────────────────────────────────────────────────
# taildrop helpers
# ─────────────────────────────────────────────────────────────────────────────
.PHONY: taildrop-file taildrop-folder
TAILDROP_HOST ?= server

# make taildrop-file FILE=path [TAILDROP_HOST=server]    (sudo tailscale file cp)
# make taildrop-folder DIR=path [TAILDROP_HOST=server]
taildrop-file:
>@test -n "$(FILE)" || { echo "usage: make taildrop-file FILE=<path> [TAILDROP_HOST=<device>]"; exit 2; }
>@sudo tailscale file cp "$(FILE)" "$(TAILDROP_HOST):"

taildrop-folder:
>@test -n "$(DIR)" || { echo "usage: make taildrop-folder DIR=<folder> [TAILDROP_HOST=<device>]"; exit 2; }
>@sudo tailscale file cp -r "$(DIR)" "$(TAILDROP_HOST):"

# ─────────────────────────────────────────────────────────────────────────────
# Goose recipes — reusable read-only agent tasks (recipes/*.yaml).
# Every recipe inspects and reports; it never mutates the host. The operator
# applies changes after review. `make goose-recipes` lists them. The recipe
# path is the repo-local recipes/ dir so the recipes stay versioned with the
# scripts and docs they operate on.
# ─────────────────────────────────────────────────────────────────────────────

GOOSE_RECIPE_PATH ?= $(REPO)/recipes

.PHONY: goose-recipes goose-audit goose-review goose-troubleshoot \
	goose-check-backups goose-check-network goose-validate-installer \
	goose-audit-docs goose-deploy-plan

goose-recipes:
>@GOOSE_RECIPE_PATH=$(GOOSE_RECIPE_PATH) goose recipe list

goose-audit:
>@GOOSE_RECIPE_PATH=$(GOOSE_RECIPE_PATH) goose run --recipe audit-server $(if $(FOCUS),--params focus_area=$(FOCUS),)

goose-review:
>@test -n "$(MODULE)" || { echo "usage: make goose-review MODULE=<cloud|vault|mail|monitor|edge>"; exit 1; }
>@GOOSE_RECIPE_PATH=$(GOOSE_RECIPE_PATH) goose run --recipe review-module --params module=$(MODULE)

goose-troubleshoot:
>@test -n "$(SERVICE)" || { echo "usage: make goose-troubleshoot SERVICE=<hostname|container|recipe>"; exit 1; }
>@GOOSE_RECIPE_PATH=$(GOOSE_RECIPE_PATH) goose run --recipe troubleshoot-service --params service=$(SERVICE)

goose-check-backups:
>@GOOSE_RECIPE_PATH=$(GOOSE_RECIPE_PATH) goose run --recipe check-backups $(if $(FOCUS),--params focus=$(FOCUS),)

goose-check-network:
>@GOOSE_RECIPE_PATH=$(GOOSE_RECIPE_PATH) goose run --recipe check-networking $(if $(FOCUS),--params focus=$(FOCUS),)

goose-validate-installer:
>@GOOSE_RECIPE_PATH=$(GOOSE_RECIPE_PATH) goose run --recipe validate-installer $(if $(TARGET),--params target=$(TARGET),)

goose-audit-docs:
>@GOOSE_RECIPE_PATH=$(GOOSE_RECIPE_PATH) goose run --recipe audit-docs $(if $(SCOPE),--params scope=$(SCOPE),)

goose-deploy-plan:
>@test -n "$(CHANGE)" || { echo "usage: make goose-deploy-plan CHANGE='<what to change>'" ; exit 1; }
>@GOOSE_RECIPE_PATH=$(GOOSE_RECIPE_PATH) goose run --recipe deployment-plan --params change=$(CHANGE)
