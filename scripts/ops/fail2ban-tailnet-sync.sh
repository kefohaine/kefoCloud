#!/usr/bin/env bash
# scripts/ops/fail2ban-tailnet-sync.sh — keep the tailnet whitelist true AND enforced.
#
# Why this exists: the jails ban by SOURCE IP with a host-wide ufw REJECT, and
# the operator's own devices sit behind NAT, so the address a jail sees is the
# router's — shared by every browser in that house. One retry loop against an
# app's token endpoint therefore locked the whole tailnet out of every vhost.
#
# Two layers close that hole, and this script is the second one:
#   * at ban time, each jail's ignorecommand (fail2ban-tailnet-ignore.sh) asks
#     this script for the list and refuses to ban an address on it;
#   * on a timer, this script re-collects the list and UNBANS any jailed address
#     that is on it — so a ban placed before the whitelist existed, or while
#     tailscaled was restarting, or under a stale NAT mapping, heals by itself.
#
# The list is the direct endpoints tailscaled reports for itself and its peers
# (CurAddr plus the Endpoints candidate set), minus anything that is not a
# routable public address: tailnet CGNAT, RFC1918, loopback, link-local. A peer
# that is currently DERP-relayed reports no endpoint, so nothing is whitelisted
# for it — the conservative direction. Everything off-tailnet keeps the full
# jail behaviour: same filter, same maxretry/findtime/bantime, same ufw ban.
#
# Usage:  script           refresh the persisted list, then unban its addresses
#         script --list    print the union of persisted and live addresses
#
# The persisted copy (data/fail2ban/tailnet-ips) is what makes the whitelist
# survive a tailscaled outage: a failed collection never truncates it.

set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
STATE="$ROOT/data/fail2ban"
LIST="$STATE/tailnet-ips"
LOG="$ROOT/data/logs/fail2ban-tailnet-sync.log"

# Public, non-tailnet, non-private address — the only thing worth comparing.
is_public() {
  case "$1" in
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) return 1 ;;  # tailnet CGNAT
    fd7a:115c:a1e0:*) return 1 ;;
    10.*|127.*|169.254.*|192.168.*) return 1 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 1 ;;
    fe80:*|::1) return 1 ;;
  esac
  return 0
}

# Address plus port, or a bracketed IPv6 address plus port, from tailscaled.
collect() {
  command -v tailscale >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local out
  out=$(tailscale status --json 2>/dev/null \
    | jq -r '[.Self, .Peer[]?] | .[] | ((.Endpoints // [])[]?, .CurAddr // empty)' 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" \
    | sed -nE 's/^\[?([0-9A-Fa-f:.]+)\]?:[0-9]+$/\1/p' \
    | while read -r ip; do is_public "$ip" && printf '%s\n' "$ip"; done \
    | sort -u
}

live=$(collect)

if [ "${1:-}" = "--list" ]; then
  { [ -s "$LIST" ] && cat "$LIST"; [ -n "$live" ] && printf '%s\n' "$live"; } | sort -u
  exit 0
fi

mkdir -p "$STATE" "$(dirname "$LOG")"

# Replace the persisted copy only with a non-empty answer, so an outage keeps
# the last known good list instead of blanking the whitelist.
if [ -n "$live" ]; then
  printf '%s\n' "$live" > "$LIST.tmp" && mv -f "$LIST.tmp" "$LIST"
fi
[ -s "$LIST" ] || exit 0

known=$(sort -u "$LIST")

unbanned=0
for jail in $(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr ',' ' '); do
  for ip in $(fail2ban-client status "$jail" 2>/dev/null | sed -n 's/.*Banned IP list:[[:space:]]*//p'); do
    if printf '%s\n' "$known" | grep -qxF -- "$ip"; then
      fail2ban-client set "$jail" unbanip "$ip" >/dev/null 2>&1 && {
        unbanned=$((unbanned + 1))
        printf '%s tailnet endpoint %s unbanned from %s\n' "$(date -Is)" "$ip" "$jail" >> "$LOG"
      }
    fi
  done
done

printf '%s whitelist=%s unbanned=%s\n' "$(date -Is)" "$(printf '%s\n' "$known" | wc -l)" "$unbanned" >> "$LOG"
exit 0
