#!/usr/bin/env bash
# scripts/modules/matrix-identity.sh — rebuild the homeserver's identity store.
#
# DESTRUCTIVE, on purpose: it drops the Synapse and MAS databases, deletes the
# signing key and regenerates homeserver.yaml, so every account, room, device
# and session is gone. What survives is the configuration that names the
# deployment — the server_name (matrix.$DOMAIN), the secrets already in
# modules/matrix/.env, and the one admin account it re-creates at the end.
#
# This is the only supported way to change the server_name of a running
# homeserver: user ids are @name:<server_name>, so renaming is a wipe, never an
# edit. Requires CONFIRM=delete-accounts (the literal words, nothing else).
#
#   make matrix-reset CONFIRM=delete-accounts
#   DRYRUN=1 bash scripts/modules/matrix-identity.sh CONFIRM=delete-accounts   (plan only)
#
# --dry-run / DRYRUN=1 prints the plan and exits 0: CONFIRM is still required,
# so a plan run still refuses without it. Nothing is dropped or deleted.
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/instance.sh"
. "$(dirname "$(readlink -f "$0")")/../lib/dryrun.sh"

[ "${CONFIRM:-}" = delete-accounts ] || {
  echo "matrix-identity: refusing — re-run with CONFIRM=delete-accounts (this deletes every account, room and session)" >&2
  exit 1
}

COMPOSE="$REPO_DIR/modules/matrix/docker-compose.yml"
ENV="$REPO_DIR/modules/matrix/.env"
SYN="$DATA_DIR/matrix/synapse"
MAS="$DATA_DIR/matrix/mas"

[ -f "$ENV" ] || { echo "matrix-identity: $ENV is missing — run 'make matrix-gen'" >&2; exit 1; }
# shellcheck disable=SC1090
. "$ENV"
[ -n "${DOMAIN:-}" ] || { echo "matrix-identity: DOMAIN is empty in $ENV" >&2; exit 1; }
[ -n "${DATA_DIR:-}" ] || { echo "matrix-identity: DATA_DIR is empty in $ENV" >&2; exit 1; }

dryrun_wanted "$@" && DRY=1

say() { printf 'matrix-identity: %s\n' "$*" >&2; }

if [ "${DRY:-0}" = 1 ]; then
  _keys=$(ls "$SYN"/*.signing.key 2>/dev/null | paste -sd' ' -)
  dryrun_plan "stop matrix-synapse, matrix-mas, matrix-element and element-admin"
  dryrun_plan "start matrix-db and matrix-mas-db"
  dryrun_plan "drop and re-create the Synapse database \"$POSTGRES_DB\" (owner $POSTGRES_USER) on matrix-db"
  dryrun_plan "drop and re-create the MAS database \"mas\" (owner mas) on matrix-mas-db"
  dryrun_plan "delete $SYN/homeserver.yaml and the signing key(s) ${_keys:-$SYN/*.signing.key}"
  dryrun_plan "delete $DATA_DIR/matrix/element/config.json and $DATA_DIR/matrix/mas/config.yaml"
  dryrun_plan "regenerate that configuration with matrix-gen.sh under server_name matrix.$DOMAIN"
  dryrun_plan "start the whole chat stack: docker compose -f $COMPOSE up -d"
  dryrun_plan "re-create the single admin account @$SYNAPSE_ADMIN_USER:matrix.$DOMAIN in MAS (its password is read from $ENV and is never printed)"
  dryrun_end "nothing changed — every account, room, device and session is still there"
fi

say "stopping the chat stack"
docker compose -f "$COMPOSE" stop matrix-synapse matrix-mas matrix-element element-admin >/dev/null 2>&1 || true
docker compose -f "$COMPOSE" up -d matrix-db matrix-mas-db >/dev/null 2>&1 || { echo "matrix-identity: the databases did not start" >&2; exit 1; }

say "waiting for PostgreSQL"
for _ in $(seq 1 30); do
  docker exec matrix-db pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1 \
    && docker exec matrix-mas-db pg_isready -U mas -d mas >/dev/null 2>&1 && break
  sleep 2
done

say "dropping the Synapse and MAS databases"
docker exec matrix-db psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 \
  -c "drop database if exists \"$POSTGRES_DB\" with (force);" \
  -c "create database \"$POSTGRES_DB\" owner \"$POSTGRES_USER\";" >/dev/null 2>&1 \
  || { echo "matrix-identity: could not reset the Synapse database" >&2; exit 1; }
docker exec matrix-mas-db psql -U mas -d postgres -v ON_ERROR_STOP=1 \
  -c "drop database if exists mas with (force);" \
  -c "create database mas owner mas;" >/dev/null 2>&1 \
  || { echo "matrix-identity: could not reset the MAS database" >&2; exit 1; }

say "removing the signing key, homeserver.yaml and the Element and MAS configs"
rm -f "$SYN/homeserver.yaml" "$SYN"/*.signing.key \
  "$DATA_DIR/matrix/element/config.json" "$DATA_DIR/matrix/mas/config.yaml"

say "regenerating the configuration under server_name matrix.$DOMAIN"
bash "$REPO_DIR/scripts/modules/matrix-gen.sh" || { echo "matrix-identity: matrix-gen failed" >&2; exit 1; }

say "starting the stack"
docker compose -f "$COMPOSE" up -d >/dev/null 2>&1 || { echo "matrix-identity: the stack did not start" >&2; exit 1; }

say "waiting for the homeserver"
for _ in $(seq 1 120); do
  docker exec matrix-synapse python3 -c 'import urllib.request,sys; sys.exit(0 if urllib.request.urlopen("http://127.0.0.1:8008/health").status == 200 else 1)' >/dev/null 2>&1 && break
  sleep 2
done

say "re-creating the one admin account in MAS"
docker exec matrix-mas mas-cli manage -c /data/config.yaml register-user \
  --yes -a -p "$SYNAPSE_ADMIN_PASSWORD" "$SYNAPSE_ADMIN_USER" >/dev/null 2>&1 \
  || say "admin registration refused (it may already exist)"

if docker exec matrix-mas-db psql -U mas -d mas -tAc \
    "select username from users where username='$SYNAPSE_ADMIN_USER'" 2>/dev/null \
    | grep -qx "$SYNAPSE_ADMIN_USER"; then
  say "done — the only account is @${SYNAPSE_ADMIN_USER}:matrix.$DOMAIN (password in $ENV)"
else
  echo "matrix-identity: the admin account was not created — see: docker logs matrix-mas" >&2
  exit 1
fi
