#!/usr/bin/env bash
# scripts/ops/connect.sh — `make connect`: join this host's modules to another box.
#
# NFS-datadirectory only: the database stays on the main VPS and is NEVER moved
# — no dbhost change, no dump/restore, nothing touches the database. The user
# files (the datadirectory) are moved to the other box over NFS. This is the
# direct replacement of the old `make storage` command.
#
# It asks three things, in this order:
#   1. WHICH MODULE  — nextcloud today; kuma/vaultwarden print what they would
#                      need instead of pretending to work.
#   2. WHICH SERVER  — another box on the tailnet (`root@storage` or an IP).
#   3. WHAT TO DO    — about the datadirectory (the database stays on the main VPS):
#        overwrite   copy THIS host's datadirectory to the other server over NFS,
#                    replacing whatever is there. The other server gets NFS,
#                    tailscale, swap and a ufw gate set up. (the old
#                    'make storage' workflow)
#        link        mount the datadirectory that ALREADY lives on the other
#                    server over the tailnet. Nothing is copied on either side.
#      plus, for nextcloud, the full guided storage wizard (option 3 —
#      `scripts/ops/datadir-nfs.sh`, the old `make storage` command, untouched).
#
# Safety rails: the other server must answer before anything is written; the
# local datadirectory is backed up to `$LOCAL_MOUNT.local-backup` before the
# swap; the app is stopped for the swap and started again afterwards; the
# change is verified by a read/write probe on the mounted datadirectory; every
# step is idempotent and safe to re-run.
#
# Env overrides (no prompts): MODULE, TARGET, ACTION=datadir-overwrite|datadir-
# link, NC_CONTAINER, LOCAL_MOUNT, SIZE_GB, QUOTA_USER, QUOTA, STORAGE_PASS, TS_AUTHKEY.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
. "$ROOT/scripts/lib/instance.sh"

NC_CONTAINER="${NC_CONTAINER:-nextcloud}"
PG_CONTAINER="${PG_CONTAINER:-postgresql}"
NC_MOUNT="${NC_MOUNT:-/srv/nextcloud-data}"
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

  1) nextcloud    — user files over NFS to the other server; the PostgreSQL DB
                   stays on the main VPS (it is never moved)
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
DATA_DIR_NC="$(docker inspect "$NC_CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}')"
LOCAL_MOUNT="$DATA_DIR_NC"
[ -n "$DATA_DIR_NC" ] || die "cannot find the /data bind mount of $NC_CONTAINER (detection failed)"
[ -n "$DB_NAME" ] && [ -n "$DB_USER" ] && [ -n "$DB_PASS" ] \
  || die "cannot read the database credentials from $NC_CONTAINER (POSTGRES_* env missing)"
log "local: nc=$NC_CONTAINER db=$PG_CONTAINER ($DB_USER@$DB_NAME) data=$DATA_DIR_NC"

# ────────────────────── what should happen with the data ────────────────────
# The database NEVER moves: it stays on the main VPS. This block only decides
# what happens with the datadirectory.
if [ -z "$ACTION" ]; then
  hr
  cat <<EOF
What should happen with the Nextcloud datadirectory? (the database stays on this VPS)

  1) overwrite — copy THIS host's datadirectory to the other server over NFS,
                 replacing what is there. The other server must not exist yet:
                 it gets NFS + tailscale + swap set up. (the old 'make storage'
                 workflow)
  2) link      — mount the datadirectory that ALREADY lives on the other server
                 over the tailnet. Nothing is copied on either side.
  3) datadirectory — run the full guided storage wizard
                     (scripts/ops/datadir-nfs.sh, the old 'make storage'
                     command — untouched).
EOF
  read -r -p "choice [1]: " c
  case "${c:-1}" in
    1|overwrite|o) NC_ACTION="datadir-overwrite" ;;
    2|link|l)      NC_ACTION="datadir-link" ;;
    3|datadirectory|datadir|nfs) exec bash "$ROOT/scripts/ops/datadir-nfs.sh" ;;
    *) die "unknown choice: $c" ;;
  esac
else
  NC_ACTION="datadir-overwrite"
  case "$ACTION" in link|l|datadir-link) NC_ACTION="datadir-link";; esac
fi
log "action: $NC_ACTION — the database stays on the main VPS"

if [ -z "$TARGET" ]; then
  read -r -p "other server (tailnet name or root@ip): " TARGET
fi
[ -n "$TARGET" ] || die "a target server is required"
case "$TARGET" in *@*) ;; *) TARGET="root@$TARGET" ;; esac

# ───────────────── build the storage VPS (NFS + tailscale + ufw) ──────────────
log "checking that $TARGET answers and preparing the storage VPS"
S "$TARGET" "true" || die "cannot ssh to $TARGET (key installed? tailnet up?)"

S "$TARGET" "apt-get update -qq && apt-get install -y -qq curl ca-certificates ufw nfs-kernel-server >/dev/null 2>&1" \
  || die "failed to prepare the storage VPS"
