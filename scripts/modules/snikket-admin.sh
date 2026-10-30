#!/usr/bin/env bash
#
# scripts/modules/snikket-admin.sh — Snikket (XMPP) accounts + instance utilities.
#
# Snikket is module `xmpp` (modules/snikket/, compose project `snikket`), so
# every container is also a module container (make dok-*/snk-* recipes and the
# shared helpers apply). This script is the one place that knows the project,
# the container names and the domain from the module's .env.
#
# Accounts are Prosody accounts, reached through `prosodyctl shell` inside the
# server container. Snikket deliberately has no "add user with a password"
# path: an account is created by redeeming an invite in the Snikket app, which
# generates the device keys client-side. That is why create = invite.
#
# Subcommands:
#   users                      list accounts
#   invite [user] <admin> [qr]
#                              account invite (no user = any username;
#                              admin=true|false is required)
#   invites                    pending invites (token, expiry, description)
#   revoke <token>             revoke a pending invite
#   reset <user>               password-reset invite for an existing account
#   passwd <user> [pass]       set the password (empty = generated, printed once)
#   disable|enable <user>      block/restore login without deleting the account
#   del-user <user> [force]    delete the account + its server data (typed yes)
#   status                     the four compose services, state and image
#   doctor                     containers, prosody, BOSH, TLS, TURN — exit 1 on failure
#   tls                        served certificates and expiry
#   turn                       turnserver process, address, relay range
#   logs <service> [lines]     tail one container (follows)
#   restart [service|all]      restart one compose service or all four
#   exec <cmd>                 run a shell command inside the server container
#   shell                      interactive bash in the server container
#
# Passwords never go through argv: `prosodyctl passwd` reads them from stdin.

set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
. "$ROOT/scripts/lib/instance.sh" 2>/dev/null || true

SBX="${SNIKKET_DIR:-$ROOT/modules/snikket}"
COMPOSE_FILE="$SBX/docker-compose.yml"
CONF="$SBX/.env"
PROJECT="${SNIKKET_PROJECT:-snikket}"

conf_val() { sed -n "s/^$1=//p" "$CONF" 2>/dev/null | head -1; }
SNIKKET_DOMAIN="${SNIKKET_DOMAIN:-$(conf_val SNIKKET_DOMAIN)}"
SNIKKET_DOMAIN="${SNIKKET_DOMAIN:-chat.${DOMAIN:-example.com}}"
HTTPS_PORT="$(conf_val SNIKKET_TWEAK_HTTPS_PORT)"; HTTPS_PORT="${HTTPS_PORT:-5443}"
TURN_MIN="$(conf_val SNIKKET_TWEAK_TURNSERVER_MIN_PORT)"; TURN_MIN="${TURN_MIN:-49152}"
TURN_MAX="$(conf_val SNIKKET_TWEAK_TURNSERVER_MAX_PORT)"; TURN_MAX="${TURN_MAX:-65535}"
TURN_ON="$(conf_val SNIKKET_TWEAK_TURNSERVER)"; TURN_ON="${TURN_ON:-1}"

die() { echo "error: $*" >&2; exit 1; }
info() { printf 'info:  %s\n' "$*"; }
warn() { printf 'warn:  %s\n' "$*"; }
fail() { printf 'fail:  %s\n' "$*"; }

[ -f "$COMPOSE_FILE" ] || die "no compose file at $COMPOSE_FILE (is the snikket module up? fix: make dok-recreate-snikket)"

compose() { docker compose -p "$PROJECT" -f "$COMPOSE_FILE" "$@"; }

# Container name for a compose service, from docker's own labels — never a
# hand-kept name list (the compose file may rename a container at any time).
ctn() {
  docker ps -a --filter "label=com.docker.compose.project=$PROJECT" \
    --filter "label=com.docker.compose.service=$1" --format '{{.Names}}' | head -1
}

running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }

server_ctn() {
  local c; c="$(ctn server)"
  [ -n "$c" ] && running "$c" || die "the snikket server container is not running (fix: make snikket-status / make snikket-restart)"
  printf '%s' "$c"
}

# Lua single-quoted string. Backslash and quote must survive both bash and Lua.
luaq() { local s=${1//\\/\\\\}; s=${s//\'/\\\'}; printf "'%s'" "$s"; }

jid() { case "$1" in *@*) printf '%s' "$1" ;; *) printf '%s@%s' "$1" "$SNIKKET_DOMAIN" ;; esac; }

