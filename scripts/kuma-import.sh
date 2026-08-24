#!/bin/bash
# kuma-import.sh — import a Uptime Kuma DB from another host (e.g. the old
# jehpok VPS) into ut-kuma, adapting it to the current stack.
#
# The old host is not reachable from this VPS (SSH keys denied, Tailscale
# SSH off, no taildrop inbox), so the operator must deliver the DB:
#   on jehpok:  tailscale file cp kuma.db fxmq:    (or scp once a key exists)
#   on fxmq:    tailscale file get /var/www/custom/projects/homelab/kuma/import
# then run:  make kuma-import        (defaults to kuma/import/kuma.db)
#        or:  make kuma-import KUMA_DB=/path/to/kuma.db
#
# The source DB should be quiesced (stop the old kuma, or `sqlite3 kuma.db
# ".backup out.db"`) so the copy is not mid-WAL.
#
# What the script does:
#   1. stops ut-kuma, backs up the current db, swaps the imported db in
#   2. starts ut-kuma and waits for it to migrate the schema on boot
#   3. adapts monitors: jehpok.com -> fxmq.net URLs, old docker container
#      names -> current names, deactivates monitors for retired services
#   4. re-runs services/ut-kuma/seed-monitors.sql (idempotent) so the
#      current container set's monitors/groups exist
#
# Run via `make kuma-import`; requires docker + sqlite3 in ut-kuma.

set -euo pipefail

REPO=/var/www/custom/projects/homelab/repo
KUMA_DATA=/var/www/custom/projects/homelab/kuma/data
IMPORT_DIR=/var/www/custom/projects/homelab/kuma/import
SRC="${1:-$IMPORT_DIR/kuma.db}"
STAMP=$(date +%Y%m%d-%H%M%S)

[ -f "$SRC" ] || { echo "source db not found: $SRC"; exit 1; }

sudo mkdir -p "$IMPORT_DIR"

echo "-> stopping ut-kuma"
docker stop ut-kuma

echo "-> backing up current db"
sudo cp "$KUMA_DATA/kuma.db" "$IMPORT_DIR/kuma.db.pre-import-$STAMP"
sudo rm -f "$KUMA_DATA/kuma.db-wal" "$KUMA_DATA/kuma.db-shm"

echo "-> installing imported db"
sudo cp "$SRC" "$KUMA_DATA/kuma.db"
# Ownership stays root:root — matches how the live db is created and how
# the container (running as root) writes it. Do not chown to 1000 here.

echo "-> starting ut-kuma (schema migration on boot)"
docker start ut-kuma

for i in $(seq 1 30); do
  if docker exec ut-kuma sqlite3 /app/data/kuma.db "SELECT 1;" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
sleep 5

echo "-> adapting monitors to the fxmq.net stack"
docker exec ut-kuma sqlite3 /app/data/kuma.db <<'SQL'
-- domain swap in monitor URLs
UPDATE monitor SET url = replace(url, 'jehpok.com', 'fxmq.net') WHERE url LIKE '%jehpok.com%';
-- caddy container renamed vhosts -> fxmq.net
UPDATE monitor SET name = 'docker: fxmq.net', docker_container = 'fxmq.net' WHERE name = 'docker: vhosts';
-- retired services (mc, share, homer, api, www): keep history, stop checking
UPDATE monitor SET active = 0 WHERE name IN
  ('docker: mc','docker: mc-flask','docker: share-flask','docker: homer',
   'http: mc','http: share','http: www','http: api');
-- docker host entry points at the local socket
UPDATE docker_host SET docker_type = 'socket', docker_daemon = '/var/run/docker.sock' WHERE name = 'local';
SQL

echo "-> seeding current container monitors"
docker exec -i ut-kuma sqlite3 /app/data/kuma.db < "$REPO/services/ut-kuma/seed-monitors.sql"

echo "done. verify at https://status.fxmq.net — old account/status pages are in;"
echo "backup of the pre-import db: $IMPORT_DIR/kuma.db.pre-import-$STAMP"
