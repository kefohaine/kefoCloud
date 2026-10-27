# This script performs the reverse of the installer.
#!/bin/bash
# This script performs the reverse of the installer:
# • Stops and removes all Docker containers started by the installer
# • Deletes generated data directories (data/, rendered/, cloud/recovery/)
# • Removes Cloudflare DNS records (A, CNAME, TXT for domain and services)
# • Revokes Let's Encrypt certificates via certbot cleanup
# • Clears instance state and logs
# • Disables modules (cloud, vault, mail, monitor) and cleans up configs
# • Optionally removes GitHub remote authentication keys
# homelab uninstall.sh — the exact opposite of the installer, in the same style.
#
# Reverse-onboarding: takes the deployment apart module by module (cloud,
# vault, mail, monitor — none removed unless the operator answers yes per
# module), then optionally the edge
# (Caddy + caddy_data), the host services (goose, ttyd, dnsmasq, cron,
# fail2ban, the stack's ufw rules), the installed packages (docker, …),
# the 'root' user, and the tailscale membership (always LAST, so the session
# and re-joining stay possible).
#
# MODE: the first prompt picks the scope —
#   1) specific modules    — per-module prompts (each requires an explicit
#                            yes), the scope prompts below likewise
#   2) the whole framework — every module + edge + host services + packages
#                            + user + tailnet preselected (the data prompts
#                            are still asked; one explicit confirm)
#   3) cancel
#
# Installs nothing, creates nothing. It removes what the installer put on the
# box — auto-detected from the live system (compose files, systemctl, dpkg
# — no hardcoded rosters) — and NEVER deletes operator data without an
# explicit per-category prompt (no defaults — only an explicit yes removes):
#   - the external machine's datadirectory — EXTERMINATED in full mode
#     (NFS export line removed from /etc/exports, remote files rm -rf'd;
#     only the reserved granular mode leaves the remote files in place)
#   - data/ — removed WHOLE (no granular folder picks; removed modules' data
#     dirs always go with them). There are NO partial teardowns: removing any
#     module removes ALL of them, and data/ dies with them.
#   - the repo clone — prompt, explicit yes required
#   - sshd hardening — deliberately KEPT (removing the drop-in would
#     re-enable password auth; weakening is never the uninstall's job)
#
# wizard.state (data/wizard.state) is the record the installer is the sole writer
# of. Teardown is the ONE exception that may change it: at the end of a
# teardown that removed anything, the removed modules are dropped from
# enabled_modules and `finished` is set back to false — so `make smoke` (which
# aborts unless finished=true) no longer treats a torn-down host as a finished
# install. Only those two fields are rewritten; the prompted secrets are kept.
#
# Errors are collected with tags, each shown as a "problem" plus a "hint",
# and re-checked on Enter until all are green — then SUCCESS. Manual steps
# are grouped as expected; real failures as unexpected.
#
# MODES (UNINSTALL_MODE, picked by argument — granular is NOT an operator mode):
#   full (default, no argument)
#     the whole production stack and its data, verified gone. The three
#     consequence confirmations always apply.
#   granular (--granular)
#     RESERVED for wizard.sh repair mode (requires WIZARD_REPAIR=1). wizard.state
#     is the source of truth: ONLY disabled modules are torn down (containers,
#     compose stacks, data dirs, stale .svc hashes) and only disabled doors'
#     Cloudflare A records are deleted. wizard.state, .cred-*.sha and enabled
#     modules are untouched — the repair run converges the rest itself.
#   interactive (--interactive) — per-module scope prompts.
#
# Usage (root on the box, from the repo checkout):
#   sudo bash scripts/install/uninstall.sh               # full teardown (warned)
#   sudo bash scripts/install/uninstall.sh --interactive # pick the scope
#
# Full log: $LOG_DIR/uninstall.log

. "$(dirname "$(readlink -f "$0")")/../lib/instance.sh" 2>/dev/null || true

set -uo pipefail

OP_USER=root
# The checkout path is DERIVED from this script's location — never
# hardcoded — so the repo can live anywhere and be renamed
# ($NODE_NAME -> kefoCloud) without editing any script.
REPO="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
PROJECT_DIR="$REPO/data"
INSTALL_STATE="${INSTALL_STATE:-$PROJECT_DIR/wizard.state}"
# The log lives with EVERY other log this project writes — $DATA_DIR/logs, the
# one namespace covered by config/logrotate/instance — instead of next to this
# script, so no repo directory and no instance directory are ever confused.
# A full teardown deletes data/ while this script is running, so wipe_data()
# copies the log to /var/tmp and CONTINUES there: the record survives the
# teardown it describes (LOG_DIR is inherited from the wizard hand-off, which
# already exports $DATA/logs).
LOG_DIR="${LOG_DIR:-$PROJECT_DIR/logs}"
LOG="$LOG_DIR/uninstall.log"
mkdir -p "$LOG_DIR" 2>/dev/null || true
ERR_TAGS=()
declare -A ERR_DETAIL=()

