#!/usr/bin/env bash
#
# scripts/ops/restore-data.sh — `make import-backups TAILDROP=<device>`:
# restore module data from bundles taildropped to the device's ~/backups/.
#
#   make import-backups TAILDROP=<tailnet-device>
#
# - Queries the device for nextcloud-backup-*.tar.gz and other-backup-*.tar.gz.
# - Always previews what's available, which modules they cover, and what would
#   be restored/overridden, then requires a typed yes before touching anything.
# - Stops all non-caddy containers, extracts, then restarts containers (ownership
#   comes from the live system). No DRYRUN flag: the preview + confirmation IS
#   the dry run.
# - Caddy is NEVER touched (stop or restart) — it is explicitly excluded.
#
# Vars: TAILDROP (required).
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

TAILDROP="${TAILDROP:-}"
[ -n "$TAILDROP" ] || {
  echo "make import-backups requires TAILDROP=<tailnet device>:"
  echo "  make import-backups TAILDROP=<device>  preview + restore module bundles from that device"
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

LIST="$S "$DEV_SSH" 'ls -1 ~/backups/nextcloud-backup-*.tar.gz ~/backups/other-backup-*.tar.gz 2>/dev/null'"

declare -A BUNDLES
declare -a NC=() OTHER=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  name="$(basename "$line")"
  BUNDLES["$name"]="$line"
  if [[ $name == nextcloud-backup-*.tar.gz ]]; then NC+=("$name")
  elif [[ $name == other-backup-*.tar.gz ]]; then OTHER+=("$name")
  fi
done <<< "$LIST"

[ ${#BUNDLES[@]} -gt 0 ] || die "no backup bundles found on $DEV_SSH:~/backups/ (make sure make backup was run there)"

hr
printf 'backup bundles on %s:\n' "$DEV_SSH"
hr
for name in "${!BUNDLES[@]}"; do
  printf '  %s\n' "$name"
done

show_plan() {
  echo
  hr
  echo "coverage:"
  [ "${#NC[@]}" -gt 0 ] && printf '  nextcloud-backup-*.tar.gz  →  postgresql DB + cloud datadir\n'
  [ "${#OTHER[@]}" -gt 0 ] && printf '  other-backup-*.tar.gz      →  vault, mailserver, kuma datadirs\n'
  echo "restore target (live): $DATA/"
  echo "containers that will be stopped (caddy is NEVER touched): $(docker ps --format '{{.Names}}' | grep -v '^caddy' | tr '\n' ' ')"
}

show_plan

printf 'select bundles to import (comma-separated names; leave empty to import all listed):\n> '
read -r -p "" -e sel || die "selection cancelled"

declare -a TO_IMPORT=()
for name in "${!BUNDLES[@]}"; do
  if [ -z "$sel" ] || echo "$sel" | tr ',' '\n' | grep -qx "$name"; then
    TO_IMPORT+=("$name")
  fi
done
[ ${#TO_IMPORT[@]} -gt 0 ] || die "no bundles selected — aborting"

printf '\nWARNING: this will OVERRIDE live module data under %s with the imported bundles:\n' "$DATA"
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

# ---- download + verify bundles ----
mkdir -p "$DATA/.import-tmp"
trap 'rm -rf "$DATA/.import-tmp"; cleanup' EXIT

for name in "${TO_IMPORT[@]}"; do
  log "downloading $name from $DEV_SSH:~/backups/"
  src="~/backups/$name"
  S "$DEV_SSH" "sha256sum $src | awk '{print \$1}'" > "$DATA/.import-tmp/${name}.sha256"
  S "$DEV_SSH" "rsync -a --info=progress2 $src $DATA/.import-tmp/$name" || die "download failed: $name"
  remote=$(cat "$DATA/.import-tmp/${name}.sha256")
  local=$(sha256sum "$DATA/.import-tmp/$name" | awk '{print $1}')
  [ "$remote" = "$local" ] || die "checksum mismatch for $name"
  log "verified: $name"
done

# ---- validate bundle contents before extraction ----
for name in "${TO_IMPORT[@]}"; do
  log "inspecting bundle contents: $name"
  bad="$(tar tzf "$DATA/.import-tmp/$name" | grep -vE '^(pgdata/|cloud/|vault/|mailserver/|kuma/)' | head -20)"
  if [ -n "$bad" ]; then
    warn "bundle $name contains unexpected paths, refusing to extract:"
    printf '  %s\n' "$bad" >&2
    die "unsafe bundle — aborting"
  fi
done

# ---- extract ----
for name in "${TO_IMPORT[@]}"; do
  log "extracting $name → $DATA/"
  tar xzf "$DATA/.import-tmp/$name" -C "$DATA"
done
echo
echo "ownership after extraction (matches the bundle's stored owners):"
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
printf 'DONE — module bundles restored into %s; all non-caddy containers restarted.\n' "$DATA"
hr
