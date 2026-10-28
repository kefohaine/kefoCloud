#!/bin/bash
# scripts/modules/beszel-system.sh — register THIS machine in the Beszel hub.
#
# The hub ships no systems, and the CLI has no "create system" command (only
# `superuser`), so a fresh install otherwise ends with a dashboard that monitors
# nothing until a human clicks through the UI. This writes the hub's own record
# into its PocketBase SQLite — the same row the UI would insert.
#
# Everything is DERIVED, never hardcoded: the agent's bridge IP and its SSH port
# come from modules/beszel/docker-compose.yml (the file that defines them), so
# moving the agent or changing LISTEN needs no edit here. Idempotent: an address
# that is already registered is left alone.

set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
DATA_DIR="${DATA_DIR:-$ROOT/data}"
COMPOSE="$ROOT/modules/beszel/docker-compose.yml"
DB="$DATA_DIR/beszel/hub/data.db"

[ -f "$COMPOSE" ] || { echo "beszel-system: missing $COMPOSE" >&2; exit 1; }
[ -f "$DB" ]      || { echo "beszel-system: missing $DB — is the hub module installed?" >&2; exit 1; }
command -v sqlite3 >/dev/null || { echo "beszel-system: sqlite3 is required" >&2; exit 1; }

# The agent's bridge IP: the ipv4_address inside the beszel-agent block. A
# service key is two-space indented and ends the block; every key inside it is
# four-space indented, so the pattern never mistakes `image:` for the next
# service.
host=$(awk '
  /^  beszel-agent:$/ { inblk = 1; next }
  inblk && /^  [A-Za-z0-9_-]+:$/ { inblk = 0 }
  inblk && /ipv4_address:/ { gsub(/[",]/, "", $2); print $2; exit }
' "$COMPOSE")

# The SSH port the agent listens on: LISTEN in its environment.
port=$(awk '
  /^  beszel-agent:$/ { inblk = 1; next }
  inblk && /^  [A-Za-z0-9_-]+:$/ && !/^  beszel-agent:$/ { inblk = 0 }
  inblk && /LISTEN:/ { gsub(/[",]/, "", $2); print $2; exit }
' "$COMPOSE")
port="${port:-45876}"

[ -n "$host" ] || { echo "beszel-system: no ipv4_address found for beszel-agent in $COMPOSE" >&2; exit 1; }

name="$(hostname -s 2>/dev/null || hostname)"
now="$(date -u '+%Y-%m-%d %H:%M:%S.000Z')"

existing=$(sqlite3 "$DB" "SELECT id FROM systems WHERE host='$host' AND port='$port';")
if [ -n "$existing" ]; then
  echo "beszel-system: already registered — $name ($host:$port), id $existing"
else
  # PocketBase's systems columns are created/host/id/info/name/port/status/
  # updated/users; `status` starts 'pending' and the hub's poller flips it to
  # 'up' within its own interval once the SSH handshake to the agent succeeds.
  id="$(printf 'sys%s' "$(openssl rand -hex 6)")"
  sqlite3 "$DB" "INSERT INTO systems (created,host,id,info,name,port,status,updated,users)
                 VALUES ('$now','$host','$id',NULL,'$name','$port','pending','$now','[]');" || {
    echo "beszel-system: insert failed" >&2; exit 1; }
  echo "beszel-system: registered $name ($host:$port)"
fi

# The hub polls on its own; waiting here turns "inserted" into "actually
# reachable", so a wrong key or port fails loudly instead of leaving a silent
# red dot on the dashboard.
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  status=$(sqlite3 "$DB" "SELECT status FROM systems WHERE host='$host' AND port='$port';")
  [ "$status" = "up" ] && { echo "beszel-system: $name is up"; exit 0; }
  sleep 5
done
echo "beszel-system: $name still '$status' after 60s — check 'docker logs beszel-agent' (the agent must hold the hub's public key: make beszel-key)" >&2
exit 1