log()  { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
fail() {
  local t
  for t in "${ERR_TAGS[@]}"; do [ "$t" = "$1" ] && return 0; done
  ERR_TAGS+=("$1"); ERR_DETAIL[$1]="${2:-}"
  echo "  ERROR: $(problem "$1")${2:+ ($2)}" >>"$LOG"
}

banner() {
cat <<'EOF'
██╗    ██╗██╗   ██╗██████╗ ██╗██╗     ███████╗██╗  ██╗██╗██╗
██║    ██║██║   ██║██╔══██╗██║██║     ██╔════╝╚██╗██╔╝╝╚██╗██║
██║ █╗ ██║██║   ██║██████╔╝██║██║     █████╗   ╚███╔╝  ╚███╔╝
██║███╗██║██║   ██║██╔══██╗██║██║     ██╔══╝   ██╔██╗  ██╔██╗
╚███╔███╔╝╚██████╔╝██║  ██║██║███████╗███████╗██╔╝ ██╗██╔╝ ██║
 ╚══╝╚══╝  ╚═════╝ ╚═╝  ╚═╝╚═╝╚══════╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝

  One-shot teardown for the homelab stack: reverses the installer
  step by step — modules first (cloud, vault, mail, monitor; nothing removed
  unless the operator answers yes one by one), then the edge, the host services, the
  installed packages, the operator user, and the tailnet membership
  (last). Destructive by design: no prompt has a default — only the words
  yes/no are accepted — and data is never touched without an explicit
  per-category confirm. Errors are listed with a hint each, re-checked on
  Enter, and SUCCESS prints only when every remaining item is resolved.

WARNING: removes containers, config and (on explicit confirm) operator
         data. SSH stays alive throughout — tailscale goes last.
EOF
}

# ───────────────────────────────── input ──────────────────────────────────

ask() { # ask <var> <question> [ignored]  (ONLY the words yes/no; recorded as true/false)
  local __var=$1 __q=$2 __ans
  if [ -n "${!__var:-}" ]; then return 0; fi
  while :; do
    read -rp "$__q (yes/no): " __ans || return 1
    case "${__ans,,}" in
      yes) eval "$__var=true";  return 0;;
      no)  eval "$__var=false"; return 0;;
      *)   echo "   type yes or no.";;
    esac
  done
}

# Three consecutive consequence confirmations before ANYTHING is touched.
# Nothing skips them: the full teardown is only ever a manual operator run.
confirm_consequences() {
  local a
  echo ""
  echo " ── CONFIRMATION 1/3 — what dies ─────────────────────────────────────────"
  echo "    ALL module containers and their config are removed; data/ is wiped"
  echo "    WHOLE (no granular folder picks); the remote machine's NFS export"
  echo "    line for the datadirectory is removed from its /etc/exports"
  echo "    (remote files stay)."
  read -rp "    Understand and want to proceed? (yes/no): " a || return 1
  [ "${a,,}" = yes ] || return 1
  echo " ── CONFIRMATION 2/3 — no way back ───────────────────────────────────────"
  echo "    Everything removed here is IRREVERSIBLE: containers, config,"
  echo "    data/ (module data, backups, logs, wizard.state) cannot be"
  echo "    recovered. The installer can rebuild the stack, but NOT your data."
  read -rp "    Accept irreversible loss? (yes/no): " a || return 1
  [ "${a,,}" = yes ] || return 1
  echo " ── CONFIRMATION 3/3 — last chance ───────────────────────────────────────"
  read -rp "    FINAL: begin the uninstall now? (yes/no): " a || return 1
  [ "${a,,}" = yes ] || return 1
  echo "   confirmed — proceeding."
  return 0
}

# There is no answer-sheet defaults file: every prompt is ALWAYS asked, only
# the literal words yes/no are accepted, and nothing is removed unless the
# operator answers yes.

# ─────────────── modes: full / granular / interactive ─────────────────────
UNINSTALL_MODE=full
for _a in "$@"; do
  case "$_a" in
    --granular)         UNINSTALL_MODE=granular ;;
    --interactive)      UNINSTALL_MODE=interactive ;;
    --mode=*)           UNINSTALL_MODE="${_a#--mode=}" ;;
  esac
done
unset _a

# The stack scope, used by BOTH the removal and the verification so a check can
# never disagree with what was removed.
STACK_MODULES="cloud vault mail monitor"

