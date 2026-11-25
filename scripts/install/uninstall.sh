#!/bin/bash
# This script performs the reverse of the installer, in the same style.
#
# TWO MODES, ASKED FIRST: the menu is the operator's first question — before
# the log is opened, before any module prompt and before a single removal.
#   full     — the whole framework: every module, the edge (Caddy), data/
#              WHOLE (no folder picks), every kefoCloud file in the other
#              system paths (systemd units/timers, dnsmasq, sysctl, fail2ban
#              jails+filters, logrotate, banner, docker daemon config, goose
#              env, the /usr/local/bin binaries), the stack's ufw rules, the
#              installed packages and the tailnet (ALWAYS LAST, so the
#              session survives). No module pick: full means all. The repo
#              clone, root and the sshd hardening stay.
#   granular — only the modules the operator picks: their containers, compose
#              stacks and (on one explicit yes) their own data dirs. data/ of
#              every other module, the edge, the host files, the packages and
#              the tailnet are untouched.
#
# wizard.state is NEVER read or rewritten here: what goes is what the operator
# named (or, for full, the whole stack), never what a state file claims. The
# installer stays its sole writer. --modules=a,b --data make the granular
# teardown non-interactive for the installer's repair hand-off (no prompts),
# and that path also drops the disabled doors' Cloudflare A records using the
# credentials the installer already exported.
#
# Idempotent by construction: every removal tolerates an absent target (rm -f,
# a docker that is not installed, an already-off tailnet, a data/ that is
# already gone), so a re-run converges instead of failing. Only a target that
# is still present after its own removal is an error.
#
# Installs nothing, creates nothing. What it removes is derived from the live
# system and the tracked config/ tree (compose files, rendered units, dpkg) —
# never a hardcoded roster — and operator data is never deleted without an
# explicit per-category yes (no defaults; only the words yes/no are accepted):
#   - data/ (full mode) — removed WHOLE, no folder picks
#   - a removed module's own data dirs — one explicit confirm
#   - the repo clone — always KEPT
#   - sshd hardening — deliberately KEPT (removing the drop-in would
#     re-enable password auth; weakening is never the uninstall's job)
#
# Errors are collected with tags, each shown as a "problem" plus a "hint",
# and re-checked on Enter until all are green — then SUCCESS.
#
# Both operator modes go through the three consequence confirmations before
# anything is touched.
#
# Usage (root on the box, from the repo checkout):
#   sudo bash scripts/install/uninstall.sh             # ask full or granular
#   sudo bash scripts/install/uninstall.sh --full      # skip the menu
#   sudo bash scripts/install/uninstall.sh --granular  # skip the menu, pick modules
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
# The log lives with EVERY other log this project writes — $DATA_DIR/logs, the
# one namespace covered by config/logrotate/instance — instead of next to this
# script, so no repo directory and no instance directory are ever confused.
# A full teardown deletes data/ while this script is running, so wipe_data()
# copies the log to /var/tmp and CONTINUES there: the record survives the
# teardown it describes (LOG_DIR is inherited from the wizard hand-off, which
# already exports $DATA/logs).
LOG_DIR="${LOG_DIR:-$PROJECT_DIR/logs}"
LOG="$LOG_DIR/uninstall.log"
# The directory is created by main(), which also decides the log location: a
# modules-only run on a host without data/ must never CREATE data/ for the log.
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

  One-shot teardown for the homelab stack: reverses the installer.
  First question: full or granular. full takes the whole framework apart
  (every module, the edge, data/ whole, the host files, the packages, the
  tailnet last); granular lets you pick the modules (their containers, compose
  stacks and, on one explicit yes, their own data dirs) and leaves the rest.
  Destructive by design: no prompt has a default — only the words yes/no are
  accepted — and data is never touched without an explicit confirm.
  Idempotent: a re-run converges. Errors are listed with a hint each, re-checked on Enter, and
  SUCCESS prints only when every remaining item is resolved.

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

