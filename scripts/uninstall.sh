#!/bin/bash
# homelab uninstall.sh — the exact opposite of install.sh, in the same style.
#
# Reverse-onboarding: takes the deployment apart module by module (cloud,
# vault, mail, games, monitor — all default OFF, opt in per module, the
# mirror of the installer's default-ON opt-out), then optionally the edge
# (Caddy + caddy_data), the host services (goose, ttyd, dnsmasq, cron,
# fail2ban, the stack's ufw rules), the installed packages (docker, …),
# the 'op' user, and the tailscale membership (always LAST, so the session
# and re-joining stay possible).
#
# MODE: the first prompt picks the scope —
#   1) specific modules    — per-module prompts (default keep), the phase
#                            prompts below all default no
#   2) the whole framework — every module + edge + host services + packages
#                            + user + tailnet preselected (the data prompts
#                            still default keep; one explicit confirm)
#   3) cancel
#
# Installs nothing, creates nothing. It removes what install.sh put on the
# box — auto-detected from the live system (compose files, systemctl, dpkg
# — no hardcoded rosters) — and NEVER deletes operator data without an
# explicit per-category prompt (every default is the safe answer):
#   - the storage VPS NFS export (user files) — untouched, period
#   - the Nextcloud local rollback copy, module data dirs, backups/ —
#     per-category prompts, default KEEP
#   - the repo clone — prompt, default KEEP
#   - sshd hardening — deliberately KEPT (removing the drop-in would
#     re-enable password auth; weakening is never the uninstall's job)
#
# installed-modules.conf is refreshed after each module removal (the same
# GENERATED file install.sh writes — read by `make smoke` + `make fetch`),
# so a partial uninstall leaves an accurate record; a full uninstall
# empties it (an EMPTY conf means "no module expected" — a MISSING conf
# means "all expected" to smoke, so the file is emptied, not deleted).
#
# Errors are collected with tags, each shown as a "problem" plus a "hint",
# and re-checked on Enter until all are green — then SUCCESS. Manual steps
# are grouped as expected; real failures as unexpected.
#
# Usage (root on the box, from the repo checkout):
#   sudo bash scripts/uninstall.sh
#
# Full log: /var/log/homelab-uninstall.log

set -uo pipefail

OP_USER=op
REPO=/var/www/custom/projects/homelab/repo
PROJECT_DIR=/var/www/custom/projects/homelab
CONF="$PROJECT_DIR/installed-modules.conf"
LOG=/var/log/homelab-uninstall.log
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

  One-shot teardown for the homelab stack: reverses scripts/install.sh
  step by step — modules first (cloud, vault, mail, games, monitor; all
  default OFF, opt in one by one), then the edge, the host services, the
  installed packages, the operator user, and the tailnet membership
  (last). Destructive by design: every prompt defaults to the safe
  answer and data is never touched without an explicit per-category
  confirm. Errors are listed with a hint each, re-checked on Enter, and
  SUCCESS prints only when every remaining item is resolved.

WARNING: removes containers, config and (on explicit confirm) operator
         data. SSH stays alive throughout — tailscale goes last.
EOF
}

# ───────────────────────────────── input ──────────────────────────────────

ask() { # ask <var> <question> <default: y|n>  (bare Enter takes the default)
  local __var=$1 __q=$2 __def=$3 __ans
  if [ -n "${!__var:-}" ]; then return 0; fi
  read -rp "$__q [$( [ "$__def" = y ] && echo Y/n || echo y/N )]: " __ans
  case "${__ans:-}" in
    y|Y|yes|YES) eval "$__var=true";;
    n|N|no|NO)   eval "$__var=false";;
    *)            eval "$__var=$([ "$__def" = y ] && echo true || echo false)";;
  esac
}

