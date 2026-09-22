#!/bin/bash
#
# stack-up.sh — the single, idempotent entry point that brings every DEPLOYED
# compose unit up. Callers:
#
#   stack-up.sh              (boot)    $NODE_NAME-stack.service
#   stack-up.sh --update     (manual)  make update
#   stack-up.sh --check      (timer)   repair pass — start only what is missing
#   stack-up.sh --validate   (gate)    validate the edge config, change nothing
#
# WHY THIS EXISTS: `make update` used to run `apt-get upgrade -y` and then a
# force-recreate loop under make's `-eu`. Any single failure aborted the loop,
# and because the Caddy edge sorted FIRST in the glob, a failed edge rebuild
# stopped every other unit from being recreated and could leave :80/:443 down —
# the one failure that locks the operator out of every hostname at once.
# This script inverts that:   failures are COLLECTED (a broken unit can never
# abort the run), the edge goes LAST, and the edge swap is gated by a config
# validation, an image rollback tag and a health probe.
#
# Rules honoured:
#   - the unit list is derived from the live system (docker ps -a + compose
#     metadata), never a hardcoded roster (AGENTS rule 12)
#   - only DEPLOYED units are touched, so an uninstalled module is never
#     started and never gets empty data dirs created under it
#   - --check/--boot never recreate a healthy container (up -d is a no-op)
#

. "$(dirname "$(readlink -f "$0")")/instance.sh" 2>/dev/null || true
set -uo pipefail

REPO=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
DATA="$REPO/data"
LOG="$REPO/scripts/mklog"

MODE=boot
for a in "$@"; do
  case "$a" in
    --update)   MODE=update ;;
    --check)    MODE=check ;;
    --validate) MODE=validate ;;
    *) echo "usage: $0 [--update|--check|--validate]"; exit 2 ;;
  esac
done

info() { [ -x "$LOG" ] && "$LOG" info "$*" || echo "info: $*"; }
warn() { [ -x "$LOG" ] && "$LOG" warn "$*" || echo "warn: $*"; }
err()  { [ -x "$LOG" ] && "$LOG" error "$*" || echo "error: $*"; }

mkdir -p "$DATA"
exec 9>"$DATA/.stack-up.lock"
flock -n 9 || { info "another stack-up run is in progress — nothing to do"; exit 0; }

compose()   { ( cd "$REPO" && docker compose -f "$1" "${@:2}" ); }
unit_names(){ compose "$1" config --format json 2>/dev/null | jq -r '.services[] | (.container_name // .name)' 2>/dev/null; }
deployed()  { local n; for n in $(unit_names "$1"); do docker ps -a --format '{{.Names}}' | grep -qx "$n" && return 0; done; return 1; }
running()   { local n; for n in $(unit_names "$1"); do docker ps    --format '{{.Names}}' | grep -qx "$n" && return 0; done; return 1; }
is_build()  { grep -qE '^[[:space:]]*build:' "$1"; }

