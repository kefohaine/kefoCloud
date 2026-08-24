#!/bin/bash
# jehpok install.sh — plug-and-play new-VPS installer.
#
# Prompts for three values (domain, Cloudflare API token, Tailscale auth
# key), then runs unattended: host services, docker, tailscale, the four
# containers (Caddy renamed to $DOMAIN, nextcloud, vaultwarden, ut-kuma),
# Cloudflare DNS records, and LE cert issuance. Errors are collected and
# printed numbered at the end, followed by a success summary.
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
REPO=/var/www/custom/projects/jehpok/repo
STATE=/var/tmp/jehpok-install.state
LOG=/var/log/jehpok-install.log
ERR=()

log()  { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
err()  { ERR+=("$*"); echo "  ERROR: $*" >>"$LOG"; }

banner() {
cat <<'EOF'
============================================================
  jehpok VPS installer
  Nextcloud + Vaultwarden + Uptime Kuma + Caddy ($DOMAIN)
  Prompts once, then runs unattended. Errors listed at the end.
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
  log "Phase 1 (root): packages, user $OP_USER, ssh, docker, tailscale, firewall"
  touch "$LOG" && chmod 666 "$LOG"

  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    docker.io docker-compose-plugin git curl make sudo dnsmasq ufw jq \
    apache2-utils >/dev/null 2>&1 || err "apt install failed"

  if ! id -u "$OP_USER" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$OP_USER" || err "adduser $OP_USER failed"
  fi
  usermod -aG sudo,docker "$OP_USER"
  echo "$OP_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$OP_USER-passwordless
  chmod 0440 /etc/sudoers.d/$OP_USER-passwordless

  mkdir -p /home/$OP_USER/.ssh
  cp /root/.ssh/authorized_keys /home/$OP_USER/.ssh/authorized_keys 2>/dev/null || \
    log "no root authorized_keys found — add a key for $OP_USER later if needed"
  chown -R $OP_USER:$OP_USER /home/$OP_USER/.ssh
  chmod 700 /home/$OP_USER/.ssh && chmod 600 /home/$OP_USER/.ssh/authorized_keys

  printf 'PasswordAuthentication no\nPermitRootLogin no\nAllowUsers %s\n' "$OP_USER" \
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
    curl -fsSL https://tailscale.com/install.sh | sh || err "tailscale install failed"
  fi
  if ! tailscale ip -4 >/dev/null 2>&1; then
    tailscale up --authkey="$TS_AUTHKEY" >>"$LOG" 2>&1 || err "tailscale up failed"
  fi
  TS_IP=$(tailscale ip -4 2>/dev/null | head -1)
  [ -n "$TS_IP" ] && log "tailscale IP: $TS_IP" || err "no tailscale IP"

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
  mkdir -p /var/www/custom/projects/jehpok
  chown $OP_USER:$OP_USER /var/www/custom/projects/jehpok
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
  if ! GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" \
       git clone git@github.com:friedutch/jehpok.com.git "$REPO" >>"$LOG" 2>&1; then
    err "repo clone failed — add the pubkey above to GitHub, then re-run"
    exit 1
  fi
}

prep_dirs() {
  cd "$REPO" || exit 1
  mkdir -p cloud/html cloud/users vault/data kuma/data
  sudo chown -R 33:33 cloud/html cloud/users
  sudo chown -R 1000:1000 vault/data
}

renames() {
  cd "$REPO" || exit 1
  log "  domain swap: jehpok.com -> $DOMAIN"
  grep -rl 'jehpok\.com' services/ config/ | xargs sed -i "s/jehpok\.com/$DOMAIN/g"
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
  rm -f www.jehpok.com.caddy share.jehpok.com.caddy api.jehpok.com.caddy mc.jehpok.com.caddy
  for f in *.jehpok.com.caddy; do [ -e "$f" ] && mv "$f" "${f/jehpok.com/$DOMAIN}"; done
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

LOG=/var/log/jehpok-daily.log
echo "=== $(date) ===" >> "$LOG"

cd /var/www/custom/projects/jehpok/repo

make update        >> "$LOG" 2>&1
make bkp-all       >> "$LOG" 2>&1 || echo "bkp-all failed" >> "$LOG"
make clean-all     >> "$LOG" 2>&1 || echo "clean-all failed" >> "$LOG"

echo "--- done ---" >> "$LOG"
EOF
  log "  kuma seed SQL (4-container set)"
  sed -i "/'docker'/ s/'cloud'/'nextcloud'/g; /'docker'/ s/'vault'/'vaultwarden'/g; /'docker'/ s/'share'/'share-flask'/g; /'docker'/ s/'domain'/'$DOMAIN'/g" services/ut-kuma/seed-monitors.sql
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
    err "no tailscale IP — dnsmasq config left at the old IP"
  fi
  make install-config >>"$LOG" 2>&1 || err "make install-config failed"
}

containers_up() {
  log "  building Caddy image ($DOMAIN:local) — ~3 min on a cold cache"
  make "recreate-$DOMAIN" >>"$LOG" 2>&1 || err "recreate-$DOMAIN failed"
  make recreate-nextcloud   >>"$LOG" 2>&1 || err "recreate-nextcloud failed"
  make recreate-vaultwarden >>"$LOG" 2>&1 || err "recreate-vaultwarden failed"
  make recreate-ut-kuma     >>"$LOG" 2>&1 || err "recreate-ut-kuma failed"
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
      || err "nextcloud datadirectory set failed"
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
        >>"$LOG" 2>&1 || err "kuma admin insert failed — create the admin in the UI instead"
    fi
  fi
  docker exec -i ut-kuma sqlite3 /app/data/kuma.db < services/ut-kuma/seed-monitors.sql \
    >>"$LOG" 2>&1 || err "kuma monitor seed failed (create monitors in the UI)"
}

cf_dns() {
  VPS_IP=$(curl -s4 ifconfig.me)
  ZONE_ID=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" | jq -r '.result[0].id // empty')
  if [ -z "$ZONE_ID" ]; then
    err "Cloudflare zone '$DOMAIN' not found — create it in the dashboard, then re-run"
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
        >>"$LOG" 2>&1 || err "DNS record $h.$DOMAIN creation failed"
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
      *) err "cert for $h.$DOMAIN: issuer is '$iss' (expected Let's Encrypt)";;
    esac
  done
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
}

