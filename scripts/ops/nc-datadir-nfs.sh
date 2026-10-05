#!/usr/bin/env bash
#
# scripts/ops/nc-datadir-nfs.sh — `make nc-datadir-nfs`: make an external machine
# the PERMANENT live datadir host for THIS Nextcloud over the tailnet. PostgreSQL
# stays local — nothing touches the database, ever. Import is the exact mirror of
# export: this host's previously-exported datadir is brought back, nothing else.
#
# Prompts:
#   1. WHICH ACTION  — export / import
#   2. BACKUP GATE   — "have you backed up the 'cloud' module today?"
#   3. EXTERNAL      — root@external-machine (tailnet name or IP)
#
# Safety rails: the external machine answers before anything is written; the
# tailnet path is probed before any firewall change; the datadirectory is copied
# (never truncated) and verified with an occ R/W probe before local copies are
# deleted; root only; yes/no choices. Idempotent — safe to re-run.
#
# Vars (overridable): NC_CONTAINER NC_MOUNT TS_AUTHKEY SSH_PASS TARGET
# Env overrides: ACTION, TARGET
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
. "$ROOT/scripts/lib/instance.sh" 2>/dev/null || true

NC_CONTAINER="${NC_CONTAINER:-nextcloud}"
NC_MOUNT="${NC_MOUNT:-/srv/nextcloud-data}"
MARKER="$ROOT/data/.nc-import-source"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

log()  { printf '\033[36m[nc-datadir-nfs]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[nc-datadir-nfs] WARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[nc-datadir-nfs] FATAL:\033[0m %s\n' "$*" >&2; exit 1; }
hr()   { printf '%s\n' "────────────────────────────────────────────────────────────────"; }

[ "$(id -u)" = 0 ] || die "run as root (this stops containers and edits fstab)"

S() { ssh "${SSH_OPTS[@]}" "$1" "$2"; }
if [ -n "${SSH_PASS:-}" ]; then
  command -v sshpass >/dev/null || die "SSH_PASS is set but sshpass is not installed"
  export SSHPASS="$SSH_PASS"
  S() { sshpass -e ssh "${SSH_OPTS[@]}" "$1" "$2"; }
fi

# ---------- auto-detect the local Nextcloud ----------
command -v docker >/dev/null || die "docker not found on this host"
docker ps --format '{{.Names}}' | grep -qx "$NC_CONTAINER" \
  || die "container '$NC_CONTAINER' is not running (set NC_CONTAINER=...)"
DATA_DIR_NC="$(docker inspect "$NC_CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}')"
LOCAL_MOUNT="$DATA_DIR_NC"
[ -n "$DATA_DIR_NC" ] || die "cannot find the /data bind mount of $NC_CONTAINER"
log "local: nc=$NC_CONTAINER data=$DATA_DIR_NC"

# ---------- banner ----------
cat <<'EOF'
┌────────────────────────────────────────────────────────────────────┐
│  nc-datadir-nfs — Nextcloud datadirectory <-> external machine     │
│  export: make the external machine the PERMANENT live datadir host │
│          (this host's datadir moves over NFS; database stays here) │
│  import: bring THIS host's previously-exported datadir back;       │
│          nothing else - never a foreign datadir                    │
│  The database stays on this machine - nothing touches it.          │
└────────────────────────────────────────────────────────────────────┘
EOF

# ---------- prompt the action ----------
ACTION="${ACTION:-}"
if [ -z "$ACTION" ]; then
  hr
  cat <<'EOF'
What should happen with the datadirectory?

  1) export  - make the external machine the PERMANENT live datadir host
               for THIS Nextcloud (the datadirectory moves over NFS;
               the database stays here).
  2) import  - bring back THIS host's previously-exported datadirectory
               from the external machine it was exported to.
EOF
  read -r -p "choice [1]: " c
  case "${c:-1}" in
    1|export|e) ACTION="export" ;;
    2|import|i) ACTION="import" ;;
    *) die "unknown choice: $c" ;;
  esac
fi

