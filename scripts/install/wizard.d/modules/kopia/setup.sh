# wizard.d/modules/kopia/setup.sh — the backup module: client container + timer.
#
# `make kopia-gen` (Stack Config) wrote the repository password and generated the
# SFTP key; the repository itself lives OFF this host, on the disk the target
# machine mounts, so the installer cannot create it. This step proves the client
# container runs and the timer is armed, then names the one remaining operator
# action (authorize the key on that machine, then `make kopia-init`).
# Idempotent.

kopia_setup() {
  cd "$REPO" || exit 1
  . modules/kopia/.env
  . scripts/lib/kopia-env.sh
  # Container name and config path come from the running container, never a literal.
  kopia_live || { fail kopia_setup "container mounts are unreadable"; return; }

  local i=0
  while [ $i -lt 60 ]; do
    docker ps --format '{{.Names}}' | grep -qx "$KOPIA_CTN" && break
    [ $((i % 15)) -eq 0 ] && log "  waiting for the kopia container (${i}s)"
    sleep 2; i=$((i+2))
  done
  if ! docker ps --format '{{.Names}}' | grep -qx "$KOPIA_CTN"; then
    fail kopia_setup "container is not running — see: make kopia-logs"
    return
  fi
  detail "  container runs (client only: no server, no listener)"

  if systemctl is-enabled --quiet kopia-snapshot.timer 2>/dev/null; then
    detail "  kopia-snapshot.timer is enabled (two daily windows)"
  else
    warn kopia_timer "kopia-snapshot.timer is not enabled — nothing takes snapshots"
  fi

  if docker exec -e KOPIA_PASSWORD="$KOPIA_PASSWORD" "$KOPIA_CTN" \
       kopia --config-file="$KOPIA_CONFIG" repository status >/dev/null 2>&1; then
    detail "  repository opens over SFTP and lists snapshots"
  else
    log "  repository not connected yet: authorize data/kopia/ssh/id_ed25519.pub on ${KOPIA_SFTP_HOST:-the machine that owns the disk}, then run 'make kopia-init'"
  fi
}
