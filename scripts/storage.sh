#!/usr/bin/env bash
#
# scripts/storage.sh — attach a storage VPS (e.g. 1 TB / 2 GB) to a Nextcloud
# instance as PRIMARY OBJECT STORAGE (Setup A: PostgreSQL stays on the
# Nextcloud host; user files + appdata move to Garage/S3 on the storage VPS).
#
# Fully autonomous after a few prompts, like install.sh — it adapts to ANY
# host that runs the Nextcloud docker image (container name, datadirectory
# and DB credentials are auto-detected), so friends can run it against their
# own VPSes too.
#
# Prompts (nothing else is needed):
#   1. storage ssh target (root@<ip>) + root password   (password: read -s)
#   2. tailscale auth key                                (read -s)
#   3. your Nextcloud user id (defaults to the first user) + personal quota
# Auto-detected: nextcloud container name, datadirectory host path (from the
# /data bind mount), postgres container + user/db (from the NC container env).
#
# Lockout-safe: storage is never firewalled until the tailnet path is
# verified from the Nextcloud host (tailscale ping + ssh over the tailnet).
#
# Flow: storage: hostname, tailscale, ufw (tailnet-only 22 + S3 port), swap,
#   garage (S3, official Docker image) + bucket/keys
#   fxmq:   upload blobs by fileid (urn:oid:<filecache fileid>), NC primary
#           object store config, filecache storage switch, quota, verify,
#           nightly pg_dump -> storage:/backups/nc (key auth, keeps 7)
# Errors are collected and re-checked interactively until resolved — no
# partial installs, fully idempotent (safe to re-run).
#
# Vars (all overridable): STORAGE_SSH STORAGE_PASS TS_AUTHKEY QUOTA_USER
# QUOTA NC_CONTAINER GARAGE_VERSION GARAGE_PORT BUCKET SWAP_GB GARAGE_DIR

set -uo pipefail

NC_CONTAINER="${NC_CONTAINER:-nextcloud}"
GARAGE_VERSION="${GARAGE_VERSION:-v2.3.0}"
GARAGE_PORT="${GARAGE_PORT:-3900}"
BUCKET="${BUCKET:-nextcloud}"
SWAP_GB="${SWAP_GB:-2}"
QUOTA="${QUOTA:-300 GB}"
GARAGE_DIR="${GARAGE_DIR:-/var/lib/garage}"

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
PG_USER=$(docker inspect "$NC_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^POSTGRES_USER=//p' | head -1)
PG_DB=$(docker inspect "$NC_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^POSTGRES_DB=//p' | head -1)
PG_USER=${PG_USER:-nextcloud}
PG_DB=${PG_DB:-nextcloud}
OCC() { docker exec -u www-data "$NC_CONTAINER" php occ "$@"; }
PSQL() { docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" "$@"; }
# clear a possibly-stuck maintenance mode from an interrupted run before any
# occ call (app commands and some outputs are unavailable while it is on)
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
QUOTA_USER="${QUOTA_USER:-}"
[ -n "$QUOTA_USER" ] || read -r -p "your Nextcloud user id [${FIRST_USER:-admin}]: " QUOTA_USER
QUOTA_USER="${QUOTA_USER:-${FIRST_USER:-admin}}"
OCC user:list 2>/dev/null | grep -q "$QUOTA_USER" || log "WARN: user '$QUOTA_USER' not found (check with 'make nc-users')"

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
  garage)       echo "PROBLEM: garage (S3) is not running on storage" ;;
  s3key)        echo "PROBLEM: no S3 credentials on storage (/root/.nc-s3.env)" ;;
  reach)        echo "PROBLEM: the nextcloud container cannot reach storage:$GARAGE_PORT" ;;
  upload)       echo "PROBLEM: blobs are missing from the bucket (urn:oid: keys)" ;;
  objectstore)  echo "PROBLEM: NC primary object store is not active" ;;
  switch)       echo "PROBLEM: the filecache storage switch did not complete" ;;
  verify)       echo "PROBLEM: NC could not read a file back through the object store" ;;
  quota)        echo "PROBLEM: quota not set for '$QUOTA_USER'" ;;
  cron)         echo "PROBLEM: nightly backup cron not installed" ;;
