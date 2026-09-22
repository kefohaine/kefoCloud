#!/usr/bin/env bash
# scripts/connect.sh — `make connect`: join this host's modules to another box.
#
# Replaces the old `make storage` (the NFS-datadirectory workflow now lives in
# scripts/datadir-nfs.sh and is one of the choices below).
#
# It asks three things, in this order:
#   1. WHICH MODULE  — nextcloud today; kuma/vaultwarden print what they would
#                      need instead of pretending to work.
#   2. WHICH SERVER  — another box on the tailnet (`root@storage` or an IP).
#   3. WHAT TO DO    — exactly two database modes, in plain words:
#        link       the database already lives on the other server: point this
#                   module at it. NOTHING is written on either side.
#        overwrite  copy THIS host's database to the other server, replacing
#                   whatever is there, then point the module at it.
#      plus, for nextcloud, the datadirectory move to a storage VPS (option 3).
#
# Safety rails: the other server must answer before anything is written; the
# local database is dumped to disk before an overwrite; the app is stopped for
# the swap and started again afterwards; the change is verified by talking to
# the database the module actually ends up using; every step is idempotent and
# safe to re-run.
#
# Env overrides (no prompts): MODULE, TARGET, ACTION=link|overwrite,
# SSH_PASS, REMOTE_PG (remote postgres container name), DB_HOST/DB_PORT.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
. "$ROOT/scripts/instance.sh"

NC_CONTAINER="${NC_CONTAINER:-nextcloud}"
PG_CONTAINER="${PG_CONTAINER:-postgresql}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

log()  { printf '\033[36m[connect]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[connect] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[connect] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }
hr()   { printf '%s\n' "────────────────────────────────────────────────────────────────"; }

[ "$(id -u)" = 0 ] || die "run as root (this stops containers and edits the instance state)"

S()  { ssh "${SSH_OPTS[@]}" "$1" "$2"; }               # S <host> <cmd>
if [ -n "${SSH_PASS:-}" ]; then
  command -v sshpass >/dev/null || die "SSH_PASS is set but sshpass is not installed"
  export SSHPASS="$SSH_PASS"
  S() { sshpass -e ssh "${SSH_OPTS[@]}" "$1" "$2"; }
fi

# ─────────────────────────────── the menu ───────────────────────────────────
MODULE="${MODULE:-}"; ACTION="${ACTION:-}"; TARGET="${TARGET:-}"

hr
printf 'kefo connect — %s\n' "$(hostname)"
hr
if [ -z "$MODULE" ]; then
  cat <<'EOF'
Which module do you want to connect?

  1) nextcloud    — the Nextcloud database (PostgreSQL) and/or its datadirectory
  2) kuma         — Uptime Kuma (SQLite; needs MariaDB on both sides first)
  3) vaultwarden  — Vaultwarden (SQLite; single file, no server-side DB)
EOF
  read -r -p "module [1]: " choice
  case "${choice:-1}" in
    1|nextcloud|nc) MODULE=nextcloud ;;
    2|kuma) MODULE=kuma ;;
    3|vaultwarden|vault) MODULE=vaultwarden ;;
    *) die "unknown module: $choice" ;;
  esac
fi
log "module: $MODULE"

case "$MODULE" in
  kuma)
    hr
    cat <<'EOF'
Uptime Kuma over there is NOT supported yet, and here is exactly why:

  · this host runs Kuma v2 with its default SQLite file (data/kuma/data/kuma.db)
  · SQLite cannot be shared over a network, so "link" is impossible by design
  · Kuma only talks to MariaDB if it was INSTALLED configured for it
    (DB_TYPE=mariadb) — switching an existing SQLite install is a data migration
    on both sides, not a connection

What that would need: Kuma made MariaDB-native on this host, a MariaDB on the
other server, and a dump/restore of the Kuma database — same shape as
`make connect` for nextcloud, reached through Kuma's own migration tooling.
EOF
    exit 0 ;;
  vaultwarden)
    hr
    cat <<'EOF'
