# wizard.d/lib/prompt.sh — the up-front input collection (locale, ssh key, tailscale, cloudflare, domain, modules).

# Module prompts are ALWAYS asked — there is no answer-sheet defaults file, and
# every prompt is asked on every run except when a resume supplies the answer.
# Yes/no affirmation: ONLY the literal words yes / no are accepted — no
# y/n/Enter shorthand, no default (a typo is re-asked). The answer is RECORDED
# as the boolean true / false in the named variable, never as what was typed.
ask_boolean() {   # ask_boolean <question> <variable>
  _task_pause
  _ask_boolean_raw "$@"
  local rc=$?
  _task_resume
  return $rc
}
_ask_boolean_raw() {
  # _reply, not `answer`: `printf -v "$var"` assigns by name under bash's
  # dynamic scope, so a local literally named like a caller's target
  # (ask_optimize's `answer`) would swallow the answer (2026-10-17 bug).
  local q="$1" var="$2" _reply
  while :; do
    printf '%s[INFO]%s %s (yes/no): ' "$C_GREY" "$C_RST" "$q"
    read -r _reply || { _task_count 1; return 1; }
    _task_count 1
    case "${_reply,,}" in
      yes) printf -v "$var" '%s' true;  return 0 ;;
      no)  printf -v "$var" '%s' false; return 0 ;;
      *)   echo "   type yes or no."; _task_count 1 ;;
    esac
  done
}

# ONE prompt for the whole module set, space-separated (multiple spaces / commas
# tolerated, any order). Every name not listed becomes false. On a resume, when
# all four answers are already saved, the prompt is skipped.
ask_cloud_options() {
  # Cloud-only optional services, asked only when the cloud module is on and
  # BEFORE the Nextcloud apps plan (the plan reflects these choices). Each is a
  # plain yes/no, persisted so a resume reuses it.
  [ "${MOD_CLOUD:-}" = "true" ] || return 0
  if [ -z "${VIDEO_CALLING:-}" ]; then
    ask_boolean "Enable Nextcloud Talk video calling (spreed + signaling + TURN)?" VIDEO_CALLING \
      || VIDEO_CALLING=false
    save_state
  fi
  if [ -z "${CLIENT_PUSH:-}" ]; then
    ask_boolean "Enable Nextcloud client push notifications (notify_push)?" CLIENT_PUSH \
      || CLIENT_PUSH=false
    save_state
  fi
}
ask_modules() {
  local k name all=1 ans ok mods
  # The offer list IS config/modules.conf (via _state_modules) — a module added
  # there is askable, recordable and detectable with no edit here.
  mods="$(_state_modules)"
  for k in $mods; do
    name="MOD_${k^^}"; [ -n "${!name:-}" ] || all=
  done
  [ -n "$all" ] && return 0
  while :; do
    printf '%s[INFO]%s Modules to install, separated by spaces (%s) — or 'all' for every one: ' \
      "$C_GREY" "$C_RST" "$(printf '%s' "$mods" | paste -sd' ' -)"
    read -r ans || exit 1
    ans="${ans,,}"; ans="${ans//,/ }"
    # Presets: `all` (and `everything`) expands to the whole roster, which is
    # the same choice as naming every app. Any other word must be an app key.
    case " $ans " in
      *" all "*|*" everything "*) ans="$mods" ;;
    esac
    ok=1
    for k in $ans; do
      case " $mods " in *" $k "*) ;; *) echo "   unknown module: $k"; ok= ;; esac
    done
    [ -n "$ok" ] || continue
    for k in $mods; do
      name="MOD_${k^^}"
      case " $ans " in *" $k "*) printf -v "$name" '%s' true ;; *) printf -v "$name" '%s' false ;; esac
    done
    return 0
  done
}

