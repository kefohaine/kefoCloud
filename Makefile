.RECIPEPREFIX = >
# Use bash explicitly so SHELLFLAGS go to bash, not /bin/sh (dash on Debian).
# Without this, `dash -eu -c '<recipe>'` runs the recipe with `set -eu` and
# bites any line that references an unset variable — see docs/GUIDE.md
# "Operational gotchas" for the symptom and the fix.
SHELL := /bin/bash
.SHELLFLAGS := -eu -c

# USER is exported by every login shell (USER=root) and make imports the whole
# environment, so an account-targeting recipe would silently act on root when
# it was meant to require USER= on the command line. Blank the inherited copy
# once here; a command-line USER= still wins.
ifeq ($(origin USER),environment)
USER :=
endif

# The repo path is DERIVED from this Makefile's own location — never hardcoded.
# That is what lets the checkout be renamed or moved without editing the
# Makefile, and it is why every other path below hangs off $(REPO).
REPO       := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
# The single untracked source of instance values (see config/instance.defaults).
CONF       := $(REPO)/data/instance.conf
DOMAIN     := $(shell sed -n 's/^DOMAIN=//p' $(CONF) 2>/dev/null | head -1)
# Instance tree (untracked). Read from the same conf the renderer uses, so a
# host that moved data/ keeps working; the repo-relative path is the norm.
DATA_DIR   := $(or $(shell sed -n 's/^DATA_DIR=//p' $(CONF) 2>/dev/null | head -1),$(REPO)/data)
RENDER_DIR := $(REPO)/data/rendered
COMPOSE  := docker compose -f
CONTAINERS := caddy uptimekuma nextcloud vaultwarden mailserver roundcube
HOST     := ttyd dnsmasq goose
# The tailnet device that receives files/bundles — one spelling for backup,
# import-backups and the taildrop helpers (TAILDROP_HOST is an alias). No
# default: shipping to an arbitrary device is worse than a usage error.
TAILDROP ?= $(TAILDROP_HOST)

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

# caddy rebuilds its image locally; the rest just pull.
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

# One compose unit's force-recreate, shared by dok-recreate-<ctn> and
# dok-recreate-all so the two can never drift. caddy rebuilds its image
# locally; compose v5.5.0 on Debian trixie ships buildx 0.13.1, which is too old
# for `compose ... --build` (needs >= 0.17) — try the compose build first and
# fall back to plain `docker build` + compose up (the installer pattern) so
# `make dok-recreate-caddy` works everywhere.
# --remove-orphans on every recreate: a container left over from a RENAMED or
# REMOVED service in the same compose file keeps running with the old name and
# the old config, and compose only warns ("Found orphan containers (...)"). The
# installer then probes the name it expects, finds nothing serving, and reports a
# failure on a stack that is actually healthy. Recreate is the one place the
# operator has asked for "this file, exactly as written", so the orphans go.
# $1 = absolute compose file path.
define compose_recreate_cmds
if [ "$1" = "$(REPO)/modules/caddy/docker-compose.yml" ]; then \
    if ! $(COMPOSE) "$1" up -d --force-recreate --remove-orphans --build; then \
      scripts/lib/mklog warn "compose build unavailable (buildx < 0.17 on trixie) — falling back to docker build + compose up"; \
      docker build -t caddy:local $(REPO)/modules/caddy \
        && $(COMPOSE) "$1" up -d --force-recreate --remove-orphans; \
    fi; \
  else \
    $(COMPOSE) "$1" up -d --force-recreate --remove-orphans; \
  fi
endef

define dok_recreate_rule
dok-recreate-$1:
>@$(call compose_recreate_cmds,$(call compose-file-of,$1))
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

# Primary container to tail per service: mailserver runs mailu-* + roundcube
# and has no container named after itself, so its log target is mailu-admin
# (per-service view: make mail-logs SERVICE=<svc>).
LOG_CONTAINER_mailserver := mailu-admin
log-container-of = $(if $(LOG_CONTAINER_$1),$(LOG_CONTAINER_$1),$1)

define dok_logs_rule
dok-logs-$1:
># Tail the service's primary container.
>docker logs $(call log-container-of,$1) --tail 50 -f
endef
$(foreach s,$(CONTAINERS),$(eval $(call dok_logs_rule,$s)))

# Shared loop: force-recreate every compose unit under modules/ (the same
# per-file body the -<ctn> rules use).
dok-recreate-all:
>@for f in $(REPO)/modules/*/docker-compose.yml; do \
    $(call compose_recreate_cmds,$$f); \
  done

dok-restart-all:
>@for f in $(REPO)/modules/*/docker-compose.yml; do \
    $(COMPOSE) "$$f" restart; \
  done

