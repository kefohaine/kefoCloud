#!/usr/bin/env bash
#
# scripts/ops/backup-ship.sh — `make backup` shipped (taildrop) workflow.
#
#   make backup MODULE=cloud TAILDROP=<tailnet-device>
#
# - MODULE is optional: empty = every installed module; a value must be one of
#   the installed modules (cloud / vault / mail / monitor). TAILDROP is
#   always required for the shipped workflow.
# - A bundle always contains the module's DB and its datadir together —
#   it never ships one without the other.
# - The taildrop device must be on the tailnet and reachable before ANY data
#   leaves this host.
# - Cloud with an EXTERNAL datadir (a prior 'make nc-data' export): the DB
#   (pgdata) is COPIED to the external machine, the bundle is built there,
#   taildropped, and the temp DB copy on the external machine is deleted
#   only AFTER the taildrop succeeds. The main machine's pgdata stays intact.
# - No permanent local copies or temp snapshots are left on the main machine:
#   each tarball is created, shipped, verified by sha256, then deleted.
#
# Vars: MODULE, TAILDROP, BACKUP_LAND_DIR (dir on the taildrop device,
#       default 'backups' under its home).
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
DATA="$ROOT/data"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

log()  { printf '\033[36m[backup]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[backup] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[backup] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }
hr()   { printf '%s\n' "────────────────────────────────────────────────────────────────"; }

S() { ssh "${SSH_OPTS[@]}" "$1" "$2"; }

# resolve a tailnet peer name/IP to its IPv4 (peer line format: <ip>  <name>: ...)
peer_ip() {
  local dev="$1"
  tailscale status 2>/dev/null | awk -v d="$dev" '{ if (index($2,d)>0) { print $1; exit } }'
}

MODULE="${MODULE:-}"
TAILDROP="${TAILDROP:-}"
LAND_DIR="${BACKUP_LAND_DIR:-backups}"

[ -n "$TAILDROP" ] || {
  echo "shipped backup requires TAILDROP=<tailnet device>."
  echo "For the local all-modules snapshot (no taildrop): run 'make backup' with no TAILDROP."
  exit 1
}

# ---------- which modules ----------
[ -f "$DATA/installed-modules.conf" ] || die "installed-modules.conf not found"
INSTALLED="$(tr -d '\r' < "$DATA/installed-modules.conf" | sed '/^$/d')"
if [ -z "$MODULE" ]; then
  SCOPE="$INSTALLED"
else
  case "$MODULE" in
    nextcloud|cloud) M=cloud ;;
    vaultwarden|vault) M=vault ;;
    mailserver|mail) M=mail ;;
    uptimekuma|kuma|monitor) M=monitor ;;
    *) die "unknown module: $MODULE (valid: cloud, vault, mail, monitor)" ;;
  esac
  echo "$INSTALLED" | grep -qx "$M" || die "module '$M' is not installed on this host"
  SCOPE="$M"
fi

# ---------- resolve + verify the taildrop device on the tailnet ----------
case "$TAILDROP" in *@*) DEV="${TAILDROP#*@}"; DEV_USER="${TAILDROP%@*}";; *) DEV="$TAILDROP"; DEV_USER="root";; esac
[ "$DEV_USER" = "root" ] || die "only root@host taildrop targets are accepted ($DEV_USER)"
case "$DEV" in
  *[!0-9.]* ) TS_IP="$(peer_ip "$DEV")" ;;       # a name -> resolve via tailnet
  * ) TS_IP="$DEV" ;;                            # already an IP
esac
[ -n "$TS_IP" ] || die "taildrop device '$DEV' is not on the tailnet (no peer by that name/IP)"
sudo tailscale ping -c 2 "$TS_IP" >/dev/null 2>&1 || die "cannot reach the taildrop device $TS_IP over the tailnet"
DEV_SSH="root@$TS_IP"
S "$DEV_SSH" "true" || die "cannot ssh to the taildrop device $DEV_SSH over the tailnet"
S "$DEV_SSH" "mkdir -p ~/$LAND_DIR"
log "taildrop: $DEV_SSH -> ~/$LAND_DIR (tailnet $TS_IP)"

TODAY="$(date +%Y%m%d)"

echo
hr
printf 'kefo backup (shipped) — %s → taildrop %s\n' "$(hostname)" "$DEV_SSH"
hr