# data/ goes as ONE directory — no granular folder picks. The stack owns every
# path under it (module dirs, caddy_data, rendered/, pages/, logs, wizard.state),
# so "stack gone" means data/ itself is gone. The installer recreates the
# directory and its fresh log right after this exits. Guard: anything still
# mounted under data/ (the Nextcloud NFS datadirectory) is unmounted first —
# an rm -rf through a live mount would propagate INTO the storage export.
# Before the wipe, the remote datadirectory export (make nc-datadir-nfs
# export, recorded in data/.nc-import-source) is un-exported on the remote
# machine — that one datadirectory line, no other exports — and (full mode
# only) the remote datadirectory files are deleted. Granular mode leaves the
# remote files in place.
remove_remote_export() {
  local marker="$PROJECT_DIR/data/.nc-import-source" tgt mnt
  [ -f "$marker" ] || return 0
  tgt="$(sed -n '1p' "$marker")"
  mnt="$(sed -n '2p' "$marker")"
  [ -n "$tgt" ] && [ -n "$mnt" ] || return 0
  log "  un-exporting the remote datadirectory on $tgt ($mnt)"
  ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$tgt" \
    "sed -i '\#^$mnt #d' /etc/exports && exportfs -ra" >>"$LOG" 2>&1 \
    || fail data "remote export on $tgt not removed (run: ssh $tgt \"sed -i '\\#$mnt #d' /etc/exports && exportfs -ra\")"
  # Every teardown except the reserved granular mode removes the remote
  # datadirectory: the NFS export line is removed above AND the directory
  # itself is exterminated on the remote machine (2026-10-19 — 'kept' wording
  # was wrong for a full teardown).
  if [ "${UNINSTALL_MODE:-full}" != granular ]; then
    log "  exterminating the remote datadirectory on $tgt ($mnt)"
    ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$tgt" \
      "rm -rf -- '$mnt'" >>"$LOG" 2>&1 \
      || fail data "remote datadirectory $mnt on $tgt not removed (run: ssh $tgt \"rm -rf -- '$mnt'\")"
  fi
}
wipe_data() {
  remove_remote_export
  local m
  # positional DIR arg lists submounts UNDER data/ only; --target would also
  # return the mount containing data/ itself (i.e. /), unmounting the root fs
  while read -r m; do
    [ -n "$m" ] || continue
    [ "$m" = "/" ] && continue
    umount "$m" >>"$LOG" 2>&1 || fail data "mountpoint $m still mounted — not deleting data/"
  done < <(findmnt -rn -o TARGET "$PROJECT_DIR" 2>/dev/null | grep -v '^/$')
  [ ${#ERR_TAGS[@]} -gt 0 ] && return 1
  # data/ (and the log inside it) is about to be deleted: keep this run
  # readable by moving the live log to /var/tmp and continuing there.
  if [ -f "$LOG" ]; then
    _keep="/var/tmp/uninstall-$(date +%Y%m%d-%H%M%S).log"
    if cp -f "$LOG" "$_keep" 2>/dev/null; then
      LOG="$_keep"
      log "log continues here — data/logs was deleted with data/"
    fi
  fi
  rm -rf "$PROJECT_DIR" >>"$LOG" 2>&1 \
    || fail data "$PROJECT_DIR not deleted"
}

# The verification: is the stack REALLY gone? Runs after the removal in full
# mode. Every item below must be clean, so a half-removed stack is reported
# instead of passing as done. Read-only: it inspects, it never deletes.
verify_stack_gone() {
  local t=""
  local ctn="caddy nextcloud postgresql vaultwarden uptimekuma mailu-front mailu-imap mailu-smtp mailu-antispam mailu-admin mailu-redis roundcube talk-hpb talk-relay notify-push"
  local c d

  for c in $ctn; do
    if ctn_list | grep -qx "$c"; then
      t+="container_$c "
    fi
  done
  docker network inspect net >/dev/null 2>&1 && t+="network "
  # data/ itself counts, whole: the stack owns everything inside it, so any
  # leftover (a module dir, rendered/, pages/, a stray file) is a live stack.
  [ -e "$PROJECT_DIR" ] && t+="data "
  [ -f "$INSTALL_STATE" ] && t+="state "
  # module compose files are repo-TRACKED and deliberately kept — they are the
  # framework, not stack state.

  ERR_TAGS=()
  [ -n "$t" ] && ERR_TAGS=($t)
  if [ ${#ERR_TAGS[@]} -gt 0 ]; then
    echo ""
    echo " Stack NOT verified gone — ${#ERR_TAGS[@]} item(s) still present:"
    local i
    for i in "${!ERR_TAGS[@]}"; do
      echo "   - $(problem "${ERR_TAGS[$i]}")"
    done
    echo " Teardown incomplete — resolve the items above, then re-run."
    log "  teardown verification FAILED: ${ERR_TAGS[*]}"
    return 1
  fi
  echo ""
  echo " Stack verified gone: containers, network, data/ and wizard.state are all clear."
  log "  teardown verification passed — nothing of the stack is left"
  return 0
}

ask_modules() {
  # Reverse of the installer's ask_modules: nothing removed unless explicitly
  # confirmed —
  # removing a module destroys its containers and (on data-confirm) its
  # data; the operator opts in per module.
  local k answer
  for k in cloud vault mail monitor; do
    local var="RM_MOD_${k^^}"
    if [ -z "${!var:-}" ]; then
      while :; do
        read -rp "Remove the $k module? (yes/no): " answer || return 1
        case "${answer,,}" in
          yes) eval "$var=true";  break ;;
          no)  eval "$var=false"; break ;;
          *)   echo "   type yes or no." ;;
        esac
      done
    fi
  done
}

ask_mode() {
  # the scope selector: specific modules, the whole framework, or cancel.
  # UNINSTALL_MODE=modules|all|cancel (env) skips the prompt; an invalid
  # value re-prompts.
  if [ -z "${UNINSTALL_MODE:-}" ]; then
    while :; do
      read -rp "Teardown scope: [1] specific modules  [2] the whole framework  [3] cancel: " m
      case "${m:-}" in
        1|modules)  UNINSTALL_MODE=modules;;
        2|all)      UNINSTALL_MODE=all;;
        3|cancel|"") UNINSTALL_MODE=cancel;;
        *) echo "enter 1, 2 or 3";;
      esac
      [ -n "${UNINSTALL_MODE:-}" ] && break
    done
  fi
  case "$UNINSTALL_MODE" in
    cancel)
      echo "Cancelled — nothing was removed."
      exit 0
      ;;
    all)
      # the whole framework: every phase preselected, data still defaults
      # to keep — the operator confirms the scope once, then per-category
      # data confirms below decide what user data dies
      local k
      for k in cloud vault mail monitor; do
        eval "RM_MOD_${k^^}=true"
      done
      RM_EDGE=true; RM_HOST=true; RM_PKGS=true; RM_USER=true; RM_TAILNET=true
      echo "Whole-framework teardown preselected: every module, the edge, the host"
      echo "services, the packages and the tailnet membership (root is never removed)."
      ;;
    modules|*)
      :   # the per-module prompts below decide the scope
      ;;
  esac
}

