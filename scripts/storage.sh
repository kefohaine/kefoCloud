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
GARAGE_VERSION="${GARAGE_VERSION:-v2.3.0}"
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

# ---------- resolve the storage host ----------
# Prefer the tailnet path (post-lockdown runs: the public port 22 is closed);
# fall back to the public IP for the first run (before tailscale exists).
TS_IP=$(sudo tailscale status 2>/dev/null | awk '$2=="storage"{print $1; exit}')
if [ -n "$TS_IP" ] && S "root@$TS_IP" "true" >/dev/null 2>&1; then
  TARGET="root@$TS_IP"
  log "storage already on the tailnet ($TS_IP)"
else
  TS_IP=""
  TARGET="$STORAGE_SSH"
fi
S "$TARGET" "true" || die "cannot ssh to $TARGET (wrong password?)"
docker ps --format '{{.Names}}' | grep -qx nextcloud || die "nextcloud container not running"

# ---------- storage: hostname + base packages ----------
S "$TARGET" "hostnamectl set-hostname storage 2>/dev/null || hostname storage; apt-get update -qq && apt-get install -y -qq curl ca-certificates ufw" \
  || die "storage base setup failed"

# ---------- storage: tailscale ----------
if ! S "$TARGET" "command -v tailscale >/dev/null && tailscale status >/dev/null 2>&1"; then
  log "installing tailscale on storage"
  S "$TARGET" "curl -fsSL https://tailscale.com/install.sh | sh" || die "tailscale install failed"
fi
if ! S "$TARGET" "tailscale status >/dev/null 2>&1"; then
  log "joining tailnet"
  S "$TARGET" "tailscale up --authkey '$TS_AUTHKEY' --hostname storage" || die "tailscale up failed — check the auth key"
fi
TS_IP=""
for _ in $(seq 1 30); do
  TS_IP=$(S "$TARGET" "tailscale ip -4 2>/dev/null | head -1")
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

# ---------- storage: garage (official Docker image; no static binaries published) ----------
if ! T "docker ps --format '{{.Names}}' | grep -qx garage"; then
  log "installing docker + garage $GARAGE_VERSION"
  T "docker rm -f garage >/dev/null 2>&1; apt-get install -y -qq docker.io >/dev/null 2>&1 && systemctl enable --now docker >/dev/null 2>&1" \
    || die "docker install failed"
  RPC_SECRET=$(T "openssl rand -hex 32") || die "rpc secret failed"
  ADMIN_TOKEN=$(T "openssl rand -hex 32") || die "admin token failed"
  T "mkdir -p $GARAGE_DIR/meta $GARAGE_DIR/data" || die "garage dirs failed"
  printf 'metadata_dir = "%s/meta"\ndata_dir = "%s/data"\ndb_engine = "lmdb"\nblock_size = 1048576\nreplication_factor = 1\nrpc_bind_addr = "[::]:3901"\nrpc_secret = "%s"\ns3_api = { api_bind_addr = "[::]:%s", s3_region = "garage" }\nadmin = { api_addr = "127.0.0.1:3903", admin_token = "%s" }\n' \
    "$GARAGE_DIR" "$GARAGE_DIR" "$RPC_SECRET" "$GARAGE_PORT" "$ADMIN_TOKEN" \
    | T "cat > /etc/garage.toml && chmod 600 /etc/garage.toml" || die "garage config failed"
  T "docker pull dxflrs/garage:$GARAGE_VERSION >/dev/null 2>&1" || die "garage image pull failed"
  # distroless image: no entrypoint, binary at /garage — invoke it explicitly
  T "docker run -d --name garage --restart unless-stopped --network host -v /etc/garage.toml:/config/garage.toml:ro -v $GARAGE_DIR:$GARAGE_DIR dxflrs/garage:$GARAGE_VERSION /garage -c /config/garage.toml server" \
    || die "garage container start failed"
  sleep 8
fi

# single-node layout (idempotent — re-runs after a partial install)
if T "docker exec garage /garage -c /config/garage.toml layout show 2>/dev/null | grep -q 'No nodes currently have a role'"; then
  NODE_ID=$(T "docker exec garage /garage -c /config/garage.toml node id 2>/dev/null | head -1") \
    || die "garage node id failed — inspect 'docker logs garage'"
  T "docker exec garage /garage -c /config/garage.toml layout assign '$NODE_ID' --zone storage --capacity 1T && docker exec garage /garage -c /config/garage.toml layout apply --version 1" \
    || die "garage layout failed"
fi

