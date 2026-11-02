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
#                         registries, and every module's own recipes
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
make backup|take one Kopia snapshot of every module's data and the rendered config (restore, retention and off-box copies from kopia.$DOMAIN)
EOF

  sec "migrate / restore"
  rows <<'EOF'
make migrate|print the migration runbook
make deploy|restore a host — config/ → live paths (same body as install-config)
EOF

  sec "git"
  rows <<'EOF'
make git-issue TITLE=<s> LABEL=<l> [BODY=<file>]|file an issue in the tracker before the change — LABEL from .github/labels.yml (type: required, status: triage added), body from BODY or stdin; then make git-start and make git-pr ISSUE=<n>
make git-start|create + switch to the next temp-<N> branch off a freshly pulled main — every change starts here (main is never pushed)
make git-branch [NAME=<b>]|same as git-start, or create + switch to NAME (BASE=<b> bases it on another branch)
make git-switch BRANCH=<b>|switch to an existing branch — local, or origin's (tracked on the way in)
make git-del BRANCH=<b> [FORCE=1]|delete a local branch — never main, never the current one; FORCE=1 drops unmerged commits
make git-branches|every branch with its distance from origin/main, plus the next free temp-<N>
make git-pr [ISSUE=<n>] [BASE=<b>]|audit the branch, push it, open the PR into main (or BASE) with gh or GITHUB_TOKEN/GH_TOKEN; ISSUE=<n> links it with Closes #<n> — a human merges on GitHub
make git-land [BASE=<b>]|after the PR is merged: fast-forward main (or BASE) onto origin and delete the local branch
make git-pull|pull remote changes
make git-add|stage every change
make git-com MSG=<sentence>|commit staged changes — single-sentence MSG only
make git-audit RANGE=<a..b>|monitor the commit-hygiene rules (26 one change per commit, 10 revert recipe) — default: what a push would publish; the pre-push hook enforces it
make prose-audit|monitor the prose rules (31 docs path, size, timing, foreign host, plan; an open task in a doc, which belongs to the Issues tab) — the pre-push hook and make git-pr enforce it
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
make install-cron|no host cron job is needed by any module (nothing to install)
make install-hooks|git hooks — pre-commit (GitHub-identity + edge guard), prepare-commit-msg (auto-split per unit: one folder + one subfolder), pre-push (smoke + history-rewrite warning + auto-split/revert)
EOF


  sec "onboarding & stack tools"
  rows <<'EOF'
make matrix-gen|generate Matrix secrets + Synapse/Element configs (idempotent)
make kopia-gen|generate the kopia repository password + UI account (idempotent)
make kopia-snapshot|take a snapshot now — SOURCE=<path in the container>, default /source
make kuma-import|import an adapted Uptime Kuma db (KUMA_DB=<path>)
make gh-web-health|check the GitHub web git-data endpoints (after a history rewrite)
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
make goose-troubleshoot SERVICE=<s>|triage a failure (layer ladder, read-only)
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

  sec "cloud accounts (module: cloud — oCIS)"
  rows <<'EOF'
make ocis-status|the container and the OCS capabilities probe (the real health, not /healthz)
make ocis-admin-pass|reset an IDM password interactively — USER=<name>, default admin (no web-UI equivalent)
make ocis-logs|tail the ocis container (N=<lines>, default 50)
EOF

  sec "dashboard (module: home — Homarr, no account CLI)"
  rows <<'EOF'
make dok-recreate-homarr|the whole app lifecycle — dok-restart-homarr / dok-stop-homarr / dok-logs-homarr (board and integrations are UI data)
EOF

  sec "matrix accounts (module: chat — Synapse + Element)"
  rows <<'EOF'
make matrix-users|list every account (@name:$DOMAIN)
make matrix-admin|the admin bot shortcut — same as matrix-add with the server-admin flag
make matrix-add|create a plain account — USER=<name> [PASS=…] (PASS generated and printed once when omitted)
make matrix-passwd|reset a password and end its sessions — USER=<name> [PASS=…]
make matrix-admin-flag|grant or revoke server admin — USER=<name> ADMIN=<true|false>
make matrix-del|deactivate an account — USER=<name>
make matrix-status|the three containers and the homeserver's /health
make matrix-logs|tail the Synapse container (N=<lines>, default 50)
EOF

  sec "kopia backups (module: kopia)"
  rows <<'EOF'
make kopia-status|container state, repository status and the latest snapshots
make kopia-password|rotate the web UI password and recreate the container — PASS=<new> (generated and printed once when omitted)
make kopia-username|rotate the web UI username and recreate the container — USER=<name> (generated and printed once when omitted)
make kopia-snapshots|list snapshots (kopia-snapshot takes one)
make kopia-logs|tail the kopia container (N=<lines>, default 50)
EOF

  rule
  echo ""
}

case "$MODE" in
  core) core ;;
  more) more ;;
esac
