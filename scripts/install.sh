#!/bin/bash
# homelab install.sh — plug-and-play new-VPS installer.
#
# Prompts for three values (domain, Cloudflare API token, Tailscale auth
# key), then runs unattended: host services, docker, tailscale, the four
# containers (Caddy renamed to $DOMAIN, nextcloud, vaultwarden, uptimekuma),
# Cloudflare DNS records, and LE cert issuance.
#
# Errors are collected with tags, each shown as a "problem" plus a separate
# "hint". Manual dashboard steps are grouped as expected; real failures as
# unexpected. No success message is printed until every error is resolved:
# after the setup you get a numbered list of what's still failing, and each
# time you press Enter the script re-checks them, prints the solved ones
# once, and the remaining ones — until all are green. Both 'root' and user
# 'op' can SSH in with keys automatically.
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
declare -A ERR_DETAIL=()

log()  { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
fail() {
  local t
  for t in "${ERR_TAGS[@]}"; do [ "$t" = "$1" ] && return 0; done  # no duplicates across runs
  ERR_TAGS+=("$1"); ERR_DETAIL[$1]="${2:-}"
  echo "  ERROR: $(problem "$1")${2:+ ($2)}" >>"$LOG"
}

banner() {
cat <<'EOF'
██╗  ██╗ ██████╗ ███╗   ███╗███████╗██╗      █████╗ ██████╗
██║  ██║██╔═══██╗████╗ ████║██╔════╝██║     ██╔══██╗██╔══██╗
███████║██║   ██║██╔████╔██║█████╗  ██║     ███████║██████╔╝
██╔══██║██║   ██║██║╚██╔╝██║██╔══╝  ██║     ██╔══██║██╔══██╗
██║  ██║╚██████╔╝██║ ╚═╝ ██║███████╗███████╗██║  ██║██████╔╝
╚═╝  ╚═╝ ╚═════╝ ╚═╝     ╚═╝╚══════╝╚══════╝╚═╝  ╚═╝╚═════╝

  One-shot setup for a fresh Debian VPS: Nextcloud, Vaultwarden,
  Uptime Kuma and Caddy (named after your domain) behind Cloudflare,
  with tailscale, ttyd, dnsmasq and goose as host services. Prompts
  once (domain, Cloudflare API token, Tailscale auth key), then runs
  unattended — errors are listed with a hint each and re-checked
  until resolved, and success prints only when all are green.

WARNING: SSH (port 22) is tailnet-only — your current session stays alive, but the next login must come from a Tailscale device.
EOF
}

load_state() {
  [ -f "$STATE" ] && . "$STATE"
  local uniq=() t
  for t in "${ERR_TAGS[@]:-}"; do
    [[ " ${uniq[*]:-} " == *" $t "* ]] || uniq+=("$t")
  done
  ERR_TAGS=("${uniq[@]}")
}

save_state() {
  umask 077
  local tmp="$STATE.tmp.$$"
  cat > "$tmp" <<EOF
DOMAIN='$DOMAIN'
CF_API_TOKEN='$CF_API_TOKEN'
TS_AUTHKEY='$TS_AUTHKEY'
TS_IP='${TS_IP:-}'
ERR_TAGS=($(printf '%q ' "${ERR_TAGS[@]}"))
EOF
  chmod 600 "$tmp"
  mv -f "$tmp" "$STATE" 2>/dev/null || sudo mv -f "$tmp" "$STATE" || rm -f "$tmp"
  chown $OP_USER:$OP_USER "$STATE" 2>/dev/null || true
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

  DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$LOG" 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    git curl make sudo dnsmasq ufw jq apache2-utils >>"$LOG" 2>&1 || fail apt
  # Docker: Debian packages first (bookworm ships docker-compose-plugin).
  # trixie does not, so fall back to Docker's official repo (docker-ce).
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io docker-compose-plugin >>"$LOG" 2>&1; then
    log "  docker-compose-plugin not in distro — installing docker-ce from Docker's repo"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl gnupg >>"$LOG" 2>&1
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg 2>>"$LOG"
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$LOG" 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >>"$LOG" 2>&1 || fail apt
  fi
  command -v docker >/dev/null 2>&1 || fail apt

  if ! id -u "$OP_USER" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$OP_USER" || fail user
  fi
  usermod -aG sudo,docker "$OP_USER"
  mkdir -p /etc/sudoers.d
  echo "$OP_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$OP_USER-passwordless
  chmod 0440 /etc/sudoers.d/$OP_USER-passwordless

  # SSH: root and op both log in with keys. Hardening (password off, root
  # key-only) is applied only when a key exists — never lock the operator
  # out of password SSH on a box that has no keys yet.
  mkdir -p /home/$OP_USER/.ssh /root/.ssh
  chown -R $OP_USER:$OP_USER /home/$OP_USER/.ssh
  chmod 700 /home/$OP_USER/.ssh
  if [ -s /root/.ssh/authorized_keys ]; then
    cp /root/.ssh/authorized_keys /home/$OP_USER/.ssh/authorized_keys
    chmod 600 /home/$OP_USER/.ssh/authorized_keys
    printf 'PasswordAuthentication no\nPermitRootLogin prohibit-password\nAllowUsers %s root\n' "$OP_USER" \
      > /etc/ssh/sshd_config.d/50-cloud-init.conf
    systemctl restart sshd
  else
    fail ssh_keys
    log "no SSH key yet — sshd hardening skipped so password login still works; add a key, then re-check"
  fi

  systemctl enable --now docker >>"$LOG" 2>&1 || log "docker enable/start failed (re-checks will catch it)"
  mkdir -p /etc/docker
  # Write the daemon config only if it differs — never clobber a working one.
  cat > /etc/docker/daemon.json.new <<'EOF'
{
    "log-driver": "json-file",
    "log-opts": {"max-size": "10m", "max-file": "3"},
    "storage-driver": "overlay2",
    "default-runtime": "runc",
    "live-restore": true
}
EOF
  if ! diff -q /etc/docker/daemon.json /etc/docker/daemon.json.new >/dev/null 2>&1; then
    mv /etc/docker/daemon.json.new /etc/docker/daemon.json
    systemctl restart docker >>"$LOG" 2>&1 || log "docker restart failed (re-checks will catch it)"
  else
    rm -f /etc/docker/daemon.json.new
  fi
  if ! systemctl is-active --quiet docker; then
    systemctl start docker >>"$LOG" 2>&1 || log "docker start failed (re-checks will catch it)"
  fi

  if ! command -v goose >/dev/null 2>&1 && [ ! -x /usr/local/bin/goose ]; then
    curl -fsSL https://github.com/aaif-goose/goose/releases/download/stable/download_cli.sh \
      | CONFIGURE=false GOOSE_BIN_DIR=/usr/local/bin bash >/dev/null 2>&1 || true
  fi
  if command -v goose >/dev/null 2>&1; then
    install -m 0755 "$(command -v goose)" /usr/local/bin/goose || true
  elif [ -x "$HOME/.local/bin/goose" ]; then
    install -m 0755 "$HOME/.local/bin/goose" /usr/local/bin/goose || true
  fi
  command -v goose >/dev/null 2>&1 || [ -x /usr/local/bin/goose ] || fail goose

  if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh || fail tailscale
  fi
  if ! tailscale ip -4 >/dev/null 2>&1; then
    tailscale up --authkey="$TS_AUTHKEY" >>"$LOG" 2>&1 || fail tailscale_up
  fi
  TS_IP=$(tailscale ip -4 2>/dev/null | head -1)
  [ -n "$TS_IP" ] && log "tailscale IP: $TS_IP" || fail ts_ip

  ufw allow from 100.64.0.0/10 to any port 22 proto tcp >/dev/null 2>&1
  # Keep the current SSH client reachable even before it joins the tailnet,
  # so enabling ufw never locks the operator out mid-install.
  if [ -n "${SSH_CLIENT:-}" ]; then
    ufw allow from "$(echo "$SSH_CLIENT" | awk '{print $1}')" to any port 22 proto tcp >/dev/null 2>&1 || true
  fi
  ufw allow 80/tcp >/dev/null 2>&1
  ufw allow 443/tcp >/dev/null 2>&1
  # Minecraft game ports — the PufferPanel-managed game server owns Java 25565; Geyser-Spigot
  # on the game server owns Bedrock 19132/udp (only answers while server is up).
  ufw allow 25565/tcp >/dev/null 2>&1
  ufw allow 19132/udp >/dev/null 2>&1
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
  if [ -d "$REPO/.git" ]; then
    # Repo already present (re-run or pre-cloned): make sure the remote is wired.
    git -C "$REPO" remote rename origin homelab 2>/dev/null || true
    git -C "$REPO" remote set-url homelab git@github.com:friedutch/homelab.git 2>/dev/null || true
    log "repo present at $REPO"
    return
  fi
  sudo mkdir -p /var/www/custom/projects/homelab
  # root umask may be 077: force parents traversable so op can clone into it
  sudo chmod 0755 /var/www /var/www/custom /var/www/custom/projects 2>/dev/null || true
  sudo chown $OP_USER:$OP_USER /var/www/custom/projects/homelab
  if [ ! -f ~/.ssh/github_key ]; then
    ssh-keygen -t ed25519 -N "" -f ~/.ssh/github_key -C "$OP_USER@$DOMAIN" >/dev/null
    cat > ~/.ssh/config <<EOF
Host github.com
  IdentityFile ~/.ssh/github_key
  IdentitiesOnly yes
EOF
    chmod 600 ~/.ssh/config
    echo "============================================================"
    echo " NEW KEY — ADD IT TO GITHUB (Settings -> SSH keys):"
    cat ~/.ssh/github_key.pub
    echo "============================================================"
  fi
  # Clone from the renamed repo first; fall back to the pre-rename URL
  # (this script is the only place the old name is allowed to appear).
  if GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" \
       git clone git@github.com:friedutch/homelab.git "$REPO" >>"$LOG" 2>&1; then
    :
  elif GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" \
       git clone git@github.com:friedutch/jehpok.com.git "$REPO" >>"$LOG" 2>&1; then
    log "cloned from the pre-rename repo; remote will point at the renamed one"
  else
    echo "============================================================"
    echo " REPO CLONE FAILED. Add this key to GitHub (Settings -> SSH keys),"
    echo " then re-run the script:"
    cat ~/.ssh/github_key.pub
    echo "============================================================"
    fail clone "repo clone failed — add the key printed above to GitHub, then re-run"
    exit 1
  fi
  git -C "$REPO" remote rename origin homelab
  git -C "$REPO" remote set-url homelab git@github.com:friedutch/homelab.git
}

prep_dirs() {
  # Data dirs live at $(REPO)/... (sibling of the clone), matching the
  # compose bind mounts — not inside repo/.
  sudo mkdir -p /var/www/custom/projects/homelab/cloud/html \
               /var/www/custom/projects/homelab/cloud/users \
               /var/www/custom/projects/homelab/vault/data \
               /var/www/custom/projects/homelab/kuma/data
  sudo chown -R 33:33 /var/www/custom/projects/homelab/cloud/html /var/www/custom/projects/homelab/cloud/users
  sudo chown -R 1000:1000 /var/www/custom/projects/homelab/vault/data
}

renames() {
  cd "$REPO" || exit 1
  log "  domain swap: homelab.com -> $DOMAIN"
  grep -rl 'homelab\.com' services/ config/ | xargs sed -i "s/homelab\.com/$DOMAIN/g"
  log "  server.$DOMAIN -> shell.$DOMAIN"
  grep -rl "server\.$DOMAIN" services/ config/ | xargs sed -i "s/server\.$DOMAIN/shell.$DOMAIN/g"
  log "  debian -> $OP_USER"
  grep -rl 'debian' Makefile config/ | xargs sed -i "s/debian/$OP_USER/g"
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
  sed -i "s/^CONTAINERS := .*/CONTAINERS := $DOMAIN uptimekuma nextcloud vaultwarden/" Makefile
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
  log "  kuma seed SQL (4-container set)"
  cat > services/uptimekuma/seed-monitors.sql <<EOF
-- First-time Kuma monitor seed (4-container set, generated by install.sh).
-- Apply with: docker exec -i uptimekuma sqlite3 /app/data/kuma.db < services/uptimekuma/seed-monitors.sql

INSERT INTO docker_host (user_id, name, docker_type, docker_daemon)
SELECT 1, 'local', 'socket', '/var/run/docker.sock'
WHERE NOT EXISTS (SELECT 1 FROM docker_host WHERE name = 'local');

INSERT INTO monitor (name, type, url, interval, retry_interval, maxretries, active, user_id, description)
SELECT 'http: cloud', 'http', 'https://cloud.$DOMAIN', 60, 60, 0, 1, 1, 'Nextcloud'
WHERE NOT EXISTS (SELECT 1 FROM monitor WHERE name = 'http: cloud');

INSERT INTO monitor (name, type, url, interval, retry_interval, maxretries, active, user_id, description)
SELECT 'http: vault', 'http', 'https://vault.$DOMAIN', 60, 60, 0, 1, 1, 'Vaultwarden'
WHERE NOT EXISTS (SELECT 1 FROM monitor WHERE name = 'http: vault');

INSERT INTO monitor (name, type, interval, retry_interval, maxretries, active, user_id, docker_host, docker_container, description)
SELECT 'docker: $DOMAIN', 'docker', 3600, 60, 0, 1, 1, d.id, '$DOMAIN', 'Caddy reverse proxy'
FROM docker_host d WHERE d.name = 'local'
  AND NOT EXISTS (SELECT 1 FROM monitor WHERE name = 'docker: $DOMAIN');

INSERT INTO monitor (name, type, interval, retry_interval, maxretries, active, user_id, docker_host, docker_container, description)
SELECT 'docker: nextcloud', 'docker', 3600, 60, 0, 1, 1, d.id, 'nextcloud', 'Nextcloud PHP-FPM'
FROM docker_host d WHERE d.name = 'local'
  AND NOT EXISTS (SELECT 1 FROM monitor WHERE name = 'docker: nextcloud');

INSERT INTO monitor (name, type, interval, retry_interval, maxretries, active, user_id, docker_host, docker_container, description)
SELECT 'docker: vaultwarden', 'docker', 3600, 60, 0, 1, 1, d.id, 'vaultwarden', 'Vaultwarden'
FROM docker_host d WHERE d.name = 'local'
  AND NOT EXISTS (SELECT 1 FROM monitor WHERE name = 'docker: vaultwarden');

INSERT INTO "group" (name) SELECT 'Public'     WHERE NOT EXISTS (SELECT 1 FROM "group" WHERE name = 'Public');
INSERT INTO "group" (name) SELECT 'Containers' WHERE NOT EXISTS (SELECT 1 FROM "group" WHERE name = 'Containers');

INSERT INTO monitor_group (monitor_id, group_id)
SELECT m.id, g.id FROM monitor m, "group" g
WHERE g.name = 'Public' AND m.name IN ('http: cloud','http: vault')
  AND NOT EXISTS (SELECT 1 FROM monitor_group mg WHERE mg.monitor_id = m.id AND mg.group_id = g.id);

INSERT INTO monitor_group (monitor_id, group_id)
SELECT m.id, g.id FROM monitor m, "group" g
WHERE g.name = 'Containers' AND m.name LIKE 'docker: %'
  AND NOT EXISTS (SELECT 1 FROM monitor_group mg WHERE mg.monitor_id = m.id AND mg.group_id = g.id);
EOF
  log "  goose service secret"
  if ! grep -q GOOSE_SERVER__SECRET_KEY config/goose/goose.service; then
    # insert into [Service] (after ExecStart) — a plain append lands after [Install] and is ignored
    sed -i "/^ExecStart=/a Environment=GOOSE_SERVER__SECRET_KEY=$(openssl rand -hex 32)" config/goose/goose.service
  fi
  git add -A && git -c user.name="$OP_USER" -c user.email="$OP_USER@$DOMAIN" \
    commit -q -m "install: domain $DOMAIN, user $OP_USER, shell., 4 containers" 2>/dev/null || true
}

docker_net() {
  docker network create net --subnet=172.22.0.0/16 >>"$LOG" 2>&1 || true
}

caddy_data() {
  # The compose env_file path is $(REPO)/caddy_data (sibling of repo/), not inside the clone.
  sudo mkdir -p /var/www/custom/projects/homelab/caddy_data
  printf 'CF_API_TOKEN=%s\n' "$CF_API_TOKEN" | sudo tee /var/www/custom/projects/homelab/caddy_data/CF_API_TOKEN >/dev/null
  sudo chown -R 201:201 /var/www/custom/projects/homelab/caddy_data
  sudo chown $OP_USER:$OP_USER /var/www/custom/projects/homelab/caddy_data/CF_API_TOKEN
  sudo chmod 0644 /var/www/custom/projects/homelab/caddy_data/CF_API_TOKEN
}

host_services() {
  if [ -n "${TS_IP:-}" ]; then
    sed -i "s/100\.81\.245\.77/$TS_IP/g" config/dnsmasq/10-tailnet.conf
  else
    fail ts_ip
  fi
  make install-config >>"$LOG" 2>&1 || fail install_config
}

containers_up() {
  log "  building Caddy image ($DOMAIN:local) — ~3 min on a cold cache"
  if ! make "d-recreate-$DOMAIN" >>"$LOG" 2>&1; then
    # compose build on trixie requires buildx >= 0.17; fall back to plain docker build
    log "  compose build failed — falling back to docker build + compose up"
    docker build -t "$DOMAIN:local" "services/$DOMAIN" >>"$LOG" 2>&1 \
      && docker compose -f "services/$DOMAIN/docker-compose.yml" up -d --force-recreate >>"$LOG" 2>&1 \
      || fail caddy
  fi
  make d-recreate-nextcloud   >>"$LOG" 2>&1 || fail nextcloud
  make d-recreate-vaultwarden >>"$LOG" 2>&1 || fail vaultwarden
  make d-recreate-uptimekuma     >>"$LOG" 2>&1 || fail kuma
}

kuma_seed() {
  local i=0
  while [ $i -lt 60 ]; do
    docker exec uptimekuma test -f /app/data/kuma.db 2>/dev/null && break
    sleep 2; i=$((i+2))
  done
  KUMA_PASS=$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)
  local n
  n=$(docker exec uptimekuma sqlite3 /app/data/kuma.db "SELECT COUNT(*) FROM user WHERE username='admin';" 2>/dev/null | tr -d '\n')
  if [ "$n" = "0" ]; then
    local HASH
    HASH=$(htpasswd -bnBC 10 "" "$KUMA_PASS" 2>/dev/null | tr -d ':\n')
    if [ -n "$HASH" ]; then
      docker exec uptimekuma sqlite3 /app/data/kuma.db \
        "INSERT OR IGNORE INTO user (username,password,active,timezone) VALUES ('admin','$HASH',1,'UTC');" \
        >>"$LOG" 2>&1 || fail kuma_admin
    fi
  fi
  docker exec -i uptimekuma sqlite3 /app/data/kuma.db < services/uptimekuma/seed-monitors.sql \
    >>"$LOG" 2>&1 || fail kuma_seed
}