esac; }
hint() { case "$1" in
  ssh)          echo "HINT: check the ssh target/password; storage still answers on the public IP before the firewall step" ;;
  tailscale)    echo "HINT: generate a fresh auth key (admin console → Keys) and re-run; check 'tailscale status' on storage" ;;
  ufw)          echo "HINT: ssh to storage over the tailnet (root@$TS_IP) and inspect: ufw status; swap via 'swapon --show'" ;;
  garage)       echo "HINT: ssh to storage: docker logs garage (config errors), ss -tlnp | grep 3900, docker ps" ;;
  s3key)        echo "HINT: the key file is missing/empty on storage — the script recreates it on re-run; delete /root/.nc-s3.env if it is redacted" ;;
  reach)        echo "HINT: from the NC host: tailscale ping $TS_IP; ufw status on storage must allow 100.64.0.0/10 → $GARAGE_PORT" ;;
  upload)       echo "HINT: re-run — the upload loop re-uploads every local file under its urn:oid: key (mc cp)" ;;
  objectstore)  echo "HINT: check config.php 'objectstore' (occ config:system:get objectstore); the php write backs up config.php first" ;;
  switch)       echo "HINT: the SQL moved filecache rows to object::* storages; verify with: SELECT s.id, count(*) FROM oc_filecache f JOIN oc_storages s ON f.storage=s.numeric_id GROUP BY s.id" ;;
  verify)       echo "HINT: php probe failed — confirm the blobs exist (mc ls ncgarage/$BUCKET/ | wc -l) and the filecache rows point at object::* storages" ;;
  quota)        echo "HINT: run: make nc-user-setting USER=$QUOTA_USER KEY=quota VALUE='$QUOTA'" ;;
  cron)         echo "HINT: re-run — the cron (sudo tee /etc/cron.d/nc-storage) installs with root's ssh key on storage" ;;
esac; }
recheck() { case "$1" in
  ssh)          S "$TARGET" "true" ;;
  tailscale)    [ -n "$TS_IP" ] && T "tailscale status >/dev/null 2>&1" ;;
  ufw)          T "ufw status | grep -q 'Status: active'" ;;
  garage)       T "docker ps --format '{{.Names}}' | grep -qx garage" ;;
  s3key)        T "test -s /root/.nc-s3.env && grep -q '^Secret key:' /root/.nc-s3.env" ;;
  reach)        docker exec "$NC_CONTAINER" bash -c "timeout 5 bash -c 'exec 3<>/dev/tcp/$TS_IP/$GARAGE_PORT'" >/dev/null 2>&1 ;;
  upload)       sudo mc ls --recursive "ncgarage/$BUCKET/" 2>/dev/null | grep -q urn:oid: ;;
  objectstore)  OCC config:system:get objectstore 2>/dev/null | grep -q "S3" ;;
  switch)       PSQL -tAc "SELECT count(*) FROM oc_filecache f JOIN oc_storages s ON f.storage=s.numeric_id WHERE s.id LIKE 'object::%';" 2>/dev/null | grep -q '[1-9]' ;;
  verify)       docker exec -u www-data "$NC_CONTAINER" php -r '
                  require_once "/var/www/html/lib/base.php";
                  \OC_Util::setupFS($argv[1]);
                  $v = \OC\Files\Filesystem::getView();
                  foreach ($v->getDirectoryContent("") as $e) { $n = $e->getName(); if (str_ends_with($n, ".pdf") || str_ends_with($n, ".txt")) { break; } }
                  $d = isset($n) ? $v->file_get_contents($n) : "";
                  exit(strlen($d) > 0 ? 0 : 1);
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

