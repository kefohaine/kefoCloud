#!/bin/bash
# scripts/ops/module-record.sh — the ONE writer of data/uninstalled-modules.conf.
#
# A script that removes a module (uninstall.sh's granular teardown,
# `make module-remove`) records it here by name. wizard.state belongs to the
# installer alone, so a removal is a HAND-OFF rather than a second state store:
# readers subtract this file at once (scripts/lib/modules.sh mod_installed), and
# the next installer run folds the names into wizard.state's enabled_modules and
# then consumes them (scripts/install/wizard.d/lib/state.sh
# apply_uninstalled_record). Until then no reader may call the module installed
# — boot/`make update` no longer recreate it and smoke no longer asserts a door
# that is gone.
#
# Usage:
#   module-record.sh add <module>...    record removals (idempotent)
#   module-record.sh clear <module>...  drop records (the installer consumed them)
#   module-record.sh list               one recorded module per line
#
# Names are validated against config/modules.conf, so a typo can never land in
# the record. A missing file means "nothing was removed by a script" — never
# "assume removals".
set -uo pipefail

SELF="$(dirname "$(readlink -f "$0")")"
. "$SELF/../lib/instance.sh" 2>/dev/null || true
. "$SELF/../lib/modules.sh" 2>/dev/null || true

RECORD="${MODULE_RECORD:-$DATA_DIR/uninstalled-modules.conf}"

_current() { [ -f "$RECORD" ] && awk 'NF' "$RECORD"; }

# The whole file, rewritten atomically, by this script only (stdin = the new
# set; an empty set removes the file, which reads as "nothing removed").
_write() {
  install -d -m 0700 "$(dirname "$RECORD")" || return 1
  local tmp="$RECORD.tmp.$$"
  cat > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0644 "$tmp"
  if [ -s "$tmp" ]; then mv -f "$tmp" "$RECORD"; else rm -f "$tmp" "$RECORD"; fi
}

_known() { mod_all | grep -qxF -- "$1"; }

cmd="${1:-list}"; [ $# -gt 0 ] && shift
case "$cmd" in
  add)
    [ $# -gt 0 ] || { echo "usage: module-record.sh add <module>..." >&2; exit 2; }
    for m in "$@"; do
      _known "$m" || { echo "module-record: '$m' is not declared in config/modules.conf" >&2; exit 2; }
    done
    { _current; printf '%s\n' "$@"; } | sort -u | _write
    ;;
  clear)
    [ $# -gt 0 ] || { echo "usage: module-record.sh clear <module>..." >&2; exit 2; }
    { _current | grep -vxF -f <(printf '%s\n' "$@") || true; } | _write
    ;;
  list)
    _current
    ;;
  *)
    echo "usage: module-record.sh add|clear|list <module>..." >&2
    exit 2
    ;;
esac