dok-stop-all:
>@for f in $(REPO)/modules/*/docker-compose.yml; do \
    $(COMPOSE) "$$f" stop; \
  done

# container:label pairs, so the mailserver map is applied without a shell case.
DOK_LOG_TARGETS := $(foreach c,$(CONTAINERS),$(call log-container-of,$c):$c)

dok-logs-all:
>@stdbuf -oL bash -c 'for t in $(DOK_LOG_TARGETS); do \
    lc=$${t%%:*}; c=$${t#*:}; \
    docker logs $$lc --tail 50 -f 2>&1 | stdbuf -oL sed "s/^/[$$c] /" & \
  done; wait'

TARGET ?=

# Container actions, TARGET= style: make dok-recreate TARGET=caddy
# (the -<ctn> suffixed targets stay as thin aliases; without TARGET the
# usage line names every accepted value).
.PHONY: dok-action
dok-action:
>@case " $(CONTAINERS) " in \
    *" $(TARGET) "*) $(MAKE) --no-print-directory $(ACTION)-$(TARGET);; \
    *) scripts/lib/mklog error "usage: make $(ACTION) TARGET=<ctn>  (one of: $(CONTAINERS))"; exit 1;; \
  esac

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
>@$(MAKE) --no-print-directory ACTION=systemd-restart systemd-action
systemd-log:
>@$(MAKE) --no-print-directory ACTION=systemd-log systemd-action

# Same TARGET= form as the dok-* family: make systemd-restart TARGET=goose
# (the -<svc> suffixed targets stay as thin aliases).
.PHONY: systemd-action
systemd-action:
>@case " $(HOST) " in \
    *" $(TARGET) "*) $(MAKE) --no-print-directory $(ACTION)-$(TARGET);; \
    *) scripts/lib/mklog error "usage: make $(ACTION) TARGET=<svc>  (one of: $(HOST)) — or make $(ACTION)-all"; exit 1;; \
  esac

# ─────────────────────────────────────────────────────────────────────────────
# Maintenance
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: fetch fetch-more render tail-targets smoke talk-config gh-web-health install-hooks update apt-upgrade install-config help talk-gen nc-capture nc-default-user-quota
.PHONY: kuma-import kuma-list-users kuma-add-user kuma-passwd kuma-del-user
.PHONY: vaultwarden-list-users vaultwarden-add-user vaultwarden-del-user
.PHONY: deploy backup nc-datadir-nfs import-backups

# The web terminal is ONE page and ONE shell: tail.$DOMAIN/ttyd attaches the
# single `main` tmux session (created by tmux-main.service at boot, or on first
# attach). There is no per-device registry and no way to name a session from the
# URL — a second shell is a tmux window INSIDE main (make tmux-new / tmux-open).

# AIO dashboard (scripts/info/fetch.sh): host perf (uptime, load, cpu, memory,
# swap, disk), all available modules (installed green / uninstalled red),
# git, units, failed units (+ their targets), docker, tmux, backups, mail,
# tailnet — one aligned colored read; module-aware (wizard.state).
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
>@bash scripts/stack/smoke-vhosts.sh || scripts/lib/mklog warn "smoke reported failures — see above (smoke runs only on a finished install)"

# Live edge smoke test — every vhost must serve its real app (see
# scripts/stack/smoke-vhosts.sh). Runs ONLY on a finished install (wizard.state
# finished=true) and has no bypass. Run after any modules/caddy/ change or
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

# Install the repo's git hooks (pre-commit: identity + Caddy validate + app-vhost
# stub guard; prepare-commit-msg: auto-split a change that spans more than one
# unit (one folder + at most one subfolder, rule 26) into one commit per unit;
# pre-push: live vhost smoke test + history-rewrite warning +
# auto-split/fill-revert over the pushed range). The installer runs this
# automatically; re-run manually after cloning or after editing a hook.
install-hooks:
>@mkdir -p .git/hooks
>@cp scripts/hooks/pre-commit scripts/hooks/prepare-commit-msg scripts/hooks/pre-push .git/hooks/
>@chmod +x .git/hooks/pre-commit .git/hooks/prepare-commit-msg .git/hooks/pre-push
>@scripts/lib/mklog info "installed git hooks: pre-commit (identity + Caddy validate + app-vhost stub guard), prepare-commit-msg (auto-split per unit: one folder + one subfolder), pre-push (live vhost smoke + history-rewrite warning + auto-split/revert)"

# ─────────────────────────────────────────────────────────────────────────────
# Mailboxes (Mailu `flask mailu` CLI — see `make help-more` > mail server).
# Passwords never land in shell history or the process list.
# Friends log in at https://mail.$(DOMAIN) with just the local part
# (ROUNDCUBEMAIL_USERNAME_DOMAIN=$(DOMAIN)); the full stack lives in the
# Mailu section below (status, doctor, domains, aliases, limits, registry).
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

# Delete an address AND all its stored mailbox data (Mailu's user-delete only
# deactivates by default; -r removes the account and its mail).
mail-del:
>@[ -n "$(MAIL)" ] || { scripts/lib/mklog error "usage: make mail-del MAIL=name@$(DOMAIN)"; exit 1; }
>@if docker exec mailu-admin flask mailu user-delete -r "$(MAIL)" >/dev/null 2>&1; then \
    scripts/lib/mklog info "$(MAIL) deleted — account, aliases, quota and stored mail"; \
  else scripts/lib/mklog error "$(MAIL) not found — nothing deleted"; exit 1; fi

# Remove one target from an alias (Mailu aliases are a target list).
# Mailu 2.0 exports an alias as {email, destination:[...]} — selection is by
# email, and the list is rejoined into the comma string `alias` expects.
mail-del-alias:
>@[ -n "$(FROM)" ] && [ -n "$(TO)" ] || { scripts/lib/mklog error "usage: make mail-del-alias FROM=x@$(DOMAIN) TO=target@example.com"; exit 1; }
>@local=$${FROM%@*}; dom=$${FROM#*@}; \
  cur=$$(docker exec mailu-admin flask mailu config-export -j 2>/dev/null | jq -r --arg e "$(FROM)" '.alias[]? | select(.email==$$e) | (.destination // []) | if type=="array" then join(",") else . end' | head -1); \
  new=$$(printf '%s' "$$cur" | tr ',' '\n' | sed '/^$$/d' | grep -vxF "$(TO)" | paste -sd, -); \
  if [ -n "$$new" ]; then docker exec mailu-admin flask mailu alias "$$local" "$$dom" "$$new" >/dev/null; \
    scripts/lib/mklog info "alias $(FROM) -> $(TO) removed"; \
  else docker exec mailu-admin flask mailu alias-delete "$(FROM)" >/dev/null && scripts/lib/mklog info "alias $(FROM) removed (no targets left)"; fi

# Quota setter: with MAIL = per-mailbox quota; without MAIL = the default
# quota that mail-gen applies (persisted in modules/mailserver/default-quota).
# B/k/M/G/T suffix or 0 (no limit).
mail-quota:
>@[ -n "$(QUOTA)" ] || { scripts/lib/mklog error "usage: make mail-quota [MAIL=name@$(DOMAIN)] QUOTA=2G (MAIL empty = set the default for mail-gen)"; exit 1; }
>@echo "$(QUOTA)" | grep -qE '^([0-9]+(B|k|M|G|T)|0)$$' || { scripts/lib/mklog error "invalid QUOTA '$(QUOTA)' — B/k/M/G/T suffix, or 0 (no limit)"; exit 1; }
>@if [ -n "$(MAIL)" ]; then \
    local=$${MAIL%@*}; dom=$${MAIL#*@}; raw=$${QUOTA%B}; \
    bytes=$$(numfmt --from=iec "$$raw" 2>/dev/null || echo "$$raw"); \
    case "$$bytes" in ''|*[!0-9]*) scripts/lib/mklog error "cannot convert QUOTA '$(QUOTA)' to bytes"; exit 1;; esac; \
    hash=$$(docker exec mailu-admin flask mailu config-export -j 2>/dev/null | jq -r --arg e "$(MAIL)" '.user[]? | select(.email==$$e) | .password // empty' | head -1); \
    [ -n "$$hash" ] || { scripts/lib/mklog error "$(MAIL) not found — create it with make mail-gen"; exit 1; }; \
    printf 'users:\n  - localpart: %s\n    domain: %s\n    quota_bytes: %s\n    password_hash: %s\n' "$$local" "$$dom" "$$bytes" "$$hash" \
      | docker exec -i mailu-admin flask mailu config-update >/dev/null \
      && scripts/lib/mklog info "quota for $(MAIL) set to $(QUOTA) ($$bytes bytes)"; \
  else printf '%s\n' "$(QUOTA)" > modules/mailserver/default-quota && scripts/lib/mklog info "default quota for mail-gen set to $(QUOTA) (modules/mailserver/default-quota) — git add/commit to keep it"; fi

# Rotate a mailbox password. PWD empty = auto-generate a 16-char password and
# print it once. (PWD is make's cwd builtin — only a command-line PWD= is used.)
mail-password:
>@[ -n "$(MAIL)" ] || { scripts/lib/mklog error "usage: make mail-password MAIL=name@$(DOMAIN) [PWD=…]"; exit 1; }
>@local=$${MAIL%@*}; dom=$${MAIL#*@}; \
  if [ "$(origin PWD)" = "command line" ] && [ -n "$(PWD)" ]; then \
    docker exec mailu-admin flask mailu password "$$local" "$$dom" "$(PWD)" >/dev/null && scripts/lib/mklog info "password updated for $(MAIL)"; \
  else p=$$(openssl rand -base64 12 | tr -d '\n'); \
    docker exec mailu-admin flask mailu password "$$local" "$$dom" "$$p" >/dev/null && scripts/lib/mklog info "password for $(MAIL) updated — new password: $$p"; fi

# Card for one address: existence, quota, webmail URL. The password is hashed
# and cannot be shown — rotate with mail-password.
mail-card:
>@[ -n "$(MAIL)" ] || { scripts/lib/mklog error "usage: make mail-card MAIL=name@$(DOMAIN)"; exit 1; }
>@local=$${MAIL%@*}; \
  card=$$(docker exec mailu-admin flask mailu config-export -j 2>/dev/null | jq -r --arg e "$(MAIL)" '[.user[]? | select(.email==$$e)] as $$u | if ($$u|length)==0 then "" else "\($$u[0].email) \($$u[0].quota_bytes // "1G default") \($$u[0].global_admin // false)" end'); \
  if [ -n "$$card" ]; then set -- $$card; q="$$2"; \
    scripts/lib/mklog info "address $$1 — exists, quota $$q, webmail https://cube.$(DOMAIN) (login with '$$local')$$( [ "$$3" = true ] && echo ' · global admin' )"; \
    scripts/lib/mklog warn "password is hashed — rotate with make mail-password MAIL=$(MAIL)"; \
  else scripts/lib/mklog error "$(MAIL) not found — create with make mail-gen [MAIL=…]"; exit 1; fi

mail-list:
>@scripts/lib/mklog info "mailboxes for $(DOMAIN):"
>@docker exec mailu-admin flask mailu config-export -j 2>/dev/null \
  | jq -r '.user[]? | "\(.email) \(.quota_bytes // "1G default")\(if .global_admin then " · global admin" else "" end)"' \
  | sort -u | while IFS= read -r row; do scripts/lib/mklog info "$$row"; done

# ─────────────────────────────────────────────────────────────────────────────
# Mailserver stack (Mailu) — the compose unit itself. Lifecycle stays in the
# generic dok-* set (dok-recreate-mailserver / dok-restart-mailserver /
# dok-stop-mailserver / dok-logs-mailserver); everything here is mail-specific:
# health, the /data ownership trap, per-service logs, domains, aliases, limits,
# the admin password, registry export/import, queue, DKIM, TLS.
# Every recipe reads the live .env — no instance value is hardcoded.
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: mail-list mail-status mail-doctor mail-fix-perms mail-tls mail-logs mail-exec \
        mail-queue mail-queue-flush mail-dkim mail-domains mail-domain-add \
        mail-limits mail-manager mail-aliases mail-alias-add \
        mail-admin-password mail-config-export mail-config-import

MAIL_COMPOSE  := $(COMPOSE) $(REPO)/modules/mailserver/docker-compose.yml
MAIL_ADMIN    := docker exec mailu-admin flask mailu
MAIL_ENV      := $(REPO)/modules/mailserver/.env
MAIL_CONTAINERS := mailu-front mailu-smtp mailu-imap mailu-antispam mailu-admin mailu-redis roundcube
MAIL_SERVICES   := front smtp imap antispam admin redis roundcube
# Host path of the container's /data, and of /dkim + /mail.
MAIL_DATA_ROOT := $(or $(shell sed -n 's/^DATA_DIR=//p' $(MAIL_ENV) 2>/dev/null | head -1),$(REPO)/data)/mailserver
MAIL_DATA      := $(MAIL_DATA_ROOT)/data

# State/health table for every container in the mail stack, plus the image tag.
mail-status:
>@$(MAIL_COMPOSE) ps
>@echo ""
>@printf '  %-18s %-10s %s\n' CONTAINER STATE HEALTH
>@for c in $(MAIL_CONTAINERS); do \
    st=$$(docker inspect -f '{{.State.Status}}' $$c 2>/dev/null || echo missing); \
    he=$$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' $$c 2>/dev/null || echo -); \
    printf '  %-18s %-10s %s\n' "$$c" "$$st" "$$he"; \
  done
>@echo ""
>@scripts/lib/mklog info "image $$(docker inspect -f '{{.Config.Image}}' mailu-admin 2>/dev/null || echo '?') — admin https://mail.$(DOMAIN)/admin/ · webmail https://cube.$(DOMAIN)"

# The 2026-10-19 outage in one command: /data was root:root 700, gunicorn runs
# as uid 100, so every DB route 500'd ("unable to open database file") while the
# healthcheck still said healthy. mail-doctor opens the DB AS uid 100:1000,
# which is the only probe that actually reproduces the failure.
mail-doctor:
>@fail=0; \
  echo "== /data ownership (admin runs as uid 100:1000)"; \
  if stat -c '  uid:gid %u:%g  mode %a  %n' "$(MAIL_DATA)" "$(MAIL_DATA)/main.db" 2>/dev/null; then :; \
  else scripts/lib/mklog error "$(MAIL_DATA) missing — check DATA_DIR in $(MAIL_ENV)"; fail=1; fi; \
  if docker exec -u 100:1000 mailu-admin python3 -c 'import sqlite3;c=sqlite3.connect("file:/data/main.db?mode=ro",uri=True);print("  db ok —",c.execute("select count(*) from user").fetchone()[0],"mailboxes")' 2>/dev/null; then :; \
  else scripts/lib/mklog error "admin cannot open /data/main.db as uid 100:1000 — every DB route returns 500; fix with: make mail-fix-perms"; fail=1; fi; \
  echo "== admin http"; \
  code=$$(curl -s -o /dev/null -w '%{http_code}' "https://mail.$(DOMAIN)/sso/login" 2>/dev/null || true); \
  if [ "$$code" = 200 ]; then echo "  sso/login 200"; \
  else scripts/lib/mklog error "sso/login returned $${code:-no answer} (500 = database, 404 = wrong route — the login page lives at /sso/login, not /admin/login)"; fail=1; fi; \
  echo "== tls"; \
  end=$$(timeout 8 openssl s_client -connect "mail.$(DOMAIN):443" -servername "mail.$(DOMAIN)" </dev/null 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null || true); \
  if [ -n "$$end" ]; then echo "  mail.$(DOMAIN):443 $$end"; \
  else scripts/lib/mklog error "no TLS answer on mail.$(DOMAIN):443"; fail=1; fi; \
  echo "== containers"; \
  for c in $(MAIL_CONTAINERS); do \
    st=$$(docker inspect -f '{{.State.Status}}' $$c 2>/dev/null || echo missing); \
    if [ "$$st" = running ]; then echo "  $$c running"; \
    else scripts/lib/mklog error "$$c $$st"; fail=1; fi; \
  done; \
  exit $$fail

# Re-own the bind mount as the app user. Targeted on purpose: a recursive chown
# would also rewrite the dovecot mail store (/mail, a different uid) and break
# IMAP delivery. main.db is the file sqlite needs write access to.
mail-fix-perms:
>@d="$(MAIL_DATA)"; \
  [ -d "$$d" ] || { scripts/lib/mklog error "$$d missing — nothing to fix (check DATA_DIR in $(MAIL_ENV))"; exit 1; }; \
  before=$$(stat -c '%u:%g %a' "$$d"); \
  sudo chown 100:1000 "$$d" && sudo chmod 700 "$$d"; \
  for f in main.db roundcube.db main.db-journal main.db-wal; do \
    [ -e "$$d/$$f" ] && sudo chown 100:1000 "$$d/$$f"; \
  done; \
  scripts/lib/mklog info "$$d: $$before → 100:1000 700 (mail store left untouched)"; \
  docker exec -u 100:1000 mailu-admin python3 -c 'import sqlite3;c=sqlite3.connect("file:/data/main.db?mode=ro",uri=True);print("info:  db readable again —",c.execute("select count(*) from user").fetchone()[0],"mailboxes")' \
    || { scripts/lib/mklog error "still unreadable — container /data mount or ACLs, not ownership (see make mail-doctor)"; exit 1; }

# Certificates the mail stack actually serves: 443 (Caddy/admin SSO), 993
# (imaps), 465 (smtps). The mailu front reads $(MAIL_DATA_ROOT)/certs.
mail-tls:
>@for e in "https mail.$(DOMAIN) 443" "imaps 127.0.0.1 993" "smtps 127.0.0.1 465"; do \
    set -- $$e; \
    out=$$(echo | timeout 8 openssl s_client -connect "$$2:$$3" -servername "mail.$(DOMAIN)" 2>/dev/null | openssl x509 -noout -subject -enddate 2>/dev/null | tr '\n' ' ' || true); \
    printf '  %-8s %-28s %s\n' "$$1" "$$2:$$3" "$${out:-no answer}"; \
  done
>@ls -1 "$(MAIL_DATA_ROOT)/certs" 2>/dev/null | sed 's/^/  cert file: /' || true

# One service's log (docker logs mailu-<svc>). dok-logs-mailserver only knows
# the container named after the compose service, so it tails admin alone.
mail-logs:
>@svc="$(SERVICE)"; svc=$${svc:-admin}; \
  case " $(MAIL_SERVICES) " in *" $$svc "*) ;; \
    *) scripts/lib/mklog error "unknown SERVICE '$$svc' — one of: $(MAIL_SERVICES)"; exit 1;; esac; \
  ctr="mailu-$$svc"; [ "$$svc" = roundcube ] && ctr=roundcube; \
  docker logs "$$ctr" --tail 50 -f

# Escape hatch: anything the Mailu CLI or the image can run, inside mailu-admin.
mail-exec:
>@[ -n "$(CMD)" ] || { scripts/lib/mklog error "usage: make mail-exec CMD='<shell command>'  (e.g. CMD='flask mailu routes')"; exit 1; }
>@docker exec -i mailu-admin sh -c "$(CMD)"

mail-queue:
>@docker exec mailu-smtp postqueue -p 2>/dev/null || { scripts/lib/mklog error "postqueue unavailable — is mailu-smtp running? (make mail-status)"; exit 1; }

mail-queue-flush:
>@docker exec mailu-smtp postqueue -f && scripts/lib/mklog info "queue flush requested — postfix retries every message now"

# DKIM keys on disk (data/mailserver/dkim/<domain>.dkim.key). The public half
# is the DNS TXT record at "<selector>._domainkey.<domain>"; Mailu's admin UI
# shows it per domain ("DNS records").
mail-dkim:
>@n=0; \
  for k in "$(MAIL_DATA_ROOT)"/dkim/*.dkim.key; do \
    [ -e "$$k" ] || continue; n=$$((n+1)); \
    d=$$(basename "$$k" .dkim.key); \
    bits=$$(openssl rsa -in "$$k" -text -noout 2>/dev/null | sed -n '1s/.*(\([0-9]*\) bit.*/\1/p'); \
    scripts/lib/mklog info "$$d — $$(basename "$$k") $${bits:+($$bits-bit)} · selector 'dkim' · TXT dkim._domainkey.$$d"; \
  done; \
  [ "$$n" -gt 0 ] || { scripts/lib/mklog error "no DKIM keys in $(MAIL_DATA_ROOT)/dkim — add the domain (make mail-domain-add MAIL_DOMAIN=…), or rspamd never generated one"; exit 1; }

