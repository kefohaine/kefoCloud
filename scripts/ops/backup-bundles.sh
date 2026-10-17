#!/usr/bin/env bash
#
# scripts/ops/backup-bundles.sh — `make backup TAILDROP=<device>`:
# ship ALL installed modules' DB + datadir to a tailnet device.
#
#   make backup TAILDROP=<tailnet-device>   [BACKUP_MODE=bundle|raw] [BACKUP_LAND_DIR=<path>]
#
# - All installed modules ship. No MODULE selection; every module is sent.
# - Two modes, chosen interactively (or via BACKUP_MODE):
#     bundle — build two tar.gz archives and taildrop them (default):
#       nextcloud-backup-YYYYMMDD.tar.gz — pgdata + cloud datadir (db + files)
#       (the cloud datadir includes data/cloud/recovery/apps.txt — the occ app:list --enabled
#        app-state manifest — so it is backed up too)
#       other-backup-YYYYMMDD.tar.gz       — vault, mailserver, kuma datadirs
#     raw    — taildrop two raw datadirectories instead, no archive built:
#       nextcloud-YYYYMMDD/ — pgdata + cloud datadir
#       others-YYYYMMDD/    — vault, mailserver, kuma datadirs
# - After the mode is chosen, the plan is printed and a typed `yes` is required
#   before any work. Everything is staged in a temp dir, taildropped to the
#   device's BACKUP_LAND_DIR (default ~/backups/), checksum-verified, then every
#   local copy is deleted. data/ on the main host is untouched and repo/config
#   is neither read nor written — this is the only `make backup` behaviour.
# - Cloud with an EXTERNAL datadir (prior `make nc-datadir-nfs` export — the
#   marker `$DATA/.nc-import-source` is present): the datadir IS the NFS export
#   on the external machine, so it is sent to the device from there; the DB
#   (pgdata) and the other datadirs are sent from the main host. In bundle mode
#   the DB is copied to that machine, the bundle built, taildropped and verified
#   there, then the temp DB copy + bundle deleted.
#
# Vars: TAILDROP (required), BACKUP_MODE (bundle|raw), BACKUP_LAND_DIR (default 'backups').
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
DATA="$ROOT/data"
BUNDLES_DIR="$(mktemp -d)"
trap 'rm -rf "$BUNDLES_DIR"' EXIT

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

log()  { printf '\033[36m[backup]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[backup] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[backup] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }
hr()   { printf '%s\n' "────────────────────────────────────────────────────────────────"; }

S() { ssh "${SSH_OPTS[@]}" "$1" "$2"; }

peer_ip() {
  local dev="$1"
  tailscale status 2>/dev/null | awk -v d="$dev" '{ if (index($2,d)>0) { print $1; exit } }'
}

# aggregate content fingerprint of a directory tree: every file's relative path
# (sorted) hashed, then the whole listing hashed — identical trees on any host
# produce the same value. Used for the checksum-less raw mode; `-L` follows the
# staging symlinks so the value matches the dereferenced copy on the device.
agg_local()  { ( cd "$1" && find -L . -type f -printf '%P\n' | sort \
  | while IFS= read -r f; do sha256sum "$f"; done | sha256sum | awk '{print $1}' ); }
agg_remote() { S "$1" "cd '$2' && find -L . -type f -printf '%P\n' | sort \
  | while IFS= read -r f; do sha256sum \"\$f\"; done | sha256sum | awk '{print \$1}'"; }

TAILDROP="${TAILDROP:-}"
[ -n "$TAILDROP" ] || {
  echo "make backup requires TAILDROP=<tailnet device>:"
  echo "  make backup TAILDROP=<device>     ships all modules (bundle or raw mode)"
  echo "  make import-backups TAILDROP=<device>  preview + restore from that device"
  exit 1
}

# ---- enabled modules (all ship; no selection) — from install.state ----
STATE="${INSTALL_STATE:-$DATA/install.state}"
[ -f "$STATE" ] || die "install.state not found — this host has not been installed"
INSTALLED="$( ( . "$STATE" 2>/dev/null; printf '%s' "${enabled_modules:-}" ) 2>/dev/null )"
[ -n "$INSTALLED" ] || die "no modules installed (install.state enabled_modules is empty)"

# ---- resolve + verify the taildrop device ----
case "$TAILDROP" in *@*) DEV="${TAILDROP#*@}"; DEV_USER="${TAILDROP%@*}";; *) DEV="$TAILDROP"; DEV_USER="root";; esac
[ "$DEV_USER" = "root" ] || die "only root@host taildrop targets are accepted ($DEV_USER)"
case "$DEV" in
  *[!0-9.]* ) TS_IP="$(peer_ip "$DEV")";;
  * ) TS_IP="$DEV";;
