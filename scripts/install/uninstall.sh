#!/bin/bash
# This script performs the reverse of the installer, in the same style.
#
# TWO OPERATOR SCOPES (--interactive picks one):
#   1) specific modules only — the operator names the modules; only their
#      containers, compose stacks and (on one explicit yes) their own data
#      dirs go. data/ of every other module, the edge, the host files, the
#      packages and the tailnet are untouched. wizard.state drops those
#      modules from enabled_modules and sets finished=false (the documented
#      teardown exception to the installer's sole-writer rule); the prompted
#      secrets are kept.
#   2) the whole framework — every module, data/ WHOLE, every kefoCloud file
#      in the other system paths the installer wrote (systemd units/timers,
#      dnsmasq, sysctl, fail2ban jails+filters, logrotate, banner, docker
#      daemon config, goose env, the /usr/local/bin binaries), the stack's ufw
#      rules, the installed packages and the tailnet membership (always LAST,
#      so the session survives).
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
#   - data/ (whole-framework scope) — removed WHOLE, no folder picks
#   - a removed module's own data dirs — one explicit confirm
#   - the repo clone — prompt, explicit yes required
#   - sshd hardening — deliberately KEPT (removing the drop-in would
#     re-enable password auth; weakening is never the uninstall's job)
#
# Errors are collected with tags, each shown as a "problem" plus a "hint",
# and re-checked on Enter until all are green — then SUCCESS.
#
# MODES (UNINSTALL_MODE, picked by argument — granular is NOT an operator mode):
#   full (default, no argument)
#     the production stack and data/ whole, verified gone. Host files,
#     packages and the tailnet are kept (the box stays reachable and
#     re-installable). The three consequence confirmations always apply.
#   interactive (--interactive)
#     scope menu (specific modules / the whole framework / cancel), then the
#     consequence confirmations worded for that scope.
#   granular (--granular)
#     RESERVED for wizard.sh repair mode (requires WIZARD_REPAIR=1). wizard.state
#     is the source of truth: ONLY disabled modules are torn down (containers,
#     compose stacks, data dirs, stale .svc hashes) and only disabled doors'
#     Cloudflare A records are deleted. wizard.state, .cred-*.sha and enabled
#     modules are untouched — the repair run converges the rest itself.
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
  --interactive picks the scope — specific modules only (their containers,
  compose stacks and, on one explicit yes, their own data dirs) or the whole
  framework (every module, data/ whole, every kefoCloud file in the system
  paths, the stack's ufw rules, the packages, the tailnet last). Destructive
  by design: no prompt has a default — only the words yes/no are accepted —
  and data is never touched without an explicit confirm. Idempotent: a re-run
  converges. Errors are listed with a hint each, re-checked on Enter, and
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
# worded for the scope the operator picked. Nothing skips them: a teardown is
# only ever a manual operator run.
confirm_consequences() { # $1 = full|all|modules
  local scope="${1:-full}" a
  echo ""
  echo " ── CONFIRMATION 1/3 — what dies ─────────────────────────────────────────"
  case "$scope" in
    modules)
      echo "    ONLY the modules you named: their containers, compose stacks and"
      echo "    (if you answered yes) their own data dirs. Everything else stays." ;;
    all)
      echo "    Every module, data/ WHOLE, every kefoCloud file in the other system"
      echo "    paths, the stack's ufw rules, the packages and the tailnet." ;;
    *)
      echo "    Every module container and config are removed; data/ is wiped"
      echo "    WHOLE (no folder picks). The repo, host files and packages stay." ;;
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

# ─────────────── modes: full / granular / interactive ─────────────────────
# SCOPE is the operator's choice INSIDE --interactive (modules|all|cancel); it
# is empty until the menu (or --scope=) sets it, so `--interactive` always
# shows the menu instead of silently falling through to one of the scopes.
UNINSTALL_MODE=full
SCOPE="${SCOPE:-}"
for _a in "$@"; do
  case "$_a" in
    --granular)         UNINSTALL_MODE=granular ;;
    --interactive)      UNINSTALL_MODE=interactive ;;
    --mode=*)           UNINSTALL_MODE="${_a#--mode=}" ;;
    --scope=*)          SCOPE="${_a#--scope=}" ;;
  esac
done
unset _a

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
  [ -f "$INSTALL_STATE" ] && t+="state "
  # module compose files are repo-TRACKED and deliberately kept — they are the
  # framework, not stack state.

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
  echo " Stack verified gone: containers, network, data/ and wizard.state are all clear."
  log "  teardown verification passed — nothing of the stack is left"
  return 0
}

# After --interactive's module scope: every chosen module must have no
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