mail-domains:
>@$(MAIL_ADMIN) config-export -j 2>/dev/null \
  | jq -r '(.user // []) as $$u | (.domain // [])[] | .name as $$n | "\($$n) \([( $$u[] | select(.email | endswith("@" + $$n)) )] | length) mailbox(es)"' \
  | while IFS= read -r row; do scripts/lib/mklog info "$$row"; done

mail-domain-add:
>@[ -n "$(MAIL_DOMAIN)" ] || { scripts/lib/mklog error "usage: make mail-domain-add MAIL_DOMAIN=<domain>"; exit 1; }
>@$(MAIL_ADMIN) domain "$(MAIL_DOMAIN)" >/dev/null && scripts/lib/mklog info "domain $(MAIL_DOMAIN) added — publish its DKIM/TXT records (make mail-dkim) before sending as it"

# Per-domain caps: users, aliases, total mailbox bytes (0 = unlimited).
mail-limits:
>@[ -n "$(MAIL_DOMAIN)" ] && [ -n "$(USERS)" ] && [ -n "$(ALIASES)" ] && [ -n "$(QUOTA)" ] \
    || { scripts/lib/mklog error "usage: make mail-limits MAIL_DOMAIN=<domain> USERS=<n> ALIASES=<n> QUOTA=<2G|0>"; exit 1; }