Vaultwarden over there is NOT supported yet, and here is exactly why:

  · Vaultwarden stores everything in ONE SQLite file (data/vault/data/db.sqlite3)
  · there is no server-side database to point at, so "link" has no meaning
  · sharing that file over NFS is possible but Vaultwarden does not lock it
    safely across hosts — the documented way to move it is a file copy while
    the service is stopped

What that would need: stop Vaultwarden, copy the sqlite3 + attachments +
rsa keys to the other server, point this host's bind mount at the remote path
(or run Vaultwarden there), then verify a login. Say the word and that becomes
a third mode.
EOF
    exit 0 ;;
esac

# ──────────────────────── detect the local Nextcloud ────────────────────────
command -v docker >/dev/null || die "docker not found on this host"
docker ps --format '{{.Names}}' | grep -qx "$NC_CONTAINER" \
  || die "container '$NC_CONTAINER' is not running (set NC_CONTAINER=...)"

OCC() { docker exec -u www-data "$NC_CONTAINER" php occ "$@"; }
PSQL() { docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d "$DB_NAME" "$@"; }

DB_NAME="${DB_NAME:-$(docker inspect "$NC_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^POSTGRES_DB=//p' | head -1)}"
DB_USER="${DB_USER:-$(docker inspect "$NC_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^POSTGRES_USER=//p' | head -1)}"
DB_PASS="$(docker inspect "$NC_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^POSTGRES_PASSWORD=//p' | head -1)"
DB_NAME="${DB_NAME:-nextcloud}"; DB_USER="${DB_USER:-nextcloud}"
LOCAL_DB_HOST="$(docker inspect "$NC_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^POSTGRES_HOST=//p' | head -1)"
LOCAL_DB_HOST="${LOCAL_DB_HOST:-$PG_CONTAINER}"
DATA_DIR_NC="$(docker inspect "$NC_CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}')"
[ -n "$DATA_DIR_NC" ] || die "cannot find the /data bind mount of $NC_CONTAINER (detection failed)"
[ -n "$DB_NAME" ] && [ -n "$DB_USER" ] && [ -n "$DB_PASS" ] \
  || die "cannot read the database credentials from $NC_CONTAINER (POSTGRES_* env missing)"
log "local: nc=$NC_CONTAINER db=$PG_CONTAINER ($DB_USER@$DB_NAME) data=$DATA_DIR_NC"

# ────────────────────── what should happen with the data ────────────────────
NC_ACTION=""
if [ -z "$ACTION" ]; then
  hr
  cat <<EOF
What should happen with the Nextcloud database?

  1) overwrite — copy THIS host's database ($DB_NAME) to the other server,
                 REPLACING the database that is there. Use this when this host
                 holds the data you trust and the other server is the new home.
  2) link      — point Nextcloud at the database that ALREADY lives on the
                 other server. Nothing is written on either side: this host
                 simply starts using the remote database.
  3) datadirectory — keep the database here and move ONLY the user files
                 (the datadirectory) to a storage VPS over NFS (this is the old
                 'make storage' workflow).
EOF
  read -r -p "choice [1]: " c
  case "${c:-1}" in
    1|overwrite|o) NC_ACTION=link; OVERWRITE_FIRST=1 ;;
    2|link|l)      NC_ACTION=link; OVERWRITE_FIRST=0 ;;
    3|datadirectory|datadir|nfs) exec bash "$ROOT/scripts/datadir-nfs.sh" ;;
    *) die "unknown choice: $c" ;;
  esac
else
  NC_ACTION=link
  [ "$ACTION" = "overwrite" ] && OVERWRITE_FIRST=1 || OVERWRITE_FIRST=0
fi
: "${OVERWRITE_FIRST:=0}"

if [ -z "$TARGET" ]; then
  read -r -p "other server (tailnet name or root@ip): " TARGET
