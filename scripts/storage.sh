#!/usr/bin/env bash
#
# scripts/storage.sh — make a storage VPS (e.g. 1 TB / 2 GB) the LIVE
# Nextcloud datadirectory, mounted over the tailnet via NFS. PostgreSQL stays
# on the Nextcloud host; the datadirectory (user files + appdata) physically
# lives on the storage VPS. The nightly pg_dump is pushed there too (backups
# coexist, but the box's role is live storage).
#
# Fully autonomous after a few prompts, like install.sh — adapts to ANY host
# that runs the Nextcloud docker image (container name, datadirectory and DB
# credentials are auto-detected), so friends can run it against their own
# VPSes.
#
# Prompts (beginning):
#   1. storage ssh target (root@<ip>) + root password      (password: read -s)
#   2. tailscale auth key                                   (read -s)
#   3. size to allocate to Nextcloud on storage — probed against the disk's
#      available space, validated <= available
#   4. your Nextcloud user id (default: first user) + personal quota
# After the migration it ASKS whether to delete the local datadirectory
# copies it moved (the rollback copy).
#
# Lockout-safe: storage is never firewalled until the tailnet path is
# verified from the Nextcloud host. Errors are collected and shown in the
# same error table style as install.sh (problem + hint per tag); the summary
# lists the manual steps. Idempotent — safe to re-run.
#
# Vars (all overridable): STORAGE_SSH STORAGE_PASS TS_AUTHKEY QUOTA_USER
# QUOTA NC_CONTAINER SIZE_GB NC_MOUNT (storage export dir + local mount)

set -uo pipefail

NC_CONTAINER="${NC_CONTAINER:-nextcloud}"
QUOTA="${QUOTA:-300 GB}"
NC_MOUNT="${NC_MOUNT:-/srv/nextcloud-data}"          # dir on the storage VPS
LOCAL_MOUNT=/var/www/custom/projects/homelab/cloud/users   # NC datadirectory (host path)

log() { echo "[storage] $*"; }
die() { echo "[storage] FATAL: $*" >&2; exit 1; }

# ---------- auto-detect the Nextcloud host ----------
command -v docker >/dev/null || die "docker not found on this host"
docker ps --format '{{.Names}}' | grep -qx "$NC_CONTAINER" \
  || die "container '$NC_CONTAINER' is not running (set NC_CONTAINER=...)"
PG_CONTAINER=$(docker ps --format '{{.Names}}' | grep -iE 'postgres' | head -1)
[ -n "$PG_CONTAINER" ] || die "no postgres container found (set the name or run one)"
DATA_DIR=$(docker inspect "$NC_CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}')
[ -n "$DATA_DIR" ] || die "cannot find the /data bind mount of $NC_CONTAINER"
LOCAL_MOUNT="$DATA_DIR"
PG_USER=$(docker inspect "$NC_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^POSTGRES_USER=//p' | head -1)
PG_DB=$(docker inspect "$NC_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^POSTGRES_DB=//p' | head -1)
PG_USER=${PG_USER:-nextcloud}
PG_DB=${PG_DB:-nextcloud}
OCC() { docker exec -u www-data "$NC_CONTAINER" php occ "$@"; }
PSQL() { docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" "$@"; }
OCC maintenance:mode --off >/dev/null 2>&1 || true
FIRST_USER=$(OCC user:list 2>/dev/null | grep -oE '^  - [^:]+' | head -1 | awk '{print $2}')
log "detected: nc=$NC_CONTAINER data=$DATA_DIR pg=$PG_CONTAINER ($PG_USER/$PG_DB) first-user=${FIRST_USER:-none}"

# ---------- prompts ----------
STORAGE_SSH="${STORAGE_SSH:-}"
[ -n "$STORAGE_SSH" ] || read -r -p "storage VPS ssh target (root@<ip>): " STORAGE_SSH
[ -n "$STORAGE_SSH" ] || die "storage ssh target required"
[ -n "${STORAGE_PASS:-}" ] || read -r -s -p "storage root password: " STORAGE_PASS; echo
[ -n "${TS_AUTHKEY:-}" ] || read -r -s -p "tailscale auth key: " TS_AUTHKEY; echo
[ -n "$STORAGE_PASS" ] || die "storage password empty"
[ -n "$TS_AUTHKEY" ] || die "tailscale auth key empty"
export SSHPASS="$STORAGE_PASS"
command -v sshpass >/dev/null || sudo apt-get install -y -qq sshpass >/dev/null || die "sshpass install failed"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
S() { sshpass -e ssh "${SSH_OPTS[@]}" "$1" "$2"; }          # S <host> <command>
T() { S "root@$TS_IP" "$@"; }                                # storage over the tailnet

# ---------- error framework (install.sh style) ----------
ERR=""
fail() { ERR="${ERR} $1"; echo "[storage] FAIL: $1 — ${2:-see hint}"; }
problem() { case "$1" in
  ssh)          echo "PROBLEM: cannot ssh to the storage VPS" ;;
  tailscale)    echo "PROBLEM: storage not on the tailnet (or the auth key was rejected)" ;;
  ufw)          echo "PROBLEM: firewall/swap setup on storage failed" ;;
  nfs)          echo "PROBLEM: the NFS export on storage is not serving" ;;
  mount)        echo "PROBLEM: the NFS mount on the NC host failed" ;;
  migrate)      echo "PROBLEM: the datadirectory rsync did not complete" ;;
  verify)       echo "PROBLEM: Nextcloud could not read/write through the mounted datadirectory" ;;
  quota)        echo "PROBLEM: quota not set for '$QUOTA_USER'" ;;
  cron)         echo "PROBLEM: nightly backup cron not installed" ;;
