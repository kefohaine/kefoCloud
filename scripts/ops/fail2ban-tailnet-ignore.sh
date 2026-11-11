#!/usr/bin/env bash
# scripts/ops/fail2ban-tailnet-ignore.sh — fail2ban ignorecommand.
#
# Why this exists: every jail bans by SOURCE IP with a host-wide ufw REJECT, but
# the operator's own devices reach Caddy through NAT — the address the jail sees
# is the home/office public IP, shared by every browser behind that router. A
# burst of failed logins from one of them (Element Admin retries /oauth2/token)
# therefore cuts the whole tailnet off from every vhost, not just the one app
# that saw the failures.
#
# So: an address that is a tailnet peer's own public endpoint is never banned.
# The list comes from `tailscale status --json` (each direct peer's Endpoints
# carry the public IP:port Tailscale is actually talking to) and is cached for
# a minute, because fail2ban calls this per candidate ban.
#
# Usage (from a jail's ignorecommand): script <ip>
#   exit 0 = ignore (never ban), exit 1 = not a tailnet endpoint.
#
# Trade-off, stated on purpose: a peer behind CGNAT shares its endpoint address
# with strangers. Those strangers are ignored too, for as long as that peer is
# a direct endpoint. Relay-only peers (DERP) advertise no endpoint, so nothing
# is whitelisted for them — that is the conservative direction.

set -uo pipefail

IP="${1:-}"
[ -n "$IP" ] || exit 1

CACHE=/run/fail2ban-tailnet-ignore.list
TTL=60

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

build() {
  command -v tailscale >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  # Every direct address of Self and every peer — an address plus a port, or
  # a bracketed IPv6 address plus a port. `CurAddr` is the address in use now, `Endpoints`
  # is the wider candidate set; both are read so a peer switching paths
  # stays whitelisted.
  tailscale status --json 2>/dev/null \
    | jq -r '[.Self, .Peer[]?] | .[] | ((.Endpoints // [])[]?, .CurAddr // empty)' 2>/dev/null \
    | sed -nE 's/^\[?([0-9A-Fa-f:.]+)\]?:[0-9]+$/\1/p' \
    | while read -r ip; do is_public "$ip" && printf '%s\n' "$ip"; done \
    | sort -u
}

if [ ! -s "$CACHE" ] || [ $(( $(date +%s) - $(stat -c %Y "$CACHE" 2>/dev/null || echo 0) )) -ge "$TTL" ]; then
  build > "$CACHE.tmp" 2>/dev/null && mv -f "$CACHE.tmp" "$CACHE" 2>/dev/null
fi

grep -qxF -- "$IP" "$CACHE" 2>/dev/null && exit 0
exit 1
