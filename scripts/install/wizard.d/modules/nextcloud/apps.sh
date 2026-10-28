# wizard.d/modules/nextcloud/apps.sh — the cloud app plan: config/cloud/apps.conf → prompt → occ apply → recovery manifest.

# nextcloud_setup()'s app-selection entry: a config-driven app set for the
# cloud module, driven by config/cloud/apps.conf (optional, operator-owned, empty
# by default: only the operator's own extra apps, read on a fresh install).
# contacts (install&enable) and app_api (install&disable) are ENFORCED, plus
# spreed/mail_roundcube/notify_push when their cloud option is on — never shown in
# the plan, applied silently and logged only. The
# config is the *intent*; this
# reads the live instance once (occ app:list) and applies actions against real
# state — an action already satisfied is skipped silently (idempotent,
# unattended re-runs). The only prompted cases are the ones where the config and
# the live state genuinely disagree in a surprising way: an unknown verb
# (ignored), the same app given two different verbs (proceed / abort), a
# `disable=` on an app that is NOT installed (install&disable / drop), and a
# `remove=` on an installed+enabled app (proceed / drop / resolve) — removal is
# the only destructive action. Runs only when cloud is selected; the resulting
# enabled set is written to $DATA/cloud/recovery/apps.txt (GENERATED, outside
# the repo).
ask_nc_apps() {
  local conf="$REPO/config/cloud/apps.conf"

  # Cloud must be desired; the configured actions then apply.
  mod_on cloud || return 0

  # apps.conf holds ONLY the operator's own extra apps, and is read on a FRESH
  # install only: on a re-run (resume/repair) the selection is already in the
  # instance, so re-asking it is useless. It may be empty (the normal case) or
  # absent (a fresh clone, where it is untracked) — neither is an error.
  local _fresh=true _sum=""
  if [ -n "${NC_APPS_APPLIED:-}" ]; then
    _fresh=false
    detail "  apps.conf not read this run (already applied) — only the enforced apps are checked"
  fi
  if [ "${_fresh}" = true ]; then
    _sum=$(sha256sum "$conf" 2>/dev/null | awk '{print $1}')
  fi

  # ---------- parse the config ----------
  # Valid verbs: install&enable=, install&disable=, disable=, remove=.
  # Multi-action lines are supported (split on whitespace); bare verbs /
  # comments are ignored; an unknown verb is warned to stderr and ignored.
  declare -A install=() install_dis=() disable=() remove=() seen=() conflict=()
  # ENFORCED, never configurable: Contacts is always installed+enabled, and
  # AppAPI is installed-but-disabled (it opens an app-install path from the web
  # UI). Talk's spreed app is enforced only when video calling is on, and the
  # Roundcube webmail app is installed when the mail module is also on. Any of
  # these names in apps.conf is dropped below with a warning — the operator
  # changes them from their own Nextcloud Apps page.
  install["contacts"]=1; seen["contacts"]=1
  install_dis["app_api"]=1; seen["app_api"]=1
  ENFORCED="contacts app_api"
  if [ "${VIDEO_CALLING:-true}" != "false" ]; then
    install["spreed"]=1; seen["spreed"]=1
    ENFORCED="$ENFORCED spreed"
  fi
  if mod_on mail; then
    # Roundcube webmail app: the mail module owns the mail platform; this only
    # adds its Nextcloud front-end (app id mail_roundcube in the appstore —
    # "roundcube" is a different, stale app; no mailserver changes).
    install["mail_roundcube"]=1; seen["mail_roundcube"]=1
    ENFORCED="$ENFORCED mail_roundcube"
  fi
  if [ "${CLIENT_PUSH:-false}" = "true" ]; then
    install["notify_push"]=1; seen["notify_push"]=1
    ENFORCED="$ENFORCED notify_push"
  fi
  local line tok verb key
  while IFS= read -r line || [ -n "$line" ]; do
    [ "${_fresh}" = true ] || break         # re-run: enforced apps only
    line="${line%%#*}"                          # strip inline comments
    line="${line#"${line%%[![:space:]]*}"}"     # trim leading whitespace
    line="${line%"${line##*[![:space:]]}"}"     # trim trailing whitespace
    [ -z "$line" ] && continue
    for tok in $line; do
      [[ "$tok" == *"="* ]] || continue         # bare verb → ignore
      verb="${tok%%=*}"; key="${tok#*=}"
      case " $ENFORCED " in *" $key "*)
          _note "$(printf '  %sENFORCED%s config/cloud/apps.conf: %s is set by the installer (contacts: install&enable, app_api: install&disable, plus the optional spreed/roundcube/notify_push) — line ignored; change it from your Nextcloud Apps page' \
            "$C_ORANGE" "$C_RST" "$key")"
          continue ;;
      esac
      case "$verb" in
        install\&enable)  install["$key"]=1; seen["$key"]=1 ;;
        install\&disable) install_dis["$key"]=1; seen["$key"]=1 ;;
        disable)          disable["$key"]=1; seen["$key"]=1 ;;
        remove)           remove["$key"]=1; seen["$key"]=1 ;;
        *) _note "$(printf '  %sWARN%s config/cloud/apps.conf: unknown verb %s in %s — ignored' "$C_ORANGE" "$C_RST" "'$verb'" "'$tok'")" ;;
      esac
    done
  done < <( [ -f "$conf" ] && cat "$conf" )

  # ---------- conflicts: same app with two different verbs ----------
  # Fatal unless you explicitly drop them: warn with full details, prompt,
  # abort only if unconfirmed.
  local key cnt
  for key in "${!seen[@]}"; do
    cnt=$(( ${install["$key"]:-0} + ${install_dis["$key"]:-0} + ${disable["$key"]:-0} + ${remove["$key"]:-0} ))
    [ "$cnt" -gt 1 ] && conflict["$key"]=1
  done
  local conflicted="${!conflict[*]}"
  if [ -n "$conflicted" ]; then
    _task_pause
    _note ""
    _note "$(printf '%s┌─ ERROR%s %ssame app has two different verbs%s' "$C_RED" "$C_RST" "$C_GREY" "$C_RST")"
    for key in $conflicted; do
      [ "${install["$key"]:-}" = "1" ] && _note "$(printf '  %s%s%s  install&enable' "$C_RED" "$key" "$C_RST")"
      [ "${install_dis["$key"]:-}" = "1" ] && _note "$(printf '  %s%s%s  install&disable' "$C_RED" "$key" "$C_RST")"
      [ "${disable["$key"]:-}" = "1" ] && _note "$(printf '  %s%s%s  disable' "$C_RED" "$key" "$C_RST")"
      [ "${remove["$key"]:-}" = "1" ] && _note "$(printf '  %s%s%s  remove' "$C_RED" "$key" "$C_RST")"
    done
    _note "$(printf '%s└──────────────────────────────────────────────%s' "$C_RED" "$C_RST")"
    local _abort
    if ! ask_boolean "abort the install?" _abort; then
      _note "no terminal input — aborting"; exit 1
    fi
    [ "$_abort" = "true" ] && exit 1
    _note "$(printf '%sdropping conflicting actions and continuing%s' "$C_ORANGE" "$C_RST")"
    _task_resume
  fi

  # ---------- print the plan ----------
  # The enforced apps are applied SILENTLY (logged, never printed): the operator
  # cannot change them here (they live on the Nextcloud Apps page), so asking
  # about them would be a question with only one answer. Only the operator's own
  # apps.conf entries are shown and confirmed — and when the config holds none,
  # there is no plan to show and no prompt to answer.
  local ipl ids dis rem
  ipl=$(printf '%s\n' "${!install[@]}"     | grep -vx -e spreed -e contacts -e mail_roundcube -e notify_push | paste -sd', ' -)
  ids=$(printf '%s\n' "${!install_dis[@]}" | grep -vx -e app_api   | paste -sd', ' -)
  dis=$(printf '%s\n' "${!disable[@]}"     | paste -sd', ' -)
  rem=$(printf '%s\n' "${!remove[@]}"      | paste -sd', ' -)
  detail "  enforced (not configurable, applied silently): install&enable='$ENFORCED' install&disable='app_api'"
  _task_pause
  _note ""
  if [ -n "$ipl$ids$dis$rem" ]; then
    _note "$(printf '%s┌─ Nextcloud apps%s  %s(config/cloud/apps.conf)%s' "$C_ORANGE" "$C_RST" "$C_GREY" "$C_RST")"
    [ -n "$ipl" ] && _note "$(printf '  %swill install/enable%s   %s' "$C_GREY" "$C_RST" "$ipl")"
    [ -n "$ids" ] && _note "$(printf '  %swill install/disable%s  %s' "$C_GREY" "$C_RST" "$ids")"
    [ -n "$dis" ] && _note "$(printf '  %swill disable%s          %s' "$C_GREY" "$C_RST" "$dis")"
    [ -n "$rem" ] && _note "$(printf '  %swill remove%s           %s' "$C_GREY" "$C_RST" "$rem")"
    _note "$(printf '%s└─────────────────────────────────────────────────────%s' "$C_ORANGE" "$C_RST")"
  fi

  local _confirm
  if [ -n "$ipl$ids$dis$rem" ]; then
    if ! ask_boolean "Apply configured app actions?" _confirm; then
      _note "app actions skipped (not confirmed)"
      _task_resume
      return 0
    fi
  fi
  _task_resume

  # ---------- pre-flight: read the live app state exactly once ----------
  # occ app:list: "Enabled:" / "Disabled:" sections, lines "  - id: version";
  # strip everything after the first colon so "spreed: 24.0.5" matches.
  local ncpid
  ncpid=$(docker ps --format '{{.Names}}' | grep -x nextcloud)
  [ -n "$ncpid" ] || { fail ask_nc_apps "nextcloud container is not running"; return 1; }
  # Timeout a hanging occ; the list is small so 120s is ample.
  occ_out=$(timeout 120 docker exec -u www-data nextcloud php occ app:list --output=plain 2>/dev/null) || {
    fail ask_nc_apps "occ app:list failed (container may still be booting) — see $LOG"
    return 1
  }
  enabled_ids=$(printf '%s' "$occ_out" | awk 'BEGIN{f=0} /^Enabled:/{f=1;next} /^Disabled:/{f=0} f && /^  -/{sub(/^  - /,""); sub(/:.*/, ""); print}')
  disabled_ids=$(printf '%s' "$occ_out" | awk 'BEGIN{f=0} /^Disabled:/{f=1} f && /^  -/{sub(/^  - /,""); sub(/:.*/, ""); print}')
  # $1 = needle, $2.. = app ids (exact match, no word-split corruption)
  in_list() {
    local needle="$1"; shift
    local item
    for item in "$@"; do
      [ "$item" = "$needle" ] && return 0
    done
    return 1
  }

  # ---------- apply install&enable ----------
  for app in "${!install[@]}"; do
    [ "${conflict["$app"]:-}" = "1" ] && continue
    if in_list "$app" $enabled_ids; then
      continue                    # already installed+enabled → skip silently
    elif in_list "$app" $disabled_ids; then
      # Enabled already in the image but reported disabled → operator request wins.
      if ! docker exec -u www-data nextcloud php occ app:enable "$app" >/dev/null 2>&1; then
        _err_note "occ app:enable $app failed — see $LOG"
        fail ask_nc_apps "occ app:enable $app failed"
        continue
      fi
      continue                    # done
    fi
    # Not installed at all → auto-install + auto-enable per operator request
    # (config/cloud/apps.conf): no prompt.
    # Failures are logged and dropped silently; the plan above is authoritative.
    detail "  install&enable='$app' — not present in occ; installing then enabling"
    # The appstore download can exceed two minutes on a cold cache; a timeout
    # used to abort the install silently, so the enforced notify_push app went
    # missing and the later `occ notify_push:setup` failed with an unrelated
    # "no commands defined" error. Retry once with a generous cap.
    _installed=0
    for _try in 1 2; do
      if timeout 300 docker exec -u www-data nextcloud php occ app:install "$app" >>"$LOG" 2>&1; then
        _installed=1; break
      fi
      log "  occ app:install $app failed (attempt $_try)"
    done
    if [ "$_installed" != 1 ]; then
      _warn_note "occ app:install $app failed after 2 attempts — app not in the appstore and no local app dir; action dropped"
      continue
    fi
    if ! timeout 120 docker exec -u www-data nextcloud php occ app:enable "$app" >>"$LOG" 2>&1; then
      _warn_note "occ app:enable $app failed after install; action dropped"
      continue
    fi
    # If still not in the enabled list after install/enable, retry once (occ
    # can be slow on a cold cache); spreed ships in the image so this handles
    # the case where it appears in occ list only after first boot.
    if ! in_list "$app" $enabled_ids; then
      sleep 15
      occ_out=$(timeout 120 docker exec -u www-data nextcloud php occ app:list --output=plain 2>/dev/null) || true
      enabled_ids=$(printf '%s' "$occ_out" | awk 'BEGIN{f=0} /^Enabled:/{f=1;next} /^Disabled:/{f=0} f && /^  -/{sub(/^  - /,""); sub(/:.*/, ""); print}')
    fi
    detail "  installed + enabled $app"
  done

  # ---------- apply install&disable ----------
  # install&disable= requests an app that should exist but stay OFF: install it
  # first (needed for a fresh DB), then disable it. Already installed (enabled
  # or disabled) → just make sure it is disabled; not in occ at all → install.
  for app in "${!install_dis[@]}"; do
    [ "${conflict["$app"]:-}" = "1" ] && continue
    if in_list "$app" $enabled_ids || in_list "$app" $disabled_ids; then
      :                                   # already present — only ensure disabled
    else
      detail "  install&disable='$app' — not present in occ; installing then disabling"
      if ! timeout 120 docker exec -u www-data nextcloud php occ app:install "$app" >>"$LOG" 2>&1; then
        _warn_note "occ app:install $app failed — app not in the appstore and no local app dir; action dropped"
        continue
      fi
    fi
    if in_list "$app" $enabled_ids; then
      if ! docker exec -u www-data nextcloud php occ app:disable "$app" >/dev/null 2>&1; then
        _err_note "occ app:disable $app failed — see $LOG"
        fail ask_nc_apps "occ app:disable $app failed"
        continue
      fi
    fi
    detail "  installed + disabled $app"
  done

  # ---------- apply disable ----------
  # disable= on an installed app (enabled or already disabled) is the operator's
  # stated intent — apply it, no prompt. Only an app that is NOT installed at all
  # is surprising (nothing to disable) — warn and offer install&disable or skip.
  for app in "${!disable[@]}"; do
    [ "${conflict["$app"]:-}" = "1" ] && continue
    if in_list "$app" $disabled_ids; then
      continue                    # already disabled → skip silently
    elif in_list "$app" $enabled_ids; then
      # Installed and enabled → apply the config's intent without prompting.
      if ! docker exec -u www-data nextcloud php occ app:disable "$app" >/dev/null 2>&1; then
        _err_note "occ app:disable $app failed — see $LOG"
        fail ask_nc_apps "occ app:disable $app failed"
      fi
      continue
    fi
    # Not installed → nothing to disable. Warn and offer to install&disable.
    _task_pause
    _note ""
    _note "$(printf '%s┌─ WARN%s %sdisable=%s but it is not installed%s' "$C_ORANGE" "$C_RST" "$C_GREY" "$app" "$C_RST")"
    _note "$(printf '  live state:  %snot installed%s' "$C_GREY" "$C_RST")"
    _note "  choices:"
    _note "$(printf '    %sinstall&disable%s — install %s, then disable it (keeps it present but off)' "$C_GREEN" "$C_RST" "$app")"
    _note "$(printf '    %sdrop%s            — skip this action (leave nothing)' "$C_GREY" "$C_RST")"
    _note "$(printf '%s└──────────────────────────────────────────────%s' "$C_ORANGE" "$C_RST")"
    local choice
    while true; do
      read -r choice || { _note "no terminal input — dropping action"; _task_count 1; break; }
      _task_count 1
      case "${choice,,}" in
        install\&disable|install|yes) break ;;
        drop|skip|no) break ;;
        *) _note "  unknown choice: $choice" ;;
      esac
    done
    _task_resume
    case "${choice,,}" in
      install\&disable|install|yes)
        if ! timeout 120 docker exec -u www-data nextcloud php occ app:install "$app" >>"$LOG" 2>&1; then
          _warn_note "occ app:install $app failed — app not in the appstore and no local app dir; action dropped"
          continue
        fi
        if ! docker exec -u www-data nextcloud php occ app:disable "$app" >/dev/null 2>&1; then
          _err_note "occ app:disable $app failed — see $LOG"
          fail ask_nc_apps "occ app:disable $app failed"
          continue
        fi
        detail "  installed + disabled $app"
        ;;
      drop|skip|no) : ;;
    esac
  done

  # ---------- apply remove ----------
  for app in "${!remove[@]}"; do
    [ "${conflict["$app"]:-}" = "1" ] && continue
    if in_list "$app" $disabled_ids; then
      continue                    # disabled → skip silently
    elif ! in_list "$app" $enabled_ids; then
      continue                    # not installed → skip silently (occ app:remove is a no-op)
    fi
    # Installed+enabled: remove silently per config intent.
    if ! docker exec -u www-data nextcloud php occ app:remove "$app" >/dev/null 2>&1; then
      _err_note "occ app:remove $app failed — see $LOG"
      fail ask_nc_apps "occ app:remove $app failed"
      continue
    fi
  done

  # ---------- record the resulting enabled set ----------
  # The installer is the source of truth: write the enabled snapshot so a fresh
  # DB can reproduce exactly what the operator configured; make nc-capture keeps
  # a read-only mirror for diffs against config/cloud/apps.conf.
  mkdir -p "$MANIFEST_DIR"
  {
    echo "# GENERATED by the installer from config/cloud/apps.conf ($(date -Is)) — do not edit; re-run install to refresh."
    echo "# Format: one app id per line (occ app:list --enabled)."
    docker exec -u www-data nextcloud php occ app:list --enabled 2>/dev/null \
      | grep -oE '^  - [^:]+' | sed -E 's/^  - ([^:]+).*/\1/'
  } > "$MANIFEST_DIR/apps.txt"
  detail "  recorded enabled apps ($MANIFEST_DIR/apps.txt): $(wc -l < "$MANIFEST_DIR/apps.txt" | tr -d ' ')"
  # Record that the app selection was applied: a later run (resume/repair) then
  # only re-checks the enforced apps instead of reading apps.conf again.
  NC_APPS_APPLIED=1
  save_state
  return 0
}
