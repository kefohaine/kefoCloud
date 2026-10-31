#!/usr/bin/env bash
#
# scripts/info/help.sh — the `make help` / `make help-more` renderer.
#
# Two aligned, colored lists in the same house style as scripts/info/fetch.sh
# (colors auto-disable when stdout is not a tty or NO_COLOR is set):
#   core (make help)      the common daily surface — dashboard, maintain,
#                         git, container/unit/tmux basics
#   more (make help-more) the granular / technical recipes — per-file
#                         installs, backup (tailnet device only), account
#                         registries, the occ wrappers
#
# Usage: help.sh [core|more]   (default core)
# Rows are `command|description` heredocs — keep one row per line, no `|`
# inside a description.

. "$(dirname "$(readlink -f "$0")")/../lib/instance.sh" 2>/dev/null || true

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
make fetch|AIO dashboard — host perf, modules, git, units, docker, tmux, backups, mail, tailnet
make render|skeleton → live: render data/rendered/ + refresh each service .env
make fetch-more|deep dive — per-core cpu, mem breakdown, processes, sockets, all units+timers+cron, docker caps/stats/log sizes, disk+inodes, data/ growth, tailnet prefs, DNS probes, TLS expiry
make smoke|live edge test — every vhost, tailnet edge, tls, mail (pre-push hook runs it; records its verdict only when the installer asks)
make dns-sync|converge the Cloudflare zone from wizard.state (A records for every enabled module + SSL mode)
EOF

  sec "maintain"
  rows <<'EOF'
make update|pull + recreate every deployed unit via stack-up.sh — edge last, gated, auto-rollback
make apt-upgrade|apt-get update + upgrade (deliberately separate from the container work)
make backup|ship ALL modules as two bundles (nextcloud-backup-*.tar.gz DB+datadir, other-backup-*.tar.gz datadirs) to a tailnet device (TAILDROP= required; data/ untouched, repo/config never touched); see import-backups to restore
make import-backups|preview + interactive restore of module bundles from a tailnet device's backups/ (TAILDROP= required; preview + typed yes are built in — no DRYRUN flag; stops all non-caddy containers); never stops caddy
EOF

  sec "migrate / restore"
  rows <<'EOF'
make migrate|print the migration runbook (docs/MIGRATE.md)
make deploy|restore a host — config/ → live paths (same body as install-config)
EOF

  sec "git"
  rows <<'EOF'
