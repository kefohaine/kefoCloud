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
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/instance.sh"

ENV="$REPO_DIR/modules/kopia/.env"
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