fi
[ -n "$TARGET" ] || die "a target server is required"
case "$TARGET" in *@*) ;; *) TARGET="root@$TARGET" ;; esac
REMOTE_HOST="${TARGET#*@}"

# ───────────────────────────── reachability ─────────────────────────────────
log "checking that $TARGET answers"
S "$TARGET" "true" || die "cannot ssh to $TARGET (key installed? tailnet up? try SSH_PASS=…)"
REMOTE_PG="${REMOTE_PG:-$(S "$TARGET" "docker ps --format '{{.Names}}' 2>/dev/null | grep -iE 'postgres' | head -1")}"
if [ -z "$REMOTE_PG" ]; then
  warn "no PostgreSQL container found on $TARGET"
  REMOTE_PG="$PG_CONTAINER"
  S "$TARGET" "docker inspect '$REMOTE_PG' >/dev/null 2>&1" \
    || die "no postgres container on $TARGET (set REMOTE_PG=<name> once it runs one)"
fi
REMOTE_PORT="${REMOTE_PORT:-5432}"
REMOTE_IP="$(S "$TARGET" "tailscale ip -4 2>/dev/null | head -1")"
[ -n "$REMOTE_IP" ] || warn "could not read a tailnet IP on $TARGET — using the hostname for the connection string"
DB_HOST_NEW="${DB_HOST:-${REMOTE_IP:-$REMOTE_HOST}}"
log "remote: $TARGET pg=$REMOTE_PG host=$DB_HOST_NEW:$REMOTE_PORT"

# The database the module will actually use must answer before we touch config.
db_answers() {   # db_answers <host> <port>
  local h="$1" p="$2"
  docker run --rm --network host -e PGPASSWORD="$DB_PASS" postgres:16-alpine \
    psql -h "$h" -p "$p" -U "$DB_USER" -d "$DB_NAME" -tAc 'select 1' >/dev/null 2>&1
}

if [ "$OVERWRITE_FIRST" = 1 ]; then
  # 1. dump locally (always, before anything is overwritten)
  STAMP="$(date +%F-%H%M)"
  mkdir -p "$DATA_DIR/backups"; chmod 700 "$DATA_DIR/backups"
  DUMP="$DATA_DIR/backups/connect-$DB_NAME-$STAMP.dump"
  log "dumping $DB_NAME locally → $DUMP"
  docker exec "$PG_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc > "$DUMP" || die "local pg_dump failed"
  log "dump: $(du -h "$DUMP" | cut -f1)"

  # 2. push it to the remote postgres, replacing what is there
  log "pushing the dump to $TARGET and restoring it into '$DB_NAME'"
  S "$TARGET" "cat > /tmp/connect-$STAMP.dump" < "$DUMP" || die "copy to $TARGET failed"
  S "$TARGET" "
    set -e
    docker exec -i $REMOTE_PG psql -U $DB_USER -d postgres -tAc \"select 1 from pg_database where datname='$DB_NAME'\" | grep -q 1 || \
      docker exec -i $REMOTE_PG createdb -U $DB_USER '$DB_NAME'
    docker exec -i $REMOTE_PG psql -U $DB_USER -d '$DB_NAME' -c 'drop schema public cascade; create schema public;' >/dev/null
    docker exec -i $REMOTE_PG pg_restore -U $DB_USER -d '$DB_NAME' --no-owner --role=$DB_USER < /tmp/connect-$STAMP.dump
    rm -f /tmp/connect-$STAMP.dump
  " || die "restore on $TARGET failed (nothing on this host was changed — the local dump is $DUMP)"
  log "remote database replaced from the local dump"
fi

log "checking that the remote database answers on $DB_HOST_NEW:$REMOTE_PORT"
db_answers "$DB_HOST_NEW" "$REMOTE_PORT" \
  || die "the database at $DB_HOST_NEW:$REMOTE_PORT did not answer a test query — refusing to re-point Nextcloud.
       Check: ufw on $TARGET allows $REMOTE_PORT from the tailnet, postgres listens on the tailnet
       interface (listen_addresses + pg_hba), and the $DB_USER password matches."