# The locally-built unit IS the edge (only the Caddy image is built here).
edge_dir() {
  local d
  for d in "$REPO"/services/*/; do
    [ -f "$d/docker-compose.yml" ] || continue
    is_build "$d/docker-compose.yml" && { basename "$d"; return 0; }
  done
  return 1
}
EDGE=$(edge_dir || true)
EDGE_FILE="$REPO/services/${EDGE:-none}/docker-compose.yml"

smoke_host() {   # a public vhost to probe (www.* preferred) — derived, never hardcoded
  local d="$DATA/rendered/caddy/vhosts" h
  h=$(ls "$d" 2>/dev/null | sed -n 's/^\(www\..*\)\.caddy$/\1/p' | head -1)
  [ -n "$h" ] || h=$(ls "$d" 2>/dev/null | sed -n 's/^\(.*\)\.caddy$/\1/p' | head -1)
  echo "${h:-localhost}"
}
# The probe host: vhost files are named after the SERVICE (cloud.caddy), not the
# domain, so the hostname is built from the instance's DOMAIN. Fall back to the
# first vhost filename if there is somehow no DOMAIN.
SHOST="${SHOST:-www.${DOMAIN:-}}"
[ -n "${DOMAIN:-}" ] || SHOST=$(smoke_host)
EDGE_CTN=$(unit_names "$EDGE_FILE" 2>/dev/null | head -1)

edge_healthy() {
  [ -n "$EDGE_CTN" ] && docker inspect -f '{{.State.Running}}' "$EDGE_CTN" 2>/dev/null | grep -qx true || return 1
  curl -sk -o /dev/null -m 8 -w '%{http_code}' --resolve "$SHOST:443:127.0.0.1" "https://$SHOST/" 2>/dev/null \
    | grep -qE '^(200|30[0-9])$'
}

# Caddyfile parses with the REAL mounts, without needing the CF token:
# `caddy adapt` only parses/adapts (it does not provision the DNS plugin), so
# it catches syntax errors and "module not registered" — the two ways an edge
# config actually kills the door. `compose config -q` covers the compose side.
edge_config_ok() {
  [ -n "$EDGE" ] || return 0
  compose "$EDGE_FILE" config -q 2>/dev/null || return 1
  docker run --rm --entrypoint caddy -v "$DATA/rendered/caddy:/etc/caddy:ro" \
    "$(docker inspect -f '{{.Config.Image}}' "$EDGE_CTN" 2>/dev/null || echo caddy:2)" \
    adapt --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1
}

edge_input_hash() {
  find "$DATA/rendered/caddy" -type f ! -name '*.log' -print0 2>/dev/null \
    | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1
}

bring_up() {   # bring_up <file>
  local f=$1
  case "$MODE" in
    check)
      running "$f" && { info "up: ${f#$REPO/}"; return 0; }
      info "repair: starting ${f#$REPO/}"
      compose "$f" up -d ;;
    update)
      is_build "$f" || compose "$f" pull || warn "pull failed: $f"
      compose "$f" up -d --force-recreate ;;
    *) compose "$f" up -d ;;
  esac
}

# ── validate-only: the gate used before any edge swap ──────────────────────
if [ "$MODE" = validate ]; then
  edge_config_ok && { info "edge config valid"; exit 0; }
  err "edge config invalid — see: docker compose -f $EDGE_FILE config"; exit 1
fi

declare -a FAILURE=()

# ── every deployed unit EXCEPT the edge ────────────────────────────────────
for d in "$REPO"/services/*/; do
  [ -d "$d" ] || continue
  [ "$(basename "$d")" = "$EDGE" ] && continue
  for f in "$d"docker-compose*.yml; do
    [ -f "$f" ] || continue
    deployed "$f" || { info "skip (not deployed): ${f#$REPO/}"; continue; }
    bring_up "$f" || { err "unit failed: ${f#$REPO/}"; FAILURE+=("${f#$REPO/}"); }
  done
done

# ── the edge, LAST, behind the gate ────────────────────────────────────────
if [ -n "$EDGE" ]; then
  info "edge: $EDGE (last, gated)"
  edge_config_ok || { err "edge config invalid — running edge left untouched"; FAILURE+=("$EDGE (config)"); }
  if [ "${#FAILURE[@]}" -eq 0 ]; then
    case "$MODE" in
      check)
        if running "$EDGE_FILE"; then info "up: $EDGE_FILE"; else
          info "repair: starting the edge"; compose "$EDGE_FILE" up -d || FAILURE+=("$EDGE")
        fi ;;
      boot)
        compose "$EDGE_FILE" up -d || FAILURE+=("$EDGE") ;;
      update)
        IMG=$(docker inspect -f '{{.Config.Image}}' "$EDGE_CTN" 2>/dev/null || true)
        HASHFILE="$DATA/.build-hash-$EDGE"
        HASH=$(edge_input_hash)
        if [ -n "$IMG" ] && docker image inspect "$IMG" >/dev/null 2>&1; then
          docker tag "$IMG" "${IMG%:*}:rollback" && info "previous edge image tagged ${IMG%:*}:rollback"
        fi
        if [ -n "$HASH" ] && [ "$(cat "$HASHFILE" 2>/dev/null)" = "$HASH" ]; then
          info "edge inputs unchanged — recreating without a rebuild"
          compose "$EDGE_FILE" up -d --force-recreate || FAILURE+=("$EDGE")
        else
          info "edge inputs changed — rebuilding (this is the slow step)"
          if compose "$EDGE_FILE" up -d --force-recreate --build; then
            printf '%s\n' "$HASH" > "$HASHFILE"
          else
            warn "edge recreate failed — rolling back to ${IMG%:*}:rollback"
            if [ -n "$IMG" ] && docker image inspect "${IMG%:*}:rollback" >/dev/null 2>&1; then
              docker tag "${IMG%:*}:rollback" "$IMG"
              compose "$EDGE_FILE" up -d --force-recreate \
                && warn "edge rolled back to the previous image — the door is up, the update was NOT applied" \
                || err "edge rollback ALSO failed — restore from $DATA (see docs/GUIDE.md)"
            fi
            FAILURE+=("$EDGE (rolled back)")
          fi
        fi ;;
    esac
    if [ "${#FAILURE[@]}" -eq 0 ] && [ "$MODE" != check ]; then
      s=; i=0
      while [ $i -lt 30 ]; do
        s=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$EDGE_CTN" 2>/dev/null)
        { [ "$s" = healthy ] || [ "$s" = running ]; } && break
        sleep 2; i=$((i+1))
      done
      info "edge state: ${s:-unknown}"
      edge_healthy || { warn "edge is not answering on :443"; FAILURE+=("$EDGE (unhealthy)"); }
    fi
  fi
fi

# ── summary ────────────────────────────────────────────────────────────────
if [ "${#FAILURE[@]}" -eq 0 ]; then
  case "$MODE" in
    update) info "update complete — every deployed unit recreated, edge verified" ;;
    check)  info "repair pass complete" ;;
    *)      info "stack is up" ;;
  esac
  exit 0
fi
err "completed with ${#FAILURE[@]} failure(s): ${FAILURE[*]}"
exit 1
