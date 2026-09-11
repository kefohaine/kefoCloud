#!/usr/bin/env bash
#
# scripts/tail-auth.sh — manage the tail.$DOMAIN HTTP basic-auth credential.
#
# The tail vhost is gated by two ordered layers: non-tailnet sources get 403,
# and every request (tailnet included) needs HTTP basic auth — because /ttyd is
# a full `op` shell and `op` has passwordless sudo. This script sets/rotates
# that credential and never prints the password.
#
# Usage: tail-auth.sh set [user] [password]
#   user defaults to `op`; the password is generated when omitted. The script
#   rewrites the basic_auth block, validates it in the running Caddy container
#   (reverting on failure), restarts Caddy, verifies an authenticated request and
#   PRINTS the credential once on the terminal — no password file is left behind.
#   The vhost is a repo file — review and commit the change afterwards.

set -uo pipefail

[ "${1:-set}" = set ] || { echo "usage: tail-auth.sh set [user] [password]"; exit 1; }
shift || true

VHOST="$(ls services/*/vhosts/tail.*.caddy 2>/dev/null | head -1)"
[ -n "$VHOST" ] || { echo "error: no services/*/vhosts/tail.*.caddy found (run from the repo root)"; exit 1; }
DOMAIN="$(basename "$VHOST" .caddy | sed 's/^tail\.//')"
UNAME="${1:-op}"
PASS="${2:-}"
[ -n "$PASS" ] || PASS="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"

docker ps --format '{{.Names}}' | grep -qx "$DOMAIN" || { echo "error: caddy container '$DOMAIN' is not running"; exit 1; }
HASH="$(docker exec "$DOMAIN" caddy hash-password --plaintext "$PASS" 2>/dev/null)"
[ -n "$HASH" ] || { echo "error: caddy hash-password failed"; exit 1; }

BAK="$(mktemp)"; cp -a "$VHOST" "$BAK"
python3 - "$VHOST" "$UNAME" "$HASH" <<'PYEOF' || { echo "error: could not rewrite the basic_auth block"; rm -f "$BAK"; exit 1; }
import re, sys
path, user, h = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
new, n = re.subn(r'(basic_auth\s*\{)(.*?)(\})',
                 lambda m: m.group(1) + "\n            %s %s\n        " % (user, h) + m.group(3),
                 src, count=1, flags=re.S)
if n != 1:
    sys.exit(1)
open(path, "w").write(new)
print("info:  basic_auth block updated for user '%s'" % user)
PYEOF

if ! docker exec "$DOMAIN" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
  cp -a "$BAK" "$VHOST"; rm -f "$BAK"
  echo "error: Caddyfile invalid after the change — vhost reverted, Caddy not reloaded"; exit 1
fi
rm -f "$BAK"

# The credential is printed here, once, at creation time — nothing is written to
# disk (no password files left lying around on the server).
sudo rm -f /root/tail-basic-auth.txt   # retire the old file-based pattern if present
echo ""
echo "=============================================================="
echo " tail.$DOMAIN — HTTP basic auth"
echo "   user:     $UNAME"
echo "   password: $PASS"
echo " (shown once — copy it now; rotate any time with: make tail-auth)"
echo "=============================================================="
echo ""

docker restart "$DOMAIN" >/dev/null
sleep 3
ip="$(tailscale ip -4 2>/dev/null | head -1)"
if [ -n "$ip" ]; then
  code="$(curl -sk -o /dev/null -w '%{http_code}' -u "$UNAME:$PASS" --resolve "tail.$DOMAIN:443:$ip" "https://tail.$DOMAIN/" 2>/dev/null)"
  if [ "$code" = 200 ]; then echo "info:  verified — authenticated request returned 200"
  else echo "warn:  authenticated request returned $code (expected 200)"; fi
fi
echo "info:  review + commit the vhost change: $VHOST"