# Three consecutive consequence confirmations before ANYTHING is touched,
# worded for the mode the operator picked. Nothing skips them: a teardown is
# only ever a manual operator run.
confirm_consequences() { # $1 = full|modules
  local scope="${1:-full}" a
  echo ""
  echo " ── CONFIRMATION 1/3 — what dies ─────────────────────────────────────────"
  case "$scope" in
    modules)
      echo "    ONLY the modules you named: their containers, compose stacks and"
      echo "    (if you answered yes) their own data dirs. Everything else stays." ;;
    *)
      echo "    Every module, data/ WHOLE, every kefoCloud file in the other"
      echo "    system paths, the stack's ufw rules, the packages and the tailnet."
      echo "    The repo clone, root and sshd hardening stay." ;;
  esac
  read -rp "    Understand and want to proceed? (yes/no): " a || return 1
  [ "${a,,}" = yes ] || return 1
  echo " ── CONFIRMATION 2/3 — no way back ───────────────────────────────────────"
  echo "    Everything removed here is IRREVERSIBLE: containers, config and any"
  echo "    data named above cannot be recovered. The installer can rebuild the"
  echo "    stack, but NOT your data."
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

# ──────────────────────── modes: full / granular ───────────────────────────
# The menu (ask_mode) is asked FIRST in main(): before the log is opened,
# before any module prompt and before a single removal. --full / --granular
# answer it up front. --modules=a,b (with --data) makes granular
# non-interactive for the installer's repair hand-off: the caller names the
# modules it turned off, so nothing here reads wizard.state.
UNINSTALL_MODE=""
MODULE_PICK=""
PICK_DATA=false
for _a in "$@"; do
  case "$_a" in
    --full|--mode=full)         UNINSTALL_MODE=full ;;
    --granular|--mode=granular) UNINSTALL_MODE=granular ;;
    --modules=*)                MODULE_PICK="${_a#--modules=}" ;;
    --data)                     PICK_DATA=true ;;
  esac
done
unset _a
[ -n "$MODULE_PICK" ] && UNINSTALL_MODE=granular

# The stack scope, used by BOTH the removal and the verification so a check can
# never disagree with what was removed. DERIVED from the catalog
# (config/modules.conf) — the same declaration the installer, `make fetch` and
# the smoke test read — never a hand-kept list: the hardcoded one here missed
# home, blog and photos, so their containers survived a teardown and a module
# turned off in repair kept serving.
MODULES_CONF="$REPO/config/modules.conf"
STACK_MODULES="$(awk '!/^#/ && NF>=3 {printf "%s ", $1}' "$MODULES_CONF" 2>/dev/null)"
module_dir_of()    { awk -v m="$1" '!/^#/ && $1==m {print $2; exit}' "$MODULES_CONF" 2>/dev/null; }
module_host_of()   { awk -v m="$1" '!/^#/ && $1==m {print $3; exit}' "$MODULES_CONF" 2>/dev/null; }
# The .svc-<group>.sha names the installer's repair skip uses; the installer
# names each group after the module DIRECTORY (chat -> matrix, vault ->
# vaultwarden, …), so the catalog's dir column is the one definition.
svc_group_of() { module_dir_of "$1"; }

