#!/usr/bin/env bash
# scripts/modules/docs-build.sh — build the /docs site with Zensical.
#
# Source: the repo's docs/ tree (the same files agents read) + the tracked
# config/docs/zensical.toml. Output: $DATA_DIR/pages/www/docs, served by
# www.<domain> at /docs/ (modules/caddy/vhosts/www.caddy). No container runs in
# production: Zensical is a build step, so the page costs zero RAM and cannot
# fail between requests.
#
# The build happens in a disposable copy under a temp dir — Zensical writes its
# cache next to the sources, and the repo must stay clean. The builder image is
# built once and reused.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
. "$ROOT/scripts/lib/instance.sh"
IMAGE=zensical:local
OUT="$DATA_DIR/pages/www/docs"

command -v docker >/dev/null 2>&1 || { echo "error: docker is required" >&2; exit 1; }
[ -f "$ROOT/config/docs/zensical.toml" ] || { echo "error: missing config/docs/zensical.toml" >&2; exit 1; }

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker build -q -t "$IMAGE" -f "$ROOT/config/docs/Dockerfile" "$ROOT/config/docs" >/dev/null || {
    echo "error: cannot build the $IMAGE builder image" >&2; exit 1; }
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/docs"
cp -a "$ROOT"/docs/. "$TMP/docs/"
cp "$ROOT/config/docs/zensical.toml" "$TMP/zensical.toml"
# The published site carries the live domain, not the skeleton token.
"$ROOT/scripts/render/render.sh" "$TMP/zensical.toml" "$TMP/zensical.toml.rendered" || exit 1
mv "$TMP/zensical.toml.rendered" "$TMP/zensical.toml"

docker run --rm -v "$TMP:/work" -w /work "$IMAGE" \
  zensical build --config-file zensical.toml --clean >/dev/null || {
  echo "error: zensical build failed" >&2; exit 1; }

[ -f "$TMP/site/index.html" ] || { echo "error: zensical produced no site/index.html" >&2; exit 1; }

mkdir -p "$OUT"
rsync -a --delete "$TMP/site/" "$OUT/"
echo "info:  built $OUT ($(find "$OUT" -type f | wc -l) file(s))"