require_user() {
  [ -n "${1:-}" ] || die "usage: $0 $2 requires USER=<jid>"
}

cmd_users() {
  local c; c="$(server_ctn)"
  docker exec "$c" prosodyctl shell "user:list($(luaq "$SNIKKET_DOMAIN"))"
}

cmd_invite() {
  local user="${1:-}" admin="${2:-}" qr="${3:-}"
  local c; local args=()
  case "${admin,,}" in
    true|false) : ;;
    *) die "usage: $0 invite requires ADMIN=true|false (got '${admin:-}')" ;;
  esac
  # create-invite only recognises --qr as its very first argument.
  case "${qr,,}" in 1|true|yes) args+=(--qr) ;; esac
  [ "${admin,,}" = true ] && args+=(--admin)
  c="$(server_ctn)"
  # create-invite appends the domain itself, so a bare local part is completed
  # here; with no user at all, any username may redeem the invite.
  [ -n "$user" ] && args+=("$(jid "$user")")
  docker exec "$c" create-invite "${args[@]}"
}

cmd_invites() {
  local c; c="$(server_ctn)"
  docker exec "$c" prosodyctl shell "invite:list($(luaq "$SNIKKET_DOMAIN"))"
}

cmd_revoke() {
  local token="${1:-}" c
  [ -n "$token" ] || die "usage: $0 revoke requires TOKEN=<token> (see: make snikket-invites)"
  c="$(server_ctn)"
  docker exec "$c" prosodyctl shell "invite:delete($(luaq "$SNIKKET_DOMAIN"),$(luaq "$token"))"
}

cmd_reset() {
  require_user "${1:-}" "reset"
  local c; c="$(server_ctn)"
  docker exec "$c" create-invite --reset "$(jid "$1")"
}

cmd_passwd() {
  require_user "${1:-}" "passwd"
  local user; user="$(jid "$1")"
  local pass="${2:-}" gen=0 c out rc
  if [ -z "$pass" ]; then
    pass=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
    gen=1
  fi
  c="$(server_ctn)"
  out=$(printf '%s\n%s\n' "$pass" "$pass" | docker exec -i "$c" prosodyctl passwd "$user" 2>&1); rc=$?
  if [ $rc -ne 0 ]; then
    printf '%s\n' "$out" >&2
    die "could not set the password for $user"
  fi
  if [ "$gen" = 1 ]; then
    info "password for $user changed — new password: $pass (printed once, stored nowhere)"
  else
    info "password for $user changed"
  fi
}

cmd_disable() {
  require_user "${1:-}" "disable"
  docker exec "$(server_ctn)" prosodyctl shell "user:disable($(luaq "$(jid "$1")"))"
}

cmd_enable() {
  require_user "${1:-}" "enable"
  docker exec "$(server_ctn)" prosodyctl shell "user:enable($(luaq "$(jid "$1")"))"
}

cmd_del_user() {
  require_user "${1:-}" "del-user"
  local user; user="$(jid "$1")"
  if [ "${2:-}" != 1 ]; then
    [ -t 0 ] || die "refusing to delete $user without a terminal prompt (re-run with FORCE=1 to skip it)"
    local answer
    read -r -p "type yes to permanently delete $user and its server data: " answer
    [ "$answer" = yes ] || die "aborted — $user was not deleted"
  fi
  docker exec "$(server_ctn)" prosodyctl shell "user:delete($(luaq "$user"))"
}

cmd_status() {
  compose ps --format 'table {{.Service}}\t{{.Name}}\t{{.Status}}\t{{.Image}}'
}

cert_rows() {
  local c; c="$(server_ctn)"
  docker exec "$c" sh -lc '
    for f in /snikket/letsencrypt/live/*/cert.pem; do
      [ -e "$f" ] || continue
      d=${f%/cert.pem}
      printf "%s|%s\n" "${d##*/}" "$(openssl x509 -in "$f" -noout -enddate | cut -d= -f2)"
    done' 2>/dev/null
}

cert_days() { date -d "$1" +%s 2>/dev/null || echo 0; }

cmd_tls() {
  local name exp days rc=0
  local found=0
  while IFS='|' read -r name exp; do
    [ -n "$name" ] || continue
    found=1
    days=$(( ($(cert_days "$exp") - $(date +%s)) / 86400 ))
    if [ "$days" -lt 0 ]; then
      fail "$name expired ($exp)"
      rc=1
    elif [ "$days" -le 14 ]; then
      warn "$name expires in $days days ($exp)"
    else
      printf 'ok:    %-28s %4s days  %s\n' "$name" "$days" "$exp"
    fi
  done < <(cert_rows)
  [ "$found" = 1 ] || die "no certificates under /snikket/letsencrypt/live (has the cert manager run?)"
  return "$rc"
}

