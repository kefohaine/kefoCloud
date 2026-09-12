#!/usr/bin/env bash
#
# scripts/help.sh — the `make help` / `make help-more` renderer.
#
# Two aligned, colored lists in the same house style as scripts/status.sh
# (colors auto-disable when stdout is not a tty or NO_COLOR is set):
#   core (make help)      the common daily surface — dashboard, maintain,
#                         git, container/unit/tmux basics
#   more (make help-more) the granular / technical recipes — per-file
#                         installs, bundles, granular backup & clean
#                         primitives, account registries, the occ wrappers
#
# Usage: help.sh [core|more]   (default core)
# Rows are `command|description` heredocs — keep one row per line, no `|`
# inside a description.

set -uo pipefail
export LC_ALL=C

MODE="${1:-core}"
case "$MODE" in core|more) ;; *) echo "usage: $0 [core|more]" >&2; exit 1 ;; esac

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m' D=$'\033[2m' C=$'\033[36m' N=$'\033[0m'
else
  B='' D='' C='' N=''
fi

W=30   # command column width
row()  { printf "  %s%-*s%s %s\n" "${C}${B}" "$W" "$1" "$N" "$2"; }
sec()  { printf "\n  %s%s%s\n" "${B}" "$1" "$N"; }
rule() { printf "  %s%s%s\n" "$D" "$(printf '%*s' 62 '' | tr ' ' '-')" "$N"; }
rows() { while IFS='|' read -r c d; do row "$c" "$d"; done; }
hdr()  { echo ""; printf "  %s%s%s %s· %s%s\n" "$B" "$1" "$N" "$D" "$2" "$N"; rule; }

core() {
  hdr "make help — common recipes" "the daily surface · everything else: make help-more"

  sec "dashboard & health"
  rows <<'EOF'
make status|AIO dashboard — host perf, modules, git, units, docker, tmux, backups, mail, tailnet
make smoke|live edge test — every vhost, tailnet edge, tls, mail, panel lockdown (pre-push hook runs it)
EOF

  sec "maintain"
  rows <<'EOF'
make update|apt update/upgrade, then docker pull + force-recreate every service
make backup|container databases & secrets → backups/; live server config → repo/config/ (git add/commit after)
make cleanup|apt autoremove/clean, docker prune, keep latest 3 backups per pattern
EOF

  sec "migrate / restore"
  rows <<'EOF'
make migrate|print the migration runbook (docs/MIGRATE.md)
make deploy|restore a host — config/ → live paths + the newest secrets bundle
EOF

  sec "git"
  rows <<'EOF'
make git-pull|pull remote changes
make git-add|stage every change
make git-com MSG=<sentence>|commit staged changes — single-sentence MSG only
make git-push|push to the remote
EOF

  sec "docker containers"
  rows <<'EOF'
make dok-recreate TARGET=<ctn>|force-recreate one container — or append -<ctn> / -all
make dok-restart TARGET=<ctn>|restart one container — same -<ctn> / -all forms
make dok-stop TARGET=<ctn>|stop one container — same forms
make dok-logs TARGET=<ctn>|tail one container's logs (last 50, follow) — dok-logs-all follows every container
EOF

  sec "host units (systemd)"
  rows <<'EOF'
make systemd-restart-<svc>|restart one host unit — systemd-restart-all for every unit
make systemd-log-<svc>|follow one host unit's journal (last 50) — systemd-log-all for every unit
EOF

  sec "tmux sessions"
  rows <<'EOF'
make tmux-new TAG=<tag>|create a detached session
make tmux-open TAG=<tag>|attach to a session (Ctrl-b d detaches)
make tmux-kill TAG=<tag>|kill a session
make tmux-list|list sessions
EOF

  rule
  echo ""
}

more() {
  hdr "make help-more — technical recipes" "the granular surface · common recipes: make help"

  sec "config → live (host bootstrap)"
  rows <<'EOF'
make install-config|one-shot host bootstrap — copy every config/ file to its live path
make install-goose|goose.service → /etc/systemd/system (+ generate goose.env if missing)
make install-ttyd|ttyd.service → /etc/systemd/system (refuses to run from inside ttyd)
make install-ssh|50-cloud-init.conf → sshd_config.d (validates with sshd -t, then restarts)
make install-dnsmasq-conf|10-tailnet.conf → /etc/dnsmasq.d
make install-dnsmasq-override|dnsmasq drop-in override → /etc/systemd/system/dnsmasq.service.d
make install-docker|daemon.json → /etc/docker (docker daemon restart needed to apply)
make install-sysctl|99-homelab.conf → /etc/sysctl.d
make install-cron|nextcloud → /etc/cron.d (occ cron every 5 min)
make install-hooks|git hooks — pre-commit edge guard, pre-push smoke + history-rewrite warning
EOF

  sec "bundles (live ↔ tarball)"
  rows <<'EOF'
make bundle-secrets|live secrets → backups/secrets-bundle-<date>.tar.gz
make install-secrets|newest secrets bundle → live paths (BUNDLE=<path> to override)
make bundle-config|config/ → backups/config-bundle-<date>.tar.gz
make install-config-bundle|newest config bundle → repo/config/ (BUNDLE=<path> to override)
EOF

  sec "granular backup & clean (behind make backup / make cleanup)"
  rows <<'EOF'
make bkp-cloud|Nextcloud snapshot — maintenance mode during the copy
make bkp-vault|Vaultwarden data tar
make bkp-list|list backup artifacts + count per pattern
make clean-docker|prune builder, images, containers
make clean-apt|apt autoremove + clean
make clean-backups|keep latest 3 per pattern, delete older
EOF

  sec "onboarding & stack tools"
  rows <<'EOF'
make storage|move the live NC datadirectory to the storage VPS (NFS over tailnet)
make talk-gen|generate NC-stack secrets + Talk/TURN configs (idempotent)
make nc-capture|snapshot live NC users/groups/quotas → recovery manifests (outside the repo)
make kuma-import|import an adapted Uptime Kuma db (KUMA_DB=<path>)
make gh-web-health|check the GitHub web git-data endpoints (after a history rewrite)
make tail-targets|regenerate the tail terminal's vhost catalogue (after adding a vhost)
make tail-auth|set/rotate the tail web terminal's basic-auth password — printed once, never stored
EOF

  sec "nextcloud db unit (PostgreSQL — not in the -all loops)"
  rows <<'EOF'
make dok-recreate-nextcloud-db|force-recreate the PostgreSQL compose unit
make dok-restart-nextcloud-db|restart the PostgreSQL container
make dok-stop-nextcloud-db|stop the PostgreSQL container
make dok-logs-nextcloud-db|tail the PostgreSQL container logs
EOF

  sec "taildrop (send to another tailnet device)"
  rows <<'EOF'
make taildrop-file|FILE=<path> [TAILDROP_HOST=<device>] — send one file
make taildrop-folder|DIR=<folder> [TAILDROP_HOST=<device>] — send a folder (-r)
EOF

  sec "mail registry (webmail login = local part only)"
  rows <<'EOF'
make mail-gen|create a mailbox — empty MAIL / PWD / QUOTA = auto-generated (PWD printed once)
make mail-gen-alias|disposable forwarding alias TO=<target> (random local part, same-domain refused)
make mail-del|delete an address + all its stored mail (MAIL=<addr>)
make mail-del-alias|remove one alias target (FROM=<addr> TO=<target>)
make mail-quota|set a quota (MAIL=<addr> QUOTA=<2G>; no MAIL = the mail-gen default)
make mail-password|rotate a mailbox password (MAIL=<addr>; empty PWD = new one printed once)
make mail-card|one address card — exists, quota, webmail URL (MAIL=<addr>)
EOF

  sec "panel accounts (PufferPanel)"
  rows <<'EOF'
make panel-list-users|list users — id/username/email, passwords never shown
make panel-add-user|add a user — USER=<email> NAME=<name> [PASS=…] [ADMIN=1]
make panel-del-user|delete a user + their permissions (USER=<email>)
make panel-passwd|reset a password (USER=<email> [PASS=…]) — restarts the panel, stopping a running game server
EOF

  sec "kuma accounts (Uptime Kuma)"
  rows <<'EOF'
make kuma-list-users|list users
make kuma-add-user|add a user — USER=<name> PASS=<password>
make kuma-passwd|rotate a password — USER=<name> PASS=<new>
make kuma-del-user|delete a user + their monitors/notifications (USER=<name>)
EOF

  sec "nextcloud occ (runs as www-data inside the container)"
  rows <<'EOF'
make nc-occ CMD=<occ args>|any occ command verbatim — the escape hatch
make nc-status|occ status (nc-check = occ check)
make nc-update-check|occ update:check — newer version available?
make nc-upgrade|occ upgrade — apply DB migrations after an image bump
make nc-cron|set the background-jobs mode to cron
make nc-cron-run|run cron.php once now (host cron does it every 5 min)
make nc-maintenance-on|maintenance mode on (off: nc-maintenance-off)
make nc-repair|occ maintenance:repair --include-expensive
make nc-db-indices|add missing indices (columns: nc-db-columns · primary keys: nc-db-primary-keys · bigint: nc-db-bigint)
make nc-apps|occ app:list (enable/disable: nc-app-enable / nc-app-disable APP=<id>)
make nc-config-get KEY=<key>|occ config:system:get
make nc-config-set|occ config:system:set — KEY=<key> VALUE=<value> [TYPE=…]
make nc-default-user-quota|default quota for NEW users — VALUE=<quota> (syncs the recovery manifest)
make nc-users|occ user:list
make nc-user-add|add a user — USER=<uid> [PASS=…] (prompts without PASS)
make nc-user-del|delete a user — USER=<uid>
make nc-user-password|reset a user's password — USER=<uid> [PASS=…]
make nc-user-setting|set a user setting — USER=<uid> KEY=<key> VALUE=<value> (e.g. KEY=email)
make nc-scan|rescan the file cache — USER=<uid>, default --all
make nc-groups|occ group:list (nc-jobs = background-job list)
make nc-talk-signaling|list Talk signaling servers (add/del: nc-talk-signaling-add/-del URL=… SECRET=…)
make nc-talk-turn|list TURN servers (add/del: nc-talk-turn-add/-del SERVER='scheme host:port' SECRET=…)
make nc-2fa-enforce|enforce two-factor auth — USER=<uid>
make nc-logs|tail the Nextcloud log (N=<lines>, default 100)
EOF

  rule
  echo ""
}

case "$MODE" in
  core) core ;;
  more) more ;;
esac