ssl_mode_full() {
  # API first (needs Zone Settings read on the token); fall back to a
  # behavior probe — Flexible/Off makes CF reach the origin over HTTP and
  # Caddy answers a 308 back to the same https URL (redirect loop).
  local mode hdrs code loc
  mode=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings/ssl" 2>/dev/null \
    | jq -r '.result.value // empty' 2>/dev/null)
  case "$mode" in full|strict) return 0 ;; esac
  [ -n "$mode" ] && return 1
  hdrs=$(curl -sI --max-time 15 "https://cloud.$DOMAIN" 2>/dev/null | tr -d '\r')
  code=$(echo "$hdrs" | awk 'NR==1{print $2}')
  loc=$(echo "$hdrs" | awk 'tolower($1)=="location:"{print $2; exit}')
  [ "$code" = "308" ] && [[ "$loc" == *"cloud.$DOMAIN"* ]] && return 1
  return 0
}

cf_dns() {
  VPS_IP=$(curl -s4 ifconfig.me)
  ZONE_ID=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" | jq -r '.result[0].id // empty')
  if [ -z "$ZONE_ID" ]; then
    fail zone
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
        >>"$LOG" 2>&1 || fail "dns_$h"
    fi
  done
  curl -s -X PATCH -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings/ssl" -d '{"value":"full"}' >>"$LOG" 2>&1 || true
  # DNS-only tokens can't set SSL mode; surface it as an expected manual step.
  if ! ssl_mode_full; then
    fail sslmode
  fi
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
      *) fail "cert_$h" "issuer was: $iss";;
    esac
  done
}

