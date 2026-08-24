#!/bin/bash
# homelab install.sh — plug-and-play new-VPS installer.
#
# Prompts for three values (domain, Cloudflare API token, Tailscale auth
# key), then runs unattended: host services, docker, tailscale, the four
# containers (Caddy renamed to $DOMAIN, nextcloud, vaultwarden, ut-kuma),
# Cloudflare DNS records, and LE cert issuance.
#
# Errors are collected with tags. No success message is printed until every
# error is resolved: after the setup you get a numbered list of what's
# still failing, and each time you press Enter the script re-checks them,
# prints the solved ones once, and the remaining ones — until all are
# green. Both 'root' and user 'op' can SSH in with keys automatically.
#
# Old-project references are renamed or deleted by this script; a sweep
# at the end verifies none reappear on the new host (the script itself is
# the only allowed carrier).
#
# Usage:
#   scp scripts/install.sh root@<new-vps>:
#   ssh root@<new-vps>
#   bash install.sh
#
# Run as root on the first run; it creates user 'op' and re-executes
# itself as op for the rest.

set -uo pipefail

OP_USER=op
REPO=/var/www/custom/projects/homelab/repo
STATE=/var/tmp/homelab-setup.state
LOG=/var/log/homelab-install.log
ERR_TAGS=()
ERR_MSGS=()

