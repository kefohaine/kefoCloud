# wizard.d/lib/state.sh — wizard.state: load/save/migrate (the installer is its SOLE writer) + module flags.

load_state() {
  [ -f "$INSTALL_STATE" ] && . "$INSTALL_STATE"
  local uniq=() t
  for t in "${ERR_TAGS[@]:-}"; do
    [[ " ${uniq[*]:-} " == *" $t "* ]] || uniq+=("$t")
  done
  ERR_TAGS=("${uniq[@]}")
}

# Is a module enabled for THIS run? One definition, one fallback. The fallback
# is "enabled" because a resume or a fresh run always sets MOD_* from the
# prompts — an UNSET value can only mean "this run never asked", which is a
# run that should be doing the full job, not silently skipping steps. Every
# caller goes through here, so a step can never disagree with the module record
# written to wizard.state (2026-10-15: three different call sites disagreed on
# the fallback, and one of them made a healthy Nextcloud report a failure).
mod_on() {
  # Build the name first, then indirect it: `${MOD_${1^^}:-true}` is NOT valid
  # bash (nested expansion inside a variable name) — it errors and every test
  # silently becomes false, which is exactly the bug that once recorded an empty
  # module set and muted smoke (2026-10-04).
  local name="MOD_${1^^}"
  [ "${!name:-true}" = "true" ]
}

# The enabled set as recorded in state: the modules the operator chose. Built
# from the MOD_* answers; an unset MOD_* is NEVER assumed true here (unlike the
# install path, which defaults to true) — the record only names answered ones.
enabled_modules_list() {
  local k v out=""
  for k in cloud vault mail monitor; do
    v="MOD_${k^^}"
    [ "${!v:-}" = "true" ] && out+="$k "
  done
  printf '%s' "${out% }"
}