esac; }
hint() { case "$1" in
  ssh)          echo "HINT: check the ssh target/password; storage still answers on the public IP before the firewall step" ;;
  tailscale)    echo "HINT: generate a fresh auth key (admin console → Keys) and re-run; check 'tailscale status' on storage" ;;
  ufw)          echo "HINT: ssh to storage over the tailnet (root@$TS_IP) and inspect: ufw status; swap via 'swapon --show'" ;;
  nfs)          echo "HINT: on storage: systemctl status nfs-server; exportfs -v; showmount -e localhost; the export must allow 100.64.0.0/10" ;;
  mount)        echo "HINT: on the NC host: sudo mount -t nfs $TS_IP:$NC_MOUNT $LOCAL_MOUNT; check ufw on storage allows 2049/111 from 100.64.0.0/10" ;;
  migrate)      echo "HINT: re-run — the rsync resumes; verify with: sudo rsync -a $LOCAL_MOUNT.local-backup/ $LOCAL_MOUNT/" ;;
  verify)       echo "HINT: the container must be up and the mount live: mount | grep $LOCAL_MOUNT; then occ status + a file write through the web UI" ;;
  quota)        echo "HINT: run: make nc-user-setting USER=$QUOTA_USER KEY=quota VALUE='$QUOTA'" ;;
  cron)         echo "HINT: re-run — the cron (sudo tee /etc/cron.d/nc-storage) installs with root's ssh key on storage" ;;
esac; }
recheck() { case "$1" in
  ssh)          S "$TARGET" "true" ;;
  tailscale)    [ -n "$TS_IP" ] && T "tailscale status >/dev/null 2>&1" ;;
  ufw)          T "ufw status | grep -q 'Status: active'" ;;
  nfs)          T "exportfs -v 2>/dev/null | grep -q '$NC_MOUNT'" ;;
  mount)        mount | grep -q "$LOCAL_MOUNT " ;;
  migrate)      sudo rsync -a --delete --dry-run "$LOCAL_MOUNT.local-backup/" "$LOCAL_MOUNT/" >/dev/null 2>&1 ;;
  verify)       docker exec -u www-data "$NC_CONTAINER" php -r '
                  require_once "/var/www/html/lib/base.php";
                  \OC_Util::setupFS($argv[1]);
                  $v = \OC\Files\Filesystem::getView();
                  $ok = $v->file_put_contents(".storage-probe", "ok") !== false && trim((string)$v->file_get_contents(".storage-probe")) === "ok";
                  $v->unlink(".storage-probe");
                  exit($ok ? 0 : 1);
                ' "$QUOTA_USER" ;;
  quota)        OCC user:setting "$QUOTA_USER" files quota 2>/dev/null | grep -q '[A-Za-z0-9]' ;;
  cron)         sudo test -f /etc/cron.d/nc-storage ;;