# ---------- storage: hostname + base packages + tailscale ----------
if [ -n "$TARGET" ]; then
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

  # ---------- storage: ufw (tailnet-only) + swap ----------
  T "ufw default deny incoming && ufw allow from 100.64.0.0/10 to any port 22 proto tcp && ufw allow from 100.64.0.0/10 to any port $GARAGE_PORT proto tcp && ufw --force enable" \
    || fail ufw "rules"
  T "grep -q /swapfile /etc/fstab 2>/dev/null || { fallocate -l ${SWAP_GB}G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo '/swapfile none swap sw 0 0' >> /etc/fstab; }" \
    || fail ufw "swap"

  # ---------- storage: garage (official Docker image; no static binaries) ----------
  if ! T "docker ps --format '{{.Names}}' | grep -qx garage"; then
    log "installing docker + garage $GARAGE_VERSION"
    T "docker rm -f garage >/dev/null 2>&1; apt-get install -y -qq docker.io >/dev/null 2>&1 && systemctl enable --now docker >/dev/null 2>&1" \
      || fail garage "docker"
    RPC_SECRET=$(T "openssl rand -hex 32") || fail garage "rpc secret"
    ADMIN_TOKEN=$(T "openssl rand -hex 32") || fail garage "admin token"
    T "mkdir -p $GARAGE_DIR/meta $GARAGE_DIR/data" || fail garage "dirs"
    printf 'metadata_dir = "%s/meta"\ndata_dir = "%s/data"\ndb_engine = "lmdb"\nblock_size = 1048576\nreplication_factor = 1\nrpc_bind_addr = "[::]:3901"\nrpc_secret = "%s"\ns3_api = { api_bind_addr = "[::]:%s", s3_region = "garage" }\nadmin = { api_addr = "127.0.0.1:3903", admin_token = "%s" }\n' \
      "$GARAGE_DIR" "$GARAGE_DIR" "$RPC_SECRET" "$GARAGE_PORT" "$ADMIN_TOKEN" \
      | T "cat > /etc/garage.toml && chmod 600 /etc/garage.toml" || fail garage "config"
    T "docker pull dxflrs/garage:$GARAGE_VERSION >/dev/null 2>&1" || fail garage "image"
    # distroless image: no entrypoint, binary at /garage — invoke it explicitly
    T "docker run -d --name garage --restart unless-stopped --network host -v /etc/garage.toml:/config/garage.toml:ro -v $GARAGE_DIR:$GARAGE_DIR dxflrs/garage:$GARAGE_VERSION /garage -c /config/garage.toml server" \
      || fail garage "container"
    sleep 8
  fi

  # single-node layout (idempotent — re-runs after a partial install)
  if T "docker exec garage /garage -c /config/garage.toml layout show 2>/dev/null | grep -q 'No nodes currently have a role'"; then
    NODE_ID=$(T "docker exec garage /garage -c /config/garage.toml node id 2>/dev/null | head -1") \
      || fail garage "node id"
    T "docker exec garage /garage -c /config/garage.toml layout assign '$NODE_ID' --zone storage --capacity 1T && docker exec garage /garage -c /config/garage.toml layout apply --version 1" \
      || fail garage "layout"
  fi

  # bucket + S3 key (idempotent; recreates the key if the secret file is missing
  # or empty — v2 redacts the secret in `key info`, so it must be captured at
  # `key create` time)
  if ! T "test -s /root/.nc-s3.env && grep -q '^Secret key:' /root/.nc-s3.env"; then
    T "docker exec garage /garage -c /config/garage.toml bucket create $BUCKET >/dev/null 2>&1; ID=\$(docker exec garage /garage -c /config/garage.toml key list 2>/dev/null | awk '/nc-s3/{print \$1; exit}'); [ -n \"\$ID\" ] && docker exec garage /garage -c /config/garage.toml key delete \"\$ID\" --yes >/dev/null 2>&1; docker exec garage /garage -c /config/garage.toml key create nc-s3 > /root/.nc-s3.env 2>&1 && chmod 600 /root/.nc-s3.env" \
      || fail s3key "create"
  fi
  # always (re)grant the key on the bucket — a re-created key has no rights
  T "docker exec garage /garage -c /config/garage.toml bucket allow --read --write $BUCKET --key nc-s3" \
    || fail s3key "allow"

  # S3 credentials (kept in shell vars, never printed)
  NC_S3_KEY=$(T "awk -F': ' '/Key ID/{print \$2; exit}' /root/.nc-s3.env" | tr -d ' ')
  NC_S3_SECRET=$(T "awk -F': ' '/^Secret key:/{print \$2; exit}' /root/.nc-s3.env" | tr -d ' ')
  [ -n "$NC_S3_KEY" ] && [ -n "$NC_S3_SECRET" ] || fail s3key "credentials"
  [ "$NC_S3_SECRET" != "(redacted)" ] || fail s3key "redacted"
  log "garage ready ($BUCKET, bucket keys on storage:/root/.nc-s3.env)"