sweep() {
  # Old-project references must not survive anywhere except this script.
  local hits
  hits=$(grep -rl 'jehpok' "$REPO" --exclude-dir=.git 2>/dev/null \
    | grep -v "^$REPO/scripts/install.sh$" || true)
  if [ -n "$hits" ]; then
    fail sweep
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
  kuma_seed
  cf_dns
  issue_certs
  sweep
  # Expected manual step — blocks SUCCESS until the operator confirms it.
  fail splitdns
}

# ──────────────────────── error problems + hints ──────────────────────────

problem() {
  case "$1" in
    apt)            echo "apt packages not installed" ;;
    goose)          echo "goose binary not installed" ;;
    user)           echo "user '$OP_USER' not created" ;;
    ssh_keys)       echo "no SSH keys for root or $OP_USER" ;;
    tailscale)      echo "tailscale binary not installed" ;;
    tailscale_up)   echo "tailscale did not connect" ;;
    ts_ip)          echo "no tailscale IP assigned" ;;
    install_config) echo "host services are not up (make install-config failed)" ;;
    caddy)          echo "caddy container '$DOMAIN' is not running" ;;
    nextcloud)      echo "nextcloud container is not running" ;;
    vaultwarden)    echo "vaultwarden container is not running" ;;
    kuma)           echo "uptimekuma container is not running" ;;
    datadirectory)  echo "nextcloud datadirectory is not /data" ;;
    kuma_admin)     echo "uptime kuma admin user is missing" ;;
    kuma_seed)      echo "uptime kuma monitors are not seeded" ;;
    zone)           echo "Cloudflare zone '$DOMAIN' not found" ;;
    dns_*)          echo "DNS record for ${1#dns_}.$DOMAIN is missing" ;;
    cert_*)         echo "cert for ${1#cert_}.$DOMAIN is not issued by Let's Encrypt" ;;
    sweep)          echo "old project name is still referenced in the repo tree" ;;
    splitdns)       echo "tailscale split-DNS for $DOMAIN is not configured" ;;
    sslmode)        echo "Cloudflare SSL/TLS mode is not Full (or strict)" ;;
    clone)          echo "repo clone failed" ;;
    *)              echo "$1" ;;
  esac
}