cmd_turn() {
  local c; c="$(server_ctn)"
  if [ "$TURN_ON" = 0 ]; then
    info "TURN is disabled in snikket.conf (SNIKKET_TWEAK_TURNSERVER=0) — no relay is published"
    return 0
  fi
  if docker exec "$c" pgrep -x turnserver >/dev/null 2>&1; then
    printf 'ok:    turnserver running (pid %s)\n' "$(docker exec "$c" pgrep -x turnserver | paste -sd, -)"
  else
    fail "turnserver is not running (see: make snikket-logs SERVICE=server | grep -i turn)"
    return 1
  fi
  printf 'ok:    advertised address  %s\n' "$(docker exec "$c" snikket-turn-addresses "$SNIKKET_DOMAIN" 2>/dev/null)"
  printf 'ok:    ports               3478, 5349 (tcp+udp) · relay %s-%s/udp\n' "$TURN_MIN" "$TURN_MAX"
}

cmd_doctor() {
  local rc=0 s n
  for s in server proxy certs portal; do
    n="$(ctn "$s")"
    if [ -n "$n" ] && running "$n"; then
      printf 'ok:    %-14s %s\n' "$s" "$n"
    else
      fail "$s is not running"
      rc=1
    fi
  done
  if [ "$rc" = 0 ]; then
    local out
    if out=$(docker exec "$(ctn server)" prosodyctl status 2>&1); then
      printf 'ok:    %s\n' "$out"
    else
      fail "prosody: $out"
      rc=1
    fi
    local code
    code=$(curl -ks -o /dev/null -w '%{http_code}' --max-time 5 \
      -H "Host: $SNIKKET_DOMAIN" "https://127.0.0.1:$HTTPS_PORT/http-bind" 2>/dev/null)
    if [ "$code" = 200 ]; then
      printf 'ok:    BOSH                   http-bind answers 200 on :%s\n' "$HTTPS_PORT"
    else
      fail "BOSH /http-bind answered ${code:-no response} on :$HTTPS_PORT"
      rc=1
    fi
    cmd_tls || rc=1
    cmd_turn || rc=1
  fi
  if [ "$rc" = 0 ]; then
    info "snikket: all checks passed"
  else
    warn "snikket: failures above — see make snikket-logs SERVICE=<name>"
  fi
  return "$rc"
}

cmd_logs() {
  local svc="${1:-server}" n="${2:-50}" c
  c="$(ctn "$svc")"
  [ -n "$c" ] || die "no container for service '$svc' in project $PROJECT (server|proxy|certs|portal)"
  docker logs --tail "$n" -f "$c"
}

cmd_restart() {
  local svc="${1:-all}"
  if [ "$svc" = all ]; then
    compose restart
    info "restarted all four services — coturn re-reads its certificate on start"
  else
    [ -n "$(ctn "$svc")" ] || die "unknown service '$svc' (server|proxy|certs|portal|all)"
    compose restart "$svc"
    info "restarted $svc"
  fi
}

cmd_exec() {
  [ -n "${1:-}" ] || die "usage: $0 exec requires CMD='<shell command>'"
  docker exec "$(server_ctn)" sh -lc "$1"
}

cmd_shell() {
  exec docker exec -it "$(server_ctn)" bash
}

MODE="${1:-}"; shift 2>/dev/null || true
case "$MODE" in
  users)    cmd_users ;;
  invite)   cmd_invite "$@" ;;
  invites)  cmd_invites ;;
  revoke)   cmd_revoke "$@" ;;
  reset)    cmd_reset "$@" ;;
  passwd)   cmd_passwd "$@" ;;
  disable)  cmd_disable "$@" ;;
  enable)   cmd_enable "$@" ;;
  del-user) cmd_del_user "$@" ;;
  status)   cmd_status ;;
  doctor)   cmd_doctor ;;
  tls)      cmd_tls ;;
  turn)     cmd_turn ;;
  logs)     cmd_logs "$@" ;;
  restart)  cmd_restart "$@" ;;
  exec)     cmd_exec "$@" ;;
  shell)    cmd_shell ;;
  *)
    sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
