#!/bin/bash
# kuma-import.sh — import a Uptime Kuma DB from another host (e.g. the old
# $GITHUB_USER VPS) into uptimekuma, adapting it to the current stack.
#
# The old host is not reachable from this VPS (SSH keys denied, Tailscale
# SSH off, no taildrop inbox), so the operator must deliver the DB:
#   on the sending box:  tailscale file cp kuma.db $NODE_NAME:
#   here:                tailscale file get $ROOT/data/kuma/import
# then run:  make kuma-import        (defaults to kuma/import/kuma.db)
#        or:  make kuma-import KUMA_DB=/path/to/kuma.db
#
# The source DB should be quiesced (stop the old kuma, or `sqlite3 kuma.db
# ".backup out.db"`) so the copy is not mid-WAL.
#
# What the script does:
#   1. stops uptimekuma, backs up the current db, swaps the imported db in
#   2. starts uptimekuma and waits for it to migrate the schema on boot
#   3. adapts monitors: $DOMAIN -> $DOMAIN URLs, old docker container
#      names -> current names, deactivates monitors for retired services
#   4. re-runs modules/uptimekuma/seed-monitors.sql (idempotent) so the
#      current container set's monitors/groups exist
#
# Run via `make kuma-import`; requires docker + sqlite3 in uptimekuma.

. "$(dirname "$(readlink -f "$0")")/../lib/instance.sh" 2>/dev/null || true

set -euo pipefail

# The checkout path is DERIVED from this script's location — never
# hardcoded — so the repo can live anywhere and be renamed
# ($NODE_NAME -> kefoServer) without editing any script.
REPO="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
KUMA_DATA=$ROOT/data/kuma/data
IMPORT_DIR=$ROOT/data/kuma/import
SRC="${1:-$IMPORT_DIR/kuma.db}"
STAMP=$(date +%Y%m%d-%H%M%S)

[ -f "$SRC" ] || { echo "source db not found: $SRC"; exit 1; }

sudo mkdir -p "$IMPORT_DIR"

echo "-> stopping uptimekuma"
docker stop uptimekuma

echo "-> backing up current db"
sudo cp "$KUMA_DATA/kuma.db" "$IMPORT_DIR/kuma.db.pre-import-$STAMP"
sudo rm -f "$KUMA_DATA/kuma.db-wal" "$KUMA_DATA/kuma.db-shm"

echo "-> installing imported db"
sudo cp "$SRC" "$KUMA_DATA/kuma.db"
# Ownership stays root:root — matches how the live db is created and how
# the container (running as root) writes it. Do not chown to 1000 here.

echo "-> starting uptimekuma (schema migration on boot)"
docker start uptimekuma

for i in $(seq 1 30); do
  if docker exec uptimekuma sqlite3 /app/data/kuma.db "SELECT 1;" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
sleep 5

echo "-> adapting monitors to the $DOMAIN stack"
docker exec uptimekuma sqlite3 /app/data/kuma.db <<'SQL'
-- domain swap in monitor URLs
UPDATE monitor SET url = replace(url, '$DOMAIN', '$DOMAIN') WHERE url LIKE '%$DOMAIN%';
-- caddy container renamed vhosts -> $DOMAIN
UPDATE monitor SET name = 'docker: caddy', docker_container = 'caddy' WHERE name = 'docker: vhosts';
-- retired services (share, homer, api, www): keep history, stop checking
UPDATE monitor SET active = 0 WHERE name IN
  ('docker: share-flask','docker: homer',
   'http: share','http: www','http: api');
-- docker host entry points at the local socket
UPDATE docker_host SET docker_type = 'socket', docker_daemon = '/var/run/docker.sock' WHERE name = 'local';
SQL

echo "-> seeding current container monitors"
docker exec -i uptimekuma sqlite3 /app/data/kuma.db < "$REPO/modules/uptimekuma/seed-monitors.sql"

echo "done. verify at https://kuma.$DOMAIN — old account/status pages are in;"
echo "backup of the pre-import db: $IMPORT_DIR/kuma.db.pre-import-$STAMP"