hint() {
  case "$1" in
    apt)            echo "install git curl make sudo dnsmasq ufw jq apache2-utils, plus docker with the compose plugin (docker-ce from download.docker.com on trixie), then re-check" ;;
    goose)          echo "run: curl -fsSL https://github.com/aaif-goose/goose/releases/download/stable/download_cli.sh | CONFIGURE=false GOOSE_BIN_DIR=/usr/local/bin bash, then re-check" ;;
    user)           echo "run: adduser --disabled-password --gecos '' $OP_USER && usermod -aG sudo,docker $OP_USER, then re-check" ;;
    ssh_keys)       echo "add a public key to /root/.ssh/authorized_keys and copy it to /home/$OP_USER/.ssh/authorized_keys, then re-check" ;;
    tailscale)      echo "run: curl -fsSL https://tailscale.com/install.sh | sh, then re-check" ;;
    tailscale_up)   echo "check the auth key (admin console -> Settings -> Keys) and run: tailscale up --authkey=<key>, then re-check" ;;
    ts_ip)          echo "wait a few seconds, then run: tailscale ip -4, then re-check" ;;
    install_config) echo "run: make install-config in $REPO, then re-check" ;;
    caddy)          echo "run: make d-recreate-$DOMAIN, then re-check" ;;
    nextcloud)      echo "run: make d-recreate-nextcloud, then re-check" ;;
    vaultwarden)    echo "run: make d-recreate-vaultwarden, then re-check" ;;
    kuma)           echo "run: make d-recreate-uptimekuma, then re-check" ;;
    datadirectory)  echo "run: docker exec -w /var/www/html nextcloud php occ config:system:set datadirectory --value /data, then re-check" ;;
    kuma_admin)     echo "create the admin account at https://kuma.$DOMAIN in the UI, then re-check" ;;
    kuma_seed)      echo "run: docker exec -i uptimekuma sqlite3 /app/data/kuma.db < services/uptimekuma/seed-monitors.sql, or create monitors in the UI, then re-check" ;;
    zone)           echo "add $DOMAIN as a zone in the Cloudflare dashboard, then re-check" ;;
    dns_*)          echo "create an A record ${1#dns_}.$DOMAIN -> ${VPS_IP:-<VPS IP>} (proxied) in Cloudflare, then re-check" ;;
    cert_*)         echo "hit https://${1#cert_}.$DOMAIN once to trigger ACME, wait a few seconds, then re-check" ;;
    sweep)          echo "rename or remove the files listed by: grep -rl jehpok $REPO --exclude-dir=.git" ;;
    splitdns)       echo "Tailscale admin console -> DNS: add split-DNS $DOMAIN -> ${TS_IP:-<tailscale IP>}, then confirm (y)" ;;
    sslmode)        echo "Cloudflare dashboard -> SSL/TLS -> Overview -> set mode to Full (or Full strict), then re-check" ;;
    clone)          echo "add the key printed above to GitHub (Settings -> SSH keys), then re-run the script" ;;
    *)              echo "" ;;
  esac
}