make git-start|create + switch to the next temp-<N> branch off a freshly pulled main — every change starts here (main is never pushed)
make git-branch [NAME=<b>]|same as git-start, or create + switch to NAME (BASE=<b> bases it on another branch)
make git-switch BRANCH=<b>|switch to an existing branch — local, or origin's (tracked on the way in)
make git-del BRANCH=<b> [FORCE=1]|delete a local branch — never main, never the current one; FORCE=1 drops unmerged commits
make git-branches|every branch with its distance from origin/main, plus the next free temp-<N>
make git-pr [ISSUE=<n>] [BASE=<b>]|audit the branch, push it, open the PR into main (or BASE); ISSUE=<n> links it with Closes #<n> — a human merges on GitHub
make git-land [BASE=<b>]|after the PR is merged: fast-forward main (or BASE) onto origin and delete the local branch
make git-pull|pull remote changes
make git-add|stage every change
make git-com MSG=<sentence>|commit staged changes — single-sentence MSG only
make git-audit RANGE=<a..b>|monitor the commit-hygiene rules (26 one change per commit, 10 revert recipe) — default: what a push would publish; the pre-push hook enforces it
make git-split RANGE=<a..b>|rewrite a local range to satisfy those rules — auto-split bundles per unit (one folder + one subfolder), auto-SHA the Revert: lines; ARGS=--dry-run to preview; refuses published commits — the hooks run it for you
make git-push|push the current temp branch to the remote (main is refused by the pre-push hook)
make git-force-push BRANCH=<b>|force-push a rewritten branch (--force-with-lease only; BRANCH required — never clobbers another's commits)
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
make systemd-restart TARGET=<svc>|restart one host unit — or append -<svc> / -all
make systemd-log TARGET=<svc>|follow one host unit's journal (last 50) — same -<svc> / -all forms
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
make install-goose|goose.service → /etc/systemd/system (+ create/migrate data/goose/.env if missing)
make goose-tokens|goose token policy → live settings store + data/goose/.env + login-shell caps (idempotent)
make install-ttyd|ttyd.service → /etc/systemd/system (refuses to run from inside ttyd)
make install-ssh|50-cloud-init.conf → sshd_config.d (validates with sshd -t, then restarts)
make install-dnsmasq-conf|10-tailnet.conf → /etc/dnsmasq.d
make install-resolv|resolv.conf → /etc/resolv.conf via Tailscale (split-DNS works for tailnet-only names; run AFTER tailscale)
make install-dnsmasq-override|dnsmasq drop-in override → /etc/systemd/system/dnsmasq.service.d
make install-docker|daemon.json → /etc/docker (docker daemon restart needed to apply)
make install-sysctl|99-kefo.conf → /etc/sysctl.d
make install-cron|nextcloud → /etc/cron.d (occ cron every 5 min)
make install-hooks|git hooks — pre-commit (GitHub-identity + edge guard), prepare-commit-msg (auto-split per unit: one folder + one subfolder), pre-push (smoke + history-rewrite warning + auto-split/revert)
EOF


  sec "onboarding & stack tools"
  rows <<'EOF'
make nc-datadir-nfs|make an external machine the permanent live Nextcloud datadir host over the tailnet (export moves THIS datadir remotely; import restores THIS host's own previously-exported datadir); the database stays local
make talk-gen|generate NC-stack secrets + Talk/TURN configs (idempotent)
make talk-config|force every Talk call through the HPB signalling server + our TURN server (occ)
make nc-capture|snapshot live NC users/groups/quotas → recovery manifests (outside the repo)
make kuma-import|import an adapted Uptime Kuma db (KUMA_DB=<path>)
make gh-web-health|check the GitHub web git-data endpoints (after a history rewrite)
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
make taildrop-file|FILE=<path> TAILDROP=<device> — send one file
make taildrop-folder|DIR=<folder> TAILDROP=<device> — send a folder (-r)
EOF

  sec "goose recipes (read-only agent tasks — recipes/*.yaml)"
  rows <<'EOF'
make goose-recipes|list the reusable agent recipes
make goose-audit [FOCUS=<area>]|read-only audit — security, backups, mail, docker, networking, docs
make goose-review MODULE=<m>|read-only module review (any module in config/modules.conf, or edge)
make goose-troubleshoot SERVICE=<s>|triage a failure via docs/DEBUG.md
make goose-check-backups [FOCUS=<area>]|audit the backup/restore posture
make goose-check-network [FOCUS=<area>]|review DNS/TLS/mail/reverse-proxy
make goose-validate-installer [TARGET=<script>]|lint and review script changes (bash -n, no apply)
make goose-audit-docs [SCOPE=<doc>]|find doc drift/stale/duplicate
make goose-deploy-plan CHANGE=<what>|produce a deployment/upgrade plan
EOF

  sec "mail server (Mailu stack — webmail login is the local part only)"
  rows <<'EOF'
make mail-list|every mailbox with its quota (global admins flagged)
make mail-gen|create a mailbox — empty MAIL / PWD / QUOTA = auto-generated (PWD printed once)
make mail-card|one address card — exists, quota, webmail URL (MAIL=<addr>)
make mail-password|rotate a mailbox password (MAIL=<addr>; empty PWD = new one printed once)
make mail-del|delete an address + all its stored mail (MAIL=<addr>)
make mail-quota|set a quota (MAIL=<addr> QUOTA=<2G>; no MAIL = the mail-gen default)
make mail-domains|every domain with its mailbox count
make mail-domain-add|add a domain — MAIL_DOMAIN=<domain>
make mail-limits|per-domain caps — MAIL_DOMAIN=<d> USERS=<n> ALIASES=<n> QUOTA=<2G, or 0 for none>
make mail-manager|make a mailbox a manager of a domain — MAIL_DOMAIN=<d> USER=<addr>
make mail-aliases|list every alias and its targets
make mail-alias-add|set an alias target list — FROM=<addr> TO=<target[,target2]>
make mail-gen-alias|disposable forwarding alias TO=<target> (random local part, same-domain refused)
make mail-del-alias|remove one alias target (FROM=<addr> TO=<target>)
make mail-admin-password|set the Mailu admin login (PWD empty = generated and printed once; warns when INITIAL_ADMIN_MODE=update will revert it)
make mail-status|ps + per-container state and health + the running image tag
make mail-doctor|one-shot triage — /data ownership, sqlite open as uid 100:1000, sso/login 200, TLS, every container running
make mail-fix-perms|re-own data/mailserver/data as 100:1000 (the sqlite "unable to open database file" 500 — mail store untouched)
make mail-tls|served certificates and expiry — https mail, imaps 993, smtps 465
make mail-dkim|DKIM key per domain on disk + the TXT record to publish
make mail-queue|list the postfix queue, per sender and recipient
make mail-queue-flush|make postfix retry every queued message now
make mail-logs|SERVICE=<front,smtp,imap,antispam,admin,redis,roundcube>, default admin — tail last 50
make mail-exec|CMD='<shell command>' inside mailu-admin (escape hatch for any flask mailu command)
make mail-config-export|dump the registry as JSON (FILE=<path> to save, SECRETS=1 to include hashes and keys)
make mail-config-import|apply a registry dump — FILE=<yaml or json>, merges into the live registry
make dok-recreate-mailserver|whole stack lifecycle — dok-restart-mailserver, dok-stop-mailserver, dok-logs-mailserver
EOF

  sec "kuma accounts (Uptime Kuma)"
  rows <<'EOF'
make kuma-list-users|list users
make kuma-add-user|add a user — USER=<name> PASS=<password>
make kuma-passwd|rotate a password — USER=<name> PASS=<new>
make kuma-del-user|delete a user + their monitors/notifications (USER=<name>)
EOF

  sec "vault accounts (Vaultwarden)"
  rows <<'EOF'
make vaultwarden-list-users|list vault accounts
make vaultwarden-add-user|add an account — EMAIL=<addr> PASS=<password>
make vaultwarden-del-user|delete an account + its vault data (EMAIL=<addr>)
EOF

  sec "blog accounts (WriteFreely)"
  rows <<'EOF'
make writefreely-users|list blog accounts (id, name, email, created)
make writefreely-add-user|add an account — USER=<name> PASS=<password> (ADMIN=1 for the instance admin)
make writefreely-passwd|reset a password — USER=<name> PASS=<new>
make writefreely-del-user|delete an account (USER=<name>; the admin cannot be deleted)
EOF

  sec "photos accounts (Immich)"
  rows <<'EOF'
make immich-users|list photo-library users
make immich-admin-pass|reset the admin password (interactive, inside the container)
make immich-grant-admin|grant admin to an account — EMAIL=<addr>
EOF

  sec "snikket accounts (XMPP — module: xmpp)"
  rows <<'EOF'
make snikket-users|list accounts on the Snikket server
make snikket-invite ADMIN=<true|false> [USER=<name>] [QR=1]|create an account invite link (ADMIN is required and grants the admin role; no USER = any username)
make snikket-invites|pending invites — token, expiry, description
make snikket-revoke TOKEN=<token>|revoke a pending invite
make snikket-reset USER=<jid>|password-reset invite link for an existing account
make snikket-passwd USER=<jid> [PASS=<new>]|set the password directly (empty PASS = generated and printed once)
make snikket-disable USER=<jid>|block login without deleting the account (undo: snikket-enable)
make snikket-del-user USER=<jid>|delete an account and all its server data (typed yes; FORCE=1 skips)
EOF

  sec "snikket utilities"
  rows <<'EOF'
make snikket-status|the four services (server, portal, proxy, certs) with state and image
make snikket-doctor|one-shot triage — containers, prosody, BOSH, TLS expiry, turnserver
make snikket-tls|served certificates and expiry
make snikket-turn|turnserver process, advertised address, relay range
make snikket-logs SERVICE=<name>|tail one container's logs — server · portal · proxy · certs (N=<lines>, default 50; follows)
make snikket-restart [SERVICE=<name>]|restart one service or all four (coturn re-reads its cert on start)
make snikket-exec CMD='<shell command>'|run a command inside the server container
make snikket-shell|interactive bash inside the server container
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
make nc-talk-turn|list TURN servers (add/del: nc-talk-turn-add SERVER='<schemes> <host:port> <protocols>' SECRET=…)
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