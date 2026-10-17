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
#   - the external machine NFS export (user files) — untouched, period
#   - the Nextcloud local rollback copy, module data dirs, backups/ —
#     per-category prompts, each requiring an explicit yes
#   - the repo clone — prompt, explicit yes required
#   - sshd hardening — deliberately KEPT (removing the drop-in would
#     re-enable password auth; weakening is never the uninstall's job)
#
# install.state (data/install.state) is the record the installer is the sole writer
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
# Usage (root on the box, from the repo checkout):
#   sudo bash scripts/install/uninstall.sh              # interactive teardown
#   sudo bash scripts/install/uninstall.sh --reinstall  # stack-only teardown,
#     no prompts, install.state dropped, then a VERIFICATION that the stack is
#     really gone. Exit 0 = verified gone, 1 = something is left. This is the
#     hand-off the installer calls for a reinstall (the installer only adds; every
#     removal lives here).
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
INSTALL_STATE="${INSTALL_STATE:-$PROJECT_DIR/install.state}"
LOG_DIR="${LOG_DIR:-$PROJECT_DIR/logs}"
LOG="$LOG_DIR/uninstall.log"
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

# There is no answer-sheet defaults file: every prompt is ALWAYS asked, only
# the literal words yes/no are accepted, and nothing is removed unless the
# operator answers yes.

# ─────────────── --reinstall: the installer's hand-off mode ───────────────
# the installer is ADD-ONLY, so a reinstall hands the removal HERE:
#   bash scripts/install/uninstall.sh --reinstall
# Scope is pre-answered and contains NO prompts — a reinstall rebuilds the
# production stack, so this mode removes exactly the stack and its data:
#   modules (containers + data dirs) · edge (Caddy + caddy_data/)
#   every module data dir including ones no module claims (pgdata, talk,
#   rendered, www, download, mailserver, logs, …) · install.state
# It NEVER touches the repo clone, the host services, the packages, the
# operator account or the tailnet membership — those are the framework, and a
# reinstall keeps them.
#
# Exit code is the SAFETY CHECK the installer depends on:
#   0 = the stack is verifiably gone (every check below passed) → the installer
#       proceeds with the reinstall run
#   1 = something is still there, or a removal failed, or the list could not be
#       listed → the installer ABORTS the reinstall (it changes nothing)
REINSTALL_MODE=false
for _a in "$@"; do
  case "$_a" in
    --reinstall) REINSTALL_MODE=true ;;
    --mode=*)    UNINSTALL_MODE="${_a#--mode=}" ;;
  esac
done
unset _a

# The stack scope, used by BOTH the removal and the verification so a check can
# never disagree with what was removed.
STACK_MODULES="cloud vault mail monitor"

# Everything under data/ that the stack owns. The four module dirs come from
# module_data_dirs; this adds the dirs no module claims (the edge's caddy_data,
# the web root, the log namespace, the render output), so "stack gone" also
# means "data/ really empty". $PROJECT_DIR itself is NOT removed while the
# installer's carried-over log is being read back — the installer recreates the
# directory and its fresh log right after this exits.
stack_data_dirs() {
  local d
  local all="$PROJECT_DIR/caddy_data $PROJECT_DIR/cloud $PROJECT_DIR/vault \
             $PROJECT_DIR/kuma $PROJECT_DIR/mailserver $PROJECT_DIR/pgdata \
             $PROJECT_DIR/talk $PROJECT_DIR/download $PROJECT_DIR/www \
             $PROJECT_DIR/rendered $PROJECT_DIR/backups"
  for d in $all; do
    [ -e "$d" ] && echo "$d"
  done
}

