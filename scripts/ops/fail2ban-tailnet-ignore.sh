#!/usr/bin/env bash
# scripts/ops/fail2ban-tailnet-ignore.sh — fail2ban ignorecommand.
#
# Why this exists: every jail bans by SOURCE IP with a host-wide ufw REJECT, but
# the operator's own devices reach Caddy through NAT — the address a jail sees
# is the router's, shared by every browser behind that router. A burst of failed
# logins from one of them (Element Admin retries its token endpoint) therefore
# cut the whole tailnet off from every vhost, not just the app that saw them.
#
# So: an address that is a tailnet peer's own public endpoint is never banned.
# The list comes from fail2ban-tailnet-sync.sh --list (live tailscaled endpoints
# merged with the persisted copy), cached for a minute here because fail2ban
# calls this once per candidate ban. The timer running the same script unbans
# an address that got banned before it appeared on the list.
#
# Usage (from a jail's ignorecommand): script <ip>
#   exit 0 = ignore (never ban), exit 1 = not a tailnet endpoint.
#
# Off-tailnet sources keep the full jail behaviour: same filter, same
# maxretry/findtime/bantime, same ufw ban.

set -uo pipefail

IP="${1:-}"
[ -n "$IP" ] || exit 1

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
CACHE=/run/fail2ban-tailnet-ignore.list
TTL=60

if [ ! -s "$CACHE" ] || [ $(( $(date +%s) - $(stat -c %Y "$CACHE" 2>/dev/null || echo 0) )) -ge "$TTL" ]; then
  "$HERE/fail2ban-tailnet-sync.sh" --list > "$CACHE.tmp" 2>/dev/null \
    && mv -f "$CACHE.tmp" "$CACHE" 2>/dev/null
fi

grep -qxF -- "$IP" "$CACHE" 2>/dev/null && exit 0
exit 1