# data/ goes as ONE directory — no granular folder picks. The stack owns every
# path under it (module dirs, caddy_data, rendered/, pages/, logs, wizard.state),
# so "stack gone" means data/ itself is gone. The installer recreates the
# directory and its fresh log right after this exits. Guard: anything still
# mounted under data/ is unmounted first — an rm -rf through a live mount
# would propagate INTO the mounted storage.
wipe_data() {
  local m
  # Idempotent: a second teardown finds data/ already gone and must not fail.
  [ -e "$PROJECT_DIR" ] || { log "  data/ is already gone — nothing to wipe"; return 0; }
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
  # Derived from the same catalog the removal used: a hardcoded roster missed
  # matrix-mas, element-admin, ocis, homarr, writefreely and immich, so a
  # half-removed stack could still verify "gone".
  local ctn c m d
  ctn="caddy"
  for m in $STACK_MODULES; do
    ctn="$ctn $(ctn_of_module "$(compose_file_of "$m")" | tr '\n' ' ')"
  done

  for c in $ctn; do
    if ctn_list | grep -qx "$c"; then
      t+="container_$c "
    fi
  done
  docker network inspect net >/dev/null 2>&1 && t+="network "
  # data/ itself counts, whole: the stack owns everything inside it, so any
  # leftover (a module dir, rendered/, pages/, a stray file) is a live stack.
  [ -e "$PROJECT_DIR" ] && t+="data "
  # module compose files are repo-TRACKED and deliberately kept — they are the
  # framework, not stack state. wizard.state is not checked or touched: the
  # teardown removes what the operator named, never what a state file claims.

  # Append, never reset: an earlier removal failure must stay in the report.
  local tag
  for tag in $t; do
    case " ${ERR_TAGS[*]:-} " in *" $tag "*) ;; *) ERR_TAGS+=("$tag") ;; esac
  done
  if [ -n "$t" ] || [ ${#ERR_TAGS[@]} -gt 0 ]; then
    log "  teardown verification FAILED: ${t:-${ERR_TAGS[*]}}"
    return 1
  fi
  echo ""
  echo " Stack verified gone: containers, network and data/ are all clear."
  log "  teardown verification passed — nothing of the stack is left"
  return 0
}

# After a granular teardown: every chosen module must have no
# container (and, when its data was confirmed, no data dir) left.
verify_modules_gone() {
  local m c d bad=0
  for m in "$@"; do
    for c in $(ctn_of_module "$(compose_file_of "$m")"); do
      if ctn_list | grep -qx "$c"; then
        case " ${ERR_TAGS[*]:-} " in *" rmmod_$m "*) ;; *) ERR_TAGS+=("rmmod_$m") ;; esac
        bad=1
      fi
    done
    if [ "${RM_MOD_DATA:-false}" = true ]; then
      for d in $(module_data_dirs "$m"); do
        [ -e "$d" ] && { ERR_TAGS+=("rmmod_$m"); bad=1; }
      done
    fi
  done
  [ "$bad" -eq 0 ] && echo " Modules verified removed: containers and data dirs are clear."
  return $bad
}

