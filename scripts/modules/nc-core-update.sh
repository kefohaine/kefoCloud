#!/usr/bin/env bash
# Update Nextcloud core by bumping the compose image tag, pulling, recreating
# and waiting for the entrypoint's `occ upgrade` — the path that keeps the tag
# in step with the installed code. The web updater is enabled too
# (data/cloud/html/updater, a host bind mount, so its result survives
# recreates); after an updater-run update the tag lags and this script's
# downgrade check is what stops you from silently going back.
#
#   make nc-core-update               # latest patch of the running major
#   make nc-core-update VERSION=34.0.5  # pin an explicit version
#
# Prints progress only; never touches the DB or config.php.

set -euo pipefail

HERE="$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
. "$HERE/../lib/instance.sh" 2>/dev/null || true
REPO_DIR="${REPO_DIR:-$(cd "$HERE/../.." && pwd)}"
COMPOSE_FILE="$REPO_DIR/modules/nextcloud/docker-compose.yml"
SERVICE=cloud
CTN=nextcloud

die() { printf 'nc-core-update: %s\n' "$*" >&2; exit 1; }
log() { printf '[nc-update] %s\n' "$*"; }

[ -f "$COMPOSE_FILE" ] || die "missing $COMPOSE_FILE"

cur=$(grep -m1 -oE 'image: nextcloud:[0-9]+\.[0-9]+\.[0-9]+-fpm' "$COMPOSE_FILE" \
        | sed -E 's/.*nextcloud:([0-9.]+)-fpm/\1/')
[ -n "$cur" ] || die "cannot read the nextcloud image tag from $COMPOSE_FILE"
major=${cur%%.*}

want="${VERSION:-}"
want=${want#nextcloud:}
want=${want%-fpm}
if [ -z "$want" ]; then
  # Docker Hub tag list for this major: names are 34.0.5-fpm, 34.0.5-apache, …
  want=$(curl -fsS "https://hub.docker.com/v2/repositories/library/nextcloud/tags?page_size=100&name=${major}." \
           | grep -oE '"name":"[^"]+-fpm"' \
           | sed -E 's/"name":"//; s/"$//; s/-fpm$//' \
           | grep -E "^${major}\.[0-9]+\.[0-9]+$" \
           | sort -V | tail -1) || true
  [ -n "$want" ] || die "could not resolve the latest ${major}.x image tag (network or Docker Hub rate limit) — pass VERSION=${cur}"
fi

case "$want" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) die "bad VERSION '$want' (expected x.y.z)" ;;
esac

if [ "$want" = "$cur" ]; then
  log "already on $cur — nothing to do"
  exit 0
fi
if [ "$(printf '%s\n%s\n' "$cur" "$want" | sort -V | tail -1)" != "$want" ]; then
  die "refusing to downgrade $cur -> $want (restore the DB backup first if that is intended)"
fi

log "bumping nextcloud:$cur-fpm -> nextcloud:$want-fpm in modules/nextcloud/docker-compose.yml"
sed -i "s|image: nextcloud:${cur}-fpm|image: nextcloud:${want}-fpm|" "$COMPOSE_FILE"

# Maintenance mode keeps clients out of the DB swap. The entrypoint does not
# clear it, so it is dropped again below on every path. `up` runs the image's
# entrypoint, which detects the version change and runs `occ upgrade` itself.
docker exec -u www-data "$CTN" php occ maintenance:mode --on >/dev/null 2>&1 || true

log "pulling nextcloud:$want-fpm"
docker compose -f "$COMPOSE_FILE" pull "$SERVICE"
log "recreating $CTN"
docker compose -f "$COMPOSE_FILE" up -d --force-recreate "$SERVICE"

# Wait for the entrypoint: it copies the image, then upgrades the DB. A cold
# pull + upgrade of a large instance takes minutes, so poll for the version
# the container reports, not for a fixed sleep.
log "waiting for the upgrade to finish (this blocks until occ reports $want)"
ok=0
for _ in $(seq 1 180); do
  v=$(docker exec -u www-data "$CTN" php occ config:system:get version 2>/dev/null | tr -d '\r\n' || true)
  case "$v" in
    "$want"*) ok=1; break ;;
  esac
  sleep 5
done

docker exec -u www-data "$CTN" php occ maintenance:mode --off >/dev/null 2>&1 || true

if [ "$ok" -ne 1 ]; then
  log "upgrade did not report $want after 15 minutes — last container log lines:"
  docker logs "$CTN" --tail 40 2>&1 || true
  die "failed; the DB may be mid-upgrade — run 'make nc-status' / 'make nc-occ CMD=\"upgrade\"' before rolling the tag back"
fi

docker exec -u www-data "$CTN" php occ maintenance:repair --include-expensive >/dev/null 2>&1 || true
log "done — core is on $want (image pinned in modules/nextcloud/docker-compose.yml)"
log "app updates: make nc-app-update"
