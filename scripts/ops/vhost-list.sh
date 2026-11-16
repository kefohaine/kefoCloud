#!/usr/bin/env bash
# scripts/ops/vhost-list.sh — every vhost, every name it answers, the module it
# belongs to, whether that module is installed, and the exposure recorded for it.
#
#   make vhost-list                every vhost
#   make vhost-list TARGET=mail    only vhosts whose file name contains `mail`
#
# READ-ONLY: reads the templates, data/instance.conf, data/wizard.state and the
# RENDERED tree. No render, no docker, no network, nothing written.
#
# Columns
#   VHOST     the vhost FILE (modules/caddy/vhosts/<vhost>.caddy, one file may
#             carry several hostnames and they share its answer)
#   HOSTS     every hostname the template declares
#   MODULE    derived by scripts/lib/modules.sh:mod_vhosts (label or module
#             directory inside the vhost name) — never a roster in this file
#   STATE     the module's word from wizard.state: installed / not installed;
#             `core` for www and ttyd, which belong to no module
#   EXPOSURE  the answer recorded in data/instance.conf (scripts/lib/exposure.sh)
#   EDGE      what the RENDERED vhost does: `gate` (refuses every source outside
#             100.64.0.0/10), `open` (no gate), `-` (nothing rendered yet)
#
# A row is marked `!` when those two last columns disagree — a tailnet-vpn answer
# with an open rendered door, or the reverse. That is a half-applied
# `make vhost-exposure`, which is exactly what a list is for; the run then exits
# 1 so it can be used as a check. A not-installed module's row is never marked:
# its route is ABSENT, not gated (config/modules.conf states the rule).

set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
. "$ROOT/scripts/lib/instance.sh" 2>/dev/null || true
. "$ROOT/scripts/lib/modules.sh"

FILTER="${1:-}"
# INSTANCE_CONF / VHOST_RENDERED exist so this can be pointed at a copy of the
# answers and a rendered tree (a test, a pre-change comparison) without touching
# the live ones; with neither set it reads the host's real state.
CONF="${INSTANCE_CONF:-$DATA_DIR/instance.conf}"
RENDERED="${VHOST_RENDERED:-$DATA_DIR/rendered/caddy/vhosts}"
DOM="$(sed -n 's/^DOMAIN=//p' "$CONF" 2>/dev/null | tail -1)"
DOM="${DOM:-${DOMAIN:-}}"

# owner_of <vhost> — '' for the core doors and for a vhost no module claims.
owner_of() {
  local v="$1" m
  case "$v" in www|ttyd) return 0 ;; esac
  for m in $(mod_all); do
    # No `mod_vhosts "$m" | grep -q`: grep exits on the first match, and under
    # pipefail the SIGPIPE it leaves behind makes the pipeline a failure — the
    # owner of every vhost but the last would read as unowned.
    case $'\n'"$(mod_vhosts "$m")"$'\n' in
      *$'\n'"$v"$'\n'*) printf '%s' "$m"; return 0 ;;
    esac
  done
}

# edge_of <vhost> — what the edge actually loads for this door.
edge_of() {
  local f="$RENDERED/$1.caddy"
  [ -f "$f" ] || { printf '%s' '-'; return 0; }
  if grep -q 'respond @not_tailnet 403' "$f"; then printf 'gate'; else printf 'open'; fi
}

# recorded_of <vhost> — the recorded answer, or the FIXED one for the two doors
# that are never a choice (scripts/lib/exposure.sh).
recorded_of() {
  local v="$1" e
  e="$(exposure_of "$v")"
  if [ -n "$e" ]; then printf '%s' "$e"; return 0; fi
  case "$v" in
    ttyd) printf '%s' 'tailnet-vpn (fixed)' ;;
    www)  printf '%s' 'cloudflare-dns (fixed)' ;;
  esac
}

printf 'vhosts — %s\n' "${DOM:-no DOMAIN recorded in data/instance.conf}"
printf '  answers: %s\n' "$CONF"
printf '  edge:    %s%s\n' "$RENDERED" "$([ -d "$RENDERED" ] || printf ' (not rendered yet — run make render)')"
printf '\n'
printf '  %-2s %-20s %-36s %-9s %-15s %-22s %s\n' '' 'VHOST' 'HOSTS' 'MODULE' 'STATE' 'EXPOSURE' 'EDGE'

rows=0 gates=0 opens=0 absent=0 drift=0 filtered=0
while IFS= read -r v; do
  [ -n "$v" ] || continue
  if [ -n "$FILTER" ] && ! printf '%s' "$v" | grep -q -- "$FILTER"; then
    filtered=$((filtered + 1)); continue
  fi
  hosts="$(exposure_hosts "$v" 2>/dev/null | paste -sd, -)"
  mod="$(owner_of "$v")"
  if [ -z "$mod" ]; then
    state="core"
  else
    state="$(mod_state "$mod")"
  fi
  exp="$(recorded_of "$v")"
  edge="$(edge_of "$v")"

  mark=' '
  case "$exp" in
    tailnet-vpn*)    want=gate ;;
    cloudflare-dns*) want=open ;;
    *)               want='' ;;
  esac
  if [ -n "$want" ] && [ "$edge" != '-' ] && [ "$edge" != "$want" ]; then
    mark='!'; drift=$((drift + 1))
  fi
  if [ "$state" = 'not installed' ]; then absent=$((absent + 1)); fi
  case "$edge" in gate) gates=$((gates + 1)) ;; open) opens=$((opens + 1)) ;; esac

  printf '  %-2s %-20s %-36s %-9s %-15s %-22s %s\n' \
    "$mark" "$v" "${hosts:--}" "${mod:--}" "$state" "${exp:--}" "$edge"
  rows=$((rows + 1))
done < <(exposure_all)

printf '\n'
printf '  %d vhost(s): %d gated · %d open · %d unrendered · %d on a not-installed module\n' \
  "$rows" "$gates" "$opens" "$((rows - gates - opens))" "$absent"
[ -n "$FILTER" ] && printf '  filter %q: %d hidden\n' "$FILTER" "$filtered"

if [ "$drift" -gt 0 ]; then
  printf '\n  %d door(s) marked ! — the recorded answer and the rendered edge disagree\n' "$drift"
  printf '  (a half-applied change: re-run make vhost-exposure, or make render for that door)\n'
  exit 1
fi
exit 0