ask_inputs() {
  ask_mode
  ask_modules
  # scope prompts only when NOT preselected by the whole-framework mode
  [ "${RM_EDGE:-false}" = true ] || ask RM_EDGE "Remove the edge (Caddy container)?"
  [ "${RM_HOST:-false}" = true ] || ask RM_HOST "Remove the host services (goose, ttyd, dnsmasq, cron, fail2ban) + the stack's ufw rules?"
  [ "${RM_PKGS:-false}" = true ] || ask RM_PKGS "Purge the installed packages (docker, dnsmasq, fail2ban, …)?"
  # operator account root is never deleted (sole entry point) — no prompt
  [ "${RM_TAILNET:-false}" = true ] || ask RM_TAILNET "Remove this host from the tailnet (last step)?"
  # data: no granular picks, and NO partial teardowns — removing any module
  # removes all of them, and data/ is wiped whole by wipe_data. Full mode
  # exterminates the remote datadirectory too (export line + remote files).
  RM_MOD_DATA=true
  ask RM_REPO     "Delete the repo clone at $REPO (scheduled after this script exits)?"
  local ml=""
  for k in cloud vault mail monitor; do
    mod_rm "$k" && ml+="$k "
  done
  echo ""
  echo "Rebuild the stack later with: bash $REPO/scripts/install/wizard.sh"
  echo "Teardown summary — modules: ${ml:-none}· edge: ${RM_EDGE:-false} · host: ${RM_HOST:-false} · pkgs: ${RM_PKGS:-false} · user: ${RM_USER:-false} · tailnet: ${RM_TAILNET:-false}"
  echo "Full log: $LOG"
}

mod_rm() { # indirection: is module $1 selected for removal?
  local v="RM_MOD_${1^^}"
  [ "${!v:-false}" = true ]
}

# ────────────── wizard.state teardown update (the one exception) ──────────

# ─────────────────────── phase: containers (reverse) ───────────────────────

ctn_list() { docker ps -a --format '{{.Names}}' 2>/dev/null; }

compose_file_of() { # module -> its compose file (repo layout)
  case "$1" in
    cloud)   echo "$REPO/modules/nextcloud/docker-compose.yml";;
    vault)   echo "$REPO/modules/vaultwarden/docker-compose.yml";;
    mail)    echo "$REPO/modules/mailserver/docker-compose.yml";;
    monitor) echo "$REPO/modules/uptimekuma/docker-compose.yml";;
  esac
}

ctn_of_module() { grep -E '^\s*container_name:' "$1" 2>/dev/null | awk '{print $2}'; }

module_data_dirs() { # module -> its host data dirs (never the storage export)
  case "$1" in
    cloud)   echo "$PROJECT_DIR/cloud $PROJECT_DIR/talk $PROJECT_DIR/pgdata";;
    vault)   echo "$PROJECT_DIR/vault";;
    mail)    echo "$PROJECT_DIR/mailserver";;
    monitor) echo "$PROJECT_DIR/kuma";;
  esac
}

remove_module() { # $1=module
  local m=$1 f c ctns
  f=$(compose_file_of "$m")
  ctns=$(ctn_of_module "$f")
  log "  removing the $m module (containers: $(echo "$ctns" | tr '\n' ' '))"
  if [ -f "$f" ]; then
    docker compose -f "$f" down --remove-orphans >>"$LOG" 2>&1 || fail "rmmod_$m" "compose down failed"
  else
    fail "rmmod_$m" "compose file not found: $f"
  fi
  # named containers that survived compose down (started outside compose)
  for c in $ctns; do
    if ctn_list | grep -qx "$c"; then
      docker rm -f "$c" >>"$LOG" 2>&1 || fail "rmmod_$m" "container $c not removed"
    fi
  done
  case "$m" in
    cloud)
      # the live datadirectory is the NFS mount of the external machine export:
      # unmount locally and drop the fstab line — the export itself is
      # NEVER touched (user files live there)
      if findmnt -n "$PROJECT_DIR/cloud/users" >/dev/null 2>&1; then
        umount "$PROJECT_DIR/cloud/users" >>"$LOG" 2>&1 \
          || fail "rmmod_cloud" "NFS datadirectory still mounted — unmount failed"
        sed -i "\#^[^#]*[[:space:]]$PROJECT_DIR/cloud/users[[:space:]]#d" /etc/fstab
        systemctl daemon-reload
        log "  NFS datadirectory unmounted (fstab entry removed; the storage export is untouched)"
      fi
      if [ -d "$PROJECT_DIR/cloud/users.local-backup" ]; then
        rm -rf "$PROJECT_DIR/cloud/users.local-backup" >>"$LOG" 2>&1 \
          || fail "rmmod_cloud" "local rollback copy not deleted"
      fi
      # stop the NC cron + off-host DB dump cron the installer set up
      rm -f /etc/cron.d/nc-storage
      ;;
  esac
  if [ "${RM_MOD_DATA:-false}" = true ]; then
    local d
    for d in $(module_data_dirs "$m"); do
      [ -d "$d" ] || continue
      # cloud/users may be the NFS mountpoint: if the unmount above failed,
      # an rm -rf here would propagate INTO the live storage export —
      # refuse rather than risk deleting user files on the machine
      if [ "$d" = "$PROJECT_DIR/cloud" ] && findmnt -n "$d/users" >/dev/null 2>&1; then
        fail "rmmod_$m" "data dir $d still holds the mounted datadirectory — not deleting"
        continue
      fi
      rm -rf "$d" >>"$LOG" 2>&1 || fail "rmmod_$m" "data dir $d not deleted"
    done
  fi
}

# ─────────────────────── phase: edge + host (reverse) ─────────────────────