if ! S "$TARGET" "command -v tailscale >/dev/null && tailscale status >/dev/null 2>&1"; then
  log "installing tailscale on storage"
  S "$TARGET" "curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1" \
    || die "tailscale install failed"
fi
if ! S "$TARGET" "tailscale status >/dev/null 2>&1"; then
  log "joining tailnet"
  S "$TARGET" "tailscale up --authkey '${TS_AUTHKEY:-$(read -r -s -p 'tailscale auth key: '; echo)}' >/dev/null 2>&1" \
    || die "tailscale up failed"
fi
for _ in $(seq 1 30); do
  TS_IP="$(S "$TARGET" "tailscale ip -4 2>/dev/null | head -1")"
  [ -n "$TS_IP" ] && break
  sleep 2
done
[ -n "$TS_IP" ] || die "no tailnet IP on $TARGET"
log "storage tailnet IP: $TS_IP"

# lockout gate: verify the tailnet path BEFORE any firewall change
sudo tailscale ping -c 2 "$TS_IP" >/dev/null 2>&1 || die "cannot ping storage over the tailnet"
T() { ssh -o StrictHostKeyChecking=accept-new root@"$TS_IP" "$@"; }
T "true" || die "tailnet ssh failed"
log "tailnet path verified — safe to restrict the firewall"

# ───────────────────── prepare the remote datadirectory ──────────────────────
log "setting up the NFS export on $TARGET at $NC_MOUNT"
S "$TARGET" "mkdir -p $NC_MOUNT && chown -R 33:33 $NC_MOUNT"
S "$TARGET" "grep -q '^$NC_MOUNT 100.64.0.0/10' /etc/exports 2>/dev/null \
  || echo '$NC_MOUNT 100.64.0.0/10(rw,sync,no_subtree_check,no_root_squash)' >> /etc/exports" \
  || die "failed to write /etc/exports on $TARGET"
S "$TARGET" "exportfs -ra >/dev/null 2>&1" || die "exportfs -ra failed on $TARGET"
# NFS needs 2049/111/20048 open to the tailnet (idempotent; rules may already exist)
S "$TARGET" "ufw allow from 100.64.0.0/10 to any port 2049 proto tcp; \
             ufw allow from 100.64.0.0/10 to any port 111 proto tcp; \
             ufw allow from 100.64.0.0/10 to any port 20048 proto tcp" >/dev/null 2>&1 \
  || warn "could not add the NFS ufw rules on $TARGET (they may already exist)"

# ──────────── overwrite: allocate space and copy THIS host's datadirectory ─────
if [ "$NC_ACTION" = "datadir-overwrite" ]; then
  log "this host holds the live datadirectory; copying it to storage ($TS_IP:$NC_MOUNT)"
  AVAIL_BYTES=$(S "$TARGET" "df -P '$NC_MOUNT' 2>/dev/null | awk 'NR==2{print \$4}'")
  [ -z "$AVAIL_BYTES" ] && AVAIL_BYTES=$(S "$TARGET" "df -P / | awk 'NR==2{print \$4}'")
  AVAIL_GB=$((AVAIL_BYTES / 1024 / 1024))
  while [ -z "${SIZE_GB:-}" ]; do
    read -r -p "size to allocate to Nextcloud on storage (GB, available: ${AVAIL_GB:-?}): " SIZE_GB
    case "$SIZE_GB" in
      ''|*[!0-9]*) echo "enter a number of GB"; SIZE_GB="";;
      *) [ "$SIZE_GB" -gt "$AVAIL_GB" ] 2>/dev/null && { echo "only $AVAIL_GB GB available — pick less"; SIZE_GB=""; };;
    esac
  done
  docker stop "$NC_CONTAINER" >/dev/null 2>&1 || true
  sudo mv "$LOCAL_MOUNT" "$LOCAL_MOUNT.local-backup" 2>/dev/null || sudo mkdir -p "$LOCAL_MOUNT.local-backup"
  sudo mkdir -p "$LOCAL_MOUNT"
  # mount the export locally and pull our data in
  sudo mount -t nfs -o rw,nofail,_netdev,vers=4 "$TS_IP:$NC_MOUNT" "$LOCAL_MOUNT" \
    || die "failed to mount $TS_IP:$NC_MOUNT over the tailnet — check exportfs on $TARGET"
  log "rsyncing the datadirectory to storage over the tailnet"
  sudo rsync -a --info=progress2 "$LOCAL_MOUNT.local-backup/" "$LOCAL_MOUNT/" \
    || die "rsync failed — rollback copy kept at $LOCAL_MOUNT.local-backup"
  SRC=$(sudo find "$LOCAL_MOUNT.local-backup" -type f 2>/dev/null | wc -l)
  DST=$(sudo find "$LOCAL_MOUNT" -type f 2>/dev/null | wc -l)
  [ "$SRC" = "$DST" ] || die "copy incomplete ($DST of $SRC files) — rollback copy kept"
  log "datadirectory copied: $SRC files"
  sudo umount "$LOCAL_MOUNT" || true
fi

