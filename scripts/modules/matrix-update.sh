#!/usr/bin/env bash
# scripts/modules/matrix-update.sh — recreate MAS (and Synapse) with a safety net.
#
# MAS applies its database migrations on start and a downgrade means restoring
# a dump, so this is the ONE path for a version change: take a real backup,
# validate it, recreate MAS, wait for healthy, then Synapse. The image tag is
# the version record (modules/matrix/docker-compose.yml); a rollback is that
# tag reverted plus the dump restored.
#
# Run via `make matrix-update CONFIRM=yes` (operator action).
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/instance.sh"

COMPOSE="$REPO_DIR/modules/matrix/docker-compose.yml"
ENV="$REPO_DIR/modules/matrix/.env"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$DATA_DIR/matrix/backups"
DUMP="$BACKUP_DIR/mas-$STAMP.sql.gz"

[ -f "$ENV" ] || { echo "matrix-update: $ENV is missing — run 'make matrix-gen'" >&2; exit 1; }
# shellcheck disable=SC1090
. "$ENV"
[ -n "${DATA_DIR:-}" ] || { echo "matrix-update: DATA_DIR is empty in $ENV" >&2; exit 1; }

if [ "${CONFIRM:-}" != yes ]; then
  cat >&2 <<EOF
matrix-update: this recreates matrix-mas (its schema migrates on start) and then
matrix-synapse, after dumping the MAS database to $DUMP.
Re-run with CONFIRM=yes to proceed.
EOF
  exit 1
fi

say() { printf 'matrix-update: %s\n' "$*" >&2; }

mkdir -p "$BACKUP_DIR" || { echo "matrix-update: cannot create $BACKUP_DIR" >&2; exit 1; }
chmod 700 "$BACKUP_DIR"

say "dumping the MAS database to $DUMP"
docker exec matrix-mas-db pg_dump -U mas -d mas | gzip >"$DUMP" \
  || { echo "matrix-update: the MAS dump failed — nothing was recreated" >&2; rm -f "$DUMP"; exit 1; }
gzip -t "$DUMP" || { echo "matrix-update: $DUMP is not a valid gzip — nothing was recreated" >&2; exit 1; }
chmod 600 "$DUMP"
say "backup ok ($(du -h "$DUMP" | cut -f1))"

say "recreating matrix-mas (migrations run on start)"
docker compose -f "$COMPOSE" pull matrix-mas >&2 || { echo "matrix-update: image pull failed — the old container is untouched" >&2; exit 1; }
docker compose -f "$COMPOSE" up -d --force-recreate matrix-mas >&2 \
  || { echo "matrix-update: matrix-mas did not start; restore with: zcat $DUMP | docker exec -i matrix-mas-db psql -U mas -d mas" >&2; exit 1; }

say "waiting for matrix-mas to report healthy"
for i in $(seq 1 60); do
  h=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' matrix-mas 2>/dev/null)
  [ "$h" = healthy ] && break
  [ "$h" = unhealthy ] && break
  sleep 3
done
if [ "$h" != healthy ]; then
  echo "matrix-update: matrix-mas is '$h' — see: docker logs matrix-mas" >&2
  echo "matrix-update: rollback: revert the image tag in $COMPOSE, recreate matrix-mas, then: zcat $DUMP | docker exec -i matrix-mas-db psql -U mas -d mas" >&2
  exit 1
fi

say "recreating matrix-synapse"
docker compose -f "$COMPOSE" up -d --force-recreate matrix-synapse >&2 \
  || { echo "matrix-update: matrix-synapse did not start — see: docker logs matrix-synapse" >&2; exit 1; }

say "waiting for matrix-synapse /health"
for i in $(seq 1 40); do
  curl -fsS --max-time 3 http://127.0.0.1:8008/health >/dev/null 2>&1 && break
  docker exec matrix-synapse python3 -c 'import urllib.request;urllib.request.urlopen("http://127.0.0.1:8008/health", timeout=3)' >/dev/null 2>&1 && break
  sleep 3
done

say "done — verify a login from Element and Element Admin, then: make smoke"
say "backup kept at $DUMP (restore: zcat $DUMP | docker exec -i matrix-mas-db psql -U mas -d mas)"