# ---------- backup gate: first prompt after selecting export ----------
if [ "$ACTION" = "export" ]; then
  read -r -p "have you backed up the 'cloud' module today? (yes/no): " ans
  case "$ans" in
    y|Y|yes)
      log "BACKUP GATE: yes - this is a MOVE, not a copy. The datadirectory"
      log "             leaves this host; only the datadirectory leaves"
      log "             (the database stays here, untouched). Continuing."
      ;;
    *)
      echo
      echo "Do it first:"
      echo "  make backup MODULE=cloud TAILDROP=<device>"
      echo "  (or set TAILDROP to your own tailnet device)"
      exit 0
      ;;
  esac
fi

# ---------- determine the external machine ----------
TARGET="${TARGET:-}"
if [ "$ACTION" = "import" ]; then
  [ -f "$MARKER" ] || die "no previous export found on this host - run 'make nc-datadir-nfs' export first"
  EXTERNAL_HOST="$(sed -n '1p' "$MARKER")"
  EXTERNAL_MOUNT="$(sed -n '2p' "$MARKER")"
  TARGET="$EXTERNAL_HOST"
  log "importing from this host's export: $EXTERNAL_HOST:$EXTERNAL_MOUNT"
else
  read -r -p "external machine (tailnet name or root@ip): " TARGET
fi
[ -n "$TARGET" ] || die "an external machine is required"
case "$TARGET" in *@*) ;; *) TARGET="root@$TARGET" ;; esac
_target_host="${TARGET#*@}"
_target_user="${TARGET%@*}"
[ "$_target_user" = "root" ] || die "only root@host targets are accepted"
unset _target_host _target_user
log "target: $TARGET"

# ---------- common: probe the external machine ----------
S "$TARGET" "true" || die "cannot ssh to $TARGET (key installed? tailnet up?)"

log "installing the NFS stack on $TARGET"
S "$TARGET" "apt-get update -qq && apt-get install -y -qq curl ca-certificates ufw nfs-kernel-server >/dev/null 2>&1" \
  || die "failed to prepare the external machine"

# tailnet
if ! S "$TARGET" "command -v tailscale >/dev/null && tailscale status >/dev/null 2>&1"; then
  log "installing tailscale on the external machine"
  S "$TARGET" "curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1" \
    || die "tailscale install failed on $TARGET"
fi
if ! S "$TARGET" "tailscale status >/dev/null 2>&1"; then
  log "joining tailnet"
  S "$TARGET" "tailscale up --authkey '${TS_AUTHKEY:-$(read -r -s -p 'tailscale auth key: '; echo)}' >/dev/null 2>&1" \
    || die "tailscale up failed on $TARGET"
fi
for _ in $(seq 1 30); do
  TS_IP="$(S "$TARGET" "tailscale ip -4 2>/dev/null | head -1")"
  [ -n "$TS_IP" ] && break
  sleep 2
done
[ -n "$TS_IP" ] || die "no tailnet IP on $TARGET"
log "external tailnet IP: $TS_IP"

# lockout gate: verify tailnet path before any firewall change
sudo tailscale ping -c 2 "$TS_IP" >/dev/null 2>&1 || die "cannot ping the external machine over the tailnet"
T() { ssh -o StrictHostKeyChecking=accept-new root@"$TS_IP" "$@"; }
T "true" || die "tailnet ssh failed"
log "tailnet path verified - safe to restrict the firewall"