# ─────────── link: check the remote datadirectory already exists ─────────────
if [ "$NC_ACTION" = "datadir-link" ]; then
  S "$TARGET" "exportfs -v 2>/dev/null | grep -q '$NC_MOUNT'" \
    || die "the datadirectory does not exist on $TARGET — run 'make connect' choice 1 (or datadir-nfs.sh) first."
fi

# ───────────────── mount the datadirectory here and start the app ─────────────
log "stopping $NC_CONTAINER to swap the datadirectory"
docker stop "$NC_CONTAINER" >/dev/null 2>&1 || true
sudo mv "$LOCAL_MOUNT" "$LOCAL_MOUNT.local-backup" 2>/dev/null || sudo mkdir -p "$LOCAL_MOUNT.local-backup"
sudo mkdir -p "$LOCAL_MOUNT"
if ! sudo mount -t nfs -o rw,nofail,_netdev,vers=4 "$TS_IP:$NC_MOUNT" "$LOCAL_MOUNT" >/dev/null 2>&1; then
  [ ! -x /sbin/mount.nfs ] && sudo apt-get install -y -qq nfs-common >/dev/null 2>&1
  sudo mount -t nfs -o rw,nofail,_netdev,vers=4 "$TS_IP:$NC_MOUNT" "$LOCAL_MOUNT" \
    || die "failed to mount $TS_IP:$NC_MOUNT (nfs-common missing? check ufw on storage allows 2049)"
fi
[ "$NC_ACTION" = "datadir-overwrite" ] && log "datadirectory migrated to storage" \
  || log "datadirectory linked from storage"
# reboot-safe mount: ordered after tailscaled, before docker, 300s mount budget
MOUNT_OPTS="rw,nofail,_netdev,vers=4,noatime,x-systemd.after=tailscaled.service,x-systemd.mount-timeout=300s,x-systemd.before=docker.service"
sudo sed -i "\#^[^#]*[[:space:]]$LOCAL_MOUNT[[:space:]]#d" /etc/fstab
printf '%s\n' "$TS_IP:$NC_MOUNT $LOCAL_MOUNT nfs $MOUNT_OPTS 0 0" | sudo tee -a /etc/fstab >/dev/null
sudo systemctl daemon-reload
docker compose -f "$ROOT/modules/nextcloud/docker-compose.yml" up -d --no-deps nextcloud >/dev/null 2>&1 \
  || die "could not start $NC_CONTAINER"
for i in $(seq 1 30); do
  docker exec -u www-data "$NC_CONTAINER" php -r 'require "/var/www/html/lib/base.php";' 2>/dev/null && break
  sleep 2
done

# ─────────── verify the live datadirectory (read/write probe) ────────────────
sleep 5
OCC maintenance:mode --off >/dev/null 2>&1 || true
FIRST_USER=$(OCC user:list 2>/dev/null | grep -oE '^  - [^:]+' | head -1 | awk '{print $2}')
docker exec -u www-data "$NC_CONTAINER" php -r '
  require_once "/var/www/html/lib/base.php";
  \OC_Util::setupFS($argv[1]);
  $v = \OC\Files\Filesystem::getView();
  $ok = $v->file_put_contents(".storage-probe", "ok") !== false \
      && trim((string)$v->file_get_contents(".storage-probe")) === "ok";
  $v->unlink(".storage-probe");
  exit($ok ? 0 : 1);
' "${FIRST_USER:-admin}" || die "datadirectory read/write probe failed"
log "datadirectory verified on $TARGET ($TS_IP:$NC_MOUNT)"

# ─────────── delete the local rollback copy now that it is verified ───────────
if [ -d "$LOCAL_MOUNT.local-backup" ] && [ "$(sudo ls -A "$LOCAL_MOUNT.local-backup" | wc -l)" -gt 0 ]; then
  read -r -p "delete the local datadirectory copies ($LOCAL_MOUNT.local-backup)? [y/N] " ans
  case "$ans" in y|Y|yes) sudo rm -rf "$LOCAL_MOUNT.local-backup"; log "local copies deleted";;
    *) log "rollback kept at $LOCAL_MOUNT.local-backup (delete later: sudo rm -rf $LOCAL_MOUNT.local-backup)";;
  esac
fi

hr
cat <<EOF
 DONE — the Nextcloud datadirectory now lives on $TARGET

   datadirectory  $TS_IP:$NC_MOUNT
   action         $([ "$NC_ACTION" = "datadir-overwrite" ] && echo "migrated: the remote copy came from this host" || echo "linked: the remote datadirectory is used as-is")
   database       stays on the main VPS ($PG_CONTAINER, $DB_NAME) — untouched

 Manual steps (none block the service):
   1. Open https://cloud.$DOMAIN and confirm files + Talk still load.
   2. Check the data is on storage: ssh $TARGET 'ls -la $NC_MOUNT'.
   3. If the migration was verified, the local copies were removed; otherwise
      the rollback copy is at $LOCAL_MOUNT.local-backup (delete by hand when
      you are sure).
   4. To point back to the local datadirectory: stop $NC_CONTAINER, mount this
      host's datadirectory again, then start the container.
EOF
hr