# read scripts/defaults/uninstall.conf (same dir as this script) — the
# non-interactive answer sheet, syntax mirrors install.conf:
#   'uninstall <key> = true|false'   (host|edge|pkgs|user|tailnet|data)
#   'uninstall <module> module = true|false'
# Everything defaults OFF (safe): a bare Enter never uninstalls anything.
defaults_uninstall() {
  local f dir line key val
  dir=$(cd "$(dirname "$0")" && pwd)
  for f in "$dir/scripts/defaults/uninstall.conf" "scripts/defaults/uninstall.conf"; do
    [ -f "$f" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      line=$(printf '%s' "$line" | sed -E 's/#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')
      [ -n "$line" ] || continue
      case "$line" in
        uninstall\ mode\ =*|uninstall\ mode=*)
          key="mode"
          val=$(echo "$line" | sed -E 's/.*=(modules|all|cancel|1|2|3)$/\1/')
          case "$val" in
            1|modules) UNINSTALL_MODE=modules;;
            2|all)    UNINSTALL_MODE=all;;
            3|cancel) UNINSTALL_MODE=cancel;;
          esac
          ;;
        uninstall\ *=true|uninstall\ *=false)
          # 'uninstall = true' = remove the module set listed below + edge
          val="${line##*=}"
          [ "$val" = true ] && DEF_RM_EDGE=true
          ;;
        uninstall\ module\ =*|uninstall\ *module*)
          key=$(echo "$line" | sed -E 's/^uninstall *([a-z-]+) *module *=.*/\1/')
          val=$(echo "$line" | sed -E 's/.*=(true|false)$/\1/')
          [ "$val" = true ] && eval "DEF_RM_MOD_${key^^}=true"
          ;;
        uninstall\ *)
          key=$(echo "$line" | sed -E 's/^uninstall *([a-z-]+) *=.*/\1/')
          val=$(echo "$line" | sed -E 's/.*=(true|false)$/\1/')
          case "$key" in
            host|edge|pkgs|user|tailnet|data)
              [ "$val" = true ] && eval "DEF_RM_${key^^}=true";;
          esac
          ;;
      esac
    done < "$f"
  done
  # safe fallbacks: everything OFF unless the conf says otherwise
  for k in host edge pkgs user tailnet data; do
    eval "[ -z \"\${DEF_RM_$k:-}\" ] && DEF_RM_$k=false"
  done
}

ask_modules() {
  # Reverse of the installer's ask_modules: default OFF for everything —
  # removing a module destroys its containers and (on data-confirm) its
  # data; the operator opts in per module.
  local k answer
  for k in cloud vault mail games monitor; do
    local var="RM_MOD_${k^^}" def=n
    eval "def=\${DEF_RM_MOD_${k^^}:-n}"
    if [ -z "${!var:-}" ]; then
      read -rp "Remove the $k module? [$( [ "$def" = y ] && echo Y/n || echo y/N )]: " answer
      case "${answer,,}" in
        y|Y|yes) eval "$var=true";;
        n|N|no)  eval "$var=false";;
        *)       eval "$var=$([ "$def" = y ] && echo true || echo false)";;
      esac
    fi
  done
}

ask_mode() {
  # the scope selector: specific modules, the whole framework, or cancel.
  # UNINSTALL_MODE=modules|all|cancel skips the prompt (defaults file or
  # env); an invalid value re-prompts.
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
      for k in cloud vault mail games monitor; do
        eval "RM_MOD_${k^^}=true"
      done
      RM_EDGE=true; RM_HOST=true; RM_PKGS=true; RM_USER=true; RM_TAILNET=true
      echo "Whole-framework teardown preselected: every module, the edge, the host"
      echo "services, the packages, the '$OP_USER' user and the tailnet membership."
      ;;
    modules|*)
      :   # the per-module prompts below decide the scope
      ;;
  esac
}