# ---------- export ----------
if [ "$ACTION" = "export" ]; then
  log "preparing $NC_MOUNT on $TARGET"
  S "$TARGET" "mkdir -p $NC_MOUNT && chown -R 33:33 $NC_MOUNT"
  S "$TARGET" "grep -q '^$NC_MOUNT 100.64.0.0/10' /etc/exports 2>/dev/null \
    || echo '$NC_MOUNT 100.64.0.0/10(rw,sync,no_subtree_check,no_root_squash)' >> /etc/exports" \
    || die "failed to write /etc/exports on $TARGET"
  S "$TARGET" "exportfs -ra >/dev/null 2>&1" || die "exportfs -ra failed on $TARGET"
  S "$TARGET" "ufw allow from 100.64.0.0/10 to any port 2049 proto tcp; \
               ufw allow from 100.64.0.0/10 to any port 111 proto tcp; \
               ufw allow from 100.64.0.0/10 to any port 20048 proto tcp" >/dev/null 2>&1 \
    || warn "could not add the NFS ufw rules on $TARGET (they may already exist)"

  # NFS client helper: without /sbin/mount.nfs the kernel refuses the
  # mount with "NFS: mount program didn't pass remote address"
  if [ ! -x /sbin/mount.nfs ] && [ ! -x /usr/sbin/mount.nfs ]; then
    sudo apt-get install -y -qq nfs-common >/dev/null 2>&1
  fi
  [ -x /sbin/mount.nfs ] || [ -x /usr/sbin/mount.nfs ] \
    || die "NFS client missing (nfs-common install failed on this host)"

  # stop app, stage, rsync, verify
  docker stop "$NC_CONTAINER" >/dev/null 2>&1 || true
  sudo mv "$LOCAL_MOUNT" "$LOCAL_MOUNT.local-backup" 2>/dev/null || sudo mkdir -p "$LOCAL_MOUNT.local-backup"
  sudo mkdir -p "$LOCAL_MOUNT"
  sudo mount -t nfs -o rw,nofail,_netdev,vers=4 "$TS_IP:$NC_MOUNT" "$LOCAL_MOUNT" \
    || die "failed to mount $TS_IP:$NC_MOUNT over the tailnet - check exportfs on $TARGET"
  log "migrating the datadirectory to the external machine ($TS_IP:$NC_MOUNT)"
  sudo rsync -a --info=progress2 "$LOCAL_MOUNT.local-backup/" "$LOCAL_MOUNT/" \
    || die "rsync failed - rollback copy kept at $LOCAL_MOUNT.local-backup"
  sudo chown -R 33:33 "$LOCAL_MOUNT" || true
  SRC=$(sudo find "$LOCAL_MOUNT.local-backup" -type f 2>/dev/null | wc -l)
  DST=$(sudo find "$LOCAL_MOUNT" -type f 2>/dev/null | wc -l)
  [ "$SRC" = "$DST" ] || die "copy incomplete ($DST of $SRC files) - rollback copy kept"
  log "datadirectory copied: $SRC files"
fi

# ---------- import ----------
if [ "$ACTION" = "import" ]; then
  [ "$TARGET" = "$EXTERNAL_HOST" ] || die "target $TARGET does not match this host's export ($EXTERNAL_HOST)"
  # verify the export is still serving (importing only from your own export)
  S "$TARGET" "exportfs -v 2>/dev/null | grep -q '$EXTERNAL_MOUNT'" \
    || die "the exported datadirectory is no longer available at $EXTERNAL_HOST:$EXTERNAL_MOUNT"

  # stop app, unmount the live NFS mount so we can write to the local dir
  docker stop "$NC_CONTAINER" >/dev/null 2>&1 || true
  sudo umount "$LOCAL_MOUNT" 2>/dev/null || true
  sudo mkdir -p "$LOCAL_MOUNT"
  log "restoring the datadirectory from $TS_IP:$EXTERNAL_MOUNT"
  sudo rsync -a --info=progress2 "root@$TS_IP:$EXTERNAL_MOUNT/" "$LOCAL_MOUNT/" \
    || die "rsync failed"
  SRC="$(S "$TARGET" "find '$EXTERNAL_MOUNT' -type f 2>/dev/null | wc -l")"
  DST="$(sudo find "$LOCAL_MOUNT" -type f 2>/dev/null | wc -l)"
  [ "$SRC" = "$DST" ] || die "restore incomplete ($DST of $SRC files)"
  log "datadirectory restored: $DST files"
fi

# ---------- make the mount persistent, then start the app ----------
MOUNT_OPTS="rw,nofail,_netdev,vers=4,noatime,x-systemd.after=tailscaled.service,x-systemd.mount-timeout=300s,x-systemd.before=docker.service"
sudo sed -i "\#^[^#]*[[:space:]]$LOCAL_MOUNT[[:space:]]#d" /etc/fstab
sudo systemctl daemon-reload
if [ "$ACTION" = "export" ]; then
  log "adding a persistent mount in /etc/fstab"
  printf '%s\n' "$TS_IP:$NC_MOUNT $LOCAL_MOUNT nfs $MOUNT_OPTS 0 0" | sudo tee -a /etc/fstab >/dev/null