# ── SSH access: STRICT and required ──────────────────────────────────────
# The box ends up root-key-only with password auth off, so a usable pubkey from
# a device the operator actually holds is REQUIRED — the installer asks for it
# here instead of leaving it as a follow-up `ssh_keys` step. Only the PUBLIC
# half is pasted; the private half never leaves that device. Nothing is ever
# minted server-side (that is the difference to the opt-in GitHub key below).
#
# The door is an ALLOWLIST: any number of keys are accepted, one per line, and
# every one is authorized (the legacy single SSH_PUBKEY is still written for
# back-compat — it holds the first key). Paste several, one per line, and leave
# a blank line to finish.
auth_add_key() {   # authorize one public key, deduplicated
  local key="$1"
  [ -n "$key" ] || return 0
  grep -qxF "$key" /root/.ssh/authorized_keys 2>/dev/null \
    || printf '%s\n' "$key" >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
}
ssh_key_count() { grep -c . /root/.ssh/authorized_keys 2>/dev/null || echo 0; }
ask_ssh_key() {
  local line info key
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  # A resumed run reuses the allowlist saved in wizard.state (SSH_PUBKEYS); a
  # fresh (no-resume) run has it unset and asks again — the keys are a
  # first-class prompted answer like DOMAIN and the tokens, not an inference
  # from authorized_keys (2026-10-16: authorized_keys existing was the old skip
  # signal, which also silenced the prompt on a fresh re-run).
  if [ -n "${SSH_PUBKEYS:-}" ]; then
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      auth_add_key "$key"
    done <<< "$SSH_PUBKEYS"
    # wizard.state is the ALLOWLIST: keys removed from it lose authorization
    # (removed-value applies too). Only allowlist keys are kept, so a key added
    # by hand outside the wizard is dropped on the next run — say so.
    local _tmp _removed
    _tmp=$(mktemp)
    grep -vxF -f <(printf '%s\n' "$SSH_PUBKEYS") /root/.ssh/authorized_keys >"$_tmp" 2>/dev/null || true
    _removed=$(grep -c . "$_tmp" 2>/dev/null || true)
    if [ "${_removed:-0}" -gt 0 ]; then
      cat "$_tmp" >>"$LOG"
      grep -vxF -f <(printf '%s\n' "$SSH_PUBKEYS") /root/.ssh/authorized_keys \
        >/root/.ssh/authorized_keys.tmp 2>/dev/null || true
      mv /root/.ssh/authorized_keys.tmp /root/.ssh/authorized_keys
      chmod 600 /root/.ssh/authorized_keys
      detail "  SSH: $_removed key(s) no longer in wizard.state — authorization removed"
    fi
    rm -f "$_tmp"
    detail "  SSH: $(ssh_key_count) device key(s) from wizard.state already authorized — paste skipped"
    return 0
  fi
  # Also honor a legacy single SSH_PUBKEY saved by an older installer.
  if [ -n "${SSH_PUBKEY:-}" ] && [ -z "${SSH_PUBKEYS:-}" ]; then
    auth_add_key "$SSH_PUBKEY"
    SSH_PUBKEYS="$SSH_PUBKEY"
    detail "  SSH: device key from wizard.state already authorized — paste skipped"
    return 0
  fi
  printf '\n SSH is key-only (root, no password). On the device you will connect FROM run\n'
  printf '   cat ~/.ssh/id_ed25519.pub\n'
  printf ' and paste that line here (no ssh-copy-id needs to run yet). Paste SEVERAL\n'
  printf ' keys, one per line, to authorize more than one device — leave a blank line\n'
  printf ' when you are done. Only the PUBLIC half goes to the server; the private half\n'
  printf ' never leaves your device. Use a key you can actually use — hardening is\n'
  printf ' key-only, so a wrong or lost key is a lockout.\n\n'
  while :; do
    printf '%s[INFO]%s Public SSH key of your device (blank line when done): ' "$C_GREY" "$C_RST"
    read -r line \
      || { echo "A public key is required — re-run the installer from a terminal."; exit 1; }
    line="$(printf '%s' "$line" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$line" in
      "")
        # A blank line finishes — but the allowlist may never be empty.
        [ -n "${SSH_PUBKEYS:-}" ] && break
        echo "   at least one public key is required (hardening is key-only)."
        continue ;;
      *"PRIVATE KEY"*) echo "   that is the PRIVATE key — never paste it; paste the .pub line."; continue ;;
    esac
    info="$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null)"
    [ -n "$info" ] || { echo "   not a valid public key — paste the whole .pub line (ssh-ed25519 AAAA… you@device)."; continue; }
    auth_add_key "$line"
    # Append to the allowlist (deduplicated, exact match — grep -F) so a resume
    # reuses every key.
    if [ -z "${SSH_PUBKEYS:-}" ]; then
      SSH_PUBKEYS="$line"
    elif ! printf '%s\n' "$SSH_PUBKEYS" | grep -qxF "$line"; then
      SSH_PUBKEYS="$SSH_PUBKEYS"$'\n'"$line"
    fi
    # Persist so a resume reuses the list and a no-resume re-asks; keep the
    # legacy single-key field pointing at the first key.
    SSH_PUBKEY="${SSH_PUBKEYS%%$'\n'*}"
    save_state
    detail "  SSH key accepted: $info (allowlist now $(ssh_key_count) key(s))"
  done
}