ask_inputs() {
  defaults_uninstall
  ask_mode
  ask_modules
  # phase prompts only when NOT preselected by the whole-framework mode
  [ "${RM_EDGE:-false}" = true ] || ask RM_EDGE "Remove the edge (Caddy container)?" "${DEF_RM_EDGE:-n}"
  ask RM_CADDY_DATA "  …and delete caddy_data/ (LE certs + CF token)?" n
  [ "${RM_HOST:-false}" = true ] || ask RM_HOST "Remove the host services (goose, ttyd, dnsmasq, cron, fail2ban) + the stack's ufw rules?" "${DEF_RM_HOST:-n}"
  [ "${RM_PKGS:-false}" = true ] || ask RM_PKGS "Purge the installed packages (docker, dnsmasq, fail2ban, …)?" "${DEF_RM_PKGS:-n}"
  [ "${RM_USER:-false}" = true ] || ask RM_USER "Delete the '$OP_USER' user?" "${DEF_RM_USER:-n}"
  [ "${RM_USER:-false}" = true ] && ask RM_USER_DATA "  …and its home dir /home/$OP_USER?" n
  [ "${RM_TAILNET:-false}" = true ] || ask RM_TAILNET "Remove this host from the tailnet (last step)?" "${DEF_RM_TAILNET:-n}"
  # data (all default KEEP; the storage VPS export is never touched)
  ask RM_MOD_DATA "Delete the data dirs of the modules being removed (vault/, kuma/, mailserver/, puffer/, cloud/ local files)?" "${DEF_RM_DATA:-n}"
  ask RM_NCLOCAL  "Delete the Nextcloud local rollback copy (cloud/users.local-backup)?" n
  ask RM_BACKUPS  "Delete $PROJECT_DIR/backups/ (snapshots + secrets bundles)?" n
  ask RM_REPO     "Delete the repo clone at $REPO (scheduled after this script exits)?" n
  local ml=""
  for k in cloud vault mail games monitor; do
    mod_rm "$k" && ml+="$k "
  done
  echo "Teardown summary — modules: ${ml:-none}· edge: ${RM_EDGE:-false} · host: ${RM_HOST:-false} · pkgs: ${RM_PKGS:-false} · user: ${RM_USER:-false} · tailnet: ${RM_TAILNET:-false}"
  echo "Full log: $LOG"
}

mod_rm() { # indirection: is module $1 selected for removal?
  local v="RM_MOD_${1^^}"
  [ "${!v:-false}" = true ]
}

# ─────────────────────── modules conf refresh (live) ───────────────────────

mod_installed() { [ -f "$CONF" ] && grep -qx "$1" "$CONF" 2>/dev/null; }

# snapshot of the modules recorded as installed BEFORE any removal (the
# conf is rewritten after each module removal, so the original set is
# captured once — no conf = every module was expected)
MODS_ORIGINAL="cloud vault mail games monitor"
[ -f "$CONF" ] && MODS_ORIGINAL=$(grep -vE '^[[:space:]]*(#|$)' "$CONF" | tr '\n' ' ')

# GENERATED — the same file install.sh writes, kept accurate: the original
# set minus every module removed so far. Removing every module leaves it
# EMPTY (not missing — a missing conf means "all modules expected" to make
# smoke).
refresh_modules_conf() {
  local m keep
  : > "$CONF"
  for m in $MODS_ORIGINAL; do
    mod_rm "$m" || echo "$m" >> "$CONF"
  done
  keep=$(paste -sd' ' "$CONF" 2>/dev/null)
  log "  refreshed installed-modules.conf (${keep:-empty})"
}

# ─────────────────────── phase: containers (reverse) ───────────────────────

ctn_list() { docker ps -a --format '{{.Names}}' 2>/dev/null; }

compose_file_of() { # module -> its compose file (repo layout)
  case "$1" in
    cloud)   echo "$REPO/services/nextcloud/docker-compose.yml";;
    vault)   echo "$REPO/services/vaultwarden/docker-compose.yml";;
    mail)    echo "$REPO/services/mailserver/docker-compose.yml";;
    games)   echo "$REPO/services/pufferpanel/docker-compose.yml";;
    monitor) echo "$REPO/services/uptimekuma/docker-compose.yml";;
  esac
}