# The host files the installer rendered out of config/ — DERIVED from the
# tracked tree one file at a time, never a hand-kept roster: a unit, jail,
# filter or logrotate rule added to config/ is removed by the same edit that
# installs it. sshd's 50-cloud-init.conf is deliberately NOT here (kept).
system_files() {
  local f
  while IFS= read -r f; do
    printf '/etc/systemd/system/%s\n' "$(basename "$f")"
  done < <(find "$REPO/config" -type f \( -name '*.service' -o -name '*.timer' \) | sort)
  printf '%s\n' '/etc/systemd/system/dnsmasq.service.d/override.conf'
  while IFS= read -r f; do
    printf '/etc/fail2ban/%s\n' "${f#"$REPO/config/fail2ban/"}"
  done < <(find "$REPO/config/fail2ban" -type f -name '*.conf' | sort)
  printf '%s\n' /etc/dnsmasq.d/10-tailnet.conf /etc/sysctl.d/99-kefo.conf \
    /etc/logrotate.d/instance /etc/kefo-banner.sh /etc/docker/daemon.json \
    /etc/goose/goose.env
}

# After the whole-framework scope: no project file may be left in a system path.
verify_host_gone() {
  local f bad=0
  while IFS= read -r f; do
    [ -e "$f" ] || continue
    ERR_TAGS+=("sysfile_$(basename "$f")"); bad=1
  done < <(system_files)
  [ "$bad" -eq 0 ] && echo " Host files verified gone: no project file left in a system path."
  return $bad
}

ask_modules() {
  # Reverse of the installer's ask_modules: nothing removed unless explicitly
  # confirmed —
  # removing a module destroys its containers and (on data-confirm) its
  # data; the operator opts in per module.
  local k answer
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
  done
}

ask_scope() {
  # the scope selector: specific modules, the whole framework, or cancel.
  # SCOPE=modules|all|cancel (env or --scope=) skips the prompt; an invalid
  # value is cleared and re-prompted. Each option prints its one-line
  # description.
  case "${SCOPE:-}" in
    modules|all|cancel) return 0 ;;
    "") ;;
    *) echo "   unknown scope '${SCOPE}' — pick 1, 2 or 3."; SCOPE="" ;;
  esac
  local m
  echo ""
  echo " Teardown scope:"
  echo "   [1] specific modules only — remove the modules you pick (containers,"
  echo "       compose stacks, and their data dirs on one explicit yes); data/ of"
  echo "       the others, the edge, host files, packages and tailnet stay"
  echo "   [2] the whole framework — every module, data/ whole, every kefoCloud"
  echo "       file in the other system paths, the stack's ufw rules, packages,"
  echo "       tailnet membership (last)"
  echo "   [3] cancel — remove nothing"
  while :; do
    read -rp " enter 1, 2 or 3: " m || return 1
    case "${m:-}" in
      1|modules) SCOPE=modules; return 0 ;;
      2|all)     SCOPE=all;     return 0 ;;
      3|cancel)  SCOPE=cancel;  return 0 ;;
      *) echo "   enter 1, 2 or 3." ;;
    esac
  done
}

ask_inputs() {
  ask_scope
  local k
  case "$SCOPE" in
    cancel)
      echo "Cancelled — nothing was removed."
      exit 0
      ;;
    all)
      # the whole framework: every phase preselected; data/ is part of the
      # scope, the three confirmations below still gate everything
      for k in $STACK_MODULES; do
        eval "RM_MOD_${k^^}=true"
      done
      RM_EDGE=true; RM_HOST=true; RM_PKGS=true; RM_TAILNET=true; RM_MOD_DATA=true
      echo ""
      echo "Whole-framework teardown preselected: every module, data/ whole, the"
      echo "edge, the host files, the packages and the tailnet membership."
      ask RM_REPO "Delete the repo clone at $REPO (scheduled after this script exits)?"
      ;;
    modules)
      # only the named modules; the rest of the framework is never touched
      ask_modules
      # the removed modules' own data dirs need ONE explicit confirm — no
      # default, and data/ of the modules that stay is never touched
      local any=false
      for k in $STACK_MODULES; do mod_rm "$k" && any=true; done
      [ "$any" = true ] && ask RM_MOD_DATA "Delete the data dirs of the removed modules?"
      ;;
  esac
  local ml=""
  for k in $STACK_MODULES; do
    mod_rm "$k" && ml+="$k "
  done
  echo ""
  echo "Rebuild the stack later with: bash $REPO/scripts/install/wizard.sh"
  case "$SCOPE" in
    modules) echo "Teardown summary — modules removed: ${ml:-none} · their data: ${RM_MOD_DATA:-false} · repo: kept" ;;
    *)       echo "Teardown summary — modules: ${ml:-none} · data/ whole · edge: ${RM_EDGE:-false} · host files: ${RM_HOST:-false} · pkgs: ${RM_PKGS:-false} · tailnet: ${RM_TAILNET:-false} · repo: ${RM_REPO:-false}" ;;
  esac
  echo "Full log: $LOG"
}