>@bytes=$$(numfmt --from=iec "$(QUOTA)" 2>/dev/null || echo "$(QUOTA)"); \
  $(MAIL_ADMIN) setlimits "$(MAIL_DOMAIN)" "$(USERS)" "$(ALIASES)" "$$bytes" >/dev/null \
    && scripts/lib/mklog info "$(MAIL_DOMAIN) limits: users=$(USERS) aliases=$(ALIASES) quota=$(QUOTA)"

# USER takes the full address; the CLI wants localpart + domain separately.
mail-manager:
>@[ -n "$(MAIL_DOMAIN)" ] || { scripts/lib/mklog error "usage: make mail-manager MAIL_DOMAIN=<domain> USER=<addr@domain>"; exit 1; }
>@case "$(USER)" in \
    *@*) ;; \
    *) scripts/lib/mklog error "USER must be a full address (USER='<addr@domain>') — USER is never taken from the environment"; exit 1;; \
  esac
>@u="$(USER)"; $(MAIL_ADMIN) setmanager "$(MAIL_DOMAIN)" "$${u%@*}" >/dev/null \
    && scripts/lib/mklog info "$${u%@*} is now a manager of $(MAIL_DOMAIN)"

mail-aliases:
>@$(MAIL_ADMIN) config-export -j 2>/dev/null \
  | jq -r '(.alias // [])[] | "\(.email) → \((.destination // []) | if type==\"array\" then join(\", \") else . end)"' \
  | while IFS= read -r row; do scripts/lib/mklog info "$$row"; done