esac
[ -n "$TS_IP" ] || die "taildrop device '$DEV' is not on the tailnet (no peer by that name/IP)"
sudo tailscale ping -c 2 "$TS_IP" >/dev/null 2>&1 || die "cannot reach the taildrop device $TS_IP over the tailnet"
DEV_SSH="root@$TS_IP"
S "$DEV_SSH" "true" || die "cannot ssh to the taildrop device $DEV_SSH over the tailnet"
LAND_DIR="${BACKUP_LAND_DIR:-backups}"
S "$DEV_SSH" "mkdir -p ~/$LAND_DIR"
log "taildrop: $DEV_SSH -> ~/$LAND_DIR (tailnet $TS_IP)"

# ---- choose the send mode ----
SEND_MODE="${BACKUP_MODE:-}"
if [ -z "$SEND_MODE" ]; then
  hr
  cat <<'EOF'
how should the backups be sent?
  1) bundle  - tar.gz both backups, then taildrop the two archives (default)
  2) raw     - taildrop two raw datadirectories (nextcloud/, others/) instead; no archive built
EOF
  read -r -p "choice [1]: " c
  case "${c:-1}" in
    1|bundle) SEND_MODE="bundle" ;;
    2|raw)    SEND_MODE="raw" ;;
    *) die "unknown choice: $c" ;;
  esac
fi
case "$SEND_MODE" in bundle|raw) ;; *) die "BACKUP_MODE must be 'bundle' or 'raw'" ;; esac

TODAY="$(date +%Y%m%d)"

hr
printf 'kefo backup (all modules) — %s → taildrop %s\n' "$(hostname)" "$DEV_SSH"
hr

# ---- nextcloud flags (db + datadir together) ----
cloud_ok=0
cloud_external=0
if [ -d "$DATA/cloud" ] && [ -d "$DATA/pgdata" ]; then
  cloud_ok=1
  [ -f "$DATA/.nc-import-source" ] && cloud_external=1
else
  warn "cloud module not fully installed (missing $DATA/cloud or $DATA/pgdata) — cloud skipped"
fi

if [ "$cloud_ok" -eq 1 ] && [ "$cloud_external" -eq 1 ]; then
  EX_HOST="${EXTERNAL_HOST:-$(sed -n '1p' "$DATA/.nc-import-source")}"
  EX_HOST="${EX_HOST#*@}"
  EX_MOUNT="$(sed -n '2p' "$DATA/.nc-import-source")"
  case "$EX_HOST" in
    *[!0-9.]* ) EX_IP="$(peer_ip "$EX_HOST")";;
    * ) EX_IP="$EX_HOST";;
  esac
  if [ -n "$EX_IP" ]; then
    EX_SSH="root@$EX_IP"
    S "$EX_SSH" "true" || die "cannot ssh to the external machine $EX_SSH"
  else
    warn "cannot resolve the external machine ($EX_HOST) — using the local datadir instead"
    cloud_external=0
  fi
fi

# ---- other module datadirs (vault, mailserver, kuma) ----
OTHER=""
for d in vault mailserver kuma; do
  [ -d "$DATA/$d" ] && OTHER="${OTHER:+$OTHER }$d"
done

# ---- plan + explicit proceed gate (both modes), before any work ----
hr
printf 'backup plan — mode=%s\n' "$SEND_MODE"
printf '  destination   %s:~/%s/\n' "$DEV_SSH" "$LAND_DIR"
if [ "$cloud_ok" -eq 1 ]; then
  if [ "$cloud_external" -eq 1 ]; then
    printf '  cloud         pgdata (local) + cloud (%s:%s)\n' "$EX_SSH" "$EX_MOUNT"
  else
    printf '  cloud         %s/pgdata + %s/cloud\n' "$DATA" "$DATA"
  fi
else
  printf '  cloud         skipped (cloud module not fully installed)\n'
fi
if [ -n "$OTHER" ]; then
  printf '  others        %s (under %s/)\n' "$OTHER" "$DATA"
else
  printf '  others        skipped (no vault/mailserver/kuma datadirs)\n'
fi
printf "Type 'yes' to proceed (Ctrl-C aborts): "
read -r conf
[ "$conf" = "yes" ] || die "not confirmed — aborting"