# Locale: the operator's country, resolved to an IANA timezone from the system's
# zoneinfo (no hardcoded map — iso3166.tab names/codes + zone.tab zones). The
# timezone is applied immediately and exported, so EVERY timestamp the run prints
# (the checklist rows, msg lines) is in the operator's local time. Asked FIRST,
# before any other input, so no timestamp is printed in the host's zone.
# Resolve the operator's answer (an ISO-3166 alpha-2 code, a country name, or an
# IANA zone like Europe/Paris) to an alpha-2 country code — from the system's own
# iso3166.tab / zone.tab, never a hardcoded list.
country_code() {
  local q="$1" code=
  case "$q" in
    */*) code=$(awk -v tz="$q" '$3==tz{print $1; exit}' /usr/share/zoneinfo/zone.tab 2>/dev/null) ;;
  esac
  [ -n "$code" ] || code=$(awk -v q="${q^^}" '$1==q{print $1; exit}' /usr/share/zoneinfo/iso3166.tab 2>/dev/null)
  [ -n "$code" ] || code=$(awk -F'\t' -v q="$q" 'tolower($2)==tolower(q){print $1; exit}' \
                            /usr/share/zoneinfo/iso3166.tab 2>/dev/null)
  [ -n "$code" ] || return 1
  printf '%s' "$code"
}
country_timezone() {
  local q="$1" code tz
  [ -e "/usr/share/zoneinfo/$q" ] && { printf '%s' "$q"; return 0; }
  code=$(country_code "$q") || return 1
  tz=$(awk -v c="$code" '$1==c{print $3; exit}' /usr/share/zoneinfo/zone.tab 2>/dev/null)
  [ -n "$tz" ] || return 1
  printf '%s' "$tz"
}
# The currency sign used as the checklist's animated marker: read glibc's own
# monetary data (the first locale for the territory that defines
# currency_symbol), keep only single-column glyphs, and fall back to `$` when the
# sign is wide or multi-character (e.g. Sweden's "kr", Switzerland's "CHF",
# Japan's full-width ￥) or the country is unknown. Silent design choice — never
# announced; purely cosmetic.
currency_symbol() {
  local cc="${1:-}" n sym w
  [ -n "$cc" ] || { printf '%s' '$'; return 0; }
  cc="${cc^^}"
  for n in $(awk -v cc="$cc" '{split($1,a,"[_.]"); if (substr(a[2],1,2)==cc){print $1}}' \
               /usr/share/i18n/SUPPORTED 2>/dev/null); do
    n="${n%%.*}"; n="${n%%@*}"
    sym=$(awk -F'"' '/^currency_symbol[[:space:]]/{print $2; exit}' \
            "/usr/share/i18n/locales/$n" 2>/dev/null)
    [ -n "$sym" ] || continue
    w=$(printf '%s' "$sym" | LC_ALL=C.UTF-8 wc -L 2>/dev/null)
    [ "${w:-0}" -eq 1 ] 2>/dev/null && { printf '%s' "$sym"; return 0; }
  done
  case "$cc" in
    JP|CN) printf '%s' '¥' ;;   # glibc ships the 2-column full-width ￥; use the narrow sign
    *)     printf '%s' '$' ;;
  esac
}
ask_locale() {
  while :; do
    if [ -z "${LOCALE_COUNTRY:-}" ]; then
      printf '%s[INFO]%s Locale country (name or ISO code, e.g. France / FR): ' "$C_GREY" "$C_RST"
      read -r LOCALE_COUNTRY || exit 1
    fi
    local tz
    if tz=$(country_timezone "$LOCALE_COUNTRY"); then
      export TZ="$tz"
      timedatectl set-timezone "$tz" >>"$LOG" 2>&1 \
        || log "  timedatectl set-timezone $tz failed (TZ exported for this run only)"
      # The checklist marker follows the country too (silent, cosmetic).
      ANIM_SYM=$(currency_symbol "$(country_code "$LOCALE_COUNTRY" 2>/dev/null || true)")
      detail "  locale country '$LOCALE_COUNTRY' -> timezone $tz, marker '$ANIM_SYM'"
      return 0
    fi
    echo "   unknown country: $LOCALE_COUNTRY (name or ISO 3166 code, e.g. France / FR)"
    LOCALE_COUNTRY=
  done
}

ask_inputs() {
  # Inputs are collected in ONE fixed order, all before any install work, and
  # each is persisted immediately (save_state) so an abort mid-run leaves the
  # answers for a resume. Order: locale country (sets local time first),
  # github-remote-access (+ identity), device-ssh, tailscale, cloudflare, domain,
  # modules. The resume question precedes all of these (it decides whether saved
  # answers are reused).

  # 1 — locale country: resolved to a timezone and applied before any timestamp.
  ask_locale

  # 2 — GitHub remote access: opt-in, then identity + key authorization.
  github_cred_inputs

  # 3 — device SSH public key (strict, required).
  ask_ssh_key

  # 4 — Tailscale auth key (input visible).
  if [ -z "${TS_AUTHKEY:-}" ]; then
    printf '%s[INFO]%s Tailscale Authentication Key: ' "$C_GREY" "$C_RST"
    read -r TS_AUTHKEY
  fi
  [ -n "$TS_AUTHKEY" ] || { echo "Auth key required."; exit 1; }
  save_state

  # 5 — Cloudflare API token (input visible).
  if [ -z "${CF_API_TOKEN:-}" ]; then
    printf '%s[INFO]%s Cloudflare API Token: ' "$C_GREY" "$C_RST"
    read -r CF_API_TOKEN
  fi
  [ -n "$CF_API_TOKEN" ] || { echo "Token required."; exit 1; }
  save_state

  # 6 — domain.
  if [ -z "${DOMAIN:-}" ]; then
    printf '%s[INFO]%s Domain Name: ' "$C_GREY" "$C_RST"
    read -r DOMAIN
  fi
  DOMAIN="${DOMAIN,,}"
  [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || { echo "Invalid domain: $DOMAIN"; exit 1; }
  save_state

  # 7 — modules (one space-separated prompt), then the cloud-only options that
  #      shape the Nextcloud apps plan (video calling / client push).
  ask_modules
  save_state
  ask_cloud_options
  save_state
}