shipped=0
_local_bundle() {
  local src="$DATA/$M-backup-$TODAY.tar.gz"
  if [ -n "$DB_DIR" ]; then
    tar czf "$src" -C "$DATA" "$(basename "$MAIN_DATADIR")" "$(basename "$DB_DIR")"
  else
    tar czf "$src" -C "$DATA" "$(basename "$MAIN_DATADIR")"
  fi
  log "built local bundle: $src"
  rsync -a --info=progress2 "$src" "$DEV_SSH:$DEST" || die "taildrop failed"
  local sum_local sum_dev
  sum_local="$(sha256sum "$src" | awk '{print $1}')"
  sum_dev="$(S "$DEV_SSH" "sha256sum $DEST | awk '{print \$1}'")"
  [ "$sum_local" = "$sum_dev" ] || die "bundle checksum mismatch after taildrop"
  log "bundle verified on the taildrop device"
  rm -f "$src"
}
for M in $SCOPE; do
  echo
  log "=== module: $M ==="

  case "$M" in
    cloud)   MAIN_DATADIR="$DATA/cloud";     DB_DIR="$DATA/pgdata";;
    vault)   MAIN_DATADIR="$DATA/vault";     DB_DIR="";;
    mail)    MAIN_DATADIR="$DATA/mailserver";DB_DIR="";;
    monitor) MAIN_DATADIR="$DATA/kuma";      DB_DIR="";;
    *) warn "no backup mapping for $M — skipped"; continue ;;
  esac
  [ -d "$MAIN_DATADIR" ] || { warn "$M datadir $MAIN_DATADIR not found — skipped"; continue; }
  [ -n "$DB_DIR" ] && [ ! -d "$DB_DIR" ] && warn "$M DB dir $DB_DIR not found — bundling datadir only"

  # the bundle on the taildrop device always lands at:
  DEST="~/$LAND_DIR/$M-backup-$TODAY.tar.gz"
  if [ "$M" = "cloud" ] && [ -f "$DATA/.nc-import-source" ]; then
    # datadir is EXTERNAL: copy the DB to it, bundle there, taildrop from there
    EX_HOST="${EXTERNAL_HOST:-$(sed -n '1p' "$DATA/.nc-import-source")}"
    EX_HOST="${EX_HOST#*@}"
    EX_MOUNT="$(sed -n '2p' "$DATA/.nc-import-source")"
    case "$EX_HOST" in
      *[!0-9.]* ) EX_IP="$(peer_ip "$EX_HOST")" ;;
      * ) EX_IP="$EX_HOST" ;;
    esac
    if [ -n "$EX_IP" ]; then
      EX_SSH="root@$EX_IP"
      S "$EX_SSH" "true" || die "cannot ssh to the external machine $EX_SSH"
      log "cloud datadir is EXTERNAL ($EX_SSH:$EX_MOUNT); copying the DB there, bundling on the external machine"
      S "$EX_SSH" "mkdir -p $EX_MOUNT/pgdata-tmp"
      rsync -a --delete "$DB_DIR/" "$EX_SSH:$EX_MOUNT/pgdata-tmp/" || die "db copy to external failed"
      BUNDLE="$EX_MOUNT/$M-backup-$TODAY.tar.gz"
      log "building the cloud bundle on the external machine (datadir + db)"
      S "$EX_SSH" "cd \"$EX_MOUNT\" && tar czf \"$M-backup-$TODAY.tar.gz\" --exclude=\"$M-backup-$TODAY.tar.gz\" ." \
        || die "bundle build failed on the external machine"
      log "taildropping the cloud bundle from the external machine to $DEV_SSH"
      S "$EX_SSH" "rsync -a \"$BUNDLE\" \"$DEV_SSH:$DEST\"" || die "taildrop from external failed"
      sum_ext="$(S "$EX_SSH" "sha256sum \"$BUNDLE\" | awk '{print \$1}'")"
      sum_dev="$(S "$DEV_SSH" "sha256sum $DEST | awk '{print \$1}'")"
      [ -n "$sum_ext" ] && [ "$sum_ext" = "$sum_dev" ] || die "cloud bundle checksum mismatch after taildrop"
      log "cloud bundle verified on the taildrop device"
      log "deleting the temp DB copy + bundle from the external machine (taildrop succeeded)"
      S "$EX_SSH" "rm -rf \"$EX_MOUNT/pgdata-tmp\" \"$BUNDLE\"" || warn "could not delete the temp DB copy/bundle on the external machine"
    else
      warn "cannot resolve the external machine ($EX_HOST) — bundling locally instead"
      _local_bundle
    fi
  else
    _local_bundle
  fi
  shipped=$((shipped+1))
  log "$M → $DEV_SSH:$DEST"
done


hr
printf ' DONE — %d bundle(s) shipped to the taildrop device %s\n' "$shipped" "$DEV_SSH"
printf '   landing dir    ~/%s/\n' "$LAND_DIR"
printf '   each file      <module>-backup-%s.tar.gz (db + datadir, together)\n' "$TODAY"
printf '   security       tailnet-only (WireGuard) transfer, verified by sha256 before\n'
printf '                  the local/temp copies are deleted\n'
printf '   main host      no permanent local copies or temp snapshots left behind\n'
printf '   external       any temp DB copy on the external machine was deleted only\n'
printf '                  after its taildrop verified\n'
printf '   confirm on the taildrop device:  ssh %s '\''ls -la ~/%s'\''\n' "$DEV_SSH" "$LAND_DIR"
hr