# The verification: is the stack REALLY gone? Runs after the removal in
# --reinstall mode. Every item below must be clean, so a half-removed stack can
# never be reinstalled onto. Read-only: it inspects, it never deletes.
verify_stack_gone() {
  local t=""
  local ctn="caddy nextcloud postgresql vaultwarden uptimekuma mailserver roundcube talk-hpb talk-relay"
  local c d

  for c in $ctn; do
    if ctn_list | grep -qx "$c"; then
      t+="container_$c "
    fi
  done
  docker network inspect net >/dev/null 2>&1 && t+="network "
  # data/ itself counts: the stack owns everything inside it, so a leftover dir
  # no module claims (rendered/, www/, caddy_data/, …) or a stray file is still
  # a live stack's data. data/logs holds the installer's and this script's own
  # logs and is recreated by the installer right after this exits — it is the
  # one directory allowed to survive, and it is reported when it is all that is
  # left behind (visible, not silent).
  for d in "$PROJECT_DIR"/* "$PROJECT_DIR"/.[!.]*; do
    [ -e "$d" ] || continue
    [ "$(basename "$d")" = logs ] && continue
    t+="data_$(basename "$d") "
  done
  [ -d "$PROJECT_DIR/logs" ] && log "  note: data/logs kept (holds this teardown's own log; the installer recreates its fresh wizard.log)"
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
    echo " Reinstall aborted (the installer will not rebuild onto a live stack)."
    log "  reinstall verification FAILED: ${ERR_TAGS[*]}"
    return 1
  fi
  echo ""
  echo " Stack verified gone: containers, network, data/ and install.state are all clear."
  log "  reinstall verification passed — nothing of the stack is left"
  return 0
}

# Hand the box back to the installer after a teardown that left it unusable (the
# stack and its data gone, nothing else touched) — that is exactly the state
# the installer's reinstall gate expects, so it rebuilds the production stack with
# freshly asked values and runs smoke last. Offered, never assumed: only an
# explicit yes spawns it, and UNS_INSTALLER=yes (set by the installer's own
# hand-off, one level down) suppresses it entirely so the two scripts can never
# bounce the box between each other.
ask_restore() {
  local v="${UNINSTALL_RESTORE:-}" a
  [ "${UNS_INSTALLER:-}" = yes ] && return 0
  if [ -n "$v" ]; then
    case "${v,,}" in
      yes) RESTORE_AFTER=true ;; no) RESTORE_AFTER=false ;; *) v="" ;;
    esac
  fi
  [ -n "$v" ] && return 0
  while :; do
    read -rp "Uninstall finished — run the installer to reinstall the stack now? (yes/no): " a || return 1
    case "${a,,}" in
      yes) RESTORE_AFTER=true;  return 0;;
      no)  RESTORE_AFTER=false; return 0;;
      *)   echo "   type yes or no.";;
    esac
  done
}

# Start the installer (never exec: this script's log stays the teardown's own).
# data/ is gone, so the installer opens its fresh data/logs/wizard.log and asks
# every value at the repair/reinstall gate.
restore_after_teardown() {
  [ "${RESTORE_AFTER:-false}" = true ] || return 0
  echo ""
  echo "Reinstalling the production stack: bash $REPO/scripts/install/install.sh"
  echo "   …it will find data/ erased; answer 'reinstall' at its first prompt."
  bash "$REPO/scripts/install/install.sh"
  log "  the installer returned ($?) after the teardown hand-off"
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
  ask RM_CADDY_DATA "  …and delete caddy_data/ (LE certs + CF token)?"
  [ "${RM_HOST:-false}" = true ] || ask RM_HOST "Remove the host services (goose, ttyd, dnsmasq, cron, fail2ban) + the stack's ufw rules?"
  [ "${RM_PKGS:-false}" = true ] || ask RM_PKGS "Purge the installed packages (docker, dnsmasq, fail2ban, …)?"
  # operator account root is never deleted (sole entry point) — no prompt
  [ "${RM_TAILNET:-false}" = true ] || ask RM_TAILNET "Remove this host from the tailnet (last step)?"
  # data (each explicitly confirmed; the external machine export is never touched)
  ask RM_MOD_DATA "Delete the data dirs of the modules being removed (vault/, kuma/, mailserver/, cloud/ local files)?"
  ask RM_NCLOCAL  "Delete the Nextcloud local rollback copy (cloud/users.local-backup)?"
  ask RM_BACKUPS  "Delete $PROJECT_DIR/backups/ (snapshots + secrets bundles)?"
  ask RM_REPO     "Delete the repo clone at $REPO (scheduled after this script exits)?"
  local ml=""
  for k in cloud vault mail monitor; do
    mod_rm "$k" && ml+="$k "
  done
  # The real reinstall is the pair: this teardown, then the installer in reinstall
  # mode on the emptied box. `any` is false when nothing is selected — an
  # operator who only wants the stack rebuilt is sent straight to the installer
  # (it can repair, no teardown needed).
  if [ "${any_sel:-false}" != true ]; then
    ask_restore
  elif [ "${RM_MOD_DATA:-false}" = true ] && [ "${RM_TAILNET:-false}" != true ]; then
    ask_restore    # data/ is gone but the box stays usable → offer the rebuild
  else
    echo ""
    echo "Reinstall the production stack later with: bash $REPO/scripts/install/install.sh"
    echo "   …answer 'reinstall' at its first prompt (repairs a running instance instead)."
  fi
  echo "Teardown summary — modules: ${ml:-none}· edge: ${RM_EDGE:-false} · host: ${RM_HOST:-false} · pkgs: ${RM_PKGS:-false} · user: ${RM_USER:-false} · tailnet: ${RM_TAILNET:-false}"
  echo "Full log: $LOG"
}

mod_rm() { # indirection: is module $1 selected for removal?
  local v="RM_MOD_${1^^}"
  [ "${!v:-false}" = true ]
}

# ────────────── install.state teardown update (the one exception) ──────────

# The enabled modules recorded BEFORE any removal (empty when there is no
# state — nothing was installed). Read in a subshell so the state's secrets
# never enter this script's environment.
MODS_ORIGINAL=""
if [ -f "$INSTALL_STATE" ]; then
  MODS_ORIGINAL="$( ( . "$INSTALL_STATE" 2>/dev/null; printf '%s' "${enabled_modules:-}" ) 2>/dev/null )"
fi

# Rewrite ONLY enabled_modules + finished in $INSTALL_STATE, preserving every
# other (secret) line. The installer is otherwise the sole writer; this is the
# documented teardown exception.
state_reset() {   # state_reset <enabled_modules> <finished>
  [ -f "$INSTALL_STATE" ] || return 0
  local tmp="$INSTALL_STATE.tmp.$$"
  { grep -vE '^(enabled_modules|finished)=' "$INSTALL_STATE" 2>/dev/null || :
    printf 'enabled_modules=%q\n' "$1"
    printf 'finished=%q\n' "$2"
  } > "$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$INSTALL_STATE" 2>/dev/null || rm -f "$tmp"
}

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
      if [ "${RM_NCLOCAL:-false}" = true ] && [ -d "$PROJECT_DIR/cloud/users.local-backup" ]; then
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
  if [ "${RM_CADDY_DATA:-false}" = true ] && [ -d "$PROJECT_DIR/caddy_data" ]; then
    rm -rf "$PROJECT_DIR/caddy_data" >>"$LOG" 2>&1 || fail edge "caddy_data not deleted"
    rm -rf "$PROJECT_DIR/download" >>"$LOG" 2>&1 || true
  fi
  # the shared bridge network goes only when nothing is attached anymore
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
  rm -f /etc/goose/goose.env /etc/kefo-banner.sh
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
    # --reinstall verification (the installer's hand-off): the stack must be gone
    container_*) echo "container ${1#container_} is still there" ;;
    network)  echo "the stack's docker network 'net' is still there" ;;
    data_*)   echo "data/${1#data_} is still there" ;;
    state)    echo "install.state is still there" ;;
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
    container_*) echo "run: docker rm -f ${1#container_}, then re-run: bash scripts/install/uninstall.sh --reinstall" ;;
    network)  echo "run: docker network rm net, then re-run: bash scripts/install/uninstall.sh --reinstall" ;;
    data_*)   echo "run: rm -rf $PROJECT_DIR/${1#data_}, then re-run: bash scripts/install/uninstall.sh --reinstall" ;;
    state)    echo "run: rm -f $INSTALL_STATE, then re-run: bash scripts/install/uninstall.sh --reinstall" ;;
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

is_expected() {
  case "$1" in
    host_ttyd) return 0 ;;  # the operator must re-run from outside ttyd — manual
    # --reinstall verification failures are UNEXPECTED: the teardown's own
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
        echo "      problem: $(problem "${exp[$i]}")${ERR_DETAIL[${exp[$i]}]:+ (${ERR_DETAIL[${exp[$i]}]})}"
        echo "      hint: $(hint "${exp[$i]}")"
      done
    fi
    if [ ${#unexp[@]} -gt 0 ]; then
      echo " Unexpected errors (${#unexp[@]}):"
      for i in "${!unexp[@]}"; do
        echo "   $((i+1)). ${unexp[$i]}"
        echo "      problem: $(problem "${unexp[$i]}")${ERR_DETAIL[${unexp[$i]}]:+ (${ERR_DETAIL[${unexp[$i]}]})}"
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
  [ "${RM_CADDY_DATA:-false}" = true ] && echo "   removed    caddy_data/"
  [ "${RM_HOST:-false}"    = true ] && echo "   removed    host services (goose, ttyd, dnsmasq, cron, fail2ban) + stack ufw ports"
  [ "${RM_PKGS:-false}"   = true ] && echo "   removed    packages (docker, dnsmasq, fail2ban, …)"
  # user root is never removed
  [ "${RM_TAILNET:-false}" = true ] && echo "   removed    tailnet membership"
  echo ""
  echo " Kept (unless explicitly confirmed otherwise):"
  echo "   - the external machine NFS export (user files) — untouched"
  echo "   - sshd hardening (removing it would re-enable password auth)"
  echo "   - $PROJECT_DIR/backups/"
  echo "   - $REPO"
  if [ -f "$INSTALL_STATE" ]; then
    echo "   - install.state: enabled_modules now '$(sed -n 's/^enabled_modules=//p' "$INSTALL_STATE")', finished=false"
  fi
  echo ""
  echo " Follow-ups (manual, none block):"
  echo "   1. Cloudflare: the DNS records for this host remain — delete them in"
  echo "      the dashboard if this machine is being decommissioned"
  echo "   2. Re-join the tailnet after a re-install: tailscale up"
  echo "   3. Re-install any time with: bash scripts/install/install.sh"
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
        echo "      problem: $(problem "${exp[$i]}")${ERR_DETAIL[${exp[$i]}]:+ (${ERR_DETAIL[${exp[$i]}](})}"
        echo "      hint: $(hint "${exp[$i]}")"
      done
    fi
    if [ ${#unexp[@]} -gt 0 ]; then
      echo " Unexpected errors (${#unexp[@]}):"
      for i in "${!unexp[@]}"; do
        echo "   $((i+1)). ${unexp[$i]}"
        echo "      problem: $(problem "${unexp[$i]}")${ERR_DETAIL[${unexp[$i]}]:+ (${ERR_DETAIL[${unexp[$i]}]})}"
        echo "      hint: $(hint "${unexp[$i]}")"
      done
    fi
  fi
}
trap summary EXIT

# ─────────────────────── --reinstall: stack only ──────────────────────────
# No prompts: the installer already asked, and this mode is the installer's hand-off.
# Removes the production stack and its data, verifies the box is clean, and
# returns the verdict as its exit code (0 = gone, 1 = something is left).
reinstall_stack_only() {
  local k
  log "=== uninstall.sh --reinstall — production stack only (no host, no repo, no tailnet)"
  echo ""
  echo "Uninstalling the production stack (hand-off from the installer):"
  for k in $STACK_MODULES; do
    mod_rm "$k" && { echo "   remove     $k"; }
  done
  echo "   remove     edge (Caddy) + caddy_data/"
  echo "   remove     data/ (module data, rendered config, logs, install.state)"
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
  docker network rm net >>"$LOG" 2>&1 || true

  local d
  for d in $(stack_data_dirs); do
    rm -rf "$d" >>"$LOG" 2>&1 || fail "data_$(basename "$d")" "$d not deleted"
  done
  # install.state lives in data/ and is written by the installer alone — this is
  # the documented teardown exception: drop the record WITH its data, so no
  # reader can see a finished install for a stack that no longer exists.
  [ -f "$INSTALL_STATE" ] && rm -f "$INSTALL_STATE" >>"$LOG" 2>&1

  resolve_errors || return 1
  verify_stack_gone || return 1
  return 0
}

# ─────────────────────────────── main ──────────────────────────────────────

main() {
  [ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash scripts/install/uninstall.sh"; exit 1; }
  install -d -m 0755 "$LOG_DIR"
  touch "$LOG" && chmod 640 "$LOG"
  banner
  if [ "${REINSTALL_MODE:-false}" = true ]; then
    reinstall_stack_only
    exit $?
  fi
  ask_inputs
  # nothing selected = nothing to do (all defaults are safe/keep)
  local any=false k
  for k in cloud vault mail monitor; do
    mod_rm "$k" && any=true
  done
  for v in RM_EDGE RM_HOST RM_PKGS RM_USER RM_TAILNET; do
    [ "${!v:-false}" = true ] && any=true
  done
  any_sel=$any
  if [ "$any" = false ]; then
    log "nothing selected — every prompt answered keep. Nothing was removed."
    ask_restore
    restore_after_teardown
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
  # backups/ on explicit confirm (after the stack is down)
  if [ "${RM_BACKUPS:-false}" = true ] && [ -d "$PROJECT_DIR/backups" ]; then
    rm -rf "$PROJECT_DIR/backups" >>"$LOG" 2>&1 || log "WARN: backups/ not deleted"
  fi
  # install.state teardown update (the one exception to the installer's sole
  # write): drop the removed modules and clear the finished checkpoint so
  # `make smoke` no longer treats this host as a finished install.
  if [ -f "$INSTALL_STATE" ]; then
    local keep="" m
    for m in $MODS_ORIGINAL; do
      mod_rm "$m" || keep+="$m "
    done
    state_reset "${keep% }" false
    log "  install.state: enabled_modules='${keep% }' finished=false"
  fi
  resolve_errors
  restore_after_teardown
  # the repo clone LAST and only after this script exits — bash reads the
  # script from disk; deleting it mid-run can truncate execution
  if [ "${RM_REPO:-false}" = true ]; then
    ( sleep 3; rm -rf "$REPO" ) >/dev/null 2>&1 &
    log "  repo deletion scheduled in 3s (after this script exits): $REPO"
  fi
}

main "$@"