>@$(MAIL_ADMIN) config-export -j 2>/dev/null | jq -e '(.alias // []) | length > 0' >/dev/null 2>&1 \
  || scripts/lib/mklog warn "no aliases yet — make mail-alias-add FROM=… TO=…"

# Set (or replace) an alias target list. Mailu aliases are a single target
# string; comma-separate several: TO='a@x.example,b@y.example'.
mail-alias-add:
>@[ -n "$(FROM)" ] && [ -n "$(TO)" ] \
    || { scripts/lib/mklog error "usage: make mail-alias-add FROM=<addr> TO=<target[,target2]>"; exit 1; }
>@$(MAIL_ADMIN) alias "$${FROM%@*}" "$${FROM#*@}" "$(TO)" >/dev/null \
    && scripts/lib/mklog info "alias $(FROM) → $(TO)"

# The Mailu (instance) admin login — NOT a mailbox password (that is
# mail-password). The CLI shape is `admin <localpart> <domain> <password>`;
# the malformed `flask mailu password admin fxmq.net 'admin123'` that took the
# page down on 2026-10-19 was one argument too many and changed nothing.
mail-admin-password:
>@p="$(if $(filter command line,$(origin PWD)),$(PWD))"; gen=0; \
  [ -n "$$p" ] || { p=$$(openssl rand -base64 12 | tr -d '\n'); gen=1; }; \
  acct=$$(sed -n 's/^INITIAL_ADMIN_ACCOUNT=//p' $(MAIL_ENV) 2>/dev/null | head -1); acct=$${acct:-admin}; \
  adom=$$(sed -n 's/^INITIAL_ADMIN_DOMAIN=//p' $(MAIL_ENV) 2>/dev/null | head -1); adom=$${adom:-$(DOMAIN)}; \
  $(MAIL_ADMIN) admin -m update "$$acct" "$$adom" "$$p" >/dev/null \
    || { scripts/lib/mklog error "could not set the admin password for $$acct@$$adom"; exit 1; }; \
  if [ "$$gen" = 1 ]; then scripts/lib/mklog info "admin $$acct@$$adom password: $$p (printed once)"; \
  else scripts/lib/mklog info "admin $$acct@$$adom password updated"; fi; \
  mode=$$(sed -n 's/^INITIAL_ADMIN_MODE=//p' $(MAIL_ENV) 2>/dev/null | head -1); \
  if [ "$$mode" = update ]; then \
    scripts/lib/mklog warn "INITIAL_ADMIN_MODE=update — the admin container resets this from INITIAL_ADMIN_PW on its next start; put the new password in $(MAIL_ENV) too, or it reverts"; \
  fi

# Full registry as JSON on stdout. FILE=<path> writes it to the host;
# SECRETS=1 adds password hashes and the DKIM private keys (keep that file
# private — it is not backed up and must never be committed).
mail-config-export:
>@f="$(FILE)"; s="$(if $(filter command line,$(origin SECRETS)),-s)"; \
  if [ -n "$$f" ]; then \
    $(MAIL_ADMIN) config-export -j $$s > "$$f" \
      && scripts/lib/mklog info "registry written to $$f$$( [ -n "$$s" ] && echo ' (WITH secrets — do not commit, do not taildrop unencrypted)' )"; \
  else \
    $(MAIL_ADMIN) config-export -j $$s; \
  fi

# Apply a registry dump (domains/users/aliases) from a file. Export one first —
# this MERGES into the live registry and overwrites entries named in the file.
mail-config-import:
>@[ -n "$(FILE)" ] || { scripts/lib/mklog error "usage: make mail-config-import FILE=<registry.yaml|registry.json>"; exit 1; }
>@[ -r "$(FILE)" ] || { scripts/lib/mklog error "cannot read $(FILE)"; exit 1; }
>@docker exec -i mailu-admin flask mailu config-import - < "$(FILE)" >/dev/null \
    && scripts/lib/mklog info "registry imported from $(FILE) — verify with make mail-domains and make mail-list"

# Regenerate the tail terminal's navigation catalogue from the Caddy vhost
# files ($DATA_DIR/pages/tail/targets.json — GENERATED, do not hand-edit). Run
# after adding a vhost or a public path; `make install-config` runs it too.
tail-targets:
>@bash scripts/access/tail-targets.sh

# ─────────────────────────────────────────────────────────────────────────────
# Uptime Kuma accounts (no CLI — scripts/modules/kuma-user.sh: bcryptjs hash in the
# container + host sqlite3 on kuma/data/kuma.db; plaintext never crosses)
# ─────────────────────────────────────────────────────────────────────────────
kuma-list-users:
>@bash scripts/modules/kuma-user.sh list

kuma-add-user:
>@[ -n "$(USER)" ] && [ -n "$(PASS)" ] || { scripts/lib/mklog error "usage: make kuma-add-user USER=<name> PASS=<password>"; exit 1; }
>@bash scripts/modules/kuma-user.sh add "$(USER)" "$(PASS)"

kuma-passwd:
>@[ -n "$(USER)" ] && [ -n "$(PASS)" ] || { scripts/lib/mklog error "usage: make kuma-passwd USER=<name> PASS=<newpassword>"; exit 1; }
>@bash scripts/modules/kuma-user.sh passwd "$(USER)" "$(PASS)"

kuma-del-user:
>@[ -n "$(USER)" ] || { scripts/lib/mklog error "usage: make kuma-del-user USER=<name>"; exit 1; }
>@bash scripts/modules/kuma-user.sh del "$(USER)"

# Import an adapted Uptime Kuma db from another host (KUMA_DB=/path).
kuma-import:
>@[ -n "$(KUMA_DB)" ] || { scripts/lib/mklog error "usage: make kuma-import KUMA_DB=<path>"; exit 1; }
>@sudo scripts/modules/kuma-import.sh "$(KUMA_DB)"

# ─────────────────────────────────────────────────────────────────────────────
# Vaultwarden accounts (no CLI — scripts/modules/vaultwarden-user.sh recreates
# Bitwarden's client crypto and writes vault/data/db.sqlite3; the plaintext
# never leaves the process and is never written down)
# ─────────────────────────────────────────────────────────────────────────────
vaultwarden-list-users:
>@bash scripts/modules/vaultwarden-user.sh list

vaultwarden-add-user:
>@[ -n "$(EMAIL)" ] && [ -n "$(PASS)" ] || { scripts/lib/mklog error "usage: make vaultwarden-add-user EMAIL=<addr> PASS=<password>"; exit 1; }
>@bash scripts/modules/vaultwarden-user.sh add "$(EMAIL)" "$(PASS)"

vaultwarden-del-user:
>@[ -n "$(EMAIL)" ] || { scripts/lib/mklog error "usage: make vaultwarden-del-user EMAIL=<addr>"; exit 1; }
>@bash scripts/modules/vaultwarden-user.sh del "$(EMAIL)"