fi

# ---------- fxmq: container must reach the S3 endpoint ----------
docker exec "$NC_CONTAINER" bash -c "timeout 5 bash -c 'exec 3<>/dev/tcp/$TS_IP/$GARAGE_PORT'" >/dev/null 2>&1 \
  || fail reach "nextcloud container cannot reach $TS_IP:$GARAGE_PORT"

# ---------- fxmq: upload blobs + configure primary object store ----------
# clear a possibly-stuck maintenance mode from an interrupted run first
OCC maintenance:mode --off >/dev/null 2>&1 || true
if ! OCC config:system:get objectstore 2>/dev/null | grep -q "S3"; then
  command -v mc >/dev/null || curl -fsSL -o /tmp/mc https://dl.min.io/client/mc/release/linux-amd64/mc && sudo install -m755 /tmp/mc /usr/local/bin/mc
  command -v mc >/dev/null || die "mc (minio client) install failed"

  log "uploading datadirectory blobs to the bucket (maintenance mode)"
  OCC maintenance:mode --on || fail objectstore "maintenance on"
  # mc alias for root: the datadirectory is www-data-only, so the upload runs
  # as root — and the S3 keys must never appear in argv, so write the alias
  # config file directly (root-only).
  sudo mkdir -p /root/.mc
  sudo tee /root/.mc/config.json >/dev/null <<EOF
{"version":"10","aliases":{"ncgarage":{"url":"http://$TS_IP:$GARAGE_PORT","accessKey":"$NC_S3_KEY","secretKey":"$NC_S3_SECRET","api":"s3v4","path":"auto","region":"garage"}}}
EOF
  sudo chmod 600 /root/.mc/config.json
  # NC's primary object store keys blobs by 'urn:oid:<filecache fileid>', NOT
  # by path — upload each local file (user files + appdata) under its fileid.
  PSQL -tAc "SELECT s.id, f.fileid, f.path FROM oc_filecache f JOIN oc_storages s ON f.storage=s.numeric_id WHERE s.id LIKE 'home::%' OR s.id='local::/data/' OR s.id LIKE 'object::%';" \
    | while IFS='|' read -r sid fileid path; do
        case "$sid" in
          home::*)          uid=${sid#home::};        local="$DATA_DIR/$uid/$path" ;;
          object::user:*)   uid=${sid#object::user:}; local="$DATA_DIR/$uid/$path" ;;
          *)                local="$DATA_DIR/$path" ;;
        esac
        sudo test -f "$local" && sudo mc cp "$local" "ncgarage/$BUCKET/urn:oid:$fileid" >/dev/null 2>&1 || true
      done
  sudo mc ls --recursive "ncgarage/$BUCKET/" 2>/dev/null | grep -q urn:oid: \
    || fail upload "bucket has no blobs"

  log "configuring NC primary object store"
  docker exec -u www-data "$NC_CONTAINER" php -r 'copy("/var/www/html/config/config.php", "/var/www/html/config/config.php.bak-" . date("Ymd-His"));' \
    || fail objectstore "config backup"
  docker exec -e NC_S3_KEY="$NC_S3_KEY" -e NC_S3_SECRET="$NC_S3_SECRET" \
           -e NC_S3_HOST="$TS_IP" -e NC_S3_PORT="$GARAGE_PORT" -e NC_S3_BUCKET="$BUCKET" \
           -u www-data "$NC_CONTAINER" php -r '
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
  ' || fail objectstore "config write"

  # move the filecache rows to the object storages (fileids are unchanged, so
  # the urn:oid:<fileid> blobs line up). Per-user statements are generated
  # from oc_users. GUARDED: only runs while home::* rows still exist — a
  # re-run after a completed switch must NOT delete the object::* rows again.
  if PSQL -tAc "SELECT count(*) FROM oc_storages WHERE id LIKE 'home::%';" 2>/dev/null | grep -q '[1-9]'; then
    PSQL <<'SQL' || fail switch "SQL failed"
