#!/usr/bin/env bash
#
# scripts/mail-gen.sh — create a mailbox (or a random "disposable" one).
# Every field auto-generates when left empty:
#   MAIL:  random 7-letter local part (or use a custom address / local part)
#   PWD:   random 16-char password (or use a custom one) — printed once
#   QUOTA: the default quota from services/mailserver/default-quota
# The password is fed via stdin so it never lands in shell history or the
# process list. Credentials print once and are stored nowhere else.
#
# Usage: mail-gen.sh [MAIL] [PWD] [QUOTA]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_QUOTA=$(cat "$SCRIPT_DIR/../services/mailserver/default-quota" 2>/dev/null || echo 1G)

MAIL="${1:-}"
PWD="${2:-}"
QUOTA="${3:-}"
[ -n "$MAIL" ] || MAIL=$(tr -dc 'a-z' < /dev/urandom | head -c 7)
case "$MAIL" in *@*) ;; *) MAIL="$MAIL@fxmq.net" ;; esac
[ -n "$PWD" ] || PWD=$(openssl rand -base64 12 | tr -d '\n')
[ -n "$QUOTA" ] || QUOTA="$DEFAULT_QUOTA"

printf '%s\n%s\n' "$PWD" "$PWD" | docker exec -i mailserver setup email add "$MAIL" >/dev/null
docker exec mailserver setup quota set "$MAIL" "$QUOTA" >/dev/null

echo "info:  mailbox $MAIL created — password: $PWD, quota: $QUOTA, webmail https://mail.fxmq.net (login with the local part)"
