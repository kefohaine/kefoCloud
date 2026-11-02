#!/usr/bin/env bash
# scripts/modules/kopia-admin.sh — accounts, repository and snapshots for the
# Kopia module, through the kopia CLI inside its own container.
#
#   kopia-admin.sh status                 containers, repository, snapshots
#   kopia-admin.sh username [<user>]      rotate the web UI/API account name
#   kopia-admin.sh password [<pass>]      rotate the web UI/API password
#   kopia-admin.sh snapshot [<source>]    snapshot a source (default: /source)
#   kopia-admin.sh snapshots              list snapshots
#   kopia-admin.sh logs [<lines>]         tail the container
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/../lib/instance.sh"

ENV="$REPO_DIR/modules/kopia/.env"
[ -f "$ENV" ] || { echo "kopia-admin: $ENV is missing — run 'make kopia-gen'" >&2; exit 1; }
# shellcheck disable=SC1090
. "$ENV"

CONF=/data/config/repository.config
die() { printf 'kopia-admin: %s\n' "$*" >&2; exit 1; }
kopia() { docker exec -e KOPIA_PASSWORD="$KOPIA_PASSWORD" kopia kopia "$@"; }
# _recreate — both credentials are compose env values, so a new one only takes
# effect once the container is recreated from the .env it was just written to.
_recreate() {
  ( cd "$REPO_DIR" && docker compose -f modules/kopia/docker-compose.yml up -d ) >/dev/null \
    || die "recreate failed — the new value is in modules/kopia/.env"
}

case "${1:-status}" in
  status)
    docker ps -a --filter name='^kopia$' --format '  {{.Names}}\t{{.Status}}'
    kopia --config-file="$CONF" repository status || die "repository not reachable"
    kopia --config-file="$CONF" snapshot list --all 2>/dev/null | tail -20 || true
    ;;
  username)
    user=${2:-kopia-$(openssl rand -hex 4)}
    sed -i "s/^KOPIA_SERVER_USERNAME=.*/KOPIA_SERVER_USERNAME=$user/" "$ENV" \
      || die "cannot write modules/kopia/.env"
    _recreate
    printf 'kopia UI username: %s\n' "$user"
    ;;
  password)
    pass=${2:-$(openssl rand -hex 24)}
    # The password is a compose env value (KOPIA_SERVER_PASSWORD), so changing it
    # means updating modules/kopia/.env and recreating the container.
    sed -i "s/^KOPIA_SERVER_PASSWORD=.*/KOPIA_SERVER_PASSWORD=$pass/" "$ENV"
    _recreate
    printf 'kopia UI password: %s\n' "$pass"
    ;;
  snapshot)
    kopia --config-file="$CONF" snapshot create "${2:-/source}" || die "snapshot failed"
    ;;
  snapshots)
    kopia --config-file="$CONF" snapshot list --all
    ;;
  logs)
    docker logs kopia --tail "${2:-50}" -f
    ;;
  *)
    die "usage: kopia-admin.sh status|username|password|snapshot|snapshots|logs"
    ;;
esac
