#!/usr/bin/env bash
# scripts/modules/kopia-gen.sh — seed the kopia module's own secrets.
#
# Idempotent: a key that already exists in modules/kopia/.env is never rotated.
# Writes:
#   KOPIA_PASSWORD         repository password (opens the backup repository)
#   KOPIA_SERVER_USERNAME  the web UI / API account
#   KOPIA_SERVER_PASSWORD  its password (printed once by the installer summary)
#
# The values are instance state: modules/kopia/.env is gitignored, and compose
# reads it through the instance block `make render` writes alongside them.
#
# Plan mode (writes nothing, refuses nothing it would otherwise refuse):
#   bash scripts/modules/kopia-gen.sh --dry-run        (or DRYRUN=1)
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/instance.sh"
. "$(dirname "$(readlink -f "$0")")/../lib/dryrun.sh"

ENV="$REPO_DIR/modules/kopia/.env"

dryrun_wanted "$@" && DRY=1
if [ "${DRY:-0}" = 1 ]; then
  dryrun_plan "create $DATA_DIR/kopia/repository and $DATA_DIR/kopia/config if they are missing"
  [ -e "$ENV" ] || dryrun_plan "create modules/kopia/.env (mode 0600)"
  grep -qE '^KOPIA_PASSWORD=.+' "$ENV" 2>/dev/null \
    || dryrun_plan "seed KOPIA_PASSWORD (random, printed once on a real run)"
  grep -qE '^KOPIA_SERVER_USERNAME=.+' "$ENV" 2>/dev/null \
    || dryrun_plan "seed KOPIA_SERVER_USERNAME=kopia"
  grep -qE '^KOPIA_SERVER_PASSWORD=.+' "$ENV" 2>/dev/null \
    || dryrun_plan "seed KOPIA_SERVER_PASSWORD (random, printed once on a real run)"
  dryrun_end
fi

mkdir -p "$DATA_DIR/kopia/repository" "$DATA_DIR/kopia/config"
touch "$ENV"
chmod 600 "$ENV"

_seed() {  # _seed <KEY> <value>
  grep -qE "^$1=.+" "$ENV" && return 0
  printf '%s=%s\n' "$1" "$2" >>"$ENV"
  echo "kopia-gen: seeded $1" >&2
}

_seed KOPIA_PASSWORD        "$(openssl rand -hex 32)"
_seed KOPIA_SERVER_USERNAME "kopia"
_seed KOPIA_SERVER_PASSWORD "$(openssl rand -hex 32)"

echo "kopia-gen: modules/kopia/.env is ready"