mod_rm() { # indirection: is module $1 selected for removal?
  local v="RM_MOD_${1^^}"
  [ "${!v:-false}" = true ]
}

# ────────────── wizard.state teardown update (the one exception) ──────────
# The installer is the state's sole writer; a module teardown is the ONE
# documented exception. Only `enabled_modules` and `finished` are rewritten
# (finished=false so `make smoke` never trusts a torn-down host); every other
# line — the prompted secrets — is copied through byte for byte.
state_drop_modules() { # $1... = removed module names
  [ -f "$INSTALL_STATE" ] || { log "  no wizard.state — nothing to update"; return 0; }
  local drop=" $* " m line raw kept="" tmp
  raw="$(sed -n 's/^enabled_modules=//p' "$INSTALL_STATE" | head -1)"
  [ -n "$raw" ] && eval "raw=$raw"
  for m in $raw; do
    case "$drop" in *" $m "*) ;; *) kept+="$m " ;; esac
  done
  kept="${kept% }"
  tmp="$INSTALL_STATE.tmp.$$"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      enabled_modules=*) printf 'enabled_modules=%q\n' "$kept" ;;
      finished=*)        printf 'finished=%q\n' false ;;
      *)                 printf '%s\n' "$line" ;;
    esac
  done < "$INSTALL_STATE" > "$tmp" && chmod 600 "$tmp" && chown root:root "$tmp" 2>/dev/null
  if mv -f "$tmp" "$INSTALL_STATE" 2>/dev/null; then
    log "  wizard.state: enabled_modules='${kept}' finished=false"
  else
    rm -f "$tmp"; fail state "wizard.state not updated"
  fi
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
    [ -n "$bin" ] && rm -f "$bin" >>"$LOG" 2>&1
  done < <(grep -h '^ExecStart=' "$REPO"/config/goose/goose.service \
             "$REPO"/config/ttyd/ttyd.service 2>/dev/null \
           | sed 's/^ExecStart=//' | awk '{print $1}' | grep '^/usr/local/bin/')
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
    state)    echo "wizard.state is still there" ;;
    edge)     echo "the edge (Caddy) is not fully removed" ;;
    host_goose)  echo "host service 'goose' not removed" ;;
    host_ttyd)   echo "host service 'ttyd' not removed (or was skipped — inside-ttyd guard)" ;;
    host_dnsmasq) echo "host service 'dnsmasq' not removed" ;;
    sysfile_*) echo "${1#sysfile_} is still in a system path" ;;
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
    sysfile_*) echo "run: rm -f <the path>; systemctl daemon-reload; check $LOG, then re-check" ;;
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
  local m
  echo ""
  echo "=============================================================="
  echo " SUCCESS — teardown complete:"
  for m in $STACK_MODULES; do
    mod_rm "$m" && echo "   removed    $m"
  done
  [ "${RM_EDGE:-false}"    = true ] && echo "   removed    edge (Caddy)"
  if [ "${SCOPE:-}" = modules ]; then
    [ "${RM_MOD_DATA:-false}" = true ] && echo "   removed    the removed modules' data dirs"
  else
    echo "   removed    data/ (whole)"
  fi
  [ "${RM_HOST:-false}"    = true ] && echo "   removed    host files (units, dnsmasq, sysctl, fail2ban, logrotate, banner, binaries) + stack ufw ports"
  [ "${RM_PKGS:-false}"    = true ] && echo "   removed    packages (docker, dnsmasq, fail2ban, …)"
  [ "${RM_TAILNET:-false}" = true ] && echo "   removed    tailnet membership"
  [ "${RM_REPO:-false}"    = true ] && echo "   removed    the repo clone (scheduled after this exit)"
  echo ""
  echo " Kept:"
  echo "   - sshd hardening (removing it would re-enable password auth)"
  [ "${RM_REPO:-false}" = true ] || echo "   - $REPO"
  echo ""
  echo " Follow-ups (manual, none block):"
  echo "   1. Cloudflare: the DNS records for this host remain — delete them in"
  echo "      the dashboard if this machine is being decommissioned"
  [ "${RM_TAILNET:-false}" = true ] && echo "   2. Re-join the tailnet after a re-install: tailscale up"
  echo "   3. Re-install any time with: bash $REPO/scripts/install/wizard.sh"
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
  remove_edge

  # data/ goes whole — one wipe, no folder picks; wizard.state lives inside it
  # and dies with it (the installer is its sole writer and recreates everything
  # fresh on the rebuild).
  wipe_data

  # Verify FIRST, then resolve: a verification that runs after the success
  # block would print SUCCESS for a stack that is still there.
  verify_stack_gone
  resolve_errors || return 1
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

  local k h
  for k in $STACK_MODULES; do
    mod_on "$k" && continue
    echo "   teardown   $k (disabled in wizard.state)"
    RM_MOD_DATA=true remove_module "$k"
    # drop the stale service hash so a later re-enable re-applies from scratch
    rm -f "$PROJECT_DIR/.svc-$(svc_group_of "$k").sha"
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
  for k in $STACK_MODULES; do
    mod_on "$k" && continue
    h="$(module_host_of "$k")"
    [ -n "$h" ] && [ "$h" != "-" ] && cf_a_del "$h"
    # doors that live on a second hostname of the same module
    case "$k" in
      chat) cf_a_del matrix; cf_a_del auth.matrix ;;
      mail) cf_a_del admin.mail ;;
    esac
  done
  return 0
}

