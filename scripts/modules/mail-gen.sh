#!/usr/bin/env bash
#
# scripts/modules/mail-gen.sh — create a mailbox (or a random "disposable" one)
# on the Mailu platform. Every field auto-generates when left empty:
#   MAIL:  random 7-letter local part (or use a custom address / local part)
#   PWD:   random 16-char password (or use a custom one) — printed once
#   QUOTA: the default quota from modules/mailserver/default-quota
# The password is passed as an argument to the Mailu CLI inside the container
# (never on the host shell's process list for long). Credentials print once and
# are stored nowhere else.
#
# Usage: mail-gen.sh [MAIL] [PWD] [QUOTA]

. "$(dirname "$(readlink -f "$0")")/../lib/instance.sh" 2>/dev/null || true

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_QUOTA=$(cat "$SCRIPT_DIR/../../modules/mailserver/default-quota" 2>/dev/null || echo 1G)

MAIL="${1:-}"
PWD="${2:-}"
QUOTA="${3:-}"
[ -n "$MAIL" ] || MAIL=$(tr -dc 'a-z' < /dev/urandom | head -c 7)
case "$MAIL" in *@*) ;; *) MAIL="$MAIL@$DOMAIN" ;; esac
[ -n "$PWD" ] || PWD=$(openssl rand -base64 12 | tr -d '\n')
[ -n "$QUOTA" ] || QUOTA="$DEFAULT_QUOTA"

localpart="${MAIL%@*}"; dom="${MAIL#*@}"
docker exec mailu-admin flask mailu domain "$dom" >/dev/null 2>&1 || true
docker exec mailu-admin flask mailu user "$localpart" "$dom" "$PWD" >/dev/null || exit 1
raw=${QUOTA%B}
bytes=$(numfmt --from=iec "$raw" 2>/dev/null || echo "$raw")
case "$bytes" in ''|*[!0-9]*) bytes=1000000000 ;; esac
# config-update sets the password from password_hash and a missing hash means
# password=None → NOT NULL violation → the WHOLE transaction (quota included)
# rolls back silently. Carry the hash the CLI just stored, or the quota never
# lands and every mailbox keeps the model default (2026-10-19).
hash=$(docker exec mailu-admin flask mailu config-export -j 2>/dev/null \
  | jq -r --arg e "$MAIL" '.user[]? | select(.email==$e) | .password // empty' | head -1)
if [ -n "$hash" ]; then
  printf 'users:\n  - localpart: %s\n    domain: %s\n    quota_bytes: %s\n    password_hash: %s\n' \
    "$localpart" "$dom" "$bytes" "$hash" \
    | docker exec -i mailu-admin flask mailu config-update >/dev/null 2>&1 || true
fi

echo "info:  mailbox $MAIL created — password: $PWD, quota: $QUOTA, webmail https://cube.$DOMAIN (login with the local part)"
