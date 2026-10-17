#!/usr/bin/env bash
#
# scripts/ops/restore-data.sh — `make import-backups TAILDROP=<device>`:
# restore module data from backups taildropped to the device's ~/backups/.
#
#   make import-backups TAILDROP=<tailnet-device>   [BACKUP_LAND_DIR=<path>]
#
# - Queries the device for bundles (nextcloud-backup-*.tar.gz,
#   other-backup-*.tar.gz) AND raw datadirectories (nextcloud-*/ , others-*/)
#   written by `make backup` (bundle / raw mode).
# - Always previews what's available, which modules they cover, and what would
#   be restored/overridden, then requires a typed yes before touching anything.
# - Stops all non-caddy containers, restores, then restarts containers (ownership
#   comes from the live system). No DRYRUN flag: the preview + confirmation IS
#   the dry run.
# - Caddy is NEVER touched (stop or restart) — it is explicitly excluded.
#
# Vars: TAILDROP (required), BACKUP_LAND_DIR (default 'backups').
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
DATA="$ROOT/data"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

log()  { printf '\033[36m[import]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[import] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[import] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }

S() { ssh "${SSH_OPTS[@]}" "$1" "$2"; }

peer_ip() {
  local dev="$1"
  tailscale status 2>/dev/null | awk -v d="$dev" '{ if (index($2,d)>0) { print $1; exit } }'
}

# aggregate content fingerprint of a directory tree (mirrors backup-bundles.sh):
# used to verify the raw datadirectories, which have no single tarball to hash.
agg_local()  { ( cd "$1" && find -L . -type f -printf '%P\n' | sort \
  | while IFS= read -r f; do sha256sum "$f"; done | sha256sum | awk '{print $1}' ); }
agg_remote() { S "$1" "cd '$2' && find -L . -type f -printf '%P\n' | sort \
  | while IFS= read -r f; do sha256sum \"\$f\"; done | sha256sum | awk '{print \$1}'"; }

TAILDROP="${TAILDROP:-}"
[ -n "$TAILDROP" ] || {
  echo "make import-backups requires TAILDROP=<tailnet device>:"
  echo "  make import-backups TAILDROP=<device>  preview + restore backups from that device"
  exit 1
}

case "$TAILDROP" in *@*) DEV="${TAILDROP#*@}"; DEV_USER="${TAILDROP%@*}";; *) DEV="$TAILDROP"; DEV_USER="root";; esac
[ "$DEV_USER" = "root" ] || die "only root@host taildrop targets are accepted ($DEV_USER)"
case "$DEV" in
  *[!0-9.]* ) TS_IP="$(peer_ip "$DEV")";;
  * ) TS_IP="$DEV";;
esac
[ -n "$TS_IP" ] || die "taildrop device '$DEV' is not on the tailnet (no peer by that name/IP)"
DEV_SSH="root@$TS_IP"
S "$DEV_SSH" "true" || die "cannot ssh to the taildrop device $DEV_SSH over the tailnet"
LAND_DIR="${BACKUP_LAND_DIR:-backups}"

# bundles are files, raw backups are dirs — discovery uses globs, never a date.
LIST="$S "$DEV_SSH" 'ls -1d ~/$LAND_DIR/*-backup-*.tar.gz ~/$LAND_DIR/nextcloud-*/ ~/$LAND_DIR/others-*/ 2>/dev/null'"

declare -A ITEM_PATH=()
declare -A ITEM_TYPE=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  name="$(basename "$line")"
  ITEM_PATH["$name"]="$line"
  case "$name" in
    nextcloud-backup-*.tar.gz|other-backup-*.tar.gz) ITEM_TYPE["$name"]=bundle ;;
    nextcloud-*|others-*)                            ITEM_TYPE["$name"]=raw ;;
  esac
done <<< "$LIST"

[ ${#ITEM_PATH[@]} -gt 0 ] || die "no backups found on $DEV_SSH:~/$LAND_DIR/ (make sure make backup was run there)"

hr
printf 'backups on %s:~/%s/:\n' "$DEV_SSH" "$LAND_DIR"
hr
for name in "${!ITEM_PATH[@]}"; do
  printf '  [%s] %s\n' "${ITEM_TYPE[$name]}" "$name"
done

show_plan() {
  echo
  hr
  echo "coverage:"
  for name in "${!ITEM_PATH[@]}"; do
    case "$name" in
      nextcloud-*) printf '  %-28s →  postgresql DB + cloud datadir\n' "$name" ;;
      other-*)     printf '  %-28s →  vault, mailserver, kuma datadirs\n' "$name" ;;
      others-*)    printf '  %-28s →  vault, mailserver, kuma datadirs\n' "$name" ;;
    esac
  done
  echo "restore target (live): $DATA/"
  echo "containers that will be stopped (caddy is NEVER touched): $(docker ps --format '{{.Names}}' | grep -v '^caddy' | tr '\n' ' ')"
}

show_plan

printf 'select backups to import (comma-separated names; leave empty to import all listed):\n> '
read -r -p "" -e sel || die "selection cancelled"

declare -a TO_IMPORT=()
for name in "${!ITEM_PATH[@]}"; do
  if [ -z "$sel" ] || echo "$sel" | tr ',' '\n' | grep -qx "$name"; then
    TO_IMPORT+=("$name")
  fi