# ─────────────────────────────── main ──────────────────────────────────────

main() {
  [ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash scripts/install/uninstall.sh"; exit 1; }
  # A modules-only teardown on a host with no data/ must not CREATE data/ just
  # to hold the log: fall back to /var/tmp (full mode wipes data/ anyway).
  if [ ! -d "$PROJECT_DIR" ] && [ "${UNINSTALL_MODE:-full}" != full ]; then
    LOG_DIR=/var/tmp
    LOG="$LOG_DIR/uninstall-$(date +%Y%m%d-%H%M%S).log"
  fi
  install -d -m 0755 "$LOG_DIR"
  # clear the log at the start of EVERY run — each teardown logs from scratch
  : > "$LOG" && chmod 640 "$LOG"
  banner
  case "${UNINSTALL_MODE:-full}" in
    granular)
      # wizard repair hand-off — wizard.state-driven, no operator prompts
      granular_stack_only
      exit $?
      ;;
    interactive)
      interactive_teardown
      exit $?
      ;;
    *)
      # full mode: the three confirmations always apply
      confirm_consequences full || { echo "   aborted — nothing was touched."; exit 1; }
      full_teardown
      exit $?
      ;;
  esac
}

interactive_teardown() {
  ask_inputs
  local k m removed=() went=false
  # all inputs are collected (ask_inputs) before ANY removal; the confirmation
  # is worded for the scope that was picked.
  confirm_consequences "$SCOPE" || { echo "   aborted — nothing was touched."; exit 1; }

  for k in $STACK_MODULES; do
    mod_rm "$k" && removed+=("$k")
  done
  if [ ${#removed[@]} -eq 0 ]; then
    log "nothing selected — every prompt answered keep. Nothing was removed."
    exit 0
  fi

  case "$SCOPE" in
    modules)
      # ONLY the named modules: no edge, no host files, no packages, no
      # tailnet, and data/ of the modules that stay is never touched.
      for m in "${removed[@]}"; do
        remove_module "$m"
        # a wiped data dir invalidates the installer's repair-skip hash, so a
        # later reinstall re-applies the module's services from scratch
        if [ "${RM_MOD_DATA:-false}" = true ]; then
          rm -f "$PROJECT_DIR/.svc-$(svc_group_of "$m").sha"
        fi
      done
      state_drop_modules "${removed[@]}"
      verify_modules_gone "${removed[@]}"
      resolve_errors || return 1
      ;;
    all)
      for m in "${removed[@]}"; do
        remove_module "$m"
        went=true
      done
      [ "$went" = true ] && remove_edge
      remove_host
      remove_pkgs
      remove_user          # a documented no-op: root is the sole entry point
      remove_tailnet       # ALWAYS last, so the session survives
      [ "$went" = true ] && wipe_data
      verify_stack_gone
      verify_host_gone
      resolve_errors || return 1
      ;;
  esac

  # the repo clone LAST and only after this script exits — bash reads the
  # script from disk; deleting it mid-run can truncate execution
  if [ "${SCOPE:-}" = all ] && [ "${RM_REPO:-false}" = true ]; then
    ( sleep 3; rm -rf "$REPO" ) >/dev/null 2>&1 &
    log "  repo deletion scheduled in 3s (after this script exits): $REPO"
  fi
}

main "$@"

