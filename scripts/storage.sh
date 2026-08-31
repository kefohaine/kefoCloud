#!/usr/bin/env bash
#
# scripts/storage.sh — onboard the 1 TB / 2 GB storage VPS as Nextcloud's
# object storage (Setup A: PostgreSQL stays on fxmq; user files move to
# Garage on storage). Run from the fxmq host: `make storage`.
#
# Prompts (read -s, never echoed):
#   1. storage root password   (SSH to the box, default root@169.40.15.125)
#   2. tailscale auth key      (join the fxmq tailnet)
#
# Lockout-safe: nothing is firewalled until the tailnet path to storage is
# verified from fxmq (tailscale ping + ssh over the tailnet IP). All
# post-lockdown commands run over the tailnet session.
#
# Flow:
#   storage: hostname, tailscale, ufw (tailnet-only 22 + S3 port), swap,
#            garage (S3) + bucket/keys
#   fxmq:    mc copies the datadirectory user files into the bucket,
#            NC primary object store configured (secrets via env, never
#            argv), quota set, occ files:scan verify, nightly pg_dump
#            pushed to storage:/backups/nc (key-based, no secrets in cron)
#
# Idempotent — safe to re-run; completed steps are skipped.
#
# Vars (defaults overridable): STORAGE_SSH GARAGE_VERSION GARAGE_PORT
# BUCKET SWAP_GB QUOTA_USER QUOTA GARAGE_DIR

set -uo pipefail

STORAGE_SSH="${STORAGE_SSH:-root@169.40.15.125}"
GARAGE_VERSION="${GARAGE_VERSION:-v1.0.1}"
GARAGE_PORT="${GARAGE_PORT:-3900}"
BUCKET="${BUCKET:-nextcloud}"
SWAP_GB="${SWAP_GB:-2}"
QUOTA_USER="${QUOTA_USER:-admin}"
QUOTA="${QUOTA:-300 GB}"
GARAGE_DIR="${GARAGE_DIR:-/var/lib/garage}"
DATA_DIR=/var/www/custom/projects/homelab/cloud/users   # NC datadirectory (host path)

log() { echo "[storage] $*"; }
die() { echo "[storage] ERROR: $*" >&2; exit 1; }

# ---------- prompts ----------
[ -n "${STORAGE_PASS:-}" ] || read -r -s -p "storage root password: " STORAGE_PASS; echo
[ -n "${TS_AUTHKEY:-}" ] || read -r -s -p "tailscale auth key: " TS_AUTHKEY; echo
[ -n "$STORAGE_PASS" ] || die "storage password empty"
[ -n "$TS_AUTHKEY" ] || die "tailscale auth key empty"
export SSHPASS="$STORAGE_PASS"

command -v sshpass >/dev/null || sudo apt-get install -y -qq sshpass >/dev/null || die "sshpass install failed"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
S() { sshpass -e ssh "${SSH_OPTS[@]}" "$1" "$2"; }          # S <host> <command>
T() { S "root@$TS_IP" "$@"; }                                # storage over the tailnet

# ---------- fxmq preflight ----------
S "$STORAGE_SSH" "true" || die "cannot ssh to $STORAGE_SSH (wrong password?)"
docker ps --format '{{.Names}}' | grep -qx nextcloud || die "nextcloud container not running"

# ---------- storage: hostname + base packages ----------
S "$STORAGE_SSH" "hostnamectl set-hostname storage 2>/dev/null || hostname storage; apt-get update -qq && apt-get install -y -qq curl ca-certificates" \
  || die "storage base setup failed"

# ---------- storage: tailscale ----------
if ! S "$STORAGE_SSH" "command -v tailscale >/dev/null && tailscale status >/dev/null 2>&1"; then
  log "installing tailscale on storage"
  S "$STORAGE_SSH" "curl -fsSL https://tailscale.com/install.sh | sh" || die "tailscale install failed"
fi
if ! S "$STORAGE_SSH" "tailscale status >/dev/null 2>&1"; then
  log "joining tailnet"
  S "$STORAGE_SSH" "tailscale up --authkey '$TS_AUTHKEY' --hostname storage" || die "tailscale up failed — check the auth key"
fi
TS_IP=""
for _ in $(seq 1 30); do
  TS_IP=$(S "$STORAGE_SSH" "tailscale ip -4 2>/dev/null | head -1")
  [ -n "$TS_IP" ] && break
  sleep 2
done
[ -n "$TS_IP" ] || die "storage has no tailnet IP yet"
log "storage tailnet IP: $TS_IP"