# bucket + S3 key (idempotent; recreates the key if the secret file is missing
# or empty — v2 redacts the secret in `key info`, so it must be captured at
# `key create` time)
if ! T "test -s /root/.nc-s3.env && grep -q '^Secret key:' /root/.nc-s3.env"; then
  T "docker exec garage /garage -c /config/garage.toml bucket create $BUCKET >/dev/null 2>&1; docker exec garage /garage -c /config/garage.toml key delete nc-s3 --yes >/dev/null 2>&1; docker exec garage /garage -c /config/garage.toml key create nc-s3 > /root/.nc-s3.env 2>&1 && chmod 600 /root/.nc-s3.env" \
    || die "garage bucket/key create failed"
fi
# always (re)grant the key on the bucket — a re-created key has no rights
T "docker exec garage /garage -c /config/garage.toml bucket allow --read --write $BUCKET --key nc-s3" \
  || die "garage bucket allow failed"

# S3 credentials (kept in shell vars, never printed)
NC_S3_KEY=$(T "awk -F': ' '/Key ID/{print \$2; exit}' /root/.nc-s3.env" | tr -d ' ')
NC_S3_SECRET=$(T "awk -F': ' '/^Secret key:/{print \$2; exit}' /root/.nc-s3.env" | tr -d ' ')
[ -n "$NC_S3_KEY" ] && [ -n "$NC_S3_SECRET" ] || die "no S3 credentials on storage"
[ "$NC_S3_SECRET" != "(redacted)" ] || die "S3 secret is redacted — delete /root/.nc-s3.env on storage and re-run"
log "garage ready ($BUCKET, bucket keys on storage:/root/.nc-s3.env)"

# ---------- fxmq: container must reach the S3 endpoint ----------
docker exec nextcloud bash -c "timeout 5 bash -c 'exec 3<>/dev/tcp/$TS_IP/$GARAGE_PORT' && echo reachable" >/dev/null 2>&1 \
  || die "nextcloud container cannot reach $TS_IP:$GARAGE_PORT — check tailnet/firewall"

# ---------- fxmq: move files + configure primary object store ----------
# clear a possibly-stuck maintenance mode from an interrupted run first
docker exec -u www-data nextcloud php occ maintenance:mode --off >/dev/null 2>&1 || true
if ! docker exec -u www-data nextcloud php occ config:system:get objectstore 2>/dev/null | grep -q "S3"; then
  command -v mc >/dev/null || curl -fsSL -o /tmp/mc https://dl.min.io/client/mc/release/linux-amd64/mc && sudo install -m755 /tmp/mc /usr/local/bin/mc
  command -v mc >/dev/null || die "mc (minio client) install failed"

  log "uploading datadirectory blobs to the bucket (maintenance mode)"
  docker exec -u www-data nextcloud php occ maintenance:mode --on || die "maintenance mode failed"
  # mc alias for root: the datadirectory is www-data-only, so the copy runs
  # as root — and the S3 keys must never appear in argv, so write the alias
  # config file directly (root-only).
  sudo mkdir -p /root/.mc
  sudo tee /root/.mc/config.json >/dev/null <<EOF
{"version":"10","aliases":{"ncgarage":{"url":"http://$TS_IP:$GARAGE_PORT","accessKey":"$NC_S3_KEY","secretKey":"$NC_S3_SECRET","api":"s3v4","path":"auto","region":"garage"}}}
EOF
  sudo chmod 600 /root/.mc/config.json
  # NC's primary object store keys blobs by 'urn:oid:<filecache fileid>', NOT
  # by path — upload each local file (user files + appdata) under its fileid.
  docker exec postgresql psql -U nextcloud -d nextcloud -tAc \
    "SELECT s.id, f.fileid, f.path FROM oc_filecache f JOIN oc_storages s ON f.storage=s.numeric_id WHERE s.id LIKE 'home::%' OR s.id='local::/data/';" \
    | while IFS='|' read -r sid fileid path; do
        case "$sid" in
          home::*) uid=${sid#home::}; local="$DATA_DIR/$uid/$path" ;;
          *)       local="$DATA_DIR/$path" ;;
        esac
        sudo test -f "$local" && sudo mc cp "$local" "ncgarage/$BUCKET/urn:oid:$fileid" >/dev/null 2>&1 \
          || echo "FAIL $fileid $path"
      done

  log "configuring NC primary object store"
  docker exec -u www-data nextcloud php -r 'copy("/var/www/html/config/config.php", "/var/www/html/config/config.php.bak-" . date("Ymd-His"));' \
    || die "config.php backup failed"
  docker exec -e NC_S3_KEY="$NC_S3_KEY" -e NC_S3_SECRET="$NC_S3_SECRET" \
           -e NC_S3_HOST="$TS_IP" -e NC_S3_PORT="$GARAGE_PORT" -e NC_S3_BUCKET="$BUCKET" \
           -u www-data nextcloud php -r '
    $f = "/var/www/html/config/config.php";
    require $f;                       # config.php defines $CONFIG (no return)
    $c = $CONFIG;
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

  # move the filecache rows to the object storages (fileids are unchanged, so
  # the urn:oid:<fileid> blobs line up). NC creates the object::* storage rows
  # on demand; drop any transitional rows first (idempotent).
  docker exec postgresql psql -U nextcloud -d nextcloud -v ON_ERROR_STOP=1 <<'SQL' || die "storage switch SQL failed"