esac; }

# ---------- resolve the storage host (tailnet first on re-runs) ----------
TS_IP=$(sudo tailscale status 2>/dev/null | awk '$2=="storage"{print $1; exit}')
if [ -n "$TS_IP" ] && S "root@$TS_IP" "true" >/dev/null 2>&1; then
  TARGET="root@$TS_IP"
  log "storage already on the tailnet ($TS_IP)"
else
  TS_IP=""
  TARGET="$STORAGE_SSH"
fi
S "$TARGET" "true" || fail ssh "cannot ssh to $TARGET"

# ---------- storage: base packages + tailscale (lockout-safe) ----------
S "$TARGET" "hostnamectl set-hostname storage 2>/dev/null || hostname storage; apt-get update -qq && apt-get install -y -qq curl ca-certificates ufw" \
  || fail ufw "base packages"
if ! S "$TARGET" "command -v tailscale >/dev/null && tailscale status >/dev/null 2>&1"; then
  log "installing tailscale on storage"
  S "$TARGET" "curl -fsSL https://tailscale.com/install.sh | sh" || fail tailscale "install"
fi
if ! S "$TARGET" "tailscale status >/dev/null 2>&1"; then
  log "joining tailnet"
  S "$TARGET" "tailscale up --authkey '$TS_AUTHKEY' --hostname storage" || fail tailscale "up"
fi
for _ in $(seq 1 30); do
  TS_IP=$(S "$TARGET" "tailscale ip -4 2>/dev/null | head -1")
  [ -n "$TS_IP" ] && break
  sleep 2
done
[ -n "$TS_IP" ] || fail tailscale "no tailnet IP"
log "storage tailnet IP: $TS_IP"

# lockout gate: verify the tailnet path BEFORE any firewall change
sudo tailscale ping -c 2 "$TS_IP" >/dev/null 2>&1 || fail tailscale "ping"
T "true" || fail ssh "tailnet"
log "tailnet ssh verified — safe to restrict the firewall"
sudo tailscale ping -c 1 "$TS_IP" 2>&1 | grep -q "direct" \
  && log "tailnet link: direct" \
  || log "WARN: link may be DERP-relayed — file transfers will be slow; check 'tailscale status'"

# ---------- allocation size prompt (validated against available disk) ----------
AVAIL_BYTES=$(T "df -P '$NC_MOUNT' 2>/dev/null | awk 'NR==2{print \$4}'" 2>/dev/null)
if [ -z "$AVAIL_BYTES" ]; then
  AVAIL_BYTES=$(T "df -P / | awk 'NR==2{print \$4}'")
  NC_MOUNT=/srv/nextcloud-data
fi
AVAIL_GB=$(( AVAIL_BYTES / 1024 / 1024 ))
SIZE_GB="${SIZE_GB:-}"
while [ -z "$SIZE_GB" ]; do
  read -r -p "size to allocate to Nextcloud on storage (GB, available: $AVAIL_GB): " SIZE_GB
  case "$SIZE_GB" in
    ''|*[!0-9]*) echo "enter a number of GB"; SIZE_GB="" ;;
    *) if [ "$SIZE_GB" -gt "$AVAIL_GB" ]; then echo "only $AVAIL_GB GB available — pick less"; SIZE_GB=""; fi ;;
  esac
done
log "allocating ${SIZE_GB} GB of ${AVAIL_GB} GB available to Nextcloud (per-user quotas enforce the split)"

# ---------- storage: ufw (tailnet-only: 22 + NFS) + swap ----------
T "ufw default deny incoming && ufw allow from 100.64.0.0/10 to any port 22 proto tcp && ufw allow from 100.64.0.0/10 to any port 2049 proto tcp && ufw allow from 100.64.0.0/10 to any port 111 proto tcp && ufw allow from 100.64.0.0/10 to any port 20048 proto tcp && ufw --force enable" \
  || fail ufw "rules"