# lockout gate: verify the tailnet path from fxmq BEFORE any firewall change
sudo tailscale ping -c 2 "$TS_IP" >/dev/null 2>&1 || die "tailscale ping $TS_IP failed — aborting (nothing was locked down)"
T "true" || die "ssh over the tailnet failed — aborting (nothing was locked down)"
log "tailnet ssh verified — safe to restrict the firewall"
sudo tailscale ping -c 1 "$TS_IP" 2>&1 | grep -q "direct" \
  && log "tailnet link: direct" \
  || log "WARN: link may be DERP-relayed — file transfers will be slow; check 'tailscale status'"

# ---------- storage: ufw (tailnet-only) + swap ----------
T "ufw default deny incoming && ufw allow from 100.64.0.0/10 to any port 22 proto tcp && ufw allow from 100.64.0.0/10 to any port $GARAGE_PORT proto tcp && ufw --force enable" \
  || die "ufw setup failed (tailnet ssh still works — inspect the rules)"
T "grep -q /swapfile /etc/fstab 2>/dev/null || { fallocate -l ${SWAP_GB}G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab; }" \
  || die "swap setup failed"

# ---------- storage: garage ----------
if ! T "command -v garage >/dev/null"; then
  log "installing garage $GARAGE_VERSION"
  T "curl -fsSL -o /tmp/garage.tgz https://git.deuxfleurs.fr/garage/garage/releases/download/$GARAGE_VERSION/garage-$GARAGE_VERSION-x86_64-unknown-linux-musl.tar.gz && tar xzf /tmp/garage.tgz -C /usr/local/bin garage && chmod +x /usr/local/bin/garage" \
    || die "garage install failed"
fi
if ! T "systemctl is-active --quiet garage"; then
  log "configuring garage"
  RPC_SECRET=$(T "openssl rand -hex 32") || die "rpc secret failed"
  ADMIN_TOKEN=$(T "openssl rand -hex 32") || die "admin token failed"
  T "useradd -r -d $GARAGE_DIR -s /bin/false garage 2>/dev/null; mkdir -p $GARAGE_DIR/meta $GARAGE_DIR/data && chown -R garage:garage $GARAGE_DIR" \
    || die "garage dirs failed"
  printf 'metadata_dir = "%s/meta"\ndata_dir = "%s/data"\ndb_engine = "lmdb"\nblock_size = 1048576\nreplication_mode = "none"\nrpc_bind_addr = "127.0.0.1:3901"\nrpc_secret = "%s"\ns3_api = { api_addr = "0.0.0.0:%s", s3_region = "garage" }\nadmin = { api_addr = "127.0.0.1:3903", admin_token = "%s" }\n' \
    "$GARAGE_DIR" "$GARAGE_DIR" "$RPC_SECRET" "$GARAGE_PORT" "$ADMIN_TOKEN" \
    | T "cat > /etc/garage.toml && chmod 600 /etc/garage.toml" || die "garage config failed"
  printf '%s\n' \
    '[Unit]' 'Description=Garage object storage' 'After=network-online.target' 'Wants=network-online.target' \
    '[Service]' 'ExecStart=/usr/local/bin/garage server -c /etc/garage.toml' 'Restart=on-failure' 'User=garage' 'Group=garage' \
    '[Install]' 'WantedBy=multi-user.target' \
    | T "cat > /etc/systemd/system/garage.service && systemctl daemon-reload && systemctl enable --now garage" \
    || die "garage service failed"
  sleep 3
  NODE_ID=$(T "garage -c /etc/garage.toml node id 2>/dev/null") || die "garage node id failed"
  T "garage -c /etc/garage.toml layout assign '$NODE_ID' --zone storage --capacity 1T && garage -c /etc/garage.toml layout apply --version 1" \
    || die "garage layout failed"
  if T "garage -c /etc/garage.toml bucket info $BUCKET >/dev/null 2>&1"; then
    T "garage -c /etc/garage.toml key info nc-s3 2>&1 | tee /root/.nc-s3.env >/dev/null; chmod 600 /root/.nc-s3.env" \
      || die "garage key info failed"
  else
    T "garage -c /etc/garage.toml bucket create $BUCKET && garage -c /etc/garage.toml key create nc-s3 2>&1 | tee /root/.nc-s3.env >/dev/null && chmod 600 /root/.nc-s3.env" \
      || die "garage bucket/key create failed"
    T "garage -c /etc/garage.toml bucket allow --read --write $BUCKET --key nc-s3" || die "garage bucket allow failed"
  fi
fi

# S3 credentials (kept in shell vars, never printed)
NC_S3_KEY=$(T "awk -F': ' '/Key ID/{print \$2; exit}' /root/.nc-s3.env")
NC_S3_SECRET=$(T "awk -F': ' '/Secret access key/{print \$2; exit}' /root/.nc-s3.env")
[ -n "$NC_S3_KEY" ] && [ -n "$NC_S3_SECRET" ] || die "no S3 credentials on storage"
log "garage ready ($BUCKET, bucket keys on storage:/root/.nc-s3.env)"