log()  { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
fail() { ERR_TAGS+=("$1"); ERR_MSGS+=("$2"); echo "  ERROR: $2" >>"$LOG"; }

banner() {
cat <<'EOF'
============================================================
  homelab VPS installer
  Nextcloud + Vaultwarden + Uptime Kuma + Caddy ($DOMAIN)
  Prompts once, then runs unattended. No success message
  until every error is resolved (re-check loop at the end).
============================================================
EOF
}

load_state() { [ -f "$STATE" ] && . "$STATE"; }

save_state() {
  umask 077
  cat > "$STATE" <<EOF
DOMAIN='$DOMAIN'
CF_API_TOKEN='$CF_API_TOKEN'
TS_AUTHKEY='$TS_AUTHKEY'
TS_IP='${TS_IP:-}'
ERR_TAGS=($(printf '%q ' "${ERR_TAGS[@]}"))
ERR_MSGS=($(printf '%q ' "${ERR_MSGS[@]}"))
EOF
  chmod 600 "$STATE"
}

ask_inputs() {
  if [ -z "${DOMAIN:-}" ]; then
    read -rp "Domain (e.g. example.com): " DOMAIN
  fi
  DOMAIN="${DOMAIN,,}"
  [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || { echo "Invalid domain: $DOMAIN"; exit 1; }
  if [ -z "${CF_API_TOKEN:-}" ]; then
    read -rsp "Cloudflare API token (Zone > DNS > Edit): " CF_API_TOKEN; echo
  fi
  [ -n "$CF_API_TOKEN" ] || { echo "Token required."; exit 1; }
  if [ -z "${TS_AUTHKEY:-}" ]; then
    read -rsp "Tailscale auth key (tskey-...): " TS_AUTHKEY; echo
  fi
  [ -n "$TS_AUTHKEY" ] || { echo "Auth key required."; exit 1; }
  echo "Installing for $DOMAIN — ~10-15 min. Full log: $LOG"
}

# ───────────────────────────── Phase 1 (root) ─────────────────────────────

phase1_root() {
  log "Phase 1 (root): packages, users, ssh, docker, tailscale, firewall"
  touch "$LOG" && chmod 666 "$LOG"

  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    docker.io docker-compose-plugin git curl make sudo dnsmasq ufw jq \
    apache2-utils >/dev/null 2>&1 || fail apt "apt packages not installed"

  if ! id -u "$OP_USER" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$OP_USER" || fail user "user $OP_USER not created"
  fi
  usermod -aG sudo,docker "$OP_USER"
  echo "$OP_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$OP_USER-passwordless
  chmod 0440 /etc/sudoers.d/$OP_USER-passwordless

  # SSH: root and op both log in with keys. root keeps its own keys; op
  # gets a copy. Password auth stays off; root is key-only.
  mkdir -p /home/$OP_USER/.ssh /root/.ssh
  if [ -s /root/.ssh/authorized_keys ]; then
    cp /root/.ssh/authorized_keys /home/$OP_USER/.ssh/authorized_keys
    chown -R $OP_USER:$OP_USER /home/$OP_USER/.ssh
    chmod 700 /home/$OP_USER/.ssh && chmod 600 /home/$OP_USER/.ssh/authorized_keys
  else
    fail ssh_keys "no SSH keys found — add a public key to /root/.ssh/authorized_keys (and copy it to /home/$OP_USER/.ssh/authorized_keys), then re-check"
  fi
  printf 'PasswordAuthentication no\nPermitRootLogin prohibit-password\nAllowUsers %s root\n' "$OP_USER" \
    > /etc/ssh/sshd_config.d/50-cloud-init.conf
  systemctl restart sshd

  systemctl enable --now docker
  cat > /etc/docker/daemon.json <<'EOF'
{
    "log-driver": "json-file",
    "log-opts": {"max-size": "10m", "max-file": "3"},
    "storage-driver": "overlayfs",
    "default-runtime": "runc",
    "live-restore": true
}
EOF
  systemctl restart docker

  curl -fsSL https://ollama.com/install.sh | sh >/dev/null 2>&1 || log "ollama install skipped"

  if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh || fail tailscale "tailscale binary not installed"
  fi
  if ! tailscale ip -4 >/dev/null 2>&1; then
    tailscale up --authkey="$TS_AUTHKEY" >>"$LOG" 2>&1 || fail tailscale_up "tailscale did not connect (check the auth key)"
  fi
  TS_IP=$(tailscale ip -4 2>/dev/null | head -1)
  [ -n "$TS_IP" ] && log "tailscale IP: $TS_IP" || fail ts_ip "no tailscale IP assigned"

  ufw allow from 100.64.0.0/10 to any port 22 proto tcp >/dev/null 2>&1
  ufw allow 80/tcp >/dev/null 2>&1
  ufw allow 443/tcp >/dev/null 2>&1
  echo y | ufw enable >/dev/null 2>&1 || true

  save_state
  cp "$0" /home/$OP_USER/install.sh
  chown $OP_USER:$OP_USER /home/$OP_USER/install.sh && chmod 700 /home/$OP_USER/install.sh
  chown $OP_USER:$OP_USER "$STATE" 2>/dev/null || true
  log "Handing off to user '$OP_USER'..."
  exec runuser -u $OP_USER -- env DOMAIN="$DOMAIN" CF_API_TOKEN="$CF_API_TOKEN" \
    TS_AUTHKEY="$TS_AUTHKEY" TS_IP="${TS_IP:-}" bash /home/$OP_USER/install.sh --op
}

# ────────────────────────────── Phase 2 (op) ──────────────────────────────

ensure_repo() {
  if [ -d "$REPO/.git" ]; then log "repo present at $REPO"; return; fi
  mkdir -p /var/www/custom/projects/homelab
  chown $OP_USER:$OP_USER /var/www/custom/projects/homelab
  if [ ! -f ~/.ssh/github_key ]; then
    ssh-keygen -t ed25519 -N "" -f ~/.ssh/github_key -C "$OP_USER@$DOMAIN" >/dev/null
    cat > ~/.ssh/config <<EOF
Host github.com
  IdentityFile ~/.ssh/github_key
  IdentitiesOnly yes
EOF
    chmod 600 ~/.ssh/config
    echo "============================================================"
    echo " ADD THIS KEY TO GITHUB, THEN RE-RUN THE SCRIPT:"
    cat ~/.ssh/github_key.pub
    echo "============================================================"
  fi
  # Clone from the renamed repo first; fall back to the pre-rename URL
  # (this script is the only place the old name is allowed to appear).
  if ! GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" \
       git clone git@github.com:friedutch/homelab.git "$REPO" >>"$LOG" 2>&1; then
    if ! GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" \
         git clone git@github.com:friedutch/jehpok.com.git "$REPO" >>"$LOG" 2>&1; then
      echo "  ERROR: repo clone failed — add the pubkey above to GitHub, then re-run" >>"$LOG"
      echo "Repo clone failed. Add the SSH key printed above to GitHub, then re-run the script."
      exit 1
    fi
    log "cloned from the pre-rename repo; remote will point at the renamed one"
  fi
  git -C "$REPO" remote rename origin homelab
  git -C "$REPO" remote set-url homelab git@github.com:friedutch/homelab.git
}

prep_dirs() {
  cd "$REPO" || exit 1
  mkdir -p cloud/html cloud/users vault/data kuma/data
  sudo chown -R 33:33 cloud/html cloud/users
  sudo chown -R 1000:1000 vault/data
}

renames() {
  cd "$REPO" || exit 1
  log "  domain swap: homelab.com -> $DOMAIN"
  grep -rl 'homelab\.com' services/ config/ | xargs sed -i "s/homelab\.com/$DOMAIN/g"
  log "  server.$DOMAIN -> shell.$DOMAIN"
  grep -rl "server\.$DOMAIN" services/ config/ | xargs sed -i "s/server\.$DOMAIN/shell.$DOMAIN/g"
  log "  debian -> $OP_USER"
  sed -i "s/debian/$OP_USER/g" Makefile config/
  log "  trimming to 4 services"
  rm -rf services/homer services/share-flask services/mc content/share content/minecraft
  log "  renaming caddy service dir vhosts -> $DOMAIN"
  mv services/vhosts "services/$DOMAIN"
  log "  renaming + trimming per-vhost files"
  cd "services/$DOMAIN/vhosts" || exit 1
  rm -f www.homelab.com.caddy share.homelab.com.caddy api.homelab.com.caddy mc.homelab.com.caddy
  for f in *.homelab.com.caddy; do [ -e "$f" ] && mv "$f" "${f/homelab.com/$DOMAIN}"; done
  mv "server.$DOMAIN.caddy" "shell.$DOMAIN.caddy"
  cd ../../..
  log "  patching caddy compose, Caddyfile, Makefile"
  sed -i "s/container_name: vhosts/container_name: $DOMAIN/" "services/$DOMAIN/docker-compose.yml"
  sed -i "s/image: caddy-dns:local/image: $DOMAIN:local/" "services/$DOMAIN/docker-compose.yml"
  sed -i "\|\.\./\.\.:/srv:ro|d; \|share/files:/files:ro|d" "services/$DOMAIN/docker-compose.yml"
  sed -i "/^import vhosts\/\(www\|share\|api\|mc\)\./d" "services/$DOMAIN/Caddyfile"
  sed -i "s/^CONTAINERS := .*/CONTAINERS := $DOMAIN ut-kuma nextcloud vaultwarden/" Makefile
  sed -i "s/filter share-flask vhosts mc-flask/filter $DOMAIN/" Makefile
  sed -i "/^COMPOSE_FILES/d" Makefile
  awk '/^bkp-(share|mc):/ {skip=1; next}
       /^bkp-all:/ {sub(/ bkp-share/,""); sub(/ bkp-mc/,""); skip=0}
       skip && /^[a-z][a-z0-9-]*:/ {skip=0}
       { if (!skip) print }' Makefile > Makefile.tmp && mv Makefile.tmp Makefile
  log "  rewriting shell vhost (share/mc routes dropped)"
  cat > "services/$DOMAIN/vhosts/shell.$DOMAIN.caddy" <<EOF
https://shell.$DOMAIN {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
    import compress
    @not_tailnet not remote_ip 100.64.0.0/10
    handle @not_tailnet {
        respond 403
    }
    @shell path /shell /shell/*
    handle @shell {
        uri strip_prefix /shell
        reverse_proxy 172.22.0.1:7681 {
            transport http {
                versions 1.1
            }
        }
    }
    handle {
        @root path /
        respond @root "ok"
        respond "not found" 404
    }
}
EOF
  log "  nextcloud env + datadir"
  sed -i "/NEXTCLOUD_TRUSTED_DOMAINS/a\      NEXTCLOUD_DATA_DIR: /data" services/nextcloud/docker-compose.yml
  NEXTCLOUD_ADMIN_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)
  cat > services/nextcloud/.env <<EOF
NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=$NEXTCLOUD_ADMIN_PASSWORD
EOF
  chmod 600 services/nextcloud/.env
  log "  daily.sh (mc block removed)"
  cat > config/maintenance/daily.sh <<'EOF'
#!/bin/bash
set -euo pipefail

LOG=/var/log/homelab-daily.log
echo "=== $(date) ===" >> "$LOG"

cd /var/www/custom/projects/homelab/repo

make update        >> "$LOG" 2>&1
make bkp-all       >> "$LOG" 2>&1 || echo "bkp-all failed" >> "$LOG"
make clean-all     >> "$LOG" 2>&1 || echo "clean-all failed" >> "$LOG"

echo "--- done ---" >> "$LOG"
EOF
  log "  kuma seed SQL (4-container set)"
  sed -i "/'docker'/ s/'cloud'/'nextcloud'/g; /'docker'/ s/'vault'/'vaultwarden'/g; /'docker'/ s/'share'/'share-flask'/g; /'docker'/ s/'vhosts'/'$DOMAIN'/g" services/ut-kuma/seed-monitors.sql
  sed -i "/docker: share/d; /docker: homer/d; /http: www/d; /http: share/d; /http: api/d" services/ut-kuma/seed-monitors.sql
  git add -A && git -c user.name="$OP_USER" -c user.email="$OP_USER@$DOMAIN" \
    commit -q -m "install: domain $DOMAIN, user $OP_USER, shell., 4 containers" 2>/dev/null || true
}

docker_net() {
  docker network create net --subnet=172.22.0.0/16 >>"$LOG" 2>&1 || true
}

caddy_data() {
  mkdir -p caddy_data
  printf 'CF_API_TOKEN=%s\n' "$CF_API_TOKEN" | sudo tee caddy_data/CF_API_TOKEN >/dev/null
  sudo chown -R 201:201 caddy_data
  sudo chown $OP_USER:$OP_USER caddy_data/CF_API_TOKEN
  sudo chmod 0644 caddy_data/CF_API_TOKEN
}

host_services() {
  if [ -n "${TS_IP:-}" ]; then
    sed -i "s/100\.81\.245\.77/$TS_IP/g" config/dnsmasq/10-tailnet.conf
  else
    fail ts_ip "no tailscale IP — dnsmasq config left at the old IP"
  fi
  make install-config >>"$LOG" 2>&1 || fail install_config "make install-config failed (host services not up)"
}

containers_up() {
  log "  building Caddy image ($DOMAIN:local) — ~3 min on a cold cache"
  make "recreate-$DOMAIN" >>"$LOG" 2>&1 || fail caddy "caddy container '$DOMAIN' not running"
  make recreate-nextcloud   >>"$LOG" 2>&1 || fail nextcloud "nextcloud container not running"
  make recreate-vaultwarden >>"$LOG" 2>&1 || fail vaultwarden "vaultwarden container not running"
  make recreate-ut-kuma     >>"$LOG" 2>&1 || fail kuma "ut-kuma container not running"
}

nextcloud_fix() {
  local i=0
  while [ $i -lt 120 ]; do
    docker exec -w /var/www/html nextcloud php occ status >/dev/null 2>&1 && break
    sleep 2; i=$((i+2))
  done
  local dd
  dd=$(docker exec -w /var/www/html nextcloud php occ config:system:get datadirectory 2>/dev/null | tr -d '\n')
  if [ "$dd" != "/data" ]; then
    docker exec -w /var/www/html nextcloud php occ config:system:set datadirectory --value /data >>"$LOG" 2>&1 \
      || fail datadirectory "nextcloud datadirectory != /data"
  fi
}

kuma_seed() {
  local i=0
  while [ $i -lt 60 ]; do
    docker exec ut-kuma test -f /app/data/kuma.db 2>/dev/null && break
    sleep 2; i=$((i+2))
  done
  KUMA_PASS=$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)
  local n
  n=$(docker exec ut-kuma sqlite3 /app/data/kuma.db "SELECT COUNT(*) FROM user WHERE username='admin';" 2>/dev/null | tr -d '\n')
  if [ "$n" = "0" ]; then
    local HASH
    HASH=$(htpasswd -bnBC 10 "" "$KUMA_PASS" 2>/dev/null | tr -d ':\n')
    if [ -n "$HASH" ]; then
      docker exec ut-kuma sqlite3 /app/data/kuma.db \
        "INSERT INTO user (username,password,active,timezone,created_date) VALUES ('admin','$HASH',1,'UTC',strftime('%s','now'));" \
        >>"$LOG" 2>&1 || fail kuma_admin "uptime kuma admin user missing"
    fi
  fi
  docker exec -i ut-kuma sqlite3 /app/data/kuma.db < services/ut-kuma/seed-monitors.sql \
    >>"$LOG" 2>&1 || fail kuma_seed "uptime kuma monitors not seeded"
}

cf_dns() {
  VPS_IP=$(curl -s4 ifconfig.me)
  ZONE_ID=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" | jq -r '.result[0].id // empty')
  if [ -z "$ZONE_ID" ]; then
    fail zone "Cloudflare zone '$DOMAIN' not found (create it in the dashboard)"
    return
  fi
  for h in cloud vault kuma; do
    local rid
    rid=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$h.$DOMAIN" | jq -r '.result[0].id // empty')
    if [ -z "$rid" ]; then
      curl -s -X POST -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -d "{\"type\":\"A\",\"name\":\"$h.$DOMAIN\",\"content\":\"$VPS_IP\",\"ttl\":1,\"proxied\":true}" \
        >>"$LOG" 2>&1 || fail "dns_$h" "DNS record for $h.$DOMAIN missing"
    fi
  done
  curl -s -X PATCH -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings/ssl" -d '{"value":"full"}' >>"$LOG" 2>&1 || true
}

issue_certs() {
  for h in cloud vault kuma; do
    curl -sk --resolve "$h.$DOMAIN:443:127.0.0.1" -o /dev/null "https://$h.$DOMAIN/" >>"$LOG" 2>&1 || true
    sleep 3
  done
  for h in cloud vault kuma; do
    local iss
    iss=$(echo | timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "$h.$DOMAIN" 2>/dev/null \
      | openssl x509 -noout -issuer 2>/dev/null | cut -d'=' -f2-)
    case "$iss" in
      *"Let's Encrypt"*) ;;
      *) fail "cert_$h" "cert for $h.$DOMAIN not Let's Encrypt (got: $iss)";;
    esac
  done
}

sweep() {
  # Old-project references must not survive anywhere except this script.
  local hits
  hits=$(grep -rl 'jehpok' "$REPO" --exclude-dir=.git 2>/dev/null \
    | grep -v "^$REPO/scripts/install.sh$" || true)
  if [ -n "$hits" ]; then
    fail sweep "old project name still referenced in: $(echo "$hits" | tr '\n' ' ')"
  fi
}

phase2_op() {
  log "Phase 2 ($OP_USER): repo, renames, host config, containers, DNS, certs"
  ensure_repo
  prep_dirs
  renames
  docker_net
  caddy_data
  host_services
  containers_up
  nextcloud_fix
  kuma_seed
  cf_dns
  issue_certs
  sweep
}

# ──────────────────────── error descriptions + rechecks ────────────────────

describe() {
  case "$1" in
    apt)           echo "apt packages not installed (docker.io, docker-compose-plugin, git, curl, make, sudo, dnsmasq, ufw, jq, apache2-utils)";;
    user)          echo "user '$OP_USER' not created";;
    ssh_keys)      echo "no SSH key for root/op — add one to /root/.ssh/authorized_keys and /home/$OP_USER/.ssh/authorized_keys";;
    tailscale)     echo "tailscale binary not installed";;
    tailscale_up)  echo "tailscale not connected (auth key invalid?)";;
    ts_ip)         echo "no tailscale IP assigned";;
    install_config) echo "host services not up (make install-config failed)";;
    caddy)         echo "caddy container '$DOMAIN' not running";;
    nextcloud)     echo "nextcloud container not running";;
    vaultwarden)   echo "vaultwarden container not running";;
    kuma)          echo "ut-kuma container not running";;
    datadirectory) echo "nextcloud datadirectory != /data";;
    kuma_admin)    echo "uptime kuma admin user missing (create it in the UI)";;
    kuma_seed)     echo "uptime kuma monitors not seeded";;
    zone)          echo "Cloudflare zone '$DOMAIN' not found (create it in the dashboard)";;
    dns_*)         echo "DNS record for ${1#dns_}.$DOMAIN missing";;
    cert_*)        echo "cert for ${1#cert_}.$DOMAIN not Let's Encrypt";;
    sweep)         echo "old project name still referenced in the repo tree";;
    *)             echo "$1";;
  esac
}

recheck() {
  case "$1" in
    apt)  dpkg -s docker.io docker-compose-plugin git curl make sudo dnsmasq ufw jq apache2-utils >/dev/null 2>&1 ;;
    user) id -u "$OP_USER" >/dev/null 2>&1 ;;
    ssh_keys) sudo test -s /root/.ssh/authorized_keys && [ -s /home/$OP_USER/.ssh/authorized_keys ] ;;
    tailscale) command -v tailscale >/dev/null 2>&1 ;;
    tailscale_up) tailscale ip -4 >/dev/null 2>&1 ;;
    ts_ip) [ -n "$(tailscale ip -4 2>/dev/null | head -1)" ] ;;
    install_config) systemctl is-active --quiet ttyd dnsmasq && systemctl is-enabled --quiet homelab-daily.timer ;;
    caddy) docker ps --format '{{.Names}}' | grep -qx "$DOMAIN" ;;
    nextcloud) docker ps --format '{{.Names}}' | grep -qx nextcloud ;;
    vaultwarden) docker ps --format '{{.Names}}' | grep -qx vaultwarden ;;
    kuma) docker ps --format '{{.Names}}' | grep -qx ut-kuma ;;
    datadirectory) [ "$(docker exec -w /var/www/html nextcloud php occ config:system:get datadirectory 2>/dev/null | tr -d '\n')" = "/data" ] ;;
    kuma_admin) [ "$(docker exec ut-kuma sqlite3 /app/data/kuma.db "SELECT COUNT(*) FROM user WHERE username='admin';" 2>/dev/null | tr -d '\n')" = "1" ] ;;
    kuma_seed) [ "$(docker exec ut-kuma sqlite3 /app/data/kuma.db "SELECT COUNT(*) FROM monitor;" 2>/dev/null | tr -d '\n')" -gt 0 ] ;;
    zone) [ -n "$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" | jq -r '.result[0].id // empty')" ] ;;
    dns_*) local h=${1#dns_}; [ -n "$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$h.$DOMAIN" | jq -r '.result[0].id // empty')" ] ;;
    cert_*) local h=${1#cert_}; echo | timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "$h.$DOMAIN" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null | grep -q "Let's Encrypt" ;;
    sweep) ! grep -rl 'jehpok' "$REPO" --exclude-dir=.git 2>/dev/null | grep -qv "^$REPO/scripts/install.sh$" ;;
    *) false ;;
  esac
}

resolve_errors() {
  local remaining=("${ERR_TAGS[@]}")
  while [ ${#remaining[@]} -gt 0 ]; do
    echo ""
    echo " Remaining issues (${#remaining[@]}):"
    for i in "${!remaining[@]}"; do
      echo "   $((i+1)). ${remaining[$i]} — $(describe "${remaining[$i]}")"
    done
    read -rp "Fix the issues above, then press Enter to re-check (Ctrl-C aborts): " input \
      || { echo "No terminal input — aborting."; exit 1; }
    local still=()
    for tag in "${remaining[@]}"; do
      if recheck "$tag"; then
        echo "   ✓ solved: $tag — $(describe "$tag")"
      else
        still+=("$tag")
      fi
    done
    remaining=("${still[@]}")
  done
  ERR_TAGS=()
  success_block
}

success_block() {
  echo ""
  echo "=============================================================="
  echo " SUCCESS — the stack is up:"
  echo "   Nextcloud    https://cloud.$DOMAIN      admin / ${NEXTCLOUD_ADMIN_PASSWORD:-<see services/nextcloud/.env>}"
  echo "   Vaultwarden  https://vault.$DOMAIN"
  echo "   Uptime Kuma  https://kuma.$DOMAIN       admin / ${KUMA_PASS:-<create in the UI>}"
  echo "   Shell        https://shell.$DOMAIN      (tailnet-only)"
  echo "   VPS IP ${VPS_IP:-?}   Tailscale IP ${TS_IP:-?}"
  echo ""
  echo " SSH: root and '$OP_USER' both log in with keys (tailnet-only, port 22)."
  echo ""
  echo " Manual follow-ups:"
  echo "   1. Tailscale admin console -> DNS: add split-DNS $DOMAIN -> ${TS_IP:-<tailscale IP>}"
  echo "      (makes shell.$DOMAIN resolve for tailnet devices)"
  echo "   2. (optional) Cloudflare WAF rule skip for cloud.$DOMAIN (desktop sync)"
  echo "   3. Git remote 'homelab' points at git@github.com:friedutch/homelab.git —"
  echo "      rename the GitHub repo to match, or push will fail"
  echo "   4. Post-migration doc pass: docs/ still name vhosts/debian until audited"
  echo "=============================================================="
}

summary() {
  if [ ${#ERR_TAGS[@]} -gt 0 ]; then
    echo ""
    echo " ERROR(S) — no success until every issue below is resolved:"
    for i in "${!ERR_TAGS[@]}"; do
      echo "   $((i+1)). ${ERR_TAGS[$i]} — $(describe "${ERR_TAGS[$i]}")"
    done
  fi
}
trap summary EXIT

# ─────────────────────────────── main ──────────────────────────────────────

main() {
  if [ "${1:-}" = "--op" ] && [ "$(id -u)" -eq 0 ]; then
    echo "Run --op mode as user '$OP_USER'."; exit 1
  fi
  [ "${1:-}" != "--op" ] && banner
  load_state
  ask_inputs
  save_state

  if [ "$(id -u)" -eq 0 ] && [ "${1:-}" != "--op" ]; then
    phase1_root
  elif [ "${1:-}" = "--op" ]; then
    phase2_op
    resolve_errors
  else
    echo "First run must be as root (the script hands off to '$OP_USER' automatically)."; exit 1
  fi
}

main "$@"