done
[ ${#TO_IMPORT[@]} -gt 0 ] || die "no backups selected — aborting"

printf '\nWARNING: this will OVERRIDE live module data under %s with the imported backups:\n' "$DATA"
printf '  '
for name in "${TO_IMPORT[@]}"; do printf '  %s  ' "$name"; done
echo
echo "This stops and restarts every non-caddy container (caddy is excluded)."
printf "Type 'yes' to continue (abort with Ctrl-C): > "
read -r -p "" conf
[ "$conf" = "yes" ] || die "not confirmed — aborting"

# ---- stop all non-caddy containers (detected from running list) ----
STOPPED=()
for n in $(docker ps --format '{{.Names}}'); do
  case "$n" in caddy*) continue;; esac
  log "stopping container: $n"
  docker stop -t 60 "$n" >/dev/null 2>&1 || { warn "container $n not running — skipping"; continue; }
  STOPPED+=("$n")
done

[ ${#STOPPED[@]} -eq 0 ] && warn "no non-caddy containers were running on this host"

# safety net: if the script aborts later, restart stopped containers
cleanup() {
  for n in "${STOPPED[@]}"; do
    docker ps -q --filter "name=$n" | grep -q . || \
      { log "cleanup: restarting $n" ; docker start "$n" >/dev/null 2>&1; }
  done
}
trap cleanup EXIT

# ---- download + verify each selected backup, staging it in .import-tmp ----
mkdir -p "$DATA/.import-tmp"
trap 'rm -rf "$DATA/.import-tmp"; cleanup' EXIT

declare -a SRC_DIRS=()
for name in "${TO_IMPORT[@]}"; do
  SRC="$DATA/.import-tmp/$name.src"
  if [ "${ITEM_TYPE[$name]}" = bundle ]; then
    log "downloading $name from $DEV_SSH:~/$LAND_DIR/"
    src="~/$LAND_DIR/$name"
    S "$DEV_SSH" "sha256sum $src | awk '{print \$1}'" > "$DATA/.import-tmp/${name}.sha256"
    S "$DEV_SSH" "rsync -a --info=progress2 $src $DATA/.import-tmp/$name" || die "download failed: $name"
    remote=$(cat "$DATA/.import-tmp/${name}.sha256")
    local=$(sha256sum "$DATA/.import-tmp/$name" | awk '{print $1}')
    [ "$remote" = "$local" ] || die "checksum mismatch for $name"
    log "verified: $name"

    log "inspecting bundle contents: $name"
    bad="$(tar tzf "$DATA/.import-tmp/$name" | grep -vE '^(pgdata/|cloud/|vault/|mailserver/|kuma/)' | head -20)"
    if [ -n "$bad" ]; then
      warn "bundle $name contains unexpected paths, refusing to extract:"
      printf '  %s\n' "$bad" >&2
      die "unsafe bundle — aborting"
    fi
    mkdir -p "$SRC"
    tar xzf "$DATA/.import-tmp/$name" -C "$SRC"

  else
    log "downloading $name from $DEV_SSH:~/$LAND_DIR/"
    mkdir -p "$SRC"
    rsync -a --info=progress2 "$DEV_SSH:~/$LAND_DIR/$name/" "$SRC/" || die "download failed: $name"
    remote="$(agg_remote "$DEV_SSH" "~/$LAND_DIR/$name")"
    local="$(agg_local "$SRC")"
    { [ -n "$remote" ] && [ "$remote" = "$local" ]; } || die "raw manifest mismatch for $name"
    log "verified: $name"

    log "inspecting raw dir contents: $name"
    bad="$(find "$SRC" -mindepth 1 -maxdepth 1 -printf '%f\n' | grep -vE '^(pgdata|cloud|vault|mailserver|kuma)$')"
    if [ -n "$bad" ]; then
      warn "raw dir $name contains unexpected top-level entries, refusing to import:"
      printf '  %s\n' "$bad" >&2
      die "unsafe raw dir — aborting"
    fi
  fi
  SRC_DIRS+=("$SRC")
done

# ---- overlay each staged tree onto the live data/ ----
for SRC in "${SRC_DIRS[@]}"; do
  log "restoring $(basename "$SRC") → $DATA/"
  rsync -a "$SRC/" "$DATA/" || die "restore failed from $SRC"
done

echo
echo "ownership after restore (matches the backup's stored owners):"
for d in pgdata cloud vault mailserver kuma; do
  [ -d "$DATA/$d" ] && printf '  %s → uid:%s gid:%s\n' "$d" "$(stat -c '%u' "$DATA/$d")" "$(stat -c '%g' "$DATA/$d")"
done

# ---- restart the containers we stopped ----
echo
for n in "${STOPPED[@]}"; do
  log "starting container: $n"
  compose=""
  for f in modules/*/docker-compose.yml modules/*/docker-compose.db.yml; do
    if [ -f "$ROOT/$f" ] && docker compose -f "$ROOT/$f" ps -a -q "$n" >/dev/null 2>&1; then
      compose="$ROOT/$f"; break
    fi
  done
  if [ -n "$compose" ]; then
    docker compose -f "$compose" up -d "$n" >/dev/null 2>&1 || \
      docker compose -f "$compose" start "$n" >/dev/null 2>&1 || { warn "failed to start $n"; continue; }
  else
    warn "no compose file found for $n — skipping start (verify manually)"; continue
  fi
done

echo
echo "=== restart liveness check ==="
alive=0
for n in "${STOPPED[@]}"; do
  if docker ps -q --filter "name=$n" | grep -q .; then
    log "running: $n"
    alive=$((alive+1))
  else
    warn "not running: $n — check logs"
  fi
done
if [ "$alive" -ne "${#STOPPED[@]}" ]; then
  warn "$(( ${#STOPPED[@]} - alive )) container(s) did not come back up — investigate"
fi
echo
printf 'DONE — backups restored into %s; all non-caddy containers restarted.\n' "$DATA"
hr