# Generate the Nextcloud-stack secrets + Talk service configs (idempotent).
# Creates modules/nextcloud/.env entries (DB, Redis, signaling, TURN, SMTP)
# if missing and renders $(REPO)/data/talk/{server,turnserver}.conf.
talk-gen:
>@bash scripts/modules/talk-gen.sh

# Force EVERY Talk call through this stack's signalling server and media path —
# not only the calls that happen to need media relay:
#  * signaling_mode=external — pins the high-performance backend for every
#    conversation, 1:1 calls included. Without the explicit pin Talk DERIVES the
#    mode from the server list and falls back to internal signalling (no HPB at
#    all: no chat relay, no participant relay) whenever that list looks empty.
#  * stun_servers — replaces the third-party default (stun.nextcloud.com:443)
#    with our own coturn, so every candidate a client learns comes from this
#    host and no call depends on Nextcloud's public STUN. TURN (udp/tcp 3478,
#    tls 5349) is registered by `make nc-talk-turn-add` / the installer and is
#    the only ICE server that can produce a relayed candidate.
talk-config:
>@$(NC_OCC) config:app:set spreed signaling_mode --value external
>@$(NC_OCC) config:app:set spreed stun_servers --value '["stun:talk.$(DOMAIN):3478"]'
>@scripts/lib/mklog info "Talk: every call pinned to the HPB (signaling_mode=external); STUN/TURN = talk.$(DOMAIN)"

# Snapshot the live NC users/groups/quotas into cloud/recovery/ outside the
# repo (generated recovery manifests — the installer recreates exactly this
# state on fresh installs; re-run after any user/group change).
nc-capture:
>@bash scripts/modules/nc-capture.sh

# `make nc-datadir-nfs`: make an external machine the PERMANENT live
# datadir host for THIS Nextcloud over the tailnet. export: this host's
# datadirectory moves over NFS to the external machine (database stays here);
# import restores THIS host's own previously-exported datadir (marker-driven:
# import only accepts the datadir exported by this host, never a foreign one).
# The external machine gets tailscale + ufw + the NFS stack set up.
nc-datadir-nfs:
>@bash scripts/ops/nc-datadir-nfs.sh

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
sudo install -d -m 0700 $(DATA_DIR)/goose; if sudo test -s $(DATA_DIR)/goose/.env; then :; elif sudo test -s /etc/goose/goose.env; then scripts/lib/mklog info "goose env: migrating /etc/goose/goose.env -> $(DATA_DIR)/goose/.env"; sudo cp -p /etc/goose/goose.env $(DATA_DIR)/goose/.env; else echo "GOOSE_SERVER__SECRET_KEY=$$(openssl rand -hex 32)" | sudo tee $(DATA_DIR)/goose/.env >/dev/null; fi; sudo chown root:root $(DATA_DIR)/goose/.env; sudo chmod 0600 $(DATA_DIR)/goose/.env
sudo cp $(RENDER_DIR)/config/goose/goose.service /etc/systemd/system/goose.service
bash $(REPO)/scripts/info/goose-tokens.sh
sudo cp $(RENDER_DIR)/config/ssh/50-cloud-init.conf /etc/ssh/sshd_config.d/50-cloud-init.conf
# The tracked copy keeps a PLACEHOLDER tailnet address; the live IP is rendered
# in at deploy time so an instance-specific address never lands in a tracked
# file (AGENTS rule 12). The old plain `cp` here silently overwrote the live
# 10-tailnet.conf with the placeholder — dnsmasq then fail-looped on
# "Cannot assign requested address" and tailnet DNS died with it.
@TS_IP=$$(tailscale ip -4 2>/dev/null | head -n1); \
    [ -n "$$TS_IP" ] || { scripts/lib/mklog error "no tailscale IP — cannot render 10-tailnet.conf"; exit 1; }; \
    sed "s/100.64.0.1/$$TS_IP/g" $(RENDER_DIR)/config/dnsmasq/10-tailnet.conf | sudo tee /etc/dnsmasq.d/10-tailnet.conf >/dev/null
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
# config/docker/daemon.json (10m x3); no journald drop-in exists —
# caps — nothing here logs unboundedly, and nothing uses chronicle-style
# per-event logging.
sudo install -d -m 0755 $(DATA_DIR)/logs
sudo cp $(RENDER_DIR)/config/logrotate/instance /etc/logrotate.d/instance
sudo chmod 0644 /etc/logrotate.d/instance
sudo systemctl enable --now fail2ban
sudo ufw --force delete allow from 172.22.0.0/16 to any port 7681 proto tcp 2>/dev/null || true
sudo cp $(RENDER_DIR)/config/systemd/kefo-stack.service /etc/systemd/system/kefo-stack.service
sudo cp $(RENDER_DIR)/config/systemd/tmux-main.service /etc/systemd/system/tmux-main.service
sudo systemctl daemon-reload
sudo systemctl enable --now goose ttyd
sudo systemctl enable kefo-stack.service
@scripts/lib/mklog info "boot unit installed + enabled: kefo-stack.service (every deployed compose unit comes up on boot)"
sudo systemctl enable --now tmux-main.service
@scripts/lib/mklog info "tmux 'main' session ensured + enabled (make tmux-open TAG=main to attach)"
sudo systemctl restart sshd dnsmasq
@scripts/lib/mklog info "host install-config complete: goose + ttyd + dnsmasq + fail2ban + sshd + cron installed"
endef

install-config:
>$(install_config_cmds)

# Full host restore: config/ → live paths. Same one-shot body as
# install-config (one implementation, so the two can never diverge); module
# data and secrets are restored separately with import-backups.
deploy: install-config

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
>@sudo install -d -m 0700 $(DATA_DIR)/goose; if sudo test -s $(DATA_DIR)/goose/.env; then scripts/lib/mklog info "goose env already present: $(DATA_DIR)/goose/.env"; elif sudo test -s /etc/goose/goose.env; then scripts/lib/mklog info "goose env: migrating /etc/goose/goose.env -> $(DATA_DIR)/goose/.env"; sudo cp -p /etc/goose/goose.env $(DATA_DIR)/goose/.env; else echo "GOOSE_SERVER__SECRET_KEY=$$(openssl rand -hex 32)" | sudo tee $(DATA_DIR)/goose/.env >/dev/null; fi; sudo chown root:root $(DATA_DIR)/goose/.env; sudo chmod 0600 $(DATA_DIR)/goose/.env
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
    [ -n "$$TS_IP" ] || { scripts/lib/mklog error "no tailscale IP — cannot render 10-tailnet.conf"; exit 1; }; \
    sed "s/100.64.0.1/$$TS_IP/g" $(RENDER_DIR)/config/dnsmasq/10-tailnet.conf | sudo tee /etc/dnsmasq.d/10-tailnet.conf >/dev/null; \
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
# Runs on this host for now; migrates to the operator's 1 TB machine later
# (see docs/GUIDE.md "Nextcloud DB"). Deliberately NOT in $(CONTAINERS) —
# the -all loops glob modules/*/docker-compose.yml only, and this file is
# named docker-compose.db.yml so they never see it.
# ─────────────────────────────────────────────────────────────────────────────