# the installer is the SOLE writer of $INSTALL_STATE — including `finished`.
# Everything else (make smoke, make fetch, modules.sh) only reads it.
# A module record exists only for a FINISHED install: while finished is not yet
# true the enabled_modules field is written empty, so a half-answered run can
# never look installed.
save_state() {
  umask 077
  install -d -m 0700 "$(dirname "$INSTALL_STATE")"
  local tmp="$INSTALL_STATE.tmp.$$" em=""
  [ "${FINISHED:-false}" = "true" ] && em="$(enabled_modules_list)"
  # Every value is written with `printf %q`, never inside literal quotes: the
  # file is later `source`d by load_state, so a value containing a quote or a
  # `$(…)` must be escaped, not interpolated raw (a free-form commit name could
  # otherwise inject on the next run).
  {
    printf 'DOMAIN=%q\n'             "${DOMAIN:-}"
    # The operator's locale country (resolved to a timezone at each run, so the
    # run's timestamps are in their local time; a resume reuses it).
    printf 'LOCALE_COUNTRY=%q\n'     "${LOCALE_COUNTRY:-}"
    printf 'CF_API_TOKEN=%q\n'       "${CF_API_TOKEN:-}"
    printf 'TS_AUTHKEY=%q\n'         "${TS_AUTHKEY:-}"
    printf 'TS_IP=%q\n'              "${TS_IP:-}"
    # The device's PUBLIC ssh key(s) (safe to store): reuses on resume, re-asked
    # on a fresh run. SSH_PUBKEYS is the allowlist (newline-separated); the
    # legacy single SSH_PUBKEY is kept pointing at the first key for back-compat.
    printf 'SSH_PUBKEY=%q\n'         "${SSH_PUBKEY:-}"
    printf 'SSH_PUBKEYS=%q\n'        "${SSH_PUBKEYS:-}"
    # The raw module ANSWERS, so a resume reuses the choice (empty once a module
    # has not been asked yet — ask_modules re-asks only the empty ones).
    printf 'MOD_CLOUD=%q\n'          "${MOD_CLOUD:-}"
    printf 'MOD_VAULT=%q\n'          "${MOD_VAULT:-}"
    printf 'MOD_MAIL=%q\n'           "${MOD_MAIL:-}"
    printf 'MOD_MONITOR=%q\n'        "${MOD_MONITOR:-}"
    # The cloud module's optional services, answered before the apps plan.
    printf 'VIDEO_CALLING=%q\n'       "${VIDEO_CALLING:-}"
    printf 'CLIENT_PUSH=%q\n'         "${CLIENT_PUSH:-}"
    # The RECORD (for other scripts) — only real once the install is finished.
    printf 'enabled_modules=%q\n'    "$em"
    printf 'finished=%q\n'           "${FINISHED:-false}"
    printf 'GH_REMOTE=%q\n'          "${GH_REMOTE:-false}"
    printf 'GH_AUTH_OK=%q\n'         "${GH_AUTH_OK:-0}"
    printf 'GITHUB_COMMIT_NAME=%q\n' "${GITHUB_COMMIT_NAME:-}"
    printf 'GITHUB_COMMIT_EMAIL=%q\n' "${GITHUB_COMMIT_EMAIL:-}"
    # The app-actions fingerprint that was APPLIED (see ask_nc_apps): a resume
    # whose config/cloud/apps.conf still hashes the same never re-asks, because
    # the actions are already in the instance. Empty until they are applied.
    printf 'NC_APPS_APPLIED=%q\n'    "${NC_APPS_APPLIED:-}"
    printf 'ERR_TAGS=(%s)\n'         "$(printf '%q ' "${ERR_TAGS[@]}")"
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$INSTALL_STATE" 2>/dev/null || sudo mv -f "$tmp" "$INSTALL_STATE" || rm -f "$tmp"
  chown root:root "$INSTALL_STATE" 2>/dev/null || true
}

# One-time import of a legacy installer state (/var/lib/<GITHUB_USER>/setup.state,
# or the pre-$GITHUB_USER /var/lib/<host>. setup.state). Only moves the file: the
# legacy MOD_* keys are not read back, so module answers are re-asked once.
migrate_state() {
  [ -f "$INSTALL_STATE" ] && return 0
  local old cands=()
  [ -n "${GITHUB_USER:-}" ] && cands+=("/var/lib/$GITHUB_USER/setup.state")
  [ -n "${NODE_NAME:-}" ]   && cands+=("/var/lib/$NODE_NAME/setup.state")
  for old in "${cands[@]}"; do
    [ -f "$old" ] || continue
    install -d -m 0700 "$(dirname "$INSTALL_STATE")"
    mv -f "$old" "$INSTALL_STATE" 2>/dev/null || continue
    chmod 600 "$INSTALL_STATE"
    detail "  migrated legacy installer state: $old -> $INSTALL_STATE"
    return 0
  done
}

# $LOG lives outside the repo and must exist before ANYTHING redirects into it
# (a `>>"$LOG"` whose directory is missing fails the redirection, the command
# behind it is never run, and `|| fail ...` then reports the step as broken) —
# and before the first `log()`, or tee swallows that line. $DATA (wizard.state)
# is tightened to 0700 because it holds the CF token + Tailscale key. Idempotent;
# main() calls it first thing.
ensure_runtime_dirs() {
  install -d -m 0755 "$LOG_DIR"
  install -d -m 0700 "$DATA"
}


# write_state records the install in $INSTALL_STATE (the enabled modules + the
# `finished` checkpoint) — the ONE artefact every reader uses. It ALSO writes a
# cross-checked detection report (independent probes) purely as evidence: a
# declared/confirmed mismatch is logged as a warning, never used as truth.
#   wizard.state                    enabled modules + finished + prompted values
#   installed-modules.detected.conf  modules confirmed by independent probes
#   installed-modules.report.txt     per-module, per-method evidence matrix
# Probes, deliberately independent of the record: (1) the container is running,
# (2) its compose file exists in the repo, (3) its data dir/db exists on disk,
# (4) its Caddy vhost exists. A module is "confirmed" when at least one fires.
write_state() {
  local det="$DATA/installed-modules.detected.conf"
  local rep="$DATA/installed-modules.report.txt"
  local m ct cf dd vh ev em

  save_state
  em="$(enabled_modules_list)"

  : > "$det"
  { echo "module detection report — $(date -Is)"
    echo "declared = install-time choice (MOD_*); probes are independent of it."
    echo; } > "$rep"

  for m in cloud vault mail monitor; do
    ct=0; dd=0; vh=0
    case "$m" in
      cloud)   ct=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -cx nextcloud)
               [ -e "$DATA/cloud/users" ] && dd=1
               [ -f "$RENDER_DIR/caddy/vhosts/cloud.caddy" ] && vh=1 ;;
      vault)   ct=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -cx vaultwarden)
               [ -e "$DATA/vault/data" ] && dd=1
               [ -f "$RENDER_DIR/caddy/vhosts/vault.caddy" ] && vh=1 ;;
      mail)    ct=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -cxE 'mailu-front|roundcube')
               [ -e "$DATA/mailserver/data" ] && dd=1
               [ -f "$RENDER_DIR/caddy/vhosts/mail.caddy" ] && vh=1 ;;
      monitor) ct=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -cx uptimekuma)
               [ -e "$DATA/kuma/data" ] && dd=1
               [ -f "$RENDER_DIR/caddy/vhosts/kuma.caddy" ] && vh=1 ;;
    esac
    # CONFIRMED = the module's container is running. The compose file is a REPO
    # fact (always present, so it proves nothing), and a leftover data dir or
    # rendered vhost is exactly what an uninstall leaves behind — it
    # used to count as "present", so every module was always PRESENT and the
    # declared/detected warning fired on every run. Those two are still shown
    # as leftovers (data/vhost columns) but never confirm a module.
    ev=$ct
    [ "$ev" -gt 0 ] && echo "$m" >> "$det"
    printf '%-8s declared=%s running=%s data=%s vhost=%s -> %s\n' \
      "$m" "$(mod_on "$m" && echo 1 || echo 0)" \
      "$ct" "$dd" "$vh" "$([ "$ev" -gt 0 ] && echo PRESENT || echo absent)" >> "$rep"
  done

  detail "  wrote $INSTALL_STATE (enabled: ${em:-none}; finished=$FINISHED)"
  detail "  detected: $(paste -sd' ' "$det" || echo none) — evidence: $rep"
  if ! diff -q <(printf '%s\n' $em | sort) <(sort "$det") >/dev/null 2>&1; then
    log "  WARNING: declared modules != detected modules — see $rep"
  fi
}