INSERT INTO oc_storages (id, available) VALUES ('object::store:amazon::nextcloud', 1) ON CONFLICT (id) DO NOTHING;
SELECT 'INSERT INTO oc_storages (id, available) VALUES (''object::user:' || uid || ''', 1) ON CONFLICT (id) DO NOTHING;' FROM oc_users \gexec
DELETE FROM oc_filecache WHERE storage IN (SELECT numeric_id FROM oc_storages WHERE id LIKE 'object::%');
SELECT 'UPDATE oc_filecache SET storage=(SELECT numeric_id FROM oc_storages WHERE id=''object::user:' || uid || ''') WHERE storage=(SELECT numeric_id FROM oc_storages WHERE id=''home::' || uid || ''');' FROM oc_users \gexec
UPDATE oc_filecache SET storage=(SELECT numeric_id FROM oc_storages WHERE id='object::store:amazon::nextcloud') WHERE storage=(SELECT numeric_id FROM oc_storages WHERE id='local::/data/');
DELETE FROM oc_storages WHERE id LIKE 'home::%' OR id='local::/data/';
SQL
    log "filecache switched to the object storages"
  else
    log "filecache already on the object storages — skipping the switch"
  fi

  OCC maintenance:mode --off || fail objectstore "maintenance off"
  # scan AFTER leaving maintenance mode — app commands (files:scan) are
  # unavailable while the instance is in maintenance mode
  OCC files:scan --all >/dev/null 2>&1 || fail objectstore "files:scan"
  OCC config:system:get objectstore 2>/dev/null | grep -q "S3" || fail objectstore "not active"
  log "object store configured — verifying a real read"
else
  log "object store already configured — skipping the upload/switch"
fi

# ---------- quota + off-host DB backup ----------
OCC user:setting "$QUOTA_USER" files quota "$QUOTA" >/dev/null 2>&1 \
  && log "quota set: $QUOTA_USER = $QUOTA" || fail quota "user '$QUOTA_USER'"
sudo test -f /root/.ssh/id_ed25519 || sudo ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519 >/dev/null
# copy root's key (the cron runs as root) — ssh-copy-id must run as root too
sudo SSHPASS="$SSHPASS" sshpass -e ssh-copy-id -o StrictHostKeyChecking=accept-new "root@$TS_IP" >/dev/null 2>&1 \
  || fail cron "ssh key copy"
sudo tee /etc/cron.d/nc-storage >/dev/null <<EOF
# Off-host Nextcloud DB backup -> storage:/backups/nc (installed by scripts/storage.sh)
30 2 * * * root docker exec $PG_CONTAINER pg_dump -U $PG_USER -d $PG_DB -Fc | ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new root@$TS_IP "mkdir -p /backups/nc && cat > /backups/nc/nextcloud-\$(date +\%F).dump && ls -t /backups/nc/nextcloud-*.dump 2>/dev/null | tail -n +8 | xargs -r rm"
EOF
log "nightly pg_dump -> storage:/backups/nc installed (keeps 7)"

# ---------- re-check loop: resolve every collected error ----------
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

log "DONE — Setup A: PostgreSQL stays on the NC host; user files served by Garage on storage ($TS_IP)."
log "  TODO (manual): friends' quotas — occ user:setting <uid> files quota '<value>'"
log "  Once you trust the bucket, the old copies under $DATA_DIR can be deleted."