dok-recreate-nextcloud-db:
>$(COMPOSE) $(REPO)/modules/nextcloud/docker-compose.db.yml up -d --force-recreate --remove-orphans

dok-restart-nextcloud-db:
>$(COMPOSE) $(REPO)/modules/nextcloud/docker-compose.db.yml restart

dok-stop-nextcloud-db:
>$(COMPOSE) $(REPO)/modules/nextcloud/docker-compose.db.yml stop

dok-logs-nextcloud-db:
>docker logs postgresql --tail 50 -f


# ──────────────────────────────────────────────────────────────────────────────
# Backups
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: backup

# Ships ALL installed modules to a tailnet device (taildrop), in one of two modes
# (prompted, or BACKUP_MODE=bundle|raw):
#   bundle — nextcloud-backup-<date>.tar.gz (PostgreSQL DB + Nextcloud datadir),
#            other-backup-<date>.tar.gz (vault / mailserver / kuma datadirs).
#   raw    — nextcloud-<date>/ and others-<date>/ raw datadirectories.
# Staged in a temp dir, taildropped to the device's ~/backups/, sha256-verified,
# then deleted locally. No local copies; repo/config is never read or written.
backup:
ifeq ($(TAILDROP),)
>@scripts/lib/mklog error "usage: make backup requires TAILDROP=<tailnet-device> — ships all modules to a tailnet device as bundles (default) or raw datadirectories (BACKUP_MODE=raw); data/ is untouched and repo/config is never read or written"
>@exit 1
endif
>BACKUP_MODE="$(BACKUP_MODE)" bash scripts/ops/backup-bundles.sh TAILDROP="$(TAILDROP)"

import-backups:
ifeq ($(TAILDROP),)
>@scripts/lib/mklog error "usage: make import-backups requires TAILDROP=<tailnet-device> — previews the bundles or raw datadirectories on the device and asks for a typed yes before restoring anything"
>@exit 1
endif
>@bash scripts/ops/restore-data.sh TAILDROP="$(TAILDROP)"

# ──────────────────────────────────────────────────────────────────────────────
# Sandbox modules (everything lives in data/sandbox/ — untracked, never pushed)
# ──────────────────────────────────────────────────────────────────────────────

.PHONY: sandbox-sync

# The one manual reconcile. `make render` rsyncs data/rendered/caddy with
# --delete, which drops the sandbox vhosts, and a project can stop after a
# `compose down` — this re-applies every sandbox vhost, prunes the doors of
# modules that are gone, revives stopped projects, then validates and restarts
# the edge. It reads the repo and never writes it.
sandbox-sync:
>@bash scripts/sandbox/editor.sh sync

# Tmux sessions
# Persistent terminal sessions on the host — detach (Ctrl-b d) and the
# shell + whatever's running inside it stays alive; reattach from any
# terminal with `make tmux-open TAG=<n>` (or `tmux attach -t <n>`).
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: tmux-new tmux-open tmux-kill tmux-list

tmux-new:
>@if [ -z "$(TAG)" ]; then \
    scripts/lib/mklog error "usage: make tmux-new TAG=<session>   (TAG is required)"; \
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
    scripts/lib/mklog error "usage: make tmux-open TAG=<session>"; \
    exit 1; \
  fi
>@if ! tmux has-session -t "$(TAG)" 2>/dev/null; then \
    echo "Session '$(TAG)' does not exist. Create it with: make tmux-new TAG=$(TAG)"; \
    exit 1; \
  fi
>@tmux attach -t "$(TAG)"

tmux-kill:
>@if [ -z "$(TAG)" ]; then \
    scripts/lib/mklog error "usage: make tmux-kill TAG=<session>"; \
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
	nc-user-setting nc-scan nc-groups nc-jobs nc-talk-signaling nc-core-update nc-app-update \
	nc-talk-signaling-del nc-talk-turn nc-talk-turn-add nc-talk-turn-del \
	nc-2fa-enforce nc-logs

nc-occ:
>@if [ -z "$(CMD)" ]; then \
    scripts/lib/mklog error "usage: make nc-occ CMD='<occ command + args>'  (e.g. CMD='status' or CMD='app:list')"; \
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

# Core update by compose image tag (the web updater also works — data/cloud/html
# is a host bind mount, so its result survives recreates — this keeps the tag in
# step with the installed code). Without VERSION it resolves the latest patch of
# the running major from Docker Hub, and refuses a downgrade.
nc-core-update:
>@VERSION=$(VERSION) $(REPO)/scripts/modules/nc-core-update.sh

nc-app-update:
>$(NC_OCC) app:update --all

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
>@if [ -z "$(APP)" ]; then scripts/lib/mklog error "usage: make nc-app-enable APP=<app-id>"; exit 1; fi
>$(NC_OCC) app:enable "$(APP)"

nc-app-disable:
>@if [ -z "$(APP)" ]; then scripts/lib/mklog error "usage: make nc-app-disable APP=<app-id>"; exit 1; fi
>$(NC_OCC) app:disable "$(APP)"

nc-config-get:
>@if [ -z "$(KEY)" ]; then scripts/lib/mklog error "usage: make nc-config-get KEY=<config-key>"; exit 1; fi
>$(NC_OCC) config:system:get "$(KEY)"

nc-config-set:
>@if [ -z "$(KEY)" ] || [ -z "$(VALUE)" ]; then \
    scripts/lib/mklog error "usage: make nc-config-set KEY=<key> VALUE=<value> [TYPE=string|integer|boolean|array]"; \
    exit 1; \
  fi
>$(NC_OCC) config:system:set "$(KEY)" --value "$(VALUE)" $(TYPE:%=--type %)

# Set the default storage quota for NEW users (files app 'default_quota' —
# an APP config, so nc-config-set (system config) is the wrong tool) and sync
# the recovery manifest so a fresh install reproduces it.
nc-default-user-quota:
>@if [ -z "$(VALUE)" ]; then \
    scripts/lib/mklog error "usage: make nc-default-user-quota VALUE='100 GB'  (or 'none' for unlimited)"; \
    exit 1; \
  fi
>$(NC_OCC) config:app:set files default_quota --value "$(VALUE)"
>@printf '# GENERATED by make nc-default-user-quota (%s) — do not edit; re-run to refresh.\n# Default storage quota for NEW users (files app '\''default_quota'\'').\n%s\n' "$$(date -Is)" "$(VALUE)" > $(REPO)/data/cloud/recovery/default-quota

nc-users:
>$(NC_OCC) user:list

nc-user-add:
>@if [ -z "$(USER)" ]; then scripts/lib/mklog error "usage: make nc-user-add USER=<uid> [PASS=<password>]"; exit 1; fi
>@if [ -n "$(PASS)" ]; then \
    docker exec -u www-data -e OC_PASS="$(PASS)" nextcloud php occ user:add --password-from-env "$(USER)"; \
  else \
    $(NC_OCC) user:add "$(USER)"; \
  fi