recheck() {
  case "$1" in
    apt) command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 && dpkg -s git curl make sudo dnsmasq ufw jq apache2-utils >/dev/null 2>&1 ;;
    goose) command -v goose >/dev/null 2>&1 || [ -x /usr/local/bin/goose ] ;;
    user) id -u "$OP_USER" >/dev/null 2>&1 ;;
    ssh_keys) sudo test -s /root/.ssh/authorized_keys && [ -s /home/$OP_USER/.ssh/authorized_keys ] ;;
    tailscale) command -v tailscale >/dev/null 2>&1 ;;
    tailscale_up) tailscale ip -4 >/dev/null 2>&1 ;;
    ts_ip) [ -n "$(tailscale ip -4 2>/dev/null | head -1)" ] ;;
    install_config) systemctl is-active --quiet ttyd dnsmasq goose ;;
    caddy) docker ps --format '{{.Names}}' | grep -qx "$DOMAIN" ;;
    nextcloud) docker ps --format '{{.Names}}' | grep -qx nextcloud ;;
    vaultwarden) docker ps --format '{{.Names}}' | grep -qx vaultwarden ;;
    kuma) docker ps --format '{{.Names}}' | grep -qx uptimekuma ;;
    datadirectory) if docker exec -w /var/www/html nextcloud php occ status 2>/dev/null | grep -q "installed: true"; then [ "$(docker exec -w /var/www/html nextcloud php occ config:system:get datadirectory 2>/dev/null | tr -d '\n')" = "/data" ]; else true; fi ;;
    kuma_admin) [ "$(docker exec uptimekuma sqlite3 /app/data/kuma.db "SELECT COUNT(*) FROM user WHERE username='admin';" 2>/dev/null | tr -d '\n')" = "1" ] ;;
    kuma_seed) [ "$(docker exec uptimekuma sqlite3 /app/data/kuma.db "SELECT COUNT(*) FROM monitor;" 2>/dev/null | tr -d '\n')" -gt 0 ] ;;
    zone) [ -n "$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" | jq -r '.result[0].id // empty')" ] ;;
    dns_*) local h=${1#dns_}; [ -n "$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$h.$DOMAIN" | jq -r '.result[0].id // empty')" ] ;;
    cert_*) local h=${1#cert_}; echo | timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "$h.$DOMAIN" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null | grep -q "Let's Encrypt" ;;
    sweep) ! grep -rl 'jehpok' "$REPO" --exclude-dir=.git 2>/dev/null | grep -qv "^$REPO/scripts/install.sh$" ;;
    splitdns) read -rp "    Confirmed split-DNS set in the Tailscale admin console? (y/N): " c && [[ "$c" =~ ^[yY]$ ]] ;;
    sslmode) ssl_mode_full ;;
    *) false ;;
  esac
}