if [ "$SEND_MODE" = "bundle" ]; then

  # ---- nextcloud bundle (db + datadir together) ----
  if [ "$cloud_ok" -eq 1 ] && [ "$cloud_external" -eq 1 ]; then
    log "cloud datadir is external ($EX_SSH:$EX_MOUNT); copying the DB there, bundling on the external machine"
    S "$EX_SSH" "mkdir -p $EX_MOUNT/pgdata-tmp"
    rsync -a --delete "$DATA/pgdata/" "$EX_SSH:$EX_MOUNT/pgdata-tmp/" || die "db copy to external failed"
    BUNDLE="$EX_MOUNT/nextcloud-backup-$TODAY.tar.gz"
    S "$EX_SSH" "cd \"$EX_MOUNT\" && tar czf \"$BUNDLE\" --exclude=\"$BUNDLE\" ." \
      || die "bundle build failed on the external machine"
    log "taildropping the cloud bundle from the external machine to $DEV_SSH"
    S "$EX_SSH" "rsync -a \"$BUNDLE\" \"$DEV_SSH:~/$LAND_DIR/nextcloud-backup-$TODAY.tar.gz\"" \
      || die "taildrop from external failed"
    sum_ext="$(S "$EX_SSH" "sha256sum \"$BUNDLE\" | awk '{print \$1}'")"
    sum_dev="$(S "$DEV_SSH" "sha256sum ~/$LAND_DIR/nextcloud-backup-$TODAY.tar.gz | awk '{print \$1}'")"
    [ "$sum_ext" = "$sum_dev" ] || die "cloud bundle checksum mismatch after taildrop"
    log "cloud bundle verified on the taildrop device"
    log "deleting the temp DB copy + bundle from the external machine (taildrop succeeded)"
    S "$EX_SSH" "rm -rf \"$EX_MOUNT/pgdata-tmp\" \"$BUNDLE\"" || warn "could not clean temp DB/bundle on the external machine"
  fi

  if [ "$cloud_ok" -eq 1 ] && [ "$cloud_external" -eq 0 ]; then
    log "building the cloud bundle locally (pgdata + cloud)"
    tar czf "$BUNDLES_DIR/nextcloud-backup-$TODAY.tar.gz" -C "$DATA" pgdata cloud \
      || die "cloud bundle build failed"
    log "built nextcloud-backup-$TODAY.tar.gz ($(du -sh "$BUNDLES_DIR/nextcloud-backup-$TODAY.tar.gz" | cut -f1))"
  fi

  # ---- other modules bundle (vault, mailserver, kuma datadirs) ----
  if [ -n "$OTHER" ]; then
    log "building the other bundle (datadirs:$OTHER)"
    tar czf "$BUNDLES_DIR/other-backup-$TODAY.tar.gz" -C "$DATA" $OTHER \
      || die "other bundle build failed"
    log "built other-backup-$TODAY.tar.gz ($(du -sh "$BUNDLES_DIR/other-backup-$TODAY.tar.gz" | cut -f1))"
  else
    warn "no other module datadirs found (vault/mailserver/kuma) — other bundle skipped"
  fi

  # ---- taildrop the local bundles ----
  taildrop_bundle() {
    local src="$1" dst="$2"
    [ -f "$src" ] || die "bundle missing: $src"
    rsync -a --info=progress2 "$src" "$DEV_SSH:$dst" || die "taildrop failed"
    local sum_local sum_dev
    sum_local="$(sha256sum "$src" | awk '{print $1}')"
    sum_dev="$(S "$DEV_SSH" "sha256sum $dst | awk '{print \$1}'")"
    [ "$sum_local" = "$sum_dev" ] || die "bundle checksum mismatch after taildrop: $src"
    log "bundle verified on the taildrop device: $dst"
  }

  if [ -f "$BUNDLES_DIR/nextcloud-backup-$TODAY.tar.gz" ]; then
    taildrop_bundle "$BUNDLES_DIR/nextcloud-backup-$TODAY.tar.gz" "~/$LAND_DIR/nextcloud-backup-$TODAY.tar.gz"
  fi
  if [ -f "$BUNDLES_DIR/other-backup-$TODAY.tar.gz" ]; then
    taildrop_bundle "$BUNDLES_DIR/other-backup-$TODAY.tar.gz" "~/$LAND_DIR/other-backup-$TODAY.tar.gz"
  fi

