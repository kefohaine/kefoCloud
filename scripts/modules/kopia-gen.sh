#!/usr/bin/env bash
# scripts/modules/kopia-gen.sh — seed the kopia module's own state.
#
# Idempotent: anything that already exists is never rotated or regenerated.
# Writes:
#   KOPIA_PASSWORD                    repository password (opens the backup repository)
#   $DATA_DIR/kopia/ssh/id_ed25519    the key kopia presents to the disk's SFTP server
#   $DATA_DIR/kopia/ssh/known_hosts   host-key pinning for that connection
#   $DATA_DIR/kopia/config            kopia's client config directory
#
# The repository lives OFF this host, on the disk mounted by the target machine,
# so nothing here creates one: `make kopia-init` connects to it once the public
# key printed below is authorized there. The values are instance state —
# modules/kopia/.env is gitignored, and compose reads it through the instance
# block `make render` writes alongside them.
#
# Plan mode (writes nothing, refuses nothing it would otherwise refuse):
#   bash scripts/modules/kopia-gen.sh --dry-run        (or DRYRUN=1)
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/instance.sh"
. "$(dirname "$(readlink -f "$0")")/../lib/dryrun.sh"

ENV="$REPO_DIR/modules/kopia/.env"
KEY="$DATA_DIR/kopia/ssh/id_ed25519"

dryrun_wanted "$@" && DRY=1
if [ "${DRY:-0}" = 1 ]; then
  dryrun_plan "create $DATA_DIR/kopia/config and $DATA_DIR/kopia/ssh if they are missing"
  [ -e "$ENV" ] || dryrun_plan "create modules/kopia/.env (mode 0600)"
  grep -qE '^KOPIA_PASSWORD=.+' "$ENV" 2>/dev/null \
    || dryrun_plan "seed KOPIA_PASSWORD (random, printed once on a real run)"
  [ -f "$KEY" ] || dryrun_plan "generate an ed25519 key at $KEY and print its public half to authorize on the disk's machine"
  [ -f "$DATA_DIR/kopia/ssh/known_hosts" ] || dryrun_plan "create an empty known_hosts (make kopia-init pins the host key)"
  dryrun_end
fi

mkdir -p "$DATA_DIR/kopia/config" "$DATA_DIR/kopia/ssh"
chmod 700 "$DATA_DIR/kopia" "$DATA_DIR/kopia/ssh"
touch "$ENV"
chmod 600 "$ENV"

_seed() {  # _seed <KEY> <value>
  grep -qE "^$1=.+" "$ENV" && return 0
  printf '%s=%s\n' "$1" "$2" >>"$ENV"
  echo "kopia-gen: seeded $1" >&2
}

_seed KOPIA_PASSWORD "$(openssl rand -hex 32)"

# Server mode is gone: these two keys belonged to the web UI account and would
# only seed a dead login.
sed -i '/^KOPIA_SERVER_USERNAME=/d;/^KOPIA_SERVER_PASSWORD=/d' "$ENV"

if [ ! -f "$KEY" ]; then
  ssh-keygen -q -t ed25519 -N '' -C "kopia-$(hostname -s)" -f "$KEY" >/dev/null
  echo "kopia-gen: generated $KEY" >&2
fi
chmod 600 "$KEY"
[ -f "$DATA_DIR/kopia/ssh/known_hosts" ] || : > "$DATA_DIR/kopia/ssh/known_hosts"
chmod 600 "$DATA_DIR/kopia/ssh/known_hosts"

printf 'kopia-gen: modules/kopia/.env is ready\n'
printf 'kopia-gen: authorize this key on the machine that owns the backup disk:\n  %s\n' \
  "$(cat "$KEY.pub")"