ctn_of_module() { grep -E '^\s*container_name:' "$1" 2>/dev/null | awk '{print $2}'; }

module_data_dirs() { # module -> its host data dirs (never the storage export)
  case "$1" in
    cloud)   echo "$PROJECT_DIR/cloud $PROJECT_DIR/talk $PROJECT_DIR/pgdata";;
    vault)   echo "$PROJECT_DIR/vault";;
    mail)    echo "$PROJECT_DIR/mailserver";;
    games)   echo "$PROJECT_DIR/puffer $PROJECT_DIR/eaglercraft $PROJECT_DIR/download";;
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
      # the live datadirectory is the NFS mount of the storage VPS export:
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
      # refuse rather than risk deleting user files on the VPS
      if [ "$d" = "$PROJECT_DIR/cloud" ] && findmnt -n "$d/users" >/dev/null 2>&1; then
        fail "rmmod_$m" "data dir $d still holds the mounted datadirectory — not deleting"
        continue
      fi
      rm -rf "$d" >>"$LOG" 2>&1 || fail "rmmod_$m" "data dir $d not deleted"
    done
  fi
  refresh_modules_conf
}

# ─────────────────────── phase: edge + host (reverse) ─────────────────────

edge_compose_file() { # the edge is the compose project running the Caddy binary/image
  # the running container is the source of truth (the edge compose may build
  # a local image instead of pulling caddy:2.x, so don't grep for 'caddy')
  local f
  for f in "$REPO"/services/*/docker-compose.yml; do
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
  rm -f /etc/goose/goose.env /etc/kefohaine-banner.sh
  rm -f /etc/dnsmasq.d/10-tailnet.conf
  rm -f /etc/systemd/system/dnsmasq.service.d/override.conf
  rmdir /etc/systemd/system/dnsmasq.service.d 2>/dev/null || true
  rm -f /etc/sysctl.d/99-homelab.conf
  rm -f /etc/cron.d/nextcloud
  rm -f /etc/fail2ban/jail.d/sshd.conf
  # the binaries install.sh dropped into /usr/local/bin
  rm -f /usr/local/bin/ttyd /usr/local/bin/goose
  systemctl daemon-reload
  # sshd hardening is deliberately KEPT: removing the drop-in would
  # re-enable password auth — weakening is never the uninstall's job
  # the stack's ufw service ports — the tailnet SSH rule ALWAYS stays
  local p
  for p in 80/tcp 443/tcp 25565/tcp 19132/udp 25/tcp 465/tcp 587/tcp 993/tcp \
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
  log "  removing the '$OP_USER' user"
  if id -u "$OP_USER" >/dev/null 2>&1; then
    if [ "${RM_USER_DATA:-false}" = true ]; then
      userdel -r "$OP_USER" >>"$LOG" 2>&1 || fail user "userdel -r failed"
    else
      userdel "$OP_USER" >>"$LOG" 2>&1 || fail user "userdel failed"
      log "  /home/$OP_USER kept (home-dir deletion not confirmed)"
    fi
  fi
  rm -f "/etc/sudoers.d/$OP_USER-passwordless"
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
    edge)     echo "the edge (Caddy) is not fully removed" ;;
    host_goose)  echo "host service 'goose' not removed" ;;
    host_ttyd)   echo "host service 'ttyd' not removed (or was skipped — inside-ttyd guard)" ;;
    host_dnsmasq) echo "host service 'dnsmasq' not removed" ;;
    pkgs)     echo "installed packages not purged" ;;
    user)     echo "user '$OP_USER' not deleted" ;;
    tailnet)  echo "still on the tailnet" ;;
    *)        echo "$1" ;;
  esac
}

hint() {
  case "$1" in
    rmmod_*)  echo "run: docker ps -a; docker rm -f <the module's containers>; check $LOG, then re-check" ;;
    edge)     echo "run: docker rm -f <edge container>; docker network rm net; check $LOG, then re-check" ;;
    host_goose|host_dnsmasq) echo "run: systemctl disable --now ${1#host_}; rm -f /etc/systemd/system/${1#host_}.service; systemctl daemon-reload, then re-check" ;;
    host_ttyd) echo "run scripts/uninstall.sh from SSH or a local terminal (not the ttyd web shell), then re-check" ;;
    pkgs)     echo "run: apt-get purge docker.io docker-ce docker-ce-cli containerd.io docker-compose-plugin dnsmasq fail2ban apache2-utils sqlite3, then re-check" ;;
    user)     echo "run: userdel $OP_USER; rm -f /etc/sudoers.d/$OP_USER-passwordless, then re-check" ;;
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
    user)     ! id -u "$OP_USER" >/dev/null 2>&1;;
    tailnet)  ! tailscale status >/dev/null 2>&1;;
    *)        false ;;
  esac
}

is_expected() {
  case "$1" in
    host_ttyd) return 0 ;;  # the operator must re-run from outside ttyd — manual
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
  for m in cloud vault mail games monitor; do
    if mod_rm "$m"; then
      echo "   removed    $m"
    fi
  done
  [ "${RM_EDGE:-false}"    = true ] && echo "   removed    edge (Caddy)"
  [ "${RM_CADDY_DATA:-false}" = true ] && echo "   removed    caddy_data/"
  [ "${RM_HOST:-false}"    = true ] && echo "   removed    host services (goose, ttyd, dnsmasq, cron, fail2ban) + stack ufw ports"
  [ "${RM_PKGS:-false}"   = true ] && echo "   removed    packages (docker, dnsmasq, fail2ban, …)"
  [ "${RM_USER:-false}"   = true ] && echo "   removed    user '$OP_USER'"
  [ "${RM_TAILNET:-false}" = true ] && echo "   removed    tailnet membership"
  echo ""
  echo " Kept (unless explicitly confirmed otherwise):"
  echo "   - the storage VPS NFS export (user files) — untouched"
  echo "   - sshd hardening (removing it would re-enable password auth)"
  echo "   - $PROJECT_DIR/backups/"
  echo "   - $REPO"
  if [ -s "$CONF" ]; then
    echo "   - installed-modules.conf still lists: $(paste -sd' ' "$CONF")"
  else
    echo "   - installed-modules.conf is now empty (no modules expected)"
  fi
  echo ""
  echo " Follow-ups (manual, none block):"
  echo "   1. Cloudflare: the DNS records for this host remain — delete them in"
  echo "      the dashboard if this VPS is being decommissioned"
  echo "   2. Re-join the tailnet after a re-install: tailscale up"
  echo "   3. Re-install any time with: bash scripts/install.sh"
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

# ─────────────────────────────── main ──────────────────────────────────────

main() {
  [ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash scripts/uninstall.sh"; exit 1; }
  touch "$LOG" && chmod 666 "$LOG"
  banner
  ask_inputs
  # nothing selected = nothing to do (all defaults are safe/keep)
  local any=false k
  for k in cloud vault mail games monitor; do
    mod_rm "$k" && any=true
  done
  for v in RM_EDGE RM_HOST RM_PKGS RM_USER RM_TAILNET; do
    [ "${!v:-false}" = true ] && any=true
  done
  if [ "$any" = false ]; then
    log "nothing selected — every prompt answered keep. Nothing was removed."
    exit 0
  fi
  for k in cloud vault mail games monitor; do
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
  resolve_errors
  # the repo clone LAST and only after this script exits — bash reads the
  # script from disk; deleting it mid-run can truncate execution
  if [ "${RM_REPO:-false}" = true ]; then
    ( sleep 3; rm -rf "$REPO" ) >/dev/null 2>&1 &
    log "  repo deletion scheduled in 3s (after this script exits): $REPO"
  fi
}

main "$@"
