#!/usr/bin/env bash
# goose-secret.sh — rotate GOOSE_SERVER__SECRET_KEY in $DATA_DIR/goose/.env.
#
# The key signs the agent's server sessions and used to be sed'ed into the
# tracked unit, so real values are in git history (issue #15). Rotation here
# changes the live key only: the .env is regenerated in place (other lines are
# preserved), the unit's EnvironmentFile= picks it up on restart, and every
# client that paired with the old key must be re-paired.
#
# Purging the value from git history is a separate, operator-only rewrite
# (filter-repo + force-push) — never something a script does silently.
#
# Usage: scripts/ops/goose-secret.sh          (sudo; the .env is root:root 0600)
#        DRYRUN=1 scripts/ops/goose-secret.sh  (or --dry-run: print the plan,
#        mint and write nothing)
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/../lib/instance.sh"

# Plan mode (--dry-run / DRYRUN=1): the gate below prints the plan, mints nothing.
. "$(dirname "$(readlink -f "$0")")/../lib/dryrun.sh"

ENVF="$DATA_DIR/goose/.env"

[ "$(id -u)" -eq 0 ] || { echo "goose-secret: run as root (sudo make goose-secret)" >&2; exit 1; }

dryrun_wanted "$@" && DRY=1

if [ "${DRY:-0}" = 1 ]; then
  dryrun_plan "rotate GOOSE_SERVER__SECRET_KEY in $ENVF (random 32-byte hex, printed once on a real run; every other line preserved)"
  dryrun_plan "restart goose so the unit's EnvironmentFile= picks up the new key (every paired client must re-pair)"
  dryrun_end
fi

key="$(openssl rand -hex 32)"

install -d -m 0700 "$DATA_DIR/goose"
if [ -f "$ENVF" ]; then
  # Keep every other line (token policy, etc.); replace just the one key.
  tmp="$(mktemp)"
  grep -v '^GOOSE_SERVER__SECRET_KEY=' "$ENVF" > "$tmp" || true
  printf 'GOOSE_SERVER__SECRET_KEY=%s\n' "$key" >> "$tmp"
  install -m 0600 -o root -g root "$tmp" "$ENVF"
  rm -f "$tmp"
else
  printf 'GOOSE_SERVER__SECRET_KEY=%s\n' "$key" > "$ENVF"
  chmod 0600 "$ENVF"
fi

systemctl restart goose
echo "goose-secret: rotated — goose restarted; re-pair every client (printed once, not stored):"
echo "$key"
