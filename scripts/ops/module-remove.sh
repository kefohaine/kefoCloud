#!/bin/bash
# scripts/ops/module-remove.sh — take one module down and record it as removed.
#
# `make module-remove MODULE=<m>` is the recipe. It also accepts a module a
# script already took down: stopping an absent compose project succeeds, so the
# run converges and only the record is added.
#
# Steps: stop the module's compose project (every docker-compose*.yml of its
# catalog directory, orphans included), then record it in
# data/uninstalled-modules.conf so every reader reports `not installed` —
# `make fetch`, `make smoke`, `make vhost-list`, the boot unit and `make update`
# stop counting it, and the next installer run folds the record into
# wizard.state. Data dirs are NOT touched: deleting operator data is
# uninstall.sh's confirmed step, never this recipe's.
set -uo pipefail

SELF="$(dirname "$(readlink -f "$0")")"
. "$SELF/../lib/instance.sh" 2>/dev/null || true
. "$SELF/../lib/modules.sh" 2>/dev/null || true

LOG="${DATA_DIR}/logs/module-remove.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || LOG=/dev/null

m="${1:-}"
[ -n "$m" ] || { echo "usage: module-remove.sh <module>" >&2; exit 2; }
mod_all | grep -qxF -- "$m" \
  || { echo "module-remove: '$m' is not declared in config/modules.conf" >&2; exit 2; }
dir="$(mod_dir "$m")"
[ -n "$dir" ] || { echo "module-remove: no directory for '$m' in config/modules.conf" >&2; exit 2; }

mapfile -t files < <(ls "$REPO_DIR/modules/$dir"/docker-compose*.yml 2>/dev/null)
if [ "${#files[@]}" -gt 0 ] && command -v docker >/dev/null 2>&1; then
  args=(); for f in "${files[@]}"; do args+=(-f "$f"); done
  ( cd "$REPO_DIR" && docker compose "${args[@]}" down --remove-orphans ) >>"$LOG" 2>&1 \
    || { echo "module-remove: compose down failed for $m — see $LOG; not recorded" >&2; exit 1; }
  echo "module: $m stopped (compose down, ${#files[@]} file(s))"
else
  echo "module: $m has no compose file here or docker is absent — nothing to stop"
fi

bash "$SELF/module-record.sh" add "$m" \
  || { echo "module-remove: could not record $m as removed" >&2; exit 1; }
echo "module: $m recorded as not installed (its data is kept)."
echo "        every reader now reports it not installed; the next installer run"
echo "        folds the record into wizard.state and consumes it."