summary() {
  echo ""
  echo "=============================================================="
  if [ ${#ERR[@]} -gt 0 ]; then
    echo " ERRORS (${#ERR[@]}):"
    for i in "${!ERR[@]}"; do echo "   $((i+1)). ${ERR[$i]}"; done
  else
    echo " No errors."
  fi
  echo "=============================================================="
  echo " SUCCESS — the stack is up:"
  echo "   Nextcloud    https://cloud.$DOMAIN      admin / ${NEXTCLOUD_ADMIN_PASSWORD:-<see services/nextcloud/.env>}"
  echo "   Vaultwarden  https://vault.$DOMAIN"
  echo "   Uptime Kuma  https://kuma.$DOMAIN       admin / ${KUMA_PASS:-<create in the UI>}"
  echo "   Shell        https://shell.$DOMAIN      (tailnet-only)"
  echo "   VPS IP ${VPS_IP:-?}   Tailscale IP ${TS_IP:-?}"
  echo ""
  echo " Manual follow-ups:"
  echo "   1. Tailscale admin console -> DNS: add split-DNS $DOMAIN -> ${TS_IP:-<tailscale IP>}"
  echo "      (makes shell.$DOMAIN resolve for tailnet devices)"
  echo "   2. (optional) Cloudflare WAF rule skip for cloud.$DOMAIN (desktop sync)"
  echo "   3. Post-migration doc pass: docs/ still name vhosts/debian until audited"
  echo "=============================================================="
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
  else
    echo "First run must be as root (the script hands off to '$OP_USER' automatically)."; exit 1
  fi
}

main "$@"