nc-user-del:
>@if [ -z "$(USER)" ]; then scripts/lib/mklog error "usage: make nc-user-del USER=<uid>"; exit 1; fi
>$(NC_OCC) user:delete "$(USER)"

nc-user-password:
>@if [ -z "$(USER)" ]; then scripts/lib/mklog error "usage: make nc-user-password USER=<uid> [PASS=<password>]"; exit 1; fi
>@if [ -n "$(PASS)" ]; then \
    docker exec -u www-data -e OC_PASS="$(PASS)" nextcloud php occ user:resetpassword --password-from-env "$(USER)"; \
  else \
    $(NC_OCC) user:resetpassword "$(USER)"; \
  fi

nc-user-setting:
>@if [ -z "$(USER)" ] || [ -z "$(KEY)" ] || [ -z "$(VALUE)" ]; then \
    scripts/lib/mklog error "usage: make nc-user-setting USER=<uid> KEY=<setting-key> VALUE=<value>  (e.g. KEY=email)"; \
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
    scripts/lib/mklog error "usage: make nc-talk-signaling-add URL=<server-url> SECRET=<shared-secret>"; \
    exit 1; \
  fi
>$(NC_OCC) talk:signaling:add "$(URL)" "$(SECRET)"

nc-talk-signaling-del:
>@if [ -z "$(URL)" ]; then scripts/lib/mklog error "usage: make nc-talk-signaling-del URL=<server-url>"; exit 1; fi
>$(NC_OCC) talk:signaling:delete "$(URL)"

nc-talk-turn:
>$(NC_OCC) talk:turn:list

nc-talk-turn-add:
>@if [ -z "$(SERVER)" ] || [ -z "$(SECRET)" ]; then \
    scripts/lib/mklog error "usage: make nc-talk-turn-add SERVER='<schemes> <host:port> <protocols>' SECRET=<shared-secret>  (schemes: turn|turns|turn,turns; protocols: udp|tcp|udp,tcp — positional, spreed has no --udp/--tcp)"; \
    exit 1; \
  fi
>$(NC_OCC) talk:turn:add $(SERVER) --secret "$(SECRET)"

nc-talk-turn-del:
>@if [ -z "$(SERVER)" ]; then scripts/lib/mklog error "usage: make nc-talk-turn-del SERVER='scheme host:port'"; exit 1; fi
>$(NC_OCC) talk:turn:delete $(SERVER)

nc-2fa-enforce:
>@if [ -z "$(USER)" ]; then scripts/lib/mklog error "usage: make nc-2fa-enforce USER=<uid>"; exit 1; fi
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

.PHONY: git-pull git-add git-com git-push git-force-push git-audit git-split

git-pull:
>cd $(REPO) && git pull --ff-only

# Commit-hygiene monitor (scripts/info/git-audit.sh). Walks a revision range and
# reports the two rules a commit cannot check about itself: rule 26 (one change
# per commit — one folder plus at most one subfolder, the same unit the
# pre-commit hook splits on) and
# rule 10 (a `Revert:` line in the message of every significant commit). Default
# range: what a push would publish; RANGE=<a..b> audits anything (RANGE=origin/main
# = the whole published history). The pre-push hook runs it over every pushed
# range and refuses on a violation — that is the only way to catch a commit made
# in the GitHub web editor, which runs no local hook.
git-audit:
>@bash scripts/info/git-audit.sh $(RANGE)

# The rewriter behind the two hooks (scripts/info/git-split.sh). It performs the
# fix `git-audit` only reports: split a bundle commit into one commit per unit
# (rule 26) and fill in the `Revert:` line of every significant commit with its
# real parent SHA (rule 10) — a replay/rebase over the given range. Refuses to
# rewrite any published commit, and needs a clean worktree. RANGE defaults to what
# a push would publish (`make git-split RANGE=<a..b>`); `ARGS=--dry-run` reports
# only. The prepare-commit-msg hook calls it with --staged; the pre-push hook
# calls it over the pushed range.
git-split:
>@bash scripts/info/git-split.sh $(ARGS) $(RANGE)

git-add:
>cd $(REPO) && git add -A

git-com:
>@if [ -z "$(MSG)" ]; then \
    scripts/lib/mklog error "usage: make git-com MSG=\"...\"  (MSG is required)"; \
    exit 1; \
  fi
>cd $(REPO) && git commit -m "$(MSG)"

git-push:
>cd $(REPO) && git push

# Force-push a branch whose history was rewritten (identity swap, linearization,
# path scrub). --force-with-lease ONLY: it refuses when the remote tip is not the
# one we last fetched, so it can never clobber a commit pushed from elsewhere.
# BRANCH is required and may list several branches. Before any rewrite keep the
# old tip in a refs/backup/* ref (that ref is the revert path).
# Revert of a rewrite pushed this way: git reset --hard <refs/backup/* tip>, then
# make git-force-push BRANCH=<branch>.
git-force-push:
>@[ -n "$(BRANCH)" ] || { scripts/lib/mklog error "usage: make git-force-push BRANCH=<branch> [BRANCH2 …]"; exit 1; }
>cd $(REPO) && git push --force-with-lease origin $(BRANCH)

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

# Same device argument as backup/import-backups (TAILDROP, defined at the top).
# make taildrop-file FILE=path TAILDROP=<device>    (sudo tailscale file cp)
# make taildrop-folder DIR=path TAILDROP=<device>
taildrop-file:
>@[ -n "$(FILE)" ] || { scripts/lib/mklog error "usage: make taildrop-file FILE=<path> TAILDROP=<device>"; exit 1; }
>@[ -n "$(TAILDROP)" ] || { scripts/lib/mklog error "usage: make taildrop-file FILE=<path> TAILDROP=<device>"; exit 1; }
>@sudo tailscale file cp "$(FILE)" "$(TAILDROP):"

taildrop-folder:
>@[ -n "$(DIR)" ] || { scripts/lib/mklog error "usage: make taildrop-folder DIR=<folder> TAILDROP=<device>"; exit 1; }
>@[ -n "$(TAILDROP)" ] || { scripts/lib/mklog error "usage: make taildrop-folder DIR=<folder> TAILDROP=<device>"; exit 1; }
>@sudo tailscale file cp -r "$(DIR)" "$(TAILDROP):"

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
>@[ -n "$(MODULE)" ] || { scripts/lib/mklog error "usage: make goose-review MODULE=<cloud|vault|mail|monitor|edge>"; exit 1; }
>@GOOSE_RECIPE_PATH=$(GOOSE_RECIPE_PATH) goose run --recipe review-module --params module=$(MODULE)

goose-troubleshoot:
>@[ -n "$(SERVICE)" ] || { scripts/lib/mklog error "usage: make goose-troubleshoot SERVICE=<hostname|container|recipe>"; exit 1; }
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
>@[ -n "$(CHANGE)" ] || { scripts/lib/mklog error "usage: make goose-deploy-plan CHANGE='<what to change>'"; exit 1; }
>@GOOSE_RECIPE_PATH=$(GOOSE_RECIPE_PATH) goose run --recipe deployment-plan --params change=$(CHANGE)