else

  # ---- raw mode: stage symlinks (no data copy), then taildrop the trees ----
  STAGE="$BUNDLES_DIR/stage"
  mkdir -p "$STAGE/nextcloud" "$STAGE/others"
  if [ "$cloud_ok" -eq 1 ]; then
    ln -s "$DATA/pgdata" "$STAGE/nextcloud/pgdata"
    [ "$cloud_external" -eq 0 ] && ln -s "$DATA/cloud" "$STAGE/nextcloud/cloud"
  fi
  for d in vault mailserver kuma; do
    [ -d "$DATA/$d" ] && ln -s "$DATA/$d" "$STAGE/others/$d"
  done

  S "$DEV_SSH" "mkdir -p ~/$LAND_DIR/nextcloud-$TODAY ~/$LAND_DIR/others-$TODAY"

  # pgdata always comes from here; cloud from here too unless it is external.
  # `-L` dereferences the staging symlinks so the device receives real dirs.
  if [ "$cloud_ok" -eq 1 ]; then
    log "sending the raw nextcloud datadir (pgdata$([ "$cloud_external" -eq 0 ] && printf ' + cloud'))"
    rsync -aL --delete "$STAGE/nextcloud/" "$DEV_SSH:~/$LAND_DIR/nextcloud-$TODAY/" \
      || die "raw nextcloud send failed"
  fi
  if [ -n "$OTHER" ]; then
    log "sending the raw other datadirs ($OTHER)"
    rsync -aL --delete "$STAGE/others/" "$DEV_SSH:~/$LAND_DIR/others-$TODAY/" \
      || die "raw others send failed"
  fi

  # external cloud: send the NFS export straight from its own machine into the
  # same device dir (the local host never pulls it over NFS).
  if [ "$cloud_ok" -eq 1 ] && [ "$cloud_external" -eq 1 ]; then
    log "sending the raw cloud datadir from $EX_SSH to $DEV_SSH"
    S "$EX_SSH" "rsync -a --delete \"$EX_MOUNT/\" \"$DEV_SSH:~/$LAND_DIR/nextcloud-$TODAY/cloud/\"" \
      || die "raw cloud send from the external machine failed"
  fi

  # ---- raw verification (aggregate manifest; raw has no single tarball) ----
  if [ "$cloud_ok" -eq 1 ]; then
    if [ "$cloud_external" -eq 0 ]; then
      [ "$(agg_local "$STAGE/nextcloud")" = "$(agg_remote "$DEV_SSH" "~/$LAND_DIR/nextcloud-$TODAY")" ] \
        || die "raw nextcloud manifest mismatch after transfer"
    else
      [ "$(agg_local "$STAGE/nextcloud")" = "$(agg_remote "$DEV_SSH" "~/$LAND_DIR/nextcloud-$TODAY/pgdata")" ] \
        || die "raw pgdata manifest mismatch after transfer"
      [ "$(agg_remote "$EX_SSH" "$EX_MOUNT")" = "$(agg_remote "$DEV_SSH" "~/$LAND_DIR/nextcloud-$TODAY/cloud")" ] \
        || die "raw cloud manifest mismatch after transfer"
    fi
  fi
  if [ -n "$OTHER" ]; then
    [ "$(agg_local "$STAGE/others")" = "$(agg_remote "$DEV_SSH" "~/$LAND_DIR/others-$TODAY")" ] \
      || die "raw others manifest mismatch after transfer"
  fi
  log "raw datadirectories verified on the taildrop device"
  rm -rf "$STAGE"

fi

hr
if [ "$SEND_MODE" = "bundle" ]; then
  printf ' DONE — bundles shipped to the taildrop device %s (dir ~/%s/)\n' "$DEV_SSH" "$LAND_DIR"
  printf '   bundles     nextcloud-backup-%s.tar.gz  (DB + datadir)\n' "$TODAY"
  printf '               other-backup-%s.tar.gz        (vault + mail + monitor datadirs)\n' "$TODAY"
else
  printf ' DONE — raw datadirectories shipped to the taildrop device %s (dir ~/%s/)\n' "$DEV_SSH" "$LAND_DIR"
  printf '   dirs        nextcloud-%s/  (DB + datadir)\n' "$TODAY"
  printf '               others-%s/     (vault + mail + monitor datadirs)\n' "$TODAY"
fi
printf '   security    tailnet-only (WireGuard) transfer, sha256-verified before\n'
printf '                  the staging copies are deleted\n'
printf '   main host   no permanent local copies left; data/ untouched; repo/config\n'
printf '                  never read or written\n'
printf '   confirm     ssh %s '\''ls -la ~/%s'\''\n' "$DEV_SSH" "$LAND_DIR"
hr