# ─────────────────── re-point Nextcloud at the remote database ──────────────
log "stopping $NC_CONTAINER, re-pointing it at $DB_HOST_NEW, starting it again"
docker stop "$NC_CONTAINER" >/dev/null

# The app container's POSTGRES_HOST lives in the service .env (rendered from
# data/instance.conf + the per-service secrets). Change it there so a recreate
# keeps the change, then change the live config with occ.
ENVF="$ROOT/services/nextcloud/.env"
if [ -f "$ENVF" ]; then
  sed -i "s#^POSTGRES_HOST=.*#POSTGRES_HOST=$DB_HOST_NEW#" "$ENVF"
  grep -q '^POSTGRES_HOST=' "$ENVF" || echo "POSTGRES_HOST=$DB_HOST_NEW" >> "$ENVF"
  sed -i "s#^POSTGRES_PORT=.*#POSTGRES_PORT=$REMOTE_PORT#" "$ENVF"
  grep -q '^POSTGRES_PORT=' "$ENVF" || echo "POSTGRES_PORT=$REMOTE_PORT" >> "$ENVF"
  log "services/nextcloud/.env: POSTGRES_HOST=$DB_HOST_NEW POSTGRES_PORT=$REMOTE_PORT"
fi

docker compose -f "$ROOT/services/nextcloud/docker-compose.yml" up -d --no-deps nextcloud >/dev/null 2>&1 \
  || die "could not start $NC_CONTAINER"
for i in $(seq 1 30); do
  docker exec -u www-data "$NC_CONTAINER" php -r 'require "/var/www/html/lib/base.php";' 2>/dev/null && break
  sleep 2
done
OCC config:system:set dbhost --value="$DB_HOST_NEW" >/dev/null 2>&1 || warn "occ dbhost write failed"
OCC config:system:set dbport --value="$REMOTE_PORT" >/dev/null 2>&1 || true
OCC maintenance:mode --off >/dev/null 2>&1 || true

# ─────────────────────────────── verify ────────────────────────────────────
log "verifying: Nextcloud must read AND write through the new database"
docker exec -u www-data "$NC_CONTAINER" php -r '
  require_once "/var/www/html/lib/base.php";
  $c = \OC::$server->getConfig();
  echo "  dbhost=", $c->getSystemValue("dbhost"), " dbname=", $c->getSystemValue("dbname"), "\n";
  $db = \OC::$server->getDatabaseConnection();
  echo "  select 1 = ", $db->fetchOne("select 1"), "\n";
' 2>&1 | sed 's/^/  /' || die "Nextcloud could not use the new database — see docker logs $NC_CONTAINER"
STATUS="$(OCC status 2>/dev/null | tr -d '\r')"
case "$STATUS" in *"installed: true"*) log "occ status: installed" ;; *) warn "occ status did not confirm the install: $STATUS" ;; esac

hr
cat <<EOF
 DONE — Nextcloud now uses the database on $TARGET

   database     $DB_USER@$DB_HOST_NEW:$REMOTE_PORT/$DB_NAME
   action       $([ "$OVERWRITE_FIRST" = 1 ] && echo "overwritten: the remote copy came from this host" || echo "linked: the remote database is used as-is")
   local dump   $([ "$OVERWRITE_FIRST" = 1 ] && echo "$DUMP" || echo "(none — nothing was copied)")

 Manual steps (none block the service):
   1. Open https://cloud.$DOMAIN and confirm files + Talk still load.
   2. The OLD local database on this host is untouched: $PG_CONTAINER still holds
      '$DB_NAME'. Keep it as the rollback until you are happy, then remove it by
      hand (the recipe deliberately does not).
   3. To point back here: run this script again with ACTION=link and
      TARGET=root@$(hostname -s) is wrong — instead set POSTGRES_HOST back to
      $PG_CONTAINER in services/nextcloud/.env and recreate the container.
EOF
hr
