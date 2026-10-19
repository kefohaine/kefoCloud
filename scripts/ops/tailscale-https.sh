#!/usr/bin/env bash
# scripts/ops/tailscale-https.sh — serve the tail door over Tailscale HTTPS.
#
# SOLE PURPOSE: expose tail.$DOMAIN through `tailscale serve` HTTPS when the
# Let's Encrypt order for that name cannot complete (typically the LE
# per-identifier rate limit, or the name not resolving publicly). The web
# address then CHANGES by design: the door is no longer reached at
# https://tail.$DOMAIN but at https://<machine>.<tailnet>.ts.net — Tailscale
# issues and renews that cert itself, no rate limit applies.
#
# Idempotent: re-running replaces the previous serve config. No prompts.
#
# Usage (as root):
#   bash scripts/ops/tailscale-https.sh

. "$(dirname "$(readlink -f "$0")")/../lib/instance.sh" 2>/dev/null \
  || { [ -f data/instance.conf ] && . ./data/instance.conf; }
: "${DOMAIN:?DOMAIN missing — run from the repo root or source data/instance.conf}"

set -uo pipefail

if ! command -v tailscale >/dev/null 2>&1; then
  echo "FAIL: tailscale is not installed" >&2
  exit 1
fi

# Tailscale itself must be up — serve is a local API call, no tailnet traffic
# needed, but `tailscaled` must answer.
if ! tailscale status >/dev/null 2>&1; then
  echo "FAIL: tailscaled is not answering (systemctl start tailscaled?)" >&2
  exit 1
fi

# https+insecure: the origin (the local Caddy edge on 127.0.0.1:443) may still
# present its local-CA or a not-yet-issued chain — tailscale serve must proxy
# regardless of the origin cert, since THIS script exists precisely because
# that cert is not trusted yet.
if tailscale serve --bg --https 443 "https+insecure://127.0.0.1:443" 2>&1; then
  echo ""
  echo "SUCCESS — tail door served over Tailscale HTTPS."
  echo "  web address: $(tailscale serve status 2>/dev/null | grep -o 'https://[^ ]*' | head -1)"
  echo "  (the tail.$DOMAIN name itself is NOT used — the address is the machine's ts.net name)"
  echo "  re-check later: once the LE order succeeds, undo with: tailscale serve --https 443 off"
  exit 0
else
  echo "FAIL: tailscale serve rejected the config — see the output above" >&2
  exit 1
fi