# ---------- fxmq: container must reach the S3 endpoint ----------
docker exec nextcloud bash -c "timeout 5 bash -c 'exec 3<>/dev/tcp/$TS_IP/$GARAGE_PORT' && echo reachable" >/dev/null 2>&1 \
  || die "nextcloud container cannot reach $TS_IP:$GARAGE_PORT — check tailnet/firewall"

# ---------- fxmq: move files + configure primary object store ----------
if ! docker exec -u www-data nextcloud php occ config:system:get objectstore 2>/dev/null | grep -q "S3"; then
  command -v mc >/dev/null || curl -fsSL -o /tmp/mc https://dl.min.io/client/mc/release/linux-amd64/mc && sudo install -m755 /tmp/mc /usr/local/bin/mc
  command -v mc >/dev/null || die "mc (minio client) install failed"

  log "moving datadirectory files into the bucket (maintenance mode)"
  docker exec -u www-data nextcloud php occ maintenance:mode --on || die "maintenance mode failed"
  mc alias set ncgarage "http://$TS_IP:$GARAGE_PORT" "$NC_S3_KEY" "$NC_S3_SECRET" >/dev/null || die "mc alias failed"
  for d in "$DATA_DIR"/*/; do
    name=$(basename "$d")
    case "$name" in appdata_* | updater-*) continue ;; esac
    mc cp --recursive "$d" "ncgarage/$BUCKET/" >/dev/null || die "mc copy of '$name' failed"
  done

  log "configuring NC primary object store"
  docker exec -e NC_S3_KEY="$NC_S3_KEY" -e NC_S3_SECRET="$NC_S3_SECRET" \
           -e NC_S3_HOST="$TS_IP" -e NC_S3_PORT="$GARAGE_PORT" -e NC_S3_BUCKET="$BUCKET" \
           -u www-data nextcloud php -r '
    $f = "/var/www/html/config/config.php";
    $c = require $f;
    $c["objectstore"] = [
      "class" => "OC\\Files\\ObjectStore\\S3",
      "arguments" => [
        "bucket" => getenv("NC_S3_BUCKET"), "autocreate" => true,
        "key" => getenv("NC_S3_KEY"), "secret" => getenv("NC_S3_SECRET"),
        "hostname" => getenv("NC_S3_HOST"), "port" => (int)getenv("NC_S3_PORT"),
        "use_ssl" => false, "region" => "garage",
      ],
    ];
    file_put_contents($f, "<?php\n\$CONFIG = " . var_export($c, true) . ";\n");
  ' || die "objectstore config write failed"

  docker exec -u www-data nextcloud php occ files:scan --all >/dev/null 2>&1 || die "occ files:scan failed"
  docker exec -u www-data nextcloud php occ maintenance:mode --off || die "maintenance mode off failed"
  docker exec -u www-data nextcloud php occ config:system:get objectstore 2>/dev/null | grep -q "S3" || die "objectstore not active after write"
  log "object store active — NC now reads files from storage"
else
  log "object store already configured — skipping the file move"
fi

# ---------- quota ----------
docker exec -u www-data nextcloud php occ user:setting "$QUOTA_USER" files quota --value "$QUOTA" >/dev/null 2>&1 \
  && log "quota set: $QUOTA_USER = $QUOTA" \
  || log "WARN: quota not set for '$QUOTA_USER' (check the uid with 'make nc-users')"

# ---------- off-host DB backup: nightly pg_dump -> storage (key auth) ----------
sudo test -f /root/.ssh/id_ed25519 || sudo ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519 >/dev/null
sshpass -e ssh-copy-id -o StrictHostKeyChecking=accept-new "root@$TS_IP" >/dev/null 2>&1 || die "ssh key copy to storage failed"
sudo tee /etc/cron.d/nc-storage >/dev/null <<EOF
# Off-host Nextcloud DB backup -> storage:/backups/nc (installed by scripts/storage.sh)
30 2 * * * root docker exec postgresql pg_dump -U nextcloud -d nextcloud -Fc | ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@$TS_IP "mkdir -p /backups/nc && cat > /backups/nc/nextcloud-\$(date +\%F).dump && ls -t /backups/nc/nextcloud-*.dump 2>/dev/null | tail -n +8 | xargs -r rm"
EOF
log "nightly pg_dump -> storage:/backups/nc installed (keeps 7)"

log "DONE — Setup A: PostgreSQL stays on fxmq; files served by Garage on storage ($TS_IP)."
log "  TODO (manual): friends' quotas — 'make nc-user-setting USER=<uid> KEY=quota VALUE=...'"
log "  Once you trust the bucket, the old copies under $DATA_DIR can be deleted."
