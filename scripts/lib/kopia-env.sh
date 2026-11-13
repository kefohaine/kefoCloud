#!/usr/bin/env bash
# scripts/lib/kopia-env.sh — the kopia module's live paths, read from Docker.
#
# No kopia script hardcodes a container name, a mount destination or a config
# path: they come from config/modules.conf (the declared container) and from the
# container's own mount table. Rename the container, move the data dir or mount
# the source somewhere else and nothing here needs editing.
#
# kopia_live sets:
#   KOPIA_CTN     container name
#   KOPIA_SOURCE  the read-only bind mount (the snapshot source)
#   KOPIA_DATA    the writable bind mount (kopia's own state)
#   KOPIA_CONFIG  repository config inside the container
#   KOPIA_KEY     SFTP private key inside the container
#   KOPIA_KNOWN   pinned host keys inside the container
#   KOPIA_SELF    source-relative path of KOPIA_DATA ('' when it is not under
#                 the source) — the one path a snapshot must ignore
# kopia_live — resolve the container, then the paths it actually mounts, so no
# script hardcodes a container name, a mount destination or a config path.
kopia_live() {
  local dsts ro_src rw_src

  KOPIA_CTN="$(mod_containers kopia 2>/dev/null)"
  KOPIA_CTN="${KOPIA_CTN%% *}"
  [ -n "${KOPIA_CTN:-}" ] || KOPIA_CTN="$(docker ps -a \
    --filter label=com.docker.compose.project=kopia \
    --format '{{.Names}}' 2>/dev/null | head -1)"
  [ -n "${KOPIA_CTN:-}" ] || return 1

  dsts="$(docker inspect "$KOPIA_CTN" \
    --format '{{range .Mounts}}{{.Destination}}={{.Source}}={{.RW}}{{"\n"}}{{end}}' 2>/dev/null)" || return 1
  [ -n "$dsts" ] || return 1

  KOPIA_SOURCE="$(printf '%s\n' "$dsts" | awk -F= '$3=="false"{print $1; exit}')"
  KOPIA_DATA="$(printf '%s\n' "$dsts" | awk -F= '$3=="true"{print $1; exit}')"
  [ -n "$KOPIA_SOURCE" ] && [ -n "$KOPIA_DATA" ] || return 1

  KOPIA_CONFIG="$KOPIA_DATA/config/repository.config"
  KOPIA_KEY="$KOPIA_DATA/ssh/id_ed25519"
  KOPIA_KNOWN="$KOPIA_DATA/ssh/known_hosts"

  ro_src="$(printf '%s\n' "$dsts" | awk -F= -v d="$KOPIA_SOURCE" '$1==d{print $2; exit}')"
  rw_src="$(printf '%s\n' "$dsts" | awk -F= -v d="$KOPIA_DATA" '$1==d{print $2; exit}')"
  case "$rw_src" in
    "$ro_src"/*) KOPIA_SELF="/${rw_src#"$ro_src"/}" ;;
    *)           KOPIA_SELF="" ;;
  esac
  return 0
}

# kopia_lock <flock args> — one snapshot at a time. The timer and a manual
# `make backup` (or `make kopia-restore`) take the SAME lock, so two runs can
# never interleave on one repository and produce a duplicate/partial snapshot.
#   kopia_lock -n          return non-zero when another run holds the lock
#   kopia_lock -w 3600     wait up to an hour
kopia_lock() {
  KOPIA_LOCKFILE="${DATA_DIR:-}/kopia/.snapshot.lock"
  case "$KOPIA_LOCKFILE" in /kopia/*) return 1 ;; esac
  mkdir -p "$(dirname "$KOPIA_LOCKFILE")" 2>/dev/null || return 1
  exec 9>"$KOPIA_LOCKFILE" || return 1
  flock "$@" 9
}

# Remote work is bounded on purpose. Nothing here may run unattended for hours:
# every provider-bound command gets a wall-clock budget and a short network
# timeout, so an unreachable storage host, an unplugged volume or a wedged SFTP session fails
# in seconds instead of hammering a disk for the rest of the night.
#   KOPIA_TIMEOUT       wall-clock seconds for a read/short kopia command (60)
#   KOPIA_LONG_TIMEOUT  wall-clock seconds for a mutating one (300)
#   KOPIA_SSH_TIMEOUT   wall-clock seconds for one remote shell command (20)
# A snapshot is the one operation allowed to outlive them (KOPIA_SNAPSHOT_TIMEOUT,
# default 0 = no cap): it uploads the whole source and is guarded by the lock.

# kopia_ssh <remote-command> — run one command on the backup host over the same
# key/known_hosts/port the SFTP transport uses (needs KOPIA_SFTP_*). Used for what
# the repository cannot answer about itself, like the size of its directory.
# Container paths are not host paths: /data is $DATA_DIR/kopia on this side.
kopia_hostpath() { printf '%s' "${1/#\/data\//$DATA_DIR/kopia/}"; }

kopia_ssh() {
  local host="${KOPIA_SFTP_HOST:-}" user="${KOPIA_SFTP_USER:-}" port="${KOPIA_SFTP_PORT:-22}"
  [ -n "$host" ] && [ -n "$user" ] || return 1
  local key known
  key="$(kopia_hostpath "${KOPIA_KEY:-}")"
  known="$(kopia_hostpath "${KOPIA_KNOWN:-}")"
  [ -r "$key" ] || return 1
  timeout "${KOPIA_SSH_TIMEOUT:-20}" \
    ssh -i "$key" -p "$port" \
      -o BatchMode=yes -o ConnectTimeout=5 \
      -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
      -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known" \
      "$user@$host" "$1" 2>/dev/null
}

# kopia_host — the container's configured hostname. kopia keys its maintenance
# owner and every snapshot source on user@hostname, and a recreated container
# would otherwise change it and silently orphan both.
kopia_host() {
  [ -n "${KOPIA_CTN:-}" ] || return 1
  docker inspect -f '{{.Config.Hostname}}' "$KOPIA_CTN" 2>/dev/null
}