# Where the installer renders one tracked config/ file on the host. DERIVED
# from the tracked tree file by file, never a hand-kept roster: a unit, jail,
# filter or logrotate rule added to config/ is removed by the same edit that
# installs it. sshd's 50-cloud-init.conf is deliberately NOT here (kept).
host_path_of() {
  local rel="${1#"$REPO"/config/}"
  case "$rel" in
    ssh/*) return 0 ;;   # hardening drop-in: deliberately kept
    systemd/*) printf '/etc/systemd/system/%s\n' "$(basename "$rel")" ;;
    goose/goose.service|ttyd/ttyd.service)
      printf '/etc/systemd/system/%s\n' "$(basename "$rel")" ;;
    fail2ban/*) printf '/etc/fail2ban/%s\n' "${rel#fail2ban/}" ;;
    dnsmasq/10-tailnet.conf) printf '/etc/dnsmasq.d/10-tailnet.conf\n' ;;
    dnsmasq/dnsmasq.service.conf)
      printf '/etc/systemd/system/dnsmasq.service.d/override.conf\n' ;;
    sysctl/99-kefo.conf) printf '/etc/sysctl.d/99-kefo.conf\n' ;;
    logrotate/instance) printf '/etc/logrotate.d/instance\n' ;;
    bash/banner.sh) printf '/etc/kefo-banner.sh\n' ;;
    docker/daemon.json) printf '/etc/docker/daemon.json\n' ;;
    # everything else is an input/template, not a file of its own on the host
  esac
}

# The host files the installer rendered out of config/ (plus the legacy goose
# env the installer migrated from).
system_files() {
  local f
  while IFS= read -r f; do
    host_path_of "$f"
  done < <(find "$REPO/config" -type f | sort)
  printf '%s\n' /etc/goose/goose.env
}

# The /usr/local/bin binaries the rendered units' own ExecStart names — no
# roster, so a unit added to config/ brings its binary into the teardown.
host_binaries() {
  local f
  while IFS= read -r f; do
    sed -n 's/^ExecStart=//p' "$f"
  done < <(find "$REPO/config" -type f \( -name '*.service' -o -name '*.timer' \) | sort) \
    | awk '{print $1}' | sed 's/^-//' | grep '^/usr/local/bin/' | sort -u
}

# After the whole-framework scope: no project file may be left in a system path.
verify_host_gone() {
  local f b bad=0
  while IFS= read -r f; do
    [ -e "$f" ] || continue
    ERR_TAGS+=("sysfile_$(basename "$f")"); bad=1
  done < <(system_files)
  while IFS= read -r b; do
    [ -e "$b" ] || continue
    ERR_TAGS+=("hostbin_$(basename "$b")"); bad=1
  done < <(host_binaries)
  if grep -qxF '. /etc/kefo-banner.sh' "${HOME:-/root}/.bashrc" 2>/dev/null; then
    ERR_TAGS+=("banner_line"); bad=1
  fi
  [ "$bad" -eq 0 ] && echo " Host files verified gone: no project file, binary or banner line is left."
  return $bad
}

ask_mode() {
  # The FIRST question: which teardown. Nothing else — no log, no module
  # prompt, no removal — happens before this answer. Each option prints what
  # it removes in plain words.
  case "${UNINSTALL_MODE:-}" in
    full|granular) return 0 ;;
    "") ;;
    *) echo "   unknown mode '${UNINSTALL_MODE}' — pick full or granular."; UNINSTALL_MODE="" ;;
  esac
  local m
  echo ""
  echo " Teardown mode:"
  echo "   [1] full — remove the whole framework: every module, the edge"
  echo "       (Caddy), data/ WHOLE (no folder picks), the host files, the"
  echo "       packages and the tailnet (last). The repo clone and root stay."
  echo "   [2] granular — remove ONLY the modules you pick next: their"
  echo "       containers, compose stacks and (on one explicit yes) their own"
  echo "       data dirs. Other modules' data, the edge, host files, packages"
  echo "       and the tailnet stay."
  while :; do
    read -rp " enter 1 (full) or 2 (granular): " m \
      || { echo "   no answer — nothing was touched."; return 1; }
    case "${m,,}" in
      1|full)     UNINSTALL_MODE=full;     return 0 ;;
      2|granular) UNINSTALL_MODE=granular; return 0 ;;
      *) echo "   enter 1 or 2." ;;
    esac
  done
}

ask_modules() {
  # Show the roster ONCE, then one yes/no per module: nothing removed unless
  # explicitly confirmed — removing a module destroys its containers and (on
  # the data confirm) its data; the operator opts in per module.
  local k answer h any=false
  echo ""
  echo " Modules in this stack (from config/modules.conf):"
  for k in $STACK_MODULES; do
    h="$(module_host_of "$k")"
    if [ -n "$h" ] && [ "$h" != "-" ]; then
      printf '   %-8s — public vhost: %s\n' "$k" "$h"
    else
      printf '   %-8s — no vhost of its own\n' "$k"
    fi
  done
  echo ""
  for k in $STACK_MODULES; do
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
    [ "${!var:-false}" = true ] && any=true
  done
  [ "$any" = true ] && ask RM_MOD_DATA "Delete the data dirs of the removed modules?"
}

ask_pick_summary() { # $1... = the modules selected
  echo ""
  echo "Rebuild the stack later with: bash $REPO/scripts/install/wizard.sh"
  echo "Teardown summary — modules removed: ${*:-none} · their data: ${RM_MOD_DATA:-false} · repo: kept"
  echo "Full log: $LOG"
}

mod_rm() { # indirection: is module $1 selected for removal?
  local v="RM_MOD_${1^^}"
  [ "${!v:-false}" = true ]
}

# ─────────────────────── phase: containers (reverse) ───────────────────────

ctn_list() { docker ps -a --format '{{.Names}}' 2>/dev/null; }

compose_file_of() { # module -> its compose file (the catalog's dir column)
  local d; d="$(module_dir_of "$1")"
  [ -n "$d" ] && echo "$REPO/modules/$d/docker-compose.yml"
}

ctn_of_module() { grep -E '^\s*container_name:' "$1" 2>/dev/null | awk '{print $2}'; }

module_data_dirs() { # module -> the host data dirs its compose file binds
  # Derived from the compose bind mounts (the catalog's dir column names the
  # module DIRECTORY, which is not always the data dir: vault -> data/vault,
  # monitor -> data/kuma, photos -> data/photos).
  # The EDGE-OWNED trees are never a module's data, even though a module's
  # compose file may mount them read-only (roundcube reads rendered/,
  # a vhost serves pages/): removing them here would delete the whole edge
  # config because one module was turned off.
  local f; f="$(compose_file_of "$1")"
  [ -f "$f" ] || return 0
  grep -ohE '\$\{DATA_DIR\}/[A-Za-z0-9._-]+' "$f" 2>/dev/null \
    | sed -E 's|^\$\{DATA_DIR\}/||' | sort -u \
    | grep -vxE 'rendered|pages|caddy_data|download' \
    | while IFS= read -r d; do printf '%s/%s\n' "$PROJECT_DIR" "$d"; done
}

remove_module() { # $1=module
  local m=$1 f c ctns
  f=$(compose_file_of "$m")
  ctns=$(ctn_of_module "$f")
  log "  removing the $m module (containers: $(echo "$ctns" | tr '\n' ' '))"
  # Idempotent: no docker on the box means nothing of this module can be
  # running (a re-run after the packages were purged), not a failure.
  if ! command -v docker >/dev/null 2>&1; then
    log "  docker is not installed — no containers to remove"
  elif [ -f "$f" ]; then
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
  if [ "${RM_MOD_DATA:-false}" = true ]; then
    local d
    for d in $(module_data_dirs "$m"); do
      [ -d "$d" ] || continue
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
  log "  removing the host files (units, dnsmasq, sysctl, fail2ban, logrotate, banner, binaries)"
  local inside_ttyd=false
  # never stop ttyd from a shell inside ttyd (2026-09-11 lesson): it would
  # kill this very session — that is a manual step from SSH/local terminal.
  # Every OTHER file still goes; only ttyd is skipped.
  grep -qs 'ttyd.service' /proc/self/cgroup && inside_ttyd=true
  local u f
  for u in $(system_files | awk -F/ '/\/etc\/systemd\/system\/.*\.(service|timer)$/ {print $NF}'); do
    if [ "$inside_ttyd" = true ] && [ "$u" = ttyd.service ]; then
      fail host_ttyd "this shell runs inside ttyd"
      continue
    fi
    systemctl disable --now "$u" >>"$LOG" 2>&1 || true
  done
  # every file the installer rendered from config/ — absent ones are skipped,
  # so a re-run converges instead of failing on a target that is already gone
  while IFS= read -r f; do
    [ -e "$f" ] || continue
    rm -f "$f" >>"$LOG" 2>&1 || fail "sysfile_$(basename "$f")" "still present: $f"
  done < <(system_files)
  rmdir /etc/systemd/system/dnsmasq.service.d /etc/goose 2>/dev/null || true
  # the binaries named by the rendered units' own ExecStart — no roster
  local bin
  while IFS= read -r bin; do
    [ -e "$bin" ] || continue
    rm -f "$bin" >>"$LOG" 2>&1 || fail "hostbin_$(basename "$bin")" "still present: $bin"
  done < <(host_binaries)
  # the banner line install-config appended (root's shell only)
  [ -f "$HOME/.bashrc" ] && \
    sed -i '\|^\. /etc/kefo-banner\.sh$|d' "$HOME/.bashrc" 2>/dev/null || true
  systemctl daemon-reload >>"$LOG" 2>&1 || true
  # sshd hardening is deliberately KEPT: removing the drop-in would
  # re-enable password auth — weakening is never the uninstall's job
  # the stack's ufw service ports — the tailnet SSH rule ALWAYS stays
  local p
  for p in 80/tcp 443/tcp 25/tcp 465/tcp 587/tcp 993/tcp \
           3478/udp 3478/tcp 5349/tcp 7881/tcp 7882/udp \
           49160:49200/udp 49160:49200/tcp; do
    ufw delete allow "$p" >>"$LOG" 2>&1 || true
  done
  log "  ufw: the stack service ports are closed; tailnet SSH (22) stays open"
}

remove_pkgs() {
  # Idempotent: purge only what is actually installed, so a re-run on a box
  # without the packages (or with a repo entry removed) does not fail apt.
  local p installed=()
  for p in docker.io docker-ce docker-ce-cli containerd.io \
           docker-buildx-plugin docker-compose-plugin \
           dnsmasq fail2ban apache2-utils sqlite3; do
    dpkg -s "$p" >/dev/null 2>&1 && installed+=("$p")
  done
  if [ ${#installed[@]} -eq 0 ]; then
    log "  none of the installer's packages are installed — nothing to purge"
    return 0
  fi
  log "  purging the installed packages (${installed[*]})"
  DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq "${installed[@]}" >>"$LOG" 2>&1 \
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
  # Idempotent: an already-off host has nothing to leave.
  if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
    tailscale logout >>"$LOG" 2>&1 || fail tailnet "logout failed"
  else
    log "  not on a tailnet — nothing to leave"
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
    edge)     echo "the edge (Caddy) is not fully removed" ;;
    host_goose)  echo "host service 'goose' not removed" ;;
    host_ttyd)   echo "host service 'ttyd' not removed (or was skipped — inside-ttyd guard)" ;;
    host_dnsmasq) echo "host service 'dnsmasq' not removed" ;;
    sysfile_*) echo "${1#sysfile_} is still in a system path" ;;
    hostbin_*) echo "the ${1#hostbin_} binary is still in /usr/local/bin" ;;
    banner_line) echo "the banner line is still in ~/.bashrc" ;;
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
    edge)     echo "run: docker rm -f <edge container>; docker network rm net; check $LOG, then re-check" ;;
    host_goose|host_dnsmasq) echo "run: systemctl disable --now ${1#host_}; rm -f /etc/systemd/system/${1#host_}.service; systemctl daemon-reload, then re-check" ;;
    host_ttyd) echo "run scripts/install/uninstall.sh from SSH or a local terminal (not the ttyd web shell), then re-check" ;;
    sysfile_*) echo "run: rm -f <the path>; systemctl daemon-reload; check $LOG, then re-check" ;;
    hostbin_*) echo "run: rm -f /usr/local/bin/${1#hostbin_}; check $LOG, then re-check" ;;
    banner_line) echo "run: sed -i '\\|^\\. /etc/kefo-banner\\.sh$|d' ~/.bashrc, then re-check" ;;
    pkgs)     echo "run: apt-get purge docker.io docker-ce docker-ce-cli containerd.io docker-compose-plugin dnsmasq fail2ban apache2-utils sqlite3, then re-check" ;;
    user)     echo "no action — root is the sole entry point and is never deleted" ;;
    tailnet)  echo "run: tailscale logout, then re-check" ;;
    *)        echo "" ;;
  esac
}

recheck() {
  case "$1" in
    rmmod_*)
      local m=${1#rmmod_} f c d
      f=$(compose_file_of "$m")
      [ -f "$f" ] || return 0
      for c in $(ctn_of_module "$f"); do
        ctn_list | grep -qx "$c" && return 1
      done
      # a data dir counts only when its removal was confirmed
      if [ "${RM_MOD_DATA:-false}" = true ]; then
        for d in $(module_data_dirs "$m"); do
          [ -e "$d" ] && return 1
        done
      fi
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
    sysfile_*)
      local b="${1#sysfile_}" p
      p=$(system_files | while IFS= read -r p; do
            [ "$(basename "$p")" = "$b" ] && { printf '%s' "$p"; break; }
          done)
      [ -z "$p" ] || [ ! -e "$p" ];;
    hostbin_*)
      local b="${1#hostbin_}" p
      p=$(host_binaries | while IFS= read -r p; do
            [ "$(basename "$p")" = "$b" ] && { printf '%s' "$p"; break; }
          done)
      [ -z "$p" ] || [ ! -e "$p" ];;
    banner_line) ! grep -qxF '. /etc/kefo-banner.sh' "${HOME:-/root}/.bashrc" 2>/dev/null;;
    pkgs)
      local q
      for q in docker.io docker-ce docker-ce-cli containerd.io \
               docker-buildx-plugin docker-compose-plugin \
               dnsmasq fail2ban apache2-utils sqlite3; do
        dpkg -s "$q" >/dev/null 2>&1 && return 1
      done
      return 0 ;;
    container_*)
      ctn_list | grep -qx "${1#container_}" && return 1
      return 0 ;;
    network)  ! docker network inspect net >/dev/null 2>&1;;
    data)     [ ! -e "$PROJECT_DIR" ];;
    data_*)   [ ! -e "$PROJECT_DIR/${1#data_}" ];;
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
    container_*|network|data_*) return 1 ;;
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
  local m
  echo ""
  echo "=============================================================="
  echo " SUCCESS — full teardown complete:"
  for m in $STACK_MODULES; do
    mod_rm "$m" && echo "   removed    $m"
  done
  echo "   removed    edge (Caddy)"
  echo "   removed    data/ (whole)"
  echo "   removed    the host files + the stack's ufw ports"
  echo "   removed    the packages (docker, dnsmasq, fail2ban, …)"
  echo "   removed    the tailnet membership"
  echo ""
  echo " Kept:"
  echo "   - the repo clone: $REPO"
  echo "   - the root account"
  echo "   - sshd hardening (removing it would re-enable password auth)"
  echo ""
  echo " Follow-ups (manual, none block):"
  echo "   1. Cloudflare: the DNS records for this host remain — delete them in"
  echo "      the dashboard if this machine is being decommissioned"
  echo "   2. Re-install any time with: bash $REPO/scripts/install/wizard.sh"
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

# ───────────────────── full: the whole framework ──────────────────────────
# No module pick: every module goes. Then the edge, every kefoCloud file the
# installer wrote into the system paths (with the stack's ufw ports), the
# installed packages and — ALWAYS LAST, so this session survives — the tailnet.
# data/ goes whole. The repo clone, root and the sshd hardening stay.
# Verifies the box is clean and returns the verdict as its exit code
# (0 = gone, 1 = something is left).
full_teardown() {
  local k
  log "=== uninstall.sh — full teardown (whole framework)"
  # The module scope is preselected explicitly, otherwise the mod_rm guards
  # below skip every module, leaving the containers attached to 'net' so the
  # network rm fails and the verification reports a live stack
  # (2026-10-19 uninstall.log bug).
  for k in $STACK_MODULES; do
    eval "RM_MOD_${k^^}=true"
  done
  RM_MOD_DATA=true
  echo ""
  echo "Uninstalling the whole framework:"
  for k in $STACK_MODULES; do
    mod_rm "$k" && { echo "   remove     $k"; }
  done
  echo "   remove     edge (Caddy)"
  echo "   remove     data/ whole (module data, rendered config, logs, wizard.state)"
  echo "   remove     the host files + the stack's ufw ports"
  echo "   remove     the installed packages"
  echo "   remove     tailnet membership (last — SSH stays alive)"
  echo "   keep       the repo clone, the root account, sshd hardening"
  echo ""

  # Containers first (their bind mounts are about to disappear), then the edge,
  # then every data dir the stack owns — including dirs no module claims.
  for k in $STACK_MODULES; do
    mod_rm "$k" && remove_module "$k"
  done
  remove_edge
  remove_host
  remove_pkgs
  remove_user          # a documented no-op: root is the sole entry point
  remove_tailnet       # ALWAYS last, so the session survives
  wipe_data

  # Verify FIRST, then resolve: a verification that runs after the success
  # block would print SUCCESS for a stack that is still there.
  verify_stack_gone
  verify_host_gone
  resolve_errors || return 1
  return 0
}

# ───────────────────────────--granular: pick modules ──────────────────────
# The operator sees the roster (ask_modules), answers yes/no per module and
# then the consequence confirmations; only the picked modules lose their
# containers, compose stacks and (on the data confirm) their own data dirs.
# Everything else — the edge, data/ of the modules that stay, the host files,
# the packages and the tailnet — is untouched.
#
# Hand-off path (--modules=a,b --data): the installer's repair run names the
# modules it turned off, so nothing here prompts or reads wizard.state. Each
# named door's Cloudflare A record is dropped with the credentials the
# installer exported; absent creds or jq skip the DNS step, never fail it.
granular_teardown() {
  local k removed=()
  if [ -n "$MODULE_PICK" ]; then
    local IFS=, n0=${#ERR_TAGS[@]}
    for k in $MODULE_PICK; do
      case " $STACK_MODULES " in
        *" $k "*) eval "RM_MOD_${k^^}=true"; removed+=("$k") ;;
        *) fail "rmmod_$k" "not a module in $MODULES_CONF" ;;
      esac
    done
    unset IFS
    [ "$PICK_DATA" = true ] && RM_MOD_DATA=true
    if [ ${#removed[@]} -eq 0 ]; then
      log "  no known module named — nothing to remove"
      ERR_TAGS=()   # the hand-off has no resolve loop; keep the exit summary quiet
      return 1
    fi
    echo "   teardown   ${removed[*]} (named by the repair hand-off)"
  else
    ask_modules
    for k in $STACK_MODULES; do
      mod_rm "$k" && removed+=("$k")
    done
    if [ ${#removed[@]} -eq 0 ]; then
      echo "   nothing selected — every prompt answered keep. Nothing was removed."
      return 0
    fi
    ask_pick_summary "${removed[@]}"
    confirm_consequences modules || { echo "   aborted — nothing was touched."; return 1; }
  fi

  for k in "${removed[@]}"; do
    remove_module "$k"
    # a wiped data dir invalidates the installer's repair-skip hash, so a later
    # reinstall re-applies the module's services from scratch
    if [ "${RM_MOD_DATA:-false}" = true ]; then
      rm -f "$PROJECT_DIR/.svc-$(svc_group_of "$k").sha"
    fi
  done

  if [ -n "$MODULE_PICK" ]; then
    # repair hand-off only: a disabled door must not keep a public record
    for k in "${removed[@]}"; do
      cf_a_del "$(module_host_of "$k")"
      # doors that live on a second hostname of the same module
      case "$k" in
        chat) cf_a_del matrix; cf_a_del auth.matrix ;;
        mail) cf_a_del admin.mail ;;
      esac
    done
    # no verification loop here: the repair run converges the rest. Failures
    # still set the exit code so the caller logs them, but the EXIT summary is
    # cleared — an operator error block is for an operator run, not a hand-off.
    local rc=0
    [ ${#ERR_TAGS[@]} -gt "$n0" ] && rc=1
    [ "$rc" -eq 1 ] && { log "  some removals failed — see $LOG"; ERR_TAGS=(); }
    return $rc
  fi

  verify_modules_gone "${removed[@]}"
  resolve_errors || return 1
  return 0
}

cf_a_del() { # cf_a_del <host-label> — drop that door's A record (repair only)
  [ -n "${1:-}" ] && [ "$1" != "-" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  [ -n "${CF_API_TOKEN:-}" ] && [ -n "${DOMAIN:-}" ] || return 0
  local zid fqdn rid
  zid=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" 2>>"$LOG" \
    | jq -r '.result[0].id // empty')
  [ -n "$zid" ] || return 0
  fqdn="$1.$DOMAIN"
  rid=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/$zid/dns_records?type=A&name=$fqdn" 2>>"$LOG" \
    | jq -r '.result[0].id // empty')
  [ -n "$rid" ] || return 0
  curl -s -X DELETE -H "Authorization: Bearer $CF_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/$zid/dns_records/$rid" >>"$LOG" 2>&1 || true
  log "  A record removed: $fqdn"
}

# ─────────────────────────────── main ──────────────────────────────────────

main() {
  [ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash scripts/install/uninstall.sh"; exit 1; }
  banner
  # The mode menu is the FIRST question — before the log exists, before any
  # module prompt and before a single removal. --modules= is the installer's
  # repair hand-off and answers it on the caller's behalf.
  [ -z "$MODULE_PICK" ] && { ask_mode || exit 1; }
  # A granular teardown on a host with no data/ must not CREATE data/ just to
  # hold the log: fall back to /var/tmp (full mode wipes data/ anyway).
  if [ ! -d "$PROJECT_DIR" ] && [ "${UNINSTALL_MODE:-full}" != full ]; then
    LOG_DIR=/var/tmp
    LOG="$LOG_DIR/uninstall-$(date +%Y%m%d-%H%M%S).log"
  fi
  install -d -m 0755 "$LOG_DIR"
  # clear the log at the start of EVERY run — each teardown logs from scratch
  : > "$LOG" && chmod 640 "$LOG"
  case "${UNINSTALL_MODE:-full}" in
    granular)
      granular_teardown
      exit $?
      ;;
    *)
      # full mode: no module pick — everything, gated by the three
      # confirmations
      confirm_consequences full || { echo "   aborted — nothing was touched."; exit 1; }
      full_teardown
      exit $?
      ;;
  esac
}

main "$@"
