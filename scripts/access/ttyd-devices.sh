#!/usr/bin/env bash
# scripts/access/ttyd-devices.sh — per-tailnet-device shells, listed on the tail page.
#
#   scripts/access/ttyd-devices.sh list                 what exists now
#   scripts/access/ttyd-devices.sh add <name>           create a shell + list it
#   scripts/access/ttyd-devices.sh rm  <name>           kill it + unlist it
#
# A "device instance" is a named tmux session served by the ONE ttyd listener
# (ttyd runs with -a, so /ttyd?arg=<name> attaches to that session). That is a
# deliberate design choice, not a shortcut:
#
#   · no extra listener — nothing new binds a port, so nothing new can be
#     reached by accident (AGENTS rule 10: no new listeners without an
#     explicit operator request)
#   · no edge edit — the existing tail.$DOMAIN vhost keeps its tailnet-only
#     matcher; a per-device vhost would mean another site block, another cert
#     and another restart of the one door that can lock the operator out
#   · one registry file (data/ttyd-devices.conf, GENERATED-ish, untracked) is
#     the single source of truth; the tail page catalogue is regenerated from it
#
# The registry lines are `name` (one per line, `#` comments allowed). Adding a
# session does NOT start anything on the remote device: this lists and manages
# the shells on THIS host. Reaching a device means ssh/tailscale ssh from the
# session — deliberately not automated, because that is where credentials and
# authorisation live.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
. "$ROOT/scripts/lib/instance.sh"
REG="$DATA_DIR/ttyd-devices.conf"

mkdir -p "$DATA_DIR"
[ -f "$REG" ] || cat > "$REG" <<EOF
# data/ttyd-devices.conf — per-tailnet-device web-terminal sessions.
# One session name per line (a-z A-Z 0-9 . _ -), '#' comments allowed.
# Managed with: make ttyd-add NAME=<name> | make ttyd-rm NAME=<name>
# Each name is served by the single ttyd listener as /ttyd?arg=<name> and is
# listed on https://tail.${DOMAIN}/ by \`make tail-targets\`.
main
EOF

sanitise() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-32; }
# Only ever return syntactically valid session names: a registry that got
# polluted (an unescaped heredoc once injected make's output into it) can then
# never produce a card or a route.
names()    { grep -vE '^[[:space:]]*(#|$)' "$REG" 2>/dev/null | grep -xE '[A-Za-z0-9][A-Za-z0-9._-]{0,31}'; }
has()      { tmux has-session -t "$1" 2>/dev/null; }

cmd_list() {
  printf 'registered sessions (%s):\n' "$REG"
  local n
  for n in $(names); do
    if has "$n"; then printf '  %-20s running\n' "$n"; else printf '  %-20s (no tmux session yet — will be created on first attach)\n' "$n"; fi
  done
  printf '\nweb terminal: https://tail.%s/ttyd   → /ttyd?arg=<name>\n' "$DOMAIN"
}

cmd_add() {
  local raw="${1:-}" n
  [ -n "$raw" ] || { echo "usage: scripts/access/ttyd-devices.sh add <name>" >&2; exit 1; }
  n="$(sanitise "$raw")"
  if names | grep -qx "$n"; then
    echo "info:  '$n' is already registered"
  else
    printf '%s\n' "$n" >> "$REG"
    echo "info:  registered '$n'"
  fi
  # create the session now so the page card works on first click
  if has "$n"; then echo "info:  tmux session '$n' already running"
  else tmux new-session -d -s "$n" -n "$n" && echo "info:  tmux session '$n' created"; fi
  bash "$ROOT/scripts/access/tail-targets.sh" >/dev/null 2>&1 && echo "info:  tail page catalogue refreshed (make tail-targets)"
  echo "info:  open https://tail.$DOMAIN/ttyd?arg=$n"
}

cmd_rm() {
  local raw="${1:-}" n
  [ -n "$raw" ] || { echo "usage: scripts/access/ttyd-devices.sh rm <name>" >&2; exit 1; }
  n="$(sanitise "$raw")"
  if names | grep -qx "$n"; then
    grep -vx "$n" "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"
    echo "info:  unregistered '$n'"
  else
    echo "warn:  '$n' was not registered"
  fi
  if has "$n"; then tmux kill-session -t "$n" && echo "info:  tmux session '$n' killed"; fi
  bash "$ROOT/scripts/access/tail-targets.sh" >/dev/null 2>&1 && echo "info:  tail page catalogue refreshed"
}

case "${1:-list}" in
  list|ls) cmd_list ;;
  add)     shift; cmd_add "${1:-}" ;;
  rm|del)  shift; cmd_rm "${1:-}" ;;
  -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "usage: scripts/access/ttyd-devices.sh [list|add <name>|rm <name>]" >&2; exit 2 ;;
esac