T "grep -q /swapfile /etc/fstab 2>/dev/null || { fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab; }" \
  || fail ufw "swap"

# ---------- storage: NFS export of the live datadirectory ----------
if ! T "dpkg -l nfs-kernel-server 2>/dev/null | grep -q '^ii'"; then
  T "apt-get install -y -qq nfs-kernel-server >/dev/null 2>&1" || fail nfs "install"
fi
T "mkdir -p $NC_MOUNT && chown -R 33:33 $NC_MOUNT" || fail nfs "dir"
T "grep -q '$NC_MOUNT' /etc/exports 2>/dev/null || echo '$NC_MOUNT 100.64.0.0/10(rw,sync,no_subtree_check,no_root_squash)' >> /etc/exports" || fail nfs "exports"
T "sed -i 's/^#\?port=.*/port=20048/' /etc/nfs.conf 2>/dev/null; sed -i 's/^\[mountd\]/[mountd]/' /etc/nfs.conf; grep -q '^port=20048' /etc/nfs.conf || sed -i '/\[mountd\]/a port=20048' /etc/nfs.conf" || true
T "exportfs -ra && systemctl enable --now nfs-server >/dev/null 2>&1 && exportfs -v 2>/dev/null | grep -q '$NC_MOUNT'" \
  || fail nfs "export"

# ---------- fxmq: mount + migrate the live datadirectory ----------
if ! mount | grep -q "$LOCAL_MOUNT "; then
  log "mounting $TS_IP:$NC_MOUNT at $LOCAL_MOUNT"
  docker stop "$NC_CONTAINER" >/dev/null 2>&1 || true
  sudo mv "$LOCAL_MOUNT" "$LOCAL_MOUNT.local-backup" 2>/dev/null || sudo mkdir -p "$LOCAL_MOUNT.local-backup"
  sudo mkdir -p "$LOCAL_MOUNT"
  sudo mount -t nfs -o rw,nofail,vers=4 "$TS_IP:$NC_MOUNT" "$LOCAL_MOUNT" || fail mount "nfs mount failed"
  log "migrating the datadirectory to storage (rsync over the tailnet)"
  sudo rsync -a "$LOCAL_MOUNT.local-backup/" "$LOCAL_MOUNT/" || fail migrate "rsync failed"
  sudo chown -R 33:33 "$LOCAL_MOUNT" || true
  sudo tee -a /etc/fstab >/dev/null <<EOF
$TS_IP:$NC_MOUNT $LOCAL_MOUNT nfs rw,nofail,vers=4 0 0
EOF
  log "fstab entry added (auto-remount on reboot)"
  docker start "$NC_CONTAINER" >/dev/null 2>&1 || fail verify "container start"
fi

# ---------- verify the live datadirectory ----------
sleep 5
OCC maintenance:mode --off >/dev/null 2>&1 || true
docker exec -u www-data "$NC_CONTAINER" php -r '
  require_once "/var/www/html/lib/base.php";
  \OC_Util::setupFS($argv[1]);
  $v = \OC\Files\Filesystem::getView();
  $ok = $v->file_put_contents(".storage-probe", "ok") !== false && trim((string)$v->file_get_contents(".storage-probe")) === "ok";
  $v->unlink(".storage-probe");
  exit($ok ? 0 : 1);
' "$QUOTA_USER" || fail verify "read/write probe failed"
log "datadirectory verified on the storage VPS ($TS_IP:$NC_MOUNT, ${SIZE_GB} GB allocated)"

# ---------- delete the local copies? (prompt after a successful migration) ----------
if [ -d "$LOCAL_MOUNT.local-backup" ] && [ "$(sudo ls -A "$LOCAL_MOUNT.local-backup" | wc -l)" -gt 0 ]; then
  read -r -p "delete the local datadirectory copies ($LOCAL_MOUNT.local-backup) now? [y/N] " ans
  case "$ans" in y|Y|yes) sudo rm -rf "$LOCAL_MOUNT.local-backup" && log "local copies deleted — storage is the only copy" ;;
  *) log "keeping $LOCAL_MOUNT.local-backup as rollback (delete later with: sudo rm -rf $LOCAL_MOUNT.local-backup)" ;; esac