INSERT INTO oc_storages (id, available) VALUES ('object::store:amazon::nextcloud', 1), ('object::user:admin', 1), ('object::user:sunny', 1), ('object::user:niyaz25', 1) ON CONFLICT (id) DO NOTHING;
DELETE FROM oc_filecache WHERE storage IN (SELECT numeric_id FROM oc_storages WHERE id LIKE 'object::%');
UPDATE oc_filecache SET storage=(SELECT numeric_id FROM oc_storages WHERE id='object::user:admin')  WHERE storage=(SELECT numeric_id FROM oc_storages WHERE id='home::admin');
UPDATE oc_filecache SET storage=(SELECT numeric_id FROM oc_storages WHERE id='object::user:sunny')  WHERE storage=(SELECT numeric_id FROM oc_storages WHERE id='home::sunny');
UPDATE oc_filecache SET storage=(SELECT numeric_id FROM oc_storages WHERE id='object::user:niyaz25') WHERE storage=(SELECT numeric_id FROM oc_storages WHERE id='home::niyaz25');
UPDATE oc_filecache SET storage=(SELECT numeric_id FROM oc_storages WHERE id='object::store:amazon::nextcloud') WHERE storage=(SELECT numeric_id FROM oc_storages WHERE id='local::/data/');
DELETE FROM oc_storages WHERE id LIKE 'home::%' OR id='local::/data/';
SQL

  docker exec -u www-data nextcloud php occ maintenance:mode --off || die "maintenance mode off failed"
  # scan AFTER leaving maintenance mode — app commands (files:scan) are
  # unavailable while the instance is in maintenance mode
  docker exec -u www-data nextcloud php occ files:scan --all >/dev/null 2>&1 || die "occ files:scan failed"
  docker exec -u www-data nextcloud php occ config:system:get objectstore 2>/dev/null | grep -q "S3" || die "objectstore not active after write"
  # verify a real read through the object store (magic bytes of the PDF)
  docker exec -u www-data nextcloud php -r '
    require_once "/var/www/html/lib/base.php";
    \OC_Util::setupFS("admin");
    $v = \OC\Files\Filesystem::getView();
    foreach ($v->getDirectoryContent("") as $e) { $n = $e->getName(); if (str_ends_with($n, ".pdf")) { break; } }
    $d = isset($n) ? $v->file_get_contents($n) : "";
    exit(strlen($d) > 0 ? 0 : 1);
  ' || die "object store read-back failed — verify the blobs and filecache"
  log "object store active — NC reads files from storage"
else
  log "object store already configured — skipping the file move"
fi

# ---------- quota ----------
docker exec -u www-data nextcloud php occ user:setting "$QUOTA_USER" files quota "$QUOTA" >/dev/null 2>&1 \
  && log "quota set: $QUOTA_USER = $QUOTA" \
  || log "WARN: quota not set for '$QUOTA_USER' (check the uid with 'make nc-users')"

# ---------- off-host DB backup: nightly pg_dump -> storage (key auth) ----------
sudo test -f /root/.ssh/id_ed25519 || sudo ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519 >/dev/null
# copy root's key (the cron runs as root) — ssh-copy-id must run as root too
sudo SSHPASS="$SSHPASS" sshpass -e ssh-copy-id -o StrictHostKeyChecking=accept-new "root@$TS_IP" >/dev/null 2>&1 \
  || die "ssh key copy to storage failed"
sudo tee /etc/cron.d/nc-storage >/dev/null <<EOF
# Off-host Nextcloud DB backup -> storage:/backups/nc (installed by scripts/storage.sh)
30 2 * * * root docker exec postgresql pg_dump -U nextcloud -d nextcloud -Fc | ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@$TS_IP "mkdir -p /backups/nc && cat > /backups/nc/nextcloud-\$(date +\%F).dump && ls -t /backups/nc/nextcloud-*.dump 2>/dev/null | tail -n +8 | xargs -r rm"
EOF
log "nightly pg_dump -> storage:/backups/nc installed (keeps 7)"

log "DONE — Setup A: PostgreSQL stays on fxmq; files served by Garage on storage ($TS_IP)."
log "  TODO (manual): friends' quotas — 'make nc-user-setting USER=<uid> KEY=quota VALUE=...'"
log "  Once you trust the bucket, the old copies under $DATA_DIR can be deleted."