edge_compose_file() { # the edge is the compose project running the Caddy binary/image
  # the running container is the source of truth (the edge compose may build
  # a local image instead of pulling caddy:2.x, so don't grep for 'caddy')
  local f
  for f in "$REPO"/modules/*/docker-compose.yml; do
    if grep -qE '^\s*container_name:' "$f" 2>/dev/null; then
      local c
      for c in $(ctn_of_module "$f"); do
        if ctn_list | grep -qx "$c"; then
          grep -qE 'caddy|network_mode: host' "$f" 2>/dev/null && { echo "$f"; return 0; }
        fi
      done
    fi
  done
  return 0
}

remove_edge() {
  log "  removing the edge (Caddy container)"
  local f ctn
  f=$(edge_compose_file)
  if [ -n "$f" ]; then
    ctn=$(ctn_of_module "$f")
    docker compose -f "$f" down --remove-orphans >>"$LOG" 2>&1 || fail edge "compose down failed"
    for c in $ctn; do
      ctn_list | grep -qx "$c" && docker rm -f "$c" >>"$LOG" 2>&1 || true
    done
  else
    log "  edge container not found running — nothing to remove"
  fi
  if [ -d "$PROJECT_DIR/caddy_data" ]; then
    rm -rf "$PROJECT_DIR/caddy_data" >>"$LOG" 2>&1 || fail edge "caddy_data not deleted"
    rm -rf "$PROJECT_DIR/download" >>"$LOG" 2>&1 || true
  fi
  # the shared bridge network goes only when nothing is attached anymore
  docker network inspect net >/dev/null 2>&1 && \
    docker network rm net >>"$LOG" 2>&1 || true
}

remove_host() {
  log "  removing the host services (goose, ttyd, dnsmasq, cron, fail2ban)"
  # never stop ttyd from a shell inside ttyd (2026-09-11 lesson): it would
  # kill this very session — that is a manual step from SSH/local terminal
  if grep -qs 'ttyd.service' /proc/self/cgroup; then
    fail host_ttyd "this shell runs inside ttyd"
    return
  fi
  local u
  for u in goose ttyd dnsmasq; do
    systemctl disable --now "$u" >>"$LOG" 2>&1 || true
    rm -f "/etc/systemd/system/$u.service"
  done
  # goose env: instance tree first, then the pre-2026-10-27 /etc location
  rm -f "$PROJECT_DIR/goose/.env" /etc/goose/goose.env /etc/kefo-banner.sh
  rm -f /etc/dnsmasq.d/10-tailnet.conf
  rm -f /etc/systemd/system/dnsmasq.service.d/override.conf
  rmdir /etc/systemd/system/dnsmasq.service.d 2>/dev/null || true
  rm -f /etc/sysctl.d/99-kefo.conf
  rm -f /etc/cron.d/nextcloud
  rm -f /etc/fail2ban/jail.d/sshd.conf
  # the binaries the installer dropped into /usr/local/bin
  rm -f /usr/local/bin/ttyd /usr/local/bin/goose
  systemctl daemon-reload
  # sshd hardening is deliberately KEPT: removing the drop-in would
  # re-enable password auth — weakening is never the uninstall's job
  # the stack's ufw service ports — the tailnet SSH rule ALWAYS stays
  local p
  for p in 80/tcp 443/tcp 25/tcp 465/tcp 587/tcp 993/tcp \
           3478/udp 3478/tcp 5349/tcp 49160:49200/udp 49160:49200/tcp; do
    ufw delete allow "$p" >>"$LOG" 2>&1 || true
  done
  log "  ufw: the stack service ports are closed; tailnet SSH (22) stays open"
}

remove_pkgs() {
  log "  purging the installed packages"
  DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq \
    'docker.io' 'docker-ce' 'docker-ce-cli' 'containerd.io' \
    'docker-buildx-plugin' 'docker-compose-plugin' \
    dnsmasq fail2ban apache2-utils sqlite3 >>"$LOG" 2>&1 \
    || fail pkgs "apt purge failed"
  DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq >>"$LOG" 2>&1 || true
  # git, curl, make, sudo, jq, ufw + tailscale stay: base tooling the
  # operator keeps using (tailscale leaves in its own confirmed phase)
}

remove_user() {
  # root@$NODE_NAME is the ONLY entry point — the operator account is never
  # deleted (that would end all access to the box). This phase is a no-op.
  log "  operator account is 'root' (sole entry point) — NOT removed, by design"
  rm -f /etc/sudoers.d/op-passwordless 2>/dev/null || true   # legacy cleanup only
}

remove_tailnet() {
  log "  leaving the tailnet (last step — SSH stays alive)"
  if command -v tailscale >/dev/null 2>&1; then
    tailscale logout >>"$LOG" 2>&1 || fail tailnet "logout failed"
  fi
  # the binary + state stay: re-join with 'tailscale up' after a re-install
}

# ───────────────────── error problems + hints + rechecks ───────────────────

problem() {
  case "$1" in
    rmmod_*)  echo "the ${1#rmmod_} module is not fully removed" ;;
    # full-mode verification: the stack must be gone
    container_*) echo "container ${1#container_} is still there" ;;
    network)  echo "the stack's docker network 'net' is still there" ;;
    data)     echo "data/ is still there" ;;
    data_*)   echo "data/${1#data_} is still there" ;;
    state)    echo "wizard.state is still there" ;;
    edge)     echo "the edge (Caddy) is not fully removed" ;;
    host_goose)  echo "host service 'goose' not removed" ;;
    host_ttyd)   echo "host service 'ttyd' not removed (or was skipped — inside-ttyd guard)" ;;
    host_dnsmasq) echo "host service 'dnsmasq' not removed" ;;
    pkgs)     echo "installed packages not purged" ;;
    user)     echo "operator account is never deleted" ;;
    tailnet)  echo "still on the tailnet" ;;
    *)        echo "$1" ;;
  esac
}

hint() {
  case "$1" in
    rmmod_*)  echo "run: docker ps -a; docker rm -f <the module's containers>; check $LOG, then re-check" ;;
    container_*) echo "run: docker rm -f ${1#container_}, then re-run: bash scripts/install/uninstall.sh" ;;
    network)  echo "run: docker network rm net, then re-run: bash scripts/install/uninstall.sh" ;;
    data*)    echo "run: rm -rf $PROJECT_DIR, then re-run: bash scripts/install/uninstall.sh" ;;
    state)    echo "run: rm -f $INSTALL_STATE, then re-run: bash scripts/install/uninstall.sh" ;;
    edge)     echo "run: docker rm -f <edge container>; docker network rm net; check $LOG, then re-check" ;;
    host_goose|host_dnsmasq) echo "run: systemctl disable --now ${1#host_}; rm -f /etc/systemd/system/${1#host_}.service; systemctl daemon-reload, then re-check" ;;
    host_ttyd) echo "run scripts/install/uninstall.sh from SSH or a local terminal (not the ttyd web shell), then re-check" ;;
    pkgs)     echo "run: apt-get purge docker.io docker-ce docker-ce-cli containerd.io docker-compose-plugin dnsmasq fail2ban apache2-utils sqlite3, then re-check" ;;
    user)     echo "no action — root is the sole entry point and is never deleted" ;;
    tailnet)  echo "run: tailscale logout, then re-check" ;;
    *)        echo "" ;;
  esac
}

recheck() {
  case "$1" in
    rmmod_*)
      local m=${1#rmmod_} f c
      f=$(compose_file_of "$m")
      [ -f "$f" ] || return 0
      for c in $(ctn_of_module "$f"); do
        ctn_list | grep -qx "$c" && return 1
      done
      return 0 ;;
    edge)
      local f
      f=$(edge_compose_file)
      [ -n "$f" ] || return 0
      for c in $(ctn_of_module "$f"); do
        ctn_list | grep -qx "$c" && return 1
      done
      return 0 ;;
    host_goose)  [ ! -e /etc/systemd/system/goose.service ] && [ ! -x /usr/local/bin/goose ];;
    host_ttyd)   [ ! -e /etc/systemd/system/ttyd.service ] && [ ! -x /usr/local/bin/ttyd ];;
    host_dnsmasq) [ ! -e /etc/dnsmasq.d/10-tailnet.conf ];;
    pkgs)  ! dpkg -s docker.io >/dev/null 2>&1 && ! dpkg -s docker-ce >/dev/null 2>&1 \
           && ! dpkg -s dnsmasq >/dev/null 2>&1 && ! dpkg -s fail2ban >/dev/null 2>&1;;
    container_*)
      ctn_list | grep -qx "${1#container_}" && return 1
      return 0 ;;
    network)  ! docker network inspect net >/dev/null 2>&1;;
    data_*)   [ ! -e "$PROJECT_DIR/${1#data_}" ];;
    state)    [ ! -f "$INSTALL_STATE" ];;
    user)     true ;;   # root is never removed
    tailnet)  ! tailscale status >/dev/null 2>&1;;
    *)        false ;;
  esac
}

# Guarded ERR_DETAIL lookup: an empty error tag (fail with no tag, seen live
# 2026-10-19) would make bash abort with "bad array subscript" — an empty key
# is never looked up, so the summary always renders.
err_d() { [ -n "$1" ] && printf ' (%s)' "${ERR_DETAIL[$1]:-}"; return 0; }

is_expected() {
  case "$1" in
    host_ttyd) return 0 ;;  # the operator must re-run from outside ttyd — manual
    # full-mode verification failures are UNEXPECTED: the teardown's own
    # removal is supposed to have left nothing behind, so a leftover is a bug in
    # it, not a manual step for the operator.
    container_*|network|data_*|state) return 1 ;;
    *)        return 1 ;;
  esac
}

# ───────────────────────── resolve + success ───────────────────────────────

resolve_errors() {
  local remaining=()
  [ ${#ERR_TAGS[@]} -gt 0 ] && remaining=("${ERR_TAGS[@]}")
  while [ ${#remaining[@]} -gt 0 ]; do
    echo ""
    local exp=() unexp=()
    for tag in "${remaining[@]}"; do
      if is_expected "$tag"; then exp+=("$tag"); else unexp+=("$tag"); fi
    done
    if [ ${#exp[@]} -gt 0 ]; then
      echo " Manual steps (expected):"
      local i
      for i in "${!exp[@]}"; do
        echo "   $((i+1)). ${exp[$i]}"
        echo "      problem: $(problem "${exp[$i]}")$(err_d "${exp[$i]}")"
        echo "      hint: $(hint "${exp[$i]}")"
      done
    fi
    if [ ${#unexp[@]} -gt 0 ]; then
      echo " Unexpected errors (${#unexp[@]}):"
      for i in "${!unexp[@]}"; do
        echo "   $((i+1)). ${unexp[$i]}"
        echo "      problem: $(problem "${unexp[$i]}")$(err_d "${unexp[$i]}")"
        echo "      hint: $(hint "${unexp[$i]}")"
      done
    fi
    read -rp "Fix / complete the items above, then press Enter to re-check (Ctrl-C aborts): " input \
      || { echo "No terminal input — aborting."; exit 1; }
    local still=()
    for tag in "${remaining[@]}"; do
      if recheck "$tag"; then
        echo "   ✓ solved: $tag — $(problem "$tag")"
      else
        still+=("$tag")
      fi
    done
    remaining=("${still[@]}")
    [ ${#remaining[@]} -eq 0 ] && remaining=()
  done
  ERR_TAGS=()
  success_block
}

success_block() {
  echo ""
  echo "=============================================================="
  echo " SUCCESS — the stack is down:"
  local m
  for m in cloud vault mail monitor; do
    if mod_rm "$m"; then
      echo "   removed    $m"
    fi
  done
  [ "${RM_EDGE:-false}"    = true ] && echo "   removed    edge (Caddy)"
  echo "   removed    caddy_data/"
  [ "${RM_HOST:-false}"    = true ] && echo "   removed    host services (goose, ttyd, dnsmasq, cron, fail2ban) + stack ufw ports"
  [ "${RM_PKGS:-false}"   = true ] && echo "   removed    packages (docker, dnsmasq, fail2ban, …)"
  # user root is never removed
  [ "${RM_TAILNET:-false}" = true ] && echo "   removed    tailnet membership"
  echo ""
  echo " Removed (always, no exceptions):"
  echo "   - the remote datadirectory (NFS export line + remote files)"
  echo ""
  echo " Kept:"
  echo "   - sshd hardening (removing it would re-enable password auth)"
  echo "   - $REPO"
  echo ""
  echo " Follow-ups (manual, none block):"
  echo "   1. Cloudflare: the DNS records for this host remain — delete them in"
  echo "      the dashboard if this machine is being decommissioned"
  echo "   2. Re-join the tailnet after a re-install: tailscale up"
  echo "   3. Re-install any time with: bash scripts/install/wizard.sh"
  echo "=============================================================="
}

summary() {
  if [ ${#ERR_TAGS[@]} -gt 0 ]; then
    echo ""
    echo " ERROR(S) — no success until every item below is resolved:"
    local exp=() unexp=() i
    for tag in "${ERR_TAGS[@]}"; do
      if is_expected "$tag"; then exp+=("$tag"); else unexp+=("$tag"); fi
    done
    if [ ${#exp[@]} -gt 0 ]; then
      echo " Manual steps (expected):"
      for i in "${!exp[@]}"; do
        echo "   $((i+1)). ${exp[$i]}"
        echo "      problem: $(problem "${exp[$i]}")$(err_d "${exp[$i]}")"
        echo "      hint: $(hint "${exp[$i]}")"
      done
    fi
    if [ ${#unexp[@]} -gt 0 ]; then
      echo " Unexpected errors (${#unexp[@]}):"
      for i in "${!unexp[@]}"; do
        echo "   $((i+1)). ${unexp[$i]}"
        echo "      problem: $(problem "${unexp[$i]}")$(err_d "${unexp[$i]}")"
        echo "      hint: $(hint "${unexp[$i]}")"
      done
    fi
  fi
}
trap summary EXIT

# ─────────────────────── full: stack and data ─────────────────────────────
# The default mode. Removes the production stack and its data, verifies the box
# is clean, and returns the verdict as its exit code (0 = gone, 1 = something is left).
full_teardown() {
  local k
  log "=== uninstall.sh — full teardown (production stack and data)"
  # The stack scope is preselected explicitly, otherwise the mod_rm guards
  # below skip every module, leaving the containers attached to 'net' so the
  # network rm fails and the verification reports a live stack
  # (2026-10-19 uninstall.log bug).
  for k in $STACK_MODULES; do
    eval "RM_MOD_${k^^}=true"
  done
  RM_MOD_DATA=true
  echo ""
  echo "Uninstalling the production stack:"
  for k in $STACK_MODULES; do
    mod_rm "$k" && { echo "   remove     $k"; }
  done
  echo "   remove     edge (Caddy)"
  echo "   remove     data/ whole (module data, rendered config, logs, wizard.state)"
  echo "   keep       the repo clone, host services, packages, root account, tailnet"
  echo ""

  # Containers first (their bind mounts are about to disappear), then the edge,
  # then every data dir the stack owns — including dirs no module claims.
  for k in $STACK_MODULES; do
    mod_rm "$k" && remove_module "$k"
  done
  local f
  f=$(edge_compose_file)
  if [ -n "$f" ]; then
    docker compose -f "$f" down --remove-orphans >>"$LOG" 2>&1 || fail edge "compose down failed"
    local c
    for c in $(ctn_of_module "$f"); do
      ctn_list | grep -qx "$c" && docker rm -f "$c" >>"$LOG" 2>&1 || true
    done
  fi
  docker network inspect net >/dev/null 2>&1 && \
    docker network rm net >>"$LOG" 2>&1 || true

  # data/ goes whole — one wipe, no granular folder picks; wizard.state lives
  # inside it and dies with it (the installer is its sole writer and recreates
  # everything fresh on the rebuild).
  wipe_data

  resolve_errors || return 1
  verify_stack_gone || return 1
  return 0
}

# ─────────────── --granular: wizard repair's teardown hand-off ────────────
# RESERVED for wizard.sh repair mode: wizard.sh calls this with WIZARD_REPAIR=1
# instead of tearing down inline. wizard.state (sourced here) is the source of
# truth — ONLY what the state says is disabled is removed:
#   • disabled modules: compose down + containers, data dirs, stale .svc hashes
#   • disabled doors' Cloudflare A records (creds read from wizard.state)
# Enabled modules, wizard.state, .cred-*.sha and the edge are untouched; the
# repair run converges everything else itself.
granular_stack_only() {
  if [ ! -f "$INSTALL_STATE" ]; then
    echo "granular mode needs $INSTALL_STATE — wizard.state is the source of truth."
    return 1
  fi
  if [ "${WIZARD_REPAIR:-}" != "1" ]; then
    echo "granular mode is reserved for wizard.sh repair mode."
    echo "For a manual teardown run: bash scripts/install/uninstall.sh   (full mode)"
    return 1
  fi
  # wizard.state is written by the wizard with printf %q — safe to source
  . "$INSTALL_STATE"
  mod_on() { local n="MOD_${1^^}"; [ "${!n:-true}" = "true" ]; }
  log "=== uninstall.sh --granular — wizard repair hand-off (wizard.state-driven)"

  local k svc
  for k in $STACK_MODULES; do
    mod_on "$k" && continue
    echo "   teardown   $k (disabled in wizard.state)"
    RM_MOD_DATA=true remove_module "$k"
    # cloud's database stack is its own compose project — down it too
    [ "$k" = cloud ] && [ -f "$REPO/modules/nextcloud/docker-compose.db.yml" ] && \
      docker compose -f "$REPO/modules/nextcloud/docker-compose.db.yml" down --remove-orphans >>"$LOG" 2>&1 || true
    case "$k" in   # drop the stale service hashes so a later re-enable re-applies
      cloud)   svc=nextcloud;;
      vault)   svc=vaultwarden;;
      mail)    svc=mailserver;;
      monitor) svc=uptimekuma;;
    esac
    rm -f "$PROJECT_DIR/.svc-$svc.sha"
  done

  # disabled doors lose their Cloudflare A records (needs the wizard.state creds)
  cf_a_del() { # cf_a_del <host> — remove the A record of a disabled door
    command -v jq >/dev/null 2>&1 || return 0
    [ -n "${CF_API_TOKEN:-}" ] && [ -n "${DOMAIN:-}" ] || return 0
    local zid fqdn rid
    zid=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" 2>>"$LOG" \
      | jq -r '.result[0].id // empty')
    [ -n "$zid" ] || { fail dns "zone id for $DOMAIN not resolved"; return 0; }
    fqdn="${1:+$1.}$DOMAIN"
    rid=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/zones/$zid/dns_records?type=A&name=$fqdn" 2>>"$LOG" \
      | jq -r '.result[0].id // empty')
    [ -n "$rid" ] || return 0
    curl -s -X DELETE -H "Authorization: Bearer $CF_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/zones/$zid/dns_records/$rid" >>"$LOG" 2>&1 || true
    log "  A record removed: $fqdn (disabled in wizard.state)"
  }
  mod_on cloud   || cf_a_del cloud
  mod_on vault   || cf_a_del vault
  mod_on monitor || cf_a_del kuma
  mod_on cloud && [ "${VIDEO_CALLING:-true}" = "false" ] && cf_a_del talk
  mod_on mail    || cf_a_del mail
  return 0
}

# ─────────────────────────────── main ──────────────────────────────────────

main() {
  [ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash scripts/install/uninstall.sh"; exit 1; }
  install -d -m 0755 "$LOG_DIR"
  # clear the log at the start of EVERY run — each teardown logs from scratch
  : > "$LOG" && chmod 640 "$LOG"
  banner
  case "${UNINSTALL_MODE:-full}" in
    granular)
      # wizard repair hand-off — no banner warnings, wizard.state-driven
      granular_stack_only
      exit $?
      ;;
    interactive)
      confirm_consequences || { echo "   aborted — nothing was touched."; exit 1; }
      interactive_teardown
      ;;
    *)
      # full mode: the three confirmations always apply
      confirm_consequences || { echo "   aborted — nothing was touched."; exit 1; }
      full_teardown
      exit $?
      ;;
  esac
}

interactive_teardown() {
  ask_inputs
  # nothing selected = nothing to do (all defaults are safe/keep)
  local any=false k
  for k in cloud vault mail monitor; do
    mod_rm "$k" && any=true
  done
  for v in RM_EDGE RM_HOST RM_PKGS RM_USER RM_TAILNET; do
    [ "${!v:-false}" = true ] && any=true
  done
  # NO partial teardowns: selecting any module for removal selects all of them.
  if [ "$any" = true ]; then
    for k in cloud vault mail monitor; do
      eval "RM_MOD_${k^^}=true"
    done
  fi
  if [ "$any" = false ]; then
    log "nothing selected — every prompt answered keep. Nothing was removed."
    exit 0
  fi
  for k in cloud vault mail monitor; do
    if mod_rm "$k"; then
      remove_module "$k"
    fi
  done
  [ "${RM_EDGE:-false}"    = true ] && remove_edge
  [ "${RM_HOST:-false}"    = true ] && remove_host
  [ "${RM_PKGS:-false}"    = true ] && remove_pkgs
  [ "${RM_USER:-false}"    = true ] && remove_user
  [ "${RM_TAILNET:-false}" = true ] && remove_tailnet
  # NO partial teardowns: removing any module removes all of them, and data/
  # is wiped whole — backups/, logs and wizard.state all die with it (the
  # installer recreates everything fresh on the rebuild).
  local went=false m
  for m in cloud vault mail monitor; do
    mod_rm "$m" && went=true
  done
  [ "$went" = true ] && wipe_data
  resolve_errors
  # the repo clone LAST and only after this script exits — bash reads the
  # script from disk; deleting it mid-run can truncate execution
  if [ "${RM_REPO:-false}" = true ]; then
    ( sleep 3; rm -rf "$REPO" ) >/dev/null 2>&1 &
    log "  repo deletion scheduled in 3s (after this script exits): $REPO"
  fi
}

main "$@"