is_expected() {
  case "$1" in
    splitdns|zone|ssh_keys|kuma_admin|clone|sslmode) return 0 ;;  # manual dashboard / UI steps
    *) return 1 ;;
  esac
}

resolve_errors() {
  local remaining=("${ERR_TAGS[@]}")
  while [ ${#remaining[@]} -gt 0 ]; do
    echo ""
    local exp=() unexp=()
    for tag in "${remaining[@]}"; do
      if is_expected "$tag"; then exp+=("$tag"); else unexp+=("$tag"); fi
    done
    if [ ${#exp[@]} -gt 0 ]; then
      echo " Manual steps (expected):"
      for i in "${!exp[@]}"; do
        echo "   $((i+1)). ${exp[$i]}"
        echo "      problem: $(problem "${exp[$i]}")${ERR_DETAIL[${exp[$i]}]:+ (${ERR_DETAIL[${exp[$i]}]})}"
        echo "      hint: $(hint "${exp[$i]}")"
      done
    fi
    if [ ${#unexp[@]} -gt 0 ]; then
      echo " Unexpected errors (${#unexp[@]}):"
      for i in "${!unexp[@]}"; do
        echo "   $((i+1)). ${unexp[$i]}"
        echo "      problem: $(problem "${unexp[$i]}")${ERR_DETAIL[${unexp[$i]}]:+ (${ERR_DETAIL[${unexp[$i]}]})}"
        echo "      hint: $(hint "${unexp[$i]}")"
      done
    fi
    read -rp "Fix / complete the items above, then press Enter to re-check (Ctrl-C aborts): " input \
      || { echo "No terminal input — aborting."; exit 1; }
    local still=()
    for tag in "${remaining[@]}"; do
      if recheck "$tag"; then
        echo "   ✓ solved: $tag — $(problem "$tag")"
      else
        still+=("$tag")
      fi
    done
    remaining=("${still[@]}")
  done
  ERR_TAGS=()
  finalize_hardening
  success_block
}

finalize_hardening() {
  # Runs once every error is resolved: if keys exist now, harden sshd
  # (phase 1 skipped it when no key was present at install time).
  if sudo test -s /root/.ssh/authorized_keys && [ -s /home/$OP_USER/.ssh/authorized_keys ]; then
    printf 'PasswordAuthentication no\nPermitRootLogin prohibit-password\nAllowUsers %s root\n' "$OP_USER" \
      | sudo tee /etc/ssh/sshd_config.d/50-cloud-init.conf >/dev/null
    sudo systemctl restart sshd >/dev/null 2>&1 || true
  fi
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
  echo "   1. (optional) Cloudflare WAF rule skip for cloud.$DOMAIN (desktop sync)"
  echo "   2. Git remote 'homelab' points at git@github.com:friedutch/homelab.git —"
  echo "      rename the GitHub repo to match, or push will fail"
  echo "   3. Post-migration doc pass: docs/ still name vhosts/debian until audited"
  echo "=============================================================="
}

summary() {
  if [ ${#ERR_TAGS[@]} -gt 0 ]; then
    echo ""
    echo " ERROR(S) — no success until every item below is resolved:"
    local exp=() unexp=()
    for tag in "${ERR_TAGS[@]}"; do
      if is_expected "$tag"; then exp+=("$tag"); else unexp+=("$tag"); fi
    done
    if [ ${#exp[@]} -gt 0 ]; then
      echo " Manual steps (expected):"
      for i in "${!exp[@]}"; do
        echo "   $((i+1)). ${exp[$i]}"
        echo "      problem: $(problem "${exp[$i]}")${ERR_DETAIL[${exp[$i]}]:+ (${ERR_DETAIL[${exp[$i]}]})}"
        echo "      hint: $(hint "${exp[$i]}")"
      done
    fi
    if [ ${#unexp[@]} -gt 0 ]; then
      echo " Unexpected errors (${#unexp[@]}):"
      for i in "${!unexp[@]}"; do
        echo "   $((i+1)). ${unexp[$i]}"
        echo "      problem: $(problem "${unexp[$i]}")${ERR_DETAIL[${unexp[$i]}]:+ (${ERR_DETAIL[${unexp[$i]}]})}"
        echo "      hint: $(hint "${unexp[$i]}")"
      done
    fi
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