else
  log "local /etc/fstab NFS line removed"
fi
docker compose -f "$ROOT/modules/nextcloud/docker-compose.yml" up -d --no-deps nextcloud >/dev/null 2>&1 \
  || die "could not start $NC_CONTAINER"
for i in $(seq 1 30); do
  docker exec -u www-data "$NC_CONTAINER" php -r 'require "/var/www/html/lib/base.php";' 2>/dev/null && break
  sleep 2
done
sleep 5

# ---------- R/W probe (occ) ----------
OCC() { docker exec -u www-data "$NC_CONTAINER" php occ "$@"; }
docker exec -u www-data "$NC_CONTAINER" php occ maintenance:mode --off >/dev/null 2>&1 || true
FIRST_USER=$(OCC user:list 2>/dev/null | grep -oE '^  - [^:]+' | head -1 | awk '{print $2}')
docker exec -u www-data "$NC_CONTAINER" php -r '
  require_once "/var/www/html/lib/base.php";
  \OC_Util::setupFS($argv[1]);
  $v = \OC\Files\Filesystem::getView();
  $ok = $v->file_put_contents(".nc-data-probe", "ok") !== false \
      && trim((string)$v->file_get_contents(".nc-data-probe")) === "ok";
  $v->unlink(".nc-data-probe");
  exit($ok ? 0 : 1);
' "${FIRST_USER:-admin}" || die "datadirectory read/write probe failed"
log "datadirectory verified"

# ---------- post-actions ----------
if [ "$ACTION" = "export" ]; then
  printf '%s\n' "$TARGET" "$NC_MOUNT" > "$MARKER"
  log "export marker written: $MARKER (import will only ever use this source)"
  if [ -d "$LOCAL_MOUNT.local-backup" ] && [ "$(sudo ls -A "$LOCAL_MOUNT.local-backup" | wc -l)" -gt 0 ]; then
    sudo rm -rf "$LOCAL_MOUNT.local-backup"
    log "local datadirectory copies deleted - the external machine is now the permanent datadir host"
  fi
else
  rm -f "$MARKER"
  log "marker deleted; removing the external export"
  S "$TARGET" "exportfs -u; sed -i '/^$EXTERNAL_MOUNT /d' /etc/exports; exportfs -ra >/dev/null 2>&1; rm -rf \"$EXTERNAL_MOUNT\"" \
    || warn "could not fully clean up the export on $TARGET - review /etc/exports manually"
  log "datadirectory restored locally - the remote copy is gone"
fi

hr
if [ "$ACTION" = "export" ]; then
  cat <<'EOF'
 DONE - the Nextcloud datadirectory now lives PERMANENTLY on the external machine

    datadirectory   $TS_IP:$NC_MOUNT
    action          exported: this host's datadir was moved to $TARGET as its
                   permanent live datadir host (mounted over the tailnet)
    database        stays on this machine (nextcloud's PostgreSQL) - untouched
    marker          $MARKER (import will only ever use this host's own export)

    Manual steps (none block the service):
      1. Open https://cloud.$DOMAIN and confirm files + Talk still load.
      2. Check the data is on $TARGET: ssh $TARGET "ls -la $NC_MOUNT".
      3. To point back to the local datadir: stop $NC_CONTAINER, run
         'make nc-datadir-nfs' import, and the datadir is moved back.
EOF
else
  cat <<'EOF'
 DONE - the datadirectory was restored to $LOCAL_MOUNT from the external machine

    datadirectory   $LOCAL_MOUNT (local again)
    action          imported: the datadir was moved back from $TS_IP:$EXTERNAL_MOUNT
    database        stays on this machine (nextcloud's PostgreSQL) - untouched
    remote          export removed from $TARGET - the datadir lives here only

    Manual steps (none block the service):
      1. Open https://cloud.$DOMAIN and confirm files + Talk still load.
EOF
fi
hr
