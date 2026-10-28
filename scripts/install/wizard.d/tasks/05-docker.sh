# wizard.d/tasks/05-docker.sh — `Docker Engine`: package, daemon config, network.

# Docker Engine: docker + compose plugin, daemon config, start.
task_docker() {
  task_start
  # Debian packages first (bookworm ships docker-compose-plugin); trixie does
  # not, so fall back to Docker's official repo (docker-ce). Skip the whole step
  # when a working docker + compose plugin already exists: on an already-
  # provisioned box the distro install removes the working docker-ce packages
  # and aborts on the docker-buildx / docker-buildx-plugin file conflict
  # (2026-10-15), forcing a full docker-ce reinstall.
  if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io docker-compose-plugin >>"$LOG" 2>&1; then
      detail "  docker-compose-plugin not in distro — installing docker-ce from Docker's repo"
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl gnupg >>"$LOG" 2>&1
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --yes --dearmor -o /etc/apt/keyrings/docker.gpg 2>>"$LOG"
      chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list
      DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$LOG" 2>&1
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >>"$LOG" 2>&1 || fail apt
    fi
  else
    detail "  docker + compose plugin already installed — package install skipped"
  fi
  command -v docker >/dev/null 2>&1 || fail apt

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
  task_end
}