fi

# ---------- quota + off-host DB backup (coexists; the box is live storage now) ----------
OCC user:setting "$QUOTA_USER" files quota "$QUOTA" >/dev/null 2>&1 \
  && log "quota set: $QUOTA_USER = $QUOTA" || fail quota "user '$QUOTA_USER'"
sudo test -f /root/.ssh/id_ed25519 || sudo ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519 >/dev/null
sudo SSHPASS="$SSHPASS" sshpass -e ssh-copy-id -o StrictHostKeyChecking=accept-new "root@$TS_IP" >/dev/null 2>&1 \
  || fail cron "ssh key copy"
sudo tee /etc/cron.d/nc-storage >/dev/null <<EOF
# Off-host Nextcloud DB backup -> storage:/backups/nc (installed by scripts/storage.sh)
30 2 * * * root docker exec $PG_CONTAINER pg_dump -U $PG_USER -d $PG_DB -Fc | ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@$TS_IP "mkdir -p /backups/nc && cat > /backups/nc/nextcloud-\$(date +\%F).dump && ls -t /backups/nc/nextcloud-*.dump 2>/dev/null | tail -n +8 | xargs -r rm"
EOF
log "nightly pg_dump -> storage:/backups/nc installed (keeps 7)"

# ---------- re-check loop: resolve every collected error (install.sh style) ----------
if [ -n "$ERR" ]; then
  while [ -n "$ERR" ]; do
    echo ""
    echo "=== ${ERR} — fix the issues below, then press Enter to re-check ==="
    for t in $ERR; do problem "$t"; hint "$t"; done
    read -r -p "press Enter to re-check (or type 'quit'): " ans \
      || { echo "non-interactive run — leaving unresolved: $ERR"; exit 1; }
    [ "$ans" = "quit" ] && { echo "leaving unresolved: $ERR"; exit 1; }
    NEW=""
    for t in $ERR; do recheck "$t" && log "OK: $t" || NEW="${NEW} $t"; done
    ERR="$NEW"
  done
fi

# ---------- summary: error table (same style as install.sh) ----------
if [ -n "$ERR" ]; then
  echo ""
  echo " ERROR(S) — no success until every item below is resolved:"
  i=1
  for t in $ERR; do
    echo "   $i. $t"
    echo "      problem: $(problem "$t")"
    echo "      hint: $(hint "$t")"
    i=$((i+1))
  done
  exit 1
fi

# ---------- success block (manual steps, same style as install.sh) ----------
echo ""
echo "=============================================================="
echo " SUCCESS — Nextcloud's live datadirectory is now on the storage VPS:"
echo "   datadirectory  $TS_IP:$NC_MOUNT (${SIZE_GB} GB allocated) mounted at $LOCAL_MOUNT"
echo "   PostgreSQL     stays on this host ($PG_CONTAINER, bridge-only)"
echo "   backups        nightly pg_dump -> storage:/backups/nc (keeps 7)"
echo "   quota          $QUOTA_USER = $QUOTA"
echo ""
echo " Manual steps (none block the service):"
echo "   1. Verify from the web UI: log in, upload a file, and confirm it lands on"
echo "      storage (ssh storage: ls $NC_MOUNT/<uid>/files/)"
echo "   2. Friends' quotas: make nc-user-setting USER=<uid> KEY=quota VALUE='...'"
echo "   3. The old local copies:"
if [ -d "$LOCAL_MOUNT.local-backup" ] && [ "$(sudo ls -A "$LOCAL_MOUNT.local-backup" | wc -l)" -gt 0 ]; then
  echo "      sudo rm -rf $LOCAL_MOUNT.local-backup  (kept as rollback)"
else
  echo "      deleted during this run (storage is the only copy)"
fi
echo "   4. Reboot safety: the NFS mount is in /etc/fstab (nofail) — after a reboot"
echo "      verify: mount | grep $LOCAL_MOUNT"
echo "=============================================================="
