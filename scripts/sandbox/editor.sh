#!/usr/bin/env bash
# scripts/sandbox/editor.sh — one helper for sandbox modules.
#
# The repo holds THIS file only. The implementation lives in data/sandbox/
# (gitignored, unpushable) and is written there on first run, then sourced the
# way wizard.sh sources wizard.d/ — same design: lib/, tasks/, flow/.
#
# What a sandbox module is: a compose project (sbx-<name>) that joins the live
# 'net' network, gets a pinned free address, and is exposed through the running
# edge with one of three exposures. Nothing in modules/, config/ or scripts/ is
# ever written, so the repo and the live stack cannot be broken by trying a
# module out. Promote it later by hand, as a deliberate act.
#
# Every fact is fetched live — core modules from REPO/modules, installed modules
# from data/wizard.state, host labels from the vhosts trees, addresses from the
# 'net' network, values from data/instance.conf. There is no module list here.
#
#   bash scripts/sandbox/editor.sh create     ask, validate, bring up, expose
#   bash scripts/sandbox/editor.sh remove     down, forget, remove the door
#   bash scripts/sandbox/editor.sh list       what is declared + what is running
#   bash scripts/sandbox/editor.sh validate   re-check every compose contract
#   bash scripts/sandbox/editor.sh sync       re-apply vhosts (make sandbox-sync)
#   bash scripts/sandbox/editor.sh backup     tar one module's data dir
#   bash scripts/sandbox/editor.sh bootstrap  write/refresh the tree (--force)
set -uo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
REPO="$(cd "$(dirname "$SELF")/../.." && pwd)"
. "$REPO/scripts/lib/instance.sh" 2>/dev/null || true
: "${DATA_DIR:=$REPO/data}"
SBX="$DATA_DIR/sandbox"
export REPO DATA_DIR SBX
VERSION=1

die_early() { printf 'editor: %s\n' "$*" >&2; exit 1; }

CMD="${1:-}"
[ $# -gt 0 ] && shift
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force|-f) FORCE=1 ;;
    *) die_early "unknown option: $1 (see --help)" ;;
  esac
  shift
done
: "${FORCE:=0}"

_usage() {
  cat <<'EOF'
editor.sh — sandbox modules for this stack, everything under data/sandbox/

  create     ask the questions, validate, bring one app up, expose it
  remove     take one down, delete its vhost (+ its A record if we made it)
  list       declared sandbox modules and what docker is actually running
  validate   re-check every module's compose contract
  sync       re-apply sandbox vhosts into data/rendered/caddy/ and revive
             stopped projects — run it after `make render`
  backup     tar one module's data/ into data/sandbox/backups/
  bootstrap  write/refresh the data/sandbox/ tree (--force to overwrite)

Nothing in the repo is written. Core modules are read from modules/, installed
modules from data/wizard.state, host labels from the vhosts trees, addresses
from the 'net' network — no list is hardcoded here.

Exposure, asked for every module:
  1 tailnet-only   ACME DNS-01 cert, 403 for anything outside 100.64.0.0/10,
                   no DNS record; the helper prints the /etc/hosts line
  2 dns-only       public A record, grey cloud — reachable anywhere
  3 cloudflare     public A record behind the proxy, orange cloud
EOF
}

# ── the tree: written once, then owned by the operator ──────────────────────
# _put <relpath> <mode>; body on stdin. An existing file is never touched
# unless --force, so local edits survive every run.
_put() {
  local rel="$1" mode="${2:-0644}" dst="$SBX/$1"
  mkdir -p "$(dirname "$dst")"
  if [ -e "$dst" ] && [ "$FORCE" != 1 ]; then cat >/dev/null; return 0; fi
  cat >"$dst" || return 1
  chmod "$mode" "$dst"
}

_bootstrap() {
  mkdir -p "$SBX"/{lib,tasks,flow,templates,modules,state,caddy,backups}
  chmod 700 "$SBX" 2>/dev/null || true

  _put lib/env.sh <<'SBXEOF'
# lib/env.sh — paths, live values, output. Sourced by editor.sh.
: "${REPO:=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)}"
. "$REPO/scripts/lib/instance.sh" 2>/dev/null || true
: "${REPO:=${REPO_DIR:-$REPO}}"
: "${DATA_DIR:=$REPO/data}"
: "${SBX:=$DATA_DIR/sandbox}"
WS="$DATA_DIR/wizard.state"
SBX_MOD="$SBX/modules"
SBX_STATE="$SBX/state"
SBX_CADDY="$SBX/caddy"
SBX_TPL="$SBX/templates"
SBX_BAK="$SBX/backups"
RENDER_VHOSTS="$DATA_DIR/rendered/caddy/vhosts"
export REPO DATA_DIR SBX WS SBX_MOD SBX_STATE SBX_CADDY SBX_TPL SBX_BAK RENDER_VHOSTS

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m' D=$'\033[2m' C=$'\033[36m' G=$'\033[32m' Y=$'\033[33m' R=$'\033[31m' N=$'\033[0m'
else
  B='' D='' C='' G='' Y='' R='' N=''
fi

say()  { printf '  %s\n' "$*"; }
sec()  { printf '\n%s%s%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '  %s×%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }

# Read one key out of data/wizard.state without ever writing it: the installer
# stays its only writer.
ws_get() {
  [ -f "$WS" ] || return 1
  ( . "$WS" >/dev/null 2>&1; printf '%s' "${!1:-}" )
}
ws_enabled() { ws_get enabled_modules; }
sbx_domain() { printf '%s' "${DOMAIN:-$(ws_get DOMAIN)}"; }
cf_token() { ws_get CF_API_TOKEN; }

# tmpl_render <template> <out> KEY=VAL... — {{KEY}} substitution in pure bash so
# a value may contain newlines or slashes. Unresolved tokens are an error.
tmpl_render() {
  local tpl="$1" out="$2" body kv left
  shift 2
  [ -f "$tpl" ] || die "missing template: $tpl"
  body="$(cat "$tpl")"
  for kv in "$@"; do
    body="${body//\{\{${kv%%=*}\}\}/${kv#*=}}"
  done
  printf '%s\n' "$body" >"$out" || die "cannot write $out"
  left="$(grep -oE '\{\{[A-Z_]+\}\}' "$out" | sort -u | tr '\n' ' ')"
  [ -z "$left" ] || die "unresolved template tokens in $out: $left"
}
SBXEOF

  _put lib/ui.sh <<'SBXEOF'
# lib/ui.sh — the step list. Same shape as the installer's checklist, without
# the animator: one line per task, a tick when it returns 0.
TASK_NAMES=()
TASKS=()

run_tasks() {
  local i=0 t
  sec "${TASK_TITLE:-sandbox}"
  for t in "${TASKS[@]}"; do
    printf '  %s▸%s %-24s ' "$C" "$N" "${TASK_NAMES[$i]}"
    "$t" || { printf '%s×%s\n' "$R" "$N"; return 1; }
    printf '%s✓%s\n' "$G" "$N"
    i=$((i + 1))
  done
  return 0
}
SBXEOF

  _put lib/derive.sh <<'SBXEOF'
# lib/derive.sh — every list this tool needs is read from the live system.
# Nothing here names a module, a label, an address or a port.

# Core modules: the repo's own module dirs that carry a compose file.
core_modules() {
  local d
  for d in "$REPO"/modules/*/; do
    [ -f "$d/docker-compose.yml" ] && basename "$d"
  done
}

# The edge is whichever core module builds its image locally (the only one).
core_edge() {
  local m
  for m in $(core_modules); do
    if grep -qE '^[[:space:]]*build:' "$REPO/modules/$m/docker-compose.yml" 2>/dev/null; then
      printf '%s' "$m"
      return 0
    fi
  done
}

# The edge container's name comes from its own compose file.
edge_container() {
  local e
  e="$(core_edge)"
  [ -n "$e" ] || return 1
  grep -hoE '^[[:space:]]*container_name:[[:space:]]*[A-Za-z0-9_.-]+' "$REPO/modules/$e/docker-compose.yml" 2>/dev/null |
    awk '{print $2; exit}'
}

installed_modules() { ws_enabled; }

# Host labels already claimed, from both vhost trees (tracked + rendered).
labels_in_use() {
  local f
  for f in "$REPO"/modules/*/vhosts/*.caddy "$RENDER_VHOSTS"/*.caddy; do
    [ -f "$f" ] && grep -hoE '^[[:space:]]*https?://[^ {]+' "$f" 2>/dev/null
  done | sed -E 's#^[[:space:]]*https?://##' |
    sed -E 's/\.?\{\{DOMAIN\}\}.*$//; s/\.\$\{?DOMAIN\}?.*$//; s/\..*$//' |
    grep -v '^$' | grep -v 'DOMAIN' | grep -vx "$(sbx_domain | cut -d. -f1)" | sort -u
}

label_taken() { labels_in_use | grep -qx -- "$1"; }

net_subnet() { docker network inspect net --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null; }
subnet_base() { net_subnet | cut -d/ -f1 | awk -F. 'NF==4{printf "%s.%s.%s", $1, $2, $3}'; }

# Addresses in use = live attachments + addresses declared in the repo modules +
# the pins recorded for sandbox modules (a stopped sandbox container keeps its
# pin). Module dirs without a state record are NOT counted: that is exactly what
# a removed module leaves behind when its data dir is kept.
ips_in_use() {
  local f
  {
    docker network inspect net --format '{{range .Containers}}{{.IPv4Address}} {{end}}' 2>/dev/null | tr ' ' '\n' | cut -d/ -f1
    grep -rhoE 'ipv4_address:[[:space:]]*[0-9.]+' "$REPO"/modules 2>/dev/null | awk '{print $2}'
    for f in "$SBX_STATE"/*.conf; do [ -f "$f" ] && ( . "$f" >/dev/null 2>&1; printf '%s\n' "${IP:-}" ); done
  } | awk -F. 'NF==4{print $4}' | sort -u
}

free_ip() {
  local base used i
  base="$(subnet_base)"
  [ -n "$base" ] || die "docker network 'net' has no IPv4 subnet — is the stack up?"
  used=" $(ips_in_use | tr '\n' ' ') "
  for i in $(seq 2 254); do
    case "$used" in *" $i "*) continue ;; esac
    printf '%s.%s\n' "$base" "$i"
    return 0
  done
  die "no free address left on network 'net'"
}

mem_available_mb() { awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo; }
mem_free_mb() { printf '%d' $(( $(mem_available_mb) - 256 )); }
SBXEOF
  _put lib/prompt.sh <<'SBXEOF'
# lib/prompt.sh — front-loaded questions (AGENTS 24): everything is asked
# before anything is written, and the answers land in state/<name>.conf.

ask_var() {
  local __v="$1" __p="$2" __d="${3:-}" __a
  printf '  %s%s%s%s ' "$B" "$__p" "$N" "${__d:+ [$__d]}"
  IFS= read -r __a || true
  [ -z "$__a" ] && __a="$__d"
  printf -v "$__v" '%s' "$__a"
}

ask_yes() {
  local __v="$1" __p="$2" __d="${3:-no}" __a
  while :; do
    ask_var __a "$__p (yes/no)" "$__d"
    case "${__a,,}" in
      y | yes) printf -v "$__v" 'yes'; return 0 ;;
      n | no) printf -v "$__v" 'no'; return 0 ;;
      *) warn "type yes or no" ;;
    esac
  done
}

ask_port() {
  local __v="$1" __p="$2" __d="${3:-}" __a
  while :; do
    ask_var __a "$__p" "$__d"
    case "$__a" in
      '' | *[!0-9]*) warn "a number, 1-65535"; continue ;;
    esac
    if [ "$__a" -ge 1 ] && [ "$__a" -le 65535 ]; then
      printf -v "$__v" '%s' "$__a"
      return 0
    fi
    warn "a number, 1-65535"
  done
}

# The exposure question is asked for EVERY module, never defaulted silently.
ask_exposure() {
  local __v="$1" __a
  sec "Exposure"
  say "1) tailnet-only        ACME DNS-01 cert, everything outside 100.64.0.0/10 gets 403, no DNS record"
  say "2) dns-only            public A record (grey cloud) — reachable from anywhere"
  say "3) cloudflare-proxied  public A record behind Cloudflare (orange cloud)"
  while :; do
    ask_var __a "exposure [1-3]" "1"
    case "$__a" in
      1 | tailnet | tailnet-only) printf -v "$__v" 'tailnet'; return 0 ;;
      2 | dns | dns-only) printf -v "$__v" 'dns'; return 0 ;;
      3 | cf | proxied | cloudflare | cloudflare-proxied) printf -v "$__v" 'proxied'; return 0 ;;
      *) warn "1, 2 or 3" ;;
    esac
  done
}
SBXEOF

  _put lib/state.sh <<'SBXEOF'
# lib/state.sh — one record per sandbox module: state/<name>.conf, %q-quoted.
# This tool is its only writer; data/wizard.state is only ever read.
state_file() { printf '%s/%s.conf' "$SBX_STATE" "$1"; }
state_names() {
  local f
  for f in "$SBX_STATE"/*.conf; do
    [ -f "$f" ] || continue
    basename "$f" .conf
  done
}
state_get() {
  local f
  f="$(state_file "$1")"
  [ -f "$f" ] || return 1
  ( . "$f" >/dev/null 2>&1; printf '%s' "${!2:-}" )
}
# state_put <name> KEY=VALUE... — merge, never drop an existing key.
state_put() {
  local n="$1" f tmp kv keys=""
  shift
  f="$(state_file "$n")"
  tmp="$f.tmp.$$"
  for kv in "$@"; do keys="$keys|${kv%%=*}"; done
  keys="${keys#|}"
  if [ -f "$f" ]; then
    grep -vE "^($keys)=" "$f" >"$tmp" 2>/dev/null || : >"$tmp"
  else
    : >"$tmp"
  fi
  for kv in "$@"; do printf '%s=%q\n' "${kv%%=*}" "${kv#*=}" >>"$tmp"; done
  chmod 600 "$tmp"
  mv "$tmp" "$f"
}
SBXEOF

  _put lib/validate.sh <<'SBXEOF'
# lib/validate.sh — the compose contract, checked on docker's NORMALISED config
# (never a YAML grep): no published ports, pinned address on 'net', no
# privileged/host escape hatches, restart: unless-stopped, capped memory, and
# every bind mount inside the module's own dir.

compose_json() { docker compose -f "$1" -p "$2" config --format json 2>/dev/null; }

validate_compose() {
  local f="$1" p="$2" j bad
  [ -f "$f" ] || die "missing compose file: $f"
  j="$(compose_json "$f" "$p")" || die "compose file does not parse: $f"
  [ -n "$j" ] || die "compose config produced no output: $f"

  bad="$(printf '%s' "$j" | jq '[.services[] | (.ports // [])[]] | length')"
  [ "$bad" = 0 ] || die "$f: publishes ports — sandbox services are reached through the edge on 'net'"

  bad="$(printf '%s' "$j" | jq -r '[.services | to_entries[] | select((.value.networks // {})["net"].ipv4_address == null) | .key] | join(" ")')"
  [ -z "$bad" ] || die "$f: service(s) without a pinned 'net' ipv4_address: $bad"

  bad="$(printf '%s' "$j" | jq -r '[.services | to_entries[] | select((.value.restart // "") != "unless-stopped") | .key] | join(" ")')"
  [ -z "$bad" ] || die "$f: restart must be unless-stopped: $bad"

  bad="$(printf '%s' "$j" | jq -r '[.services | to_entries[] | select((.value.privileged // false) or ((.value.network_mode // "") != "") or ((.value.pid // "") != "") or (((.value.devices // []) | length) > 0) or (((.value.cap_add // []) | length) > 0)) | .key] | join(" ")')"
  [ -z "$bad" ] || die "$f: privileged / network_mode / pid / devices / cap_add are forbidden: $bad"

  bad="$(printf '%s' "$j" | jq -r '[.services | to_entries[] | select((.value.mem_limit // 0) <= 0) | .key] | join(" ")')"
  [ -z "$bad" ] || die "$f: every service needs a mem_limit: $bad"

  bad="$(printf '%s' "$j" | jq -r --arg d "$(dirname "$f")" '[.services[] | (.volumes // [])[] | select((.type // "volume") == "bind") | .source | select(startswith($d) | not)] | join(" ")')"
  [ -z "$bad" ] || die "$f: bind mount(s) outside $(dirname "$f"): $bad"
}
SBXEOF

  _put lib/caddy.sh <<'SBXEOF'
# lib/caddy.sh — the edge door. Caddy runs with `admin off`, so a vhost change
# is a validate + restart, never a reload. The edge serves the RENDERED tree
# ($DATA_DIR/rendered/caddy), which is why the vhost is copied there.

vhost_render() { # <name> <label> <upstream-container> <port> <exposure>
  local n="$1" label="$2" up="$3" port="$4" exp="$5" rule=""
  if [ "$exp" = "tailnet" ]; then
    rule="	@not_tailnet not remote_ip 100.64.0.0/10
	respond @not_tailnet 403"
  fi
  mkdir -p "$SBX_CADDY"
  tmpl_render "$SBX_TPL/vhost.caddy.tmpl" "$SBX_CADDY/sbx-$n.caddy" \
    "NAME=$n" "LABEL=$label" "DOMAIN=$(sbx_domain)" \
    "UPSTREAM=$up" "PORT=$port" "ACCESS_RULE=$rule"
}

vhost_install() { # copy the module's vhost into the rendered tree
  local n="$1" src="$SBX_CADDY/sbx-$n.caddy" dst="$RENDER_VHOSTS/sbx-$n.caddy"
  [ -f "$src" ] || die "no vhost to install: $src"
  mkdir -p "$RENDER_VHOSTS"
  if cmp -s "$src" "$dst"; then
    say "vhost already applied: $(basename "$dst")"
  else
    cp -f "$src" "$dst" || die "cannot write $dst"
    say "vhost applied: $(basename "$dst")"
  fi
}

vhost_remove() {
  local n="$1" f
  for f in "$SBX_CADDY/sbx-$n.caddy" "$RENDER_VHOSTS/sbx-$n.caddy"; do
    [ -f "$f" ] && rm -f "$f" && say "removed $(basename "$f")"
  done
}

# The edge stores a certificate per host under $DATA_DIR/caddy_data/caddy/
# certificates/<issuer>/<host>/ — a removed vhost leaves its key material there.
cert_purge() { # <fqdn>
  local h="$1" d n=0
  for d in "$DATA_DIR"/caddy_data/caddy/certificates/*/"$h"; do
    [ -d "$d" ] || continue
    rm -rf "$d" && n=$((n + 1))
  done
  [ "$n" = 0 ] && say "no stored certificate for $h" || ok "removed $n stored certificate dir(s) for $h"
}

edge_validate() {
  local ec
  ec="$(edge_container)" || die "cannot find the edge container in modules/"
  docker exec "$ec" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 ||
    die "caddy rejected the Caddyfile — nothing restarted; see data/sandbox/caddy/"
  ok "edge accepts the Caddyfile"
}

edge_restart() {
  local ec
  ec="$(edge_container)" || die "cannot find the edge container in modules/"
  docker restart "$ec" >/dev/null || die "docker restart $ec failed"
  local i
  for i in $(seq 1 20); do
    [ "$(docker inspect -f '{{.State.Running}}' "$ec" 2>/dev/null)" = "true" ] && { ok "edge restarted"; return 0; }
    sleep 1
  done
  die "edge did not come back up — docker logs $ec"
}

# edge_probe <label> <exposure> — tailnet-only is expected to answer 403 from
# this host (it is not in 100.64.0.0/10); the public modes answer 2xx/3xx/401.
edge_probe() {
  local label="$1" exp="$2" host code i
  host="$label.$(sbx_domain)"
  for i in $(seq 1 10); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 --resolve "$host:443:127.0.0.1" "https://$host/" || true)"
    case "$code" in
      000 | "") sleep 2 ;;
      *)
        if [ "$exp" = "tailnet" ]; then
          [ "$code" = 403 ] && { ok "$host answers 403 outside the tailnet"; return 0; }
          warn "$host answered $code (expected 403 for tailnet-only)"
          return 0
        fi
        ok "$host answers $code"
        return 0
        ;;
    esac
  done
  warn "$host did not answer yet — the first request issues the certificate; retry with curl"
}
SBXEOF

  _put lib/dns.sh <<'SBXEOF'
# lib/dns.sh — Cloudflare A records, driven from the token the installer already
# stored. Content and proxied flag are written on every call, so a rerun fixes a
# record that drifted.

cf_api() {
  local tok
  tok="$(cf_token)"
  [ -n "$tok" ] || die "no CF_API_TOKEN in data/wizard.state — dns/proxied exposure needs it (pick dns-only at your registrar, or tailnet-only)"
  curl -s -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' "$@"
}

cf_zone_id() {
  cf_api "https://api.cloudflare.com/client/v4/zones?name=$1" | jq -r '.result[0].id // empty'
}

# The host's public address, read from the apex record the installer already
# created — no extra lookup service, no hardcoded IP.
cf_host_ip() {
  local zid
  zid="$(cf_zone_id "$(sbx_domain)")"
  [ -n "$zid" ] || return 1
  cf_api "https://api.cloudflare.com/client/v4/zones/$zid/dns_records?type=A&name=$(sbx_domain)" |
    jq -r '.result[0].content // empty'
}

cf_a_set() { # <label> <tailnet|dns|proxied>
  local label="$1" exp="$2" dom zid fqdn rid prox body ip
  dom="$(sbx_domain)"
  fqdn="$label.$dom"
  prox=false
  [ "$exp" = "proxied" ] && prox=true
  zid="$(cf_zone_id "$dom")"
  [ -n "$zid" ] || die "cloudflare zone for $dom not found with the stored token"
  ip="$(cf_host_ip)"
  [ -n "$ip" ] || die "cannot read this host's public address from the apex A record"
  rid="$(cf_api "https://api.cloudflare.com/client/v4/zones/$zid/dns_records?type=A&name=$fqdn" | jq -r '.result[0].id // empty')"
  body="{\"type\":\"A\",\"name\":\"$fqdn\",\"content\":\"$ip\",\"ttl\":1,\"proxied\":$prox}"
  if [ -n "$rid" ]; then
    cf_api -X PUT "https://api.cloudflare.com/client/v4/zones/$zid/dns_records/$rid" -d "$body" >/dev/null
  else
    cf_api -X POST "https://api.cloudflare.com/client/v4/zones/$zid/dns_records" -d "$body" >/dev/null
  fi
  ok "$fqdn → $ip (proxied=$prox)"
}

cf_a_del() { # <label> — only called when this tool created the record
  local label="$1" dom zid rid
  dom="$(sbx_domain)"
  zid="$(cf_zone_id "$dom")"
  [ -n "$zid" ] || { warn "cloudflare zone not found — record left alone"; return 0; }
  rid="$(cf_api "https://api.cloudflare.com/client/v4/zones/$zid/dns_records?type=A&name=$label.$dom" | jq -r '.result[0].id // empty')"
  [ -n "$rid" ] || { say "no A record for $label.$dom"; return 0; }
  cf_api -X DELETE "https://api.cloudflare.com/client/v4/zones/$zid/dns_records/$rid" >/dev/null
  ok "A record for $label.$dom deleted"
}

hosts_line() { printf '%s\t%s.%s\n' "$(ws_get TS_IP)" "$1" "$(sbx_domain)"; }
SBXEOF

  _put templates/docker-compose.yml.tmpl <<'SBXEOF'
# sbx-{{NAME}} — written by scripts/sandbox/editor.sh. Regenerate, do not hand-edit.
# Contract: no ports:, pinned address on the external 'net', capped memory,
# restart: unless-stopped — that is what brings it back after a reboot, because
# the stack only boots modules/*/ and never sees this project.
services:
  {{SERVICE}}:
    image: {{IMAGE}}
    container_name: sbx-{{NAME}}-{{SERVICE}}
    restart: unless-stopped
    mem_limit: {{MEM}}
    memswap_limit: {{MEM}}
    env_file:
      - ./.env
    expose:
      - "{{PORT}}"
    volumes:
      - ./data/{{SERVICE}}:{{DATA_PATH}}
{{USER_LINE}}
    networks:
      net:
        ipv4_address: {{IP}}
{{HEALTHCHECK}}
networks:
  net:
    external: true
SBXEOF

  _put templates/vhost.caddy.tmpl <<'SBXEOF'
# sbx-{{NAME}} — generated by scripts/sandbox/editor.sh into data/sandbox/caddy and
# copied into the rendered tree. After `make render` re-applies it: make sandbox-sync
https://{{LABEL}}.{{DOMAIN}} {
	tls {
		issuer acme https://acme-v02.api.letsencrypt.org/directory {
			email admin@{{DOMAIN}}
			dns cloudflare {env.CF_API_TOKEN}
		}
		issuer acme https://api.buypass.com/acme/directory {
			email admin@{{DOMAIN}}
			dns cloudflare {env.CF_API_TOKEN}
		}
		issuer acme https://acme.zerossl.com/v2/DV90 {
			email admin@{{DOMAIN}}
			dns cloudflare {env.CF_API_TOKEN}
		}
	}
	import compress
	header {
		import security_headers
		Cache-Control "no-store, no-cache, must-revalidate, max-age=0"
		-ETag
		-Last-Modified
	}
{{ACCESS_RULE}}
	reverse_proxy {{UPSTREAM}}:{{PORT}}
}
SBXEOF

  _put templates/env.tmpl <<'SBXEOF'
# sbx-{{NAME}} — environment for the container, 0600, never committed.
{{ENV}}
SBXEOF

  _put tasks/index.sh <<'SBXEOF'
# tasks/index.sh — one order for the create flow (the only place it exists).
TASK_NAMES=("questions" "compose + contract" "bring-up" "edge vhost" "dns / access" "record")
TASKS=(task_questions task_compose task_bringup task_edge task_dns task_record)
SBXEOF

  _put tasks/10-questions.sh <<'SBXEOF'
# tasks/10-questions.sh — front-loaded questions. Nothing is written until all
# of them are answered (AGENTS 24), and nothing is defaulted silently where a
# wrong default would be dangerous.

task_questions() {
  local dom core taken
  dom="$(sbx_domain)"
  [ -n "$dom" ] || die "no DOMAIN known — data/instance.conf is missing"
  [ "$(ws_get finished)" = "true" ] ||
    die "the installer has not finished on this host (data/wizard.state) — run scripts/install/wizard.sh first"

  sec "Sandbox module"
  say "the repo is read-only here: this app lives in $SBX_MOD/<name>/"

  while :; do
    ask_var NAME "name (project sbx-<name>)" ""
    case "$NAME" in
      '') warn "a name is required"; continue ;;
      *[!a-z0-9-]*) warn "lowercase letters, digits and - only"; continue ;;
      -*) warn "cannot start with -"; continue ;;
    esac
    core="$(core_modules)"
    if printf '%s\n' "$core" | grep -qx -- "$NAME"; then
      warn "'$NAME' is a core module of this repo — pick another name"
      continue
    fi
    if [ -e "$(state_file "$NAME")" ] || [ -d "$SBX_MOD/$NAME" ]; then
      warn "'$NAME' already exists in $SBX — use remove first, or pick another name"
      continue
    fi
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "sbx-$NAME-.*" 2>/dev/null; then
      warn "a container sbx-$NAME-* already exists"; continue
    fi
    break
  done

  ask_var SERVICE "service name in the compose file" "$NAME"
  while :; do
    ask_var IMAGE "image (registry/repo:tag — a pinned tag, not latest)" ""
    [ -n "$IMAGE" ] || { warn "an image is required"; continue; }
    case "${IMAGE##*/}" in
      *:*) ;;
      *) warn "no tag: '$IMAGE' would resolve to :latest — pin one (e.g. :1.2.3)"; continue ;;
    esac
    case "$IMAGE" in *:latest) warn "pin a version instead of :latest"; continue ;; esac
    break
  done

  ask_port PORT "container port the app listens on" ""
  ask_var DATA_PATH "container path to persist" "/data"
  case "$DATA_PATH" in /*) ;; *) warn "$DATA_PATH is not absolute — using /data"; DATA_PATH=/data ;; esac

  while :; do
    ask_var UIDGID "run as uid:gid (empty = image default)" ""
    case "$UIDGID" in
      '' | -) UIDGID=""; break ;;
      *[!0-9:]*) warn "uid:gid, digits only"; continue ;;
      *:*) [ -n "${UIDGID%%:*}" ] && [ -n "${UIDGID#*:}" ] && break ;;
    esac
    warn "uid:gid, e.g. 1000:1000"
  done

  local free
  free="$(mem_free_mb)"
  while :; do
    ask_var MEM "memory cap (e.g. 256m)" "256m"
    case "$MEM" in
      *[mMgG] | *[mMgG][bB]) ;;
      *) warn "256m or 1g"; continue ;;
    esac
    local want=${MEM%[!0-9]*} unit=${MEM: -1}
    local mb=$want
    case "${unit,,}" in g) mb=$((want * 1024)) ;; esac
    if [ "$mb" -gt "$free" ]; then
      warn "$MEM does not fit: ${free}m free right now (MemAvailable minus 256m reserve)"
      continue
    fi
    break
  done

  ask_yes HEALTH "add a curl healthcheck (only if the image has curl)" no

  ENV_PAIRS=()
  sec "Environment (KEY=VALUE, empty line to finish)"
  local pair
  while :; do
    ask_var pair "KEY=VALUE" ""
    [ -n "$pair" ] || break
    case "$pair" in
      *=*) ENV_PAIRS+=("$pair") ;;
      *) warn "KEY=VALUE, ignored: $pair" ;;
    esac
  done

  # Label: one free name under the existing domain, checked against the live
  # vhost trees — never a guess, never a duplicate.
  taken="$(labels_in_use | tr '\n' ' ')"
  say "labels already claimed: ${taken:-none}"
  while :; do
    ask_var LABEL "host label (<label>.$dom)" "$NAME"
    case "$LABEL" in
      '') warn "a label is required"; continue ;;
      *[!a-z0-9-]*) warn "lowercase letters, digits and - only"; continue ;;
    esac
    if label_taken "$LABEL"; then warn "'$LABEL' is already served by an existing vhost"; continue; fi
    break
  done

  ask_exposure EXPOSURE
  ask_yes START "bring it up now" yes

  IP="$(free_ip)"
  say "address on 'net': $IP (first free, persisted in state/$NAME.conf)"
}
SBXEOF

  _put tasks/20-compose.sh <<'SBXEOF'
# tasks/20-compose.sh — render from the template, then hold it to the contract
# before anything starts.

task_compose() {
  local dir="$SBX_MOD/$NAME" user_line="" hc=""
  case "$UIDGID" in
    '') user_line="" ;;
    *) user_line="    user: \"$UIDGID\"" ;;
  esac
  if [ "$HEALTH" = yes ]; then
    hc="    healthcheck:
      test: [\"CMD-SHELL\", \"curl -fsS http://127.0.0.1:$PORT/ || exit 1\"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s"
  fi

  mkdir -p "$dir/data/$SERVICE" || die "cannot create $dir"

  tmpl_render "$SBX_TPL/docker-compose.yml.tmpl" "$dir/docker-compose.yml" \
    "NAME=$NAME" "SERVICE=$SERVICE" "IMAGE=$IMAGE" "MEM=$MEM" "PORT=$PORT" \
    "IP=$IP" "DATA_PATH=$DATA_PATH" "USER_LINE=$user_line" "HEALTHCHECK=$hc"

  mkdir -p "$dir"
  tmpl_render "$SBX_TPL/env.tmpl" "$dir/.env" "NAME=$NAME" "ENV=$(printf '%s\n' "${ENV_PAIRS[@]:-}")"
  chmod 600 "$dir/.env"

  [ -n "$UIDGID" ] && chown -R "$UIDGID" "$dir/data/$SERVICE"

  validate_compose "$dir/docker-compose.yml" "sbx-$NAME"
  ok "contract holds: no ports, pinned $IP, ${MEM} cap, restart: unless-stopped"
}
SBXEOF

  _put tasks/30-bringup.sh <<'SBXEOF'
# tasks/30-bringup.sh — start it and wait for the container to actually run.

task_bringup() {
  local dir="$SBX_MOD/$NAME" i
  if [ "$START" != yes ]; then
    say "not started (answer was no) — start later with: docker compose -p sbx-$NAME -f $dir/docker-compose.yml up -d"
    return 0
  fi
  docker compose -f "$dir/docker-compose.yml" -p "sbx-$NAME" up -d 2>&1 | tail -5
  for i in $(seq 1 40); do
    if [ "$(docker inspect -f '{{.State.Running}}' "sbx-$NAME-$SERVICE" 2>/dev/null)" = "true" ]; then
      ok "sbx-$NAME-$SERVICE is running"
      return 0
    fi
    sleep 2
  done
  docker logs --tail 20 "sbx-$NAME-$SERVICE" 2>&1 | sed 's/^/    /' || true
  die "sbx-$NAME-$SERVICE did not start — see the log lines above"
}
SBXEOF

  _put tasks/40-edge.sh <<'SBXEOF'
# tasks/40-edge.sh — one vhost, validated by caddy itself before the restart
# (the edge runs with `admin off`: no reload exists).

task_edge() {
  vhost_render "$NAME" "$LABEL" "sbx-$NAME-$SERVICE" "$PORT" "$EXPOSURE"
  vhost_install "$NAME"
  edge_validate
  edge_restart
  if [ "$START" = yes ]; then
    edge_probe "$LABEL" "$EXPOSURE"
  else
    say "not started — the door will answer once the container runs"
  fi
}
SBXEOF

  _put tasks/50-dns.sh <<'SBXEOF'
# tasks/50-dns.sh — the exposure the operator picked, and nothing else.

task_dns() {
  RECORD=0
  case "$EXPOSURE" in
    tailnet)
      say "no DNS record: tailnet-only uses the tailnet's own DNS"
      say "for a client that is not on the tailnet's DNS, add to /etc/hosts:"
      printf '    %s\n' "$(hosts_line "$LABEL")"
      ;;
    dns | proxied)
      cf_a_set "$LABEL" "$EXPOSURE"
      RECORD=1
      ;;
    *) die "unknown exposure: $EXPOSURE" ;;
  esac
}
SBXEOF

  _put tasks/60-record.sh <<'SBXEOF'
# tasks/60-record.sh — one record per module, written last, only after the rest
# held. It is what list/remove/sync read; data/wizard.state is never touched.

task_record() {
  state_put "$NAME" \
    "NAME=$NAME" "SERVICE=$SERVICE" "IMAGE=$IMAGE" "PORT=$PORT" "MEM=$MEM" \
    "UIDGID=$UIDGID" "DATA_PATH=$DATA_PATH" "EXPOSURE=$EXPOSURE" "LABEL=$LABEL" \
    "IP=$IP" "PROJECT=sbx-$NAME" "RECORD=${RECORD:-0}" "CREATED=$(date -Iseconds)"
  ok "recorded in $SBX_STATE/$NAME.conf"
}
SBXEOF
}

# Second half of the tree: the flows. Same _put rule — written once, never
# overwritten unless --force.
_bootstrap_flows() {

  _put flow/create.sh <<'SBXEOF'
# flow/create.sh — the whole create, in the order tasks/index.sh declares.
flow_create() {
  need docker
  need jq
  need curl
  docker network inspect net >/dev/null 2>&1 ||
    die "docker network 'net' is not there — bring the stack up first (scripts/stack/stack-up.sh)"
  TASK_TITLE="sandbox create"
  run_tasks || die "create stopped — the module was not recorded"

  sec "Done"
  say "project   sbx-$NAME  ($SBX_MOD/$NAME)"
  case "$EXPOSURE" in
    tailnet) say "door      https://$LABEL.$(sbx_domain) — tailnet only" ;;
    dns) say "door      https://$LABEL.$(sbx_domain) — public, direct" ;;
    proxied) say "door      https://$LABEL.$(sbx_domain) — public, behind cloudflare" ;;
  esac
  say "reboot    restart: unless-stopped brings it back; the stack never sees it"
  say "render    after 'make render': make sandbox-sync"
  say "remove    bash scripts/sandbox/editor.sh remove"
}
SBXEOF

  _put flow/remove.sh <<'SBXEOF'
# flow/remove.sh — take a sandbox module down and leave NOTHING behind: the
# project, its volumes, its networks, both vhost copies, its DNS record, the
# certificate the edge stored for its host, its state record, its dir and its
# local backups. Everything it touches is either data/sandbox/ or the edge's
# own state (rendered vhosts + caddy_data/certificates) — never the repo.

# leftover containers of the project, including ones created by hand
sbx_kill_containers() { # <n>
  local n="$1" ids
  ids="$(docker ps -aq --filter "label=com.docker.compose.project=sbx-$n")"
  ids="$ids $(docker ps -aq --filter "name=^/sbx-$n-")"
  ids="$(printf '%s\n' $ids | sort -u | tr '\n' ' ')"
  [ -z "${ids// /}" ] && return 0
  docker rm -f $ids >/dev/null 2>&1 || true
  ok "containers removed"
}

# volumes and networks the project created; the shared 'net' is never touched
sbx_kill_attachments() { # <n>
  local n="$1" x name vols nets
  vols="$(docker volume ls -q --filter "label=com.docker.compose.project=sbx-$n")"
  [ -n "$vols" ] && { docker volume rm -f $vols >/dev/null 2>&1 || true; ok "volumes removed"; }
  nets="$(docker network ls -q --filter "label=com.docker.compose.project=sbx-$n")"
  for x in $nets; do
    name="$(docker network inspect -f '{{.Name}}' "$x" 2>/dev/null)"
    [ -n "$name" ] || continue
    case "$name" in
      net) warn "keeping network 'net' — it carries the whole stack" ;;
      *) docker network rm "$x" >/dev/null 2>&1 && ok "network $name removed" ;;
    esac
  done
}

# what is still left for this module, one line per item (empty = clean)
sbx_leftovers() { # <n> <fqdn>
  local n="$1" fqdn="$2" f
  {
    docker ps -a --filter "label=com.docker.compose.project=sbx-$n" --format '  container {{.Names}}'
    docker ps -a --filter "name=^/sbx-$n-" --format '  container {{.Names}}'
    docker volume ls -q --filter "label=com.docker.compose.project=sbx-$n" | sed 's/^/  volume /'
    docker network ls --filter "label=com.docker.compose.project=sbx-$n" --format '  network {{.Name}}'
    for f in "$SBX_CADDY/sbx-$n.caddy" "$RENDER_VHOSTS/sbx-$n.caddy"; do [ -f "$f" ] && printf '  vhost %s\n' "$f"; done
    for f in "$DATA_DIR"/caddy_data/caddy/certificates/*/"$fqdn"; do [ -d "$f" ] && printf '  certificate %s\n' "$f"; done
    [ -f "$(state_file "$n")" ] && printf '  state %s\n' "$(state_file "$n")"
    [ -d "$SBX_MOD/$n" ] && printf '  dir %s\n' "$SBX_MOD/$n"
  } | sort -u
}

flow_remove() {
  need docker
  local names n exp label fqdn dir ans baks i=1
  names="$(state_names)"
  [ -n "$names" ] || die "no sandbox modules recorded in $SBX_STATE"

  sec "Sandbox modules"
  for n in $names; do
    printf '  %d) %-14s %-10s %s\n' "$i" "$n" "$(state_get "$n" EXPOSURE)" \
      "$(state_get "$n" LABEL).$(sbx_domain)"
    i=$((i + 1))
  done

  ask_var n "module to remove" ""
  printf '%s\n' $names | grep -qx -- "$n" || die "unknown sandbox module: '$n'"
  exp="$(state_get "$n" EXPOSURE)"
  label="$(state_get "$n" LABEL)"
  fqdn="$label.$(sbx_domain)"
  dir="$SBX_MOD/$n"

  ask_yes ans "take sbx-$n down, drop its vhost and its record for $fqdn" no
  [ "$ans" = yes ] || die "nothing done"

  if [ -f "$dir/docker-compose.yml" ]; then
    docker compose -f "$dir/docker-compose.yml" -p "sbx-$n" down --remove-orphans --volumes 2>&1 | tail -3
  fi
  sbx_kill_containers "$n"
  sbx_kill_attachments "$n"
  ok "project sbx-$n is down"

  vhost_remove "$n"
  edge_validate
  edge_restart
  cert_purge "$fqdn"

  if [ "$(state_get "$n" RECORD)" = "1" ]; then
    cf_a_del "$label"
  else
    say "no DNS record was created by this tool — nothing to delete"
  fi

  ask_yes ans "delete $dir and its data" no
  if [ "$ans" = yes ]; then
    rm -rf "$dir"
    ok "deleted $dir"
  else
    warn "kept $dir — its .env and data/ stay on disk; delete it by hand"
  fi

  baks="$(ls -1 "$SBX_BAK/$n"-*.tar.gz* 2>/dev/null)"
  if [ -n "$baks" ]; then
    ask_yes ans "delete the local backups of $n (data/sandbox/backups)" no
    if [ "$ans" = yes ]; then
      rm -f "$SBX_BAK/$n"-*.tar.gz "$SBX_BAK/$n"-*.tar.gz.sha256
      ok "backups deleted"
    else
      say "kept: $(printf '%s ' $baks)"
    fi
  fi

  rm -f "$(state_file "$n")"
  ok "state record removed"

  ans="$(sbx_leftovers "$n" "$fqdn")"
  if [ -z "$ans" ]; then
    ok "sbx-$n is gone — no leftovers"
  else
    warn "left behind (delete by hand):"
    printf '%s\n' "$ans"
  fi
  say "image layers stay in the docker cache unless removed: docker image rm <image>"
}
SBXEOF

  _put flow/list.sh <<'SBXEOF'
# flow/list.sh — what is declared, what is running, and what drifted.
flow_list() {
  local names n fqdn exp ip run st sz f
  names="$(state_names)"
  sec "Sandbox modules — $SBX"
  if [ -z "$names" ]; then
    say "none yet — bash scripts/sandbox/editor.sh create"
    return 0
  fi
  printf '  %-14s %-24s %-10s %-16s %-18s %s\n' NAME HOST EXPOSURE ADDRESS STATE DATA
  for n in $names; do
    fqdn="$(state_get "$n" LABEL).$(sbx_domain)"
    exp="$(state_get "$n" EXPOSURE)"
    ip="$(state_get "$n" IP)"
    run="$(docker ps --filter "name=^sbx-$n-" --format '{{.Names}}' 2>/dev/null | head -1)"
    if [ -n "$run" ]; then st="running"; else st="stopped"; fi
    if [ ! -f "$RENDER_VHOSTS/sbx-$n.caddy" ]; then
      st="$st/no-vhost"
    elif ! cmp -s "$SBX_CADDY/sbx-$n.caddy" "$RENDER_VHOSTS/sbx-$n.caddy" 2>/dev/null; then
      st="$st/stale"
    fi
    sz="$(du -sh "$SBX_MOD/$n/data" 2>/dev/null | awk '{print $1}')"
    printf '  %-14s %-24s %-10s %-16s %-18s %s\n' "$n" "$fqdn" "$exp" "$ip" "$st" "${sz:--}"
  done
  for f in "$RENDER_VHOSTS"/sbx-*.caddy; do
    [ -f "$f" ] || continue
    n="$(basename "$f" .caddy)"
    n="${n#sbx-}"
    [ -f "$(state_file "$n")" ] || say "orphan: $(basename "$f") has no record — make sandbox-sync prunes it"
  done
  if [ -n "$(installed_modules)" ]; then
    say "installed core modules (data/wizard.state): $(installed_modules)"
  fi
  say "core modules (modules/): $(core_modules | tr '\n' ' ')"
}
SBXEOF

  _put flow/validate.sh <<'SBXEOF'
# flow/validate.sh — re-hold every recorded module to the contract.
flow_validate() {
  need docker
  need jq
  local names n f drift=0
  names="$(state_names)"
  [ -n "$names" ] || { say "nothing recorded"; return 0; }
  for n in $names; do
    f="$SBX_MOD/$n/docker-compose.yml"
    if [ ! -f "$f" ]; then
      warn "$n: compose file missing ($f)"
      drift=1
      continue
    fi
    validate_compose "$f" "sbx-$n"
    if ! cmp -s "$SBX_CADDY/sbx-$n.caddy" "$RENDER_VHOSTS/sbx-$n.caddy" 2>/dev/null; then
      warn "$n: rendered vhost differs — make sandbox-sync"
      drift=1
    else
      ok "$n: contract + vhost in place"
    fi
  done
  [ "$drift" = 0 ] || return 1
}
SBXEOF

  _put flow/sync.sh <<'SBXEOF'
# flow/sync.sh — the one reconcile (make sandbox-sync). `make render` rsyncs the
# rendered tree with --delete, which is why the vhosts have to be re-applied
# afterwards. Also prunes doors whose module is gone and revives projects docker
# no longer runs (restart: unless-stopped covers reboots, not `compose down`).
flow_sync() {
  need docker
  local changed=0 f b n ids
  [ -d "$SBX_CADDY" ] || die "no $SBX_CADDY yet — nothing to sync"
  mkdir -p "$RENDER_VHOSTS"

  for f in "$RENDER_VHOSTS"/sbx-*.caddy; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"
    if [ ! -f "$SBX_CADDY/$b" ]; then
      rm -f "$f"
      say "pruned $b (no module behind it)"
      changed=1
    fi
  done

  for f in "$SBX_CADDY"/*.caddy; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"
    cmp -s "$f" "$RENDER_VHOSTS/$b" && continue
    cp -f "$f" "$RENDER_VHOSTS/$b" || die "cannot write $RENDER_VHOSTS/$b"
    say "applied $b"
    changed=1
  done

  for n in $(state_names); do
    f="$SBX_MOD/$n/docker-compose.yml"
    [ -f "$f" ] || continue
    ids="$(docker ps -q --filter "label=com.docker.compose.project=sbx-$n")"
    if [ -z "$ids" ]; then
      if docker compose -f "$f" -p "sbx-$n" up -d >/dev/null 2>&1; then
        say "revived sbx-$n"
        changed=1
      else
        warn "could not revive sbx-$n — docker compose -f $f -p sbx-$n up -d"
      fi
    fi
  done

  if [ "$changed" = 1 ]; then
    edge_validate
    edge_restart
  else
    ok "already in sync"
  fi

  for f in "$SBX_CADDY"/*.caddy; do
    [ -f "$f" ] || continue
    b="$(basename "$f" .caddy)"
    n="${b#sbx-}"
    if [ -f "$RENDER_VHOSTS/sbx-$n.caddy" ]; then
      ok "$n: $(state_get "$n" LABEL).$(sbx_domain) served"
    else
      warn "$n: vhost missing from the rendered tree"
    fi
  done
}
SBXEOF

  _put flow/backup.sh <<'SBXEOF'
# flow/backup.sh — data/sandbox is outside the stack's own bundle set, so a
# sandbox module only has whatever this writes.
flow_backup() {
  local names n ans out
  names="$(state_names)"
  [ -n "$names" ] || die "no sandbox modules to back up"
  sec "Sandbox backup"
  for n in $names; do printf '  - %s\n' "$n"; done
  ask_var n "module to back up" ""
  printf '%s\n' $names | grep -qx -- "$n" || die "unknown sandbox module: '$n'"
  [ -d "$SBX_MOD/$n/data" ] || die "no data directory: $SBX_MOD/$n/data"
  mkdir -p "$SBX_BAK"
  out="$SBX_BAK/$n-$(date +%Y%m%d-%H%M).tar.gz"
  tar czf "$out" -C "$SBX_MOD/$n" data || die "tar failed"
  ( cd "$SBX_BAK" && sha256sum "$(basename "$out")" >"$(basename "$out").sha256" )
  ok "$out ($(du -h "$out" | cut -f1))"
  say "copy it off the host yourself — nothing else ships it"
}
SBXEOF

  _put flow/cli.sh <<'SBXEOF'
# flow/cli.sh — dispatch. The repo file editor.sh only writes, loads and calls
# this; every flow is a file the operator can read and edit.
cli() {
  case "${1:-}" in
    create) flow_create ;;
    remove) flow_remove ;;
    list) flow_list ;;
    validate) flow_validate ;;
    sync) flow_sync ;;
    backup) flow_backup ;;
    *) _usage; return 1 ;;
  esac
}
SBXEOF
}

case "$CMD" in
  "" | help | -h | --help) _usage; exit 0 ;;
  bootstrap)
    _bootstrap
    _bootstrap_flows
    printf 'editor: tree ready — %s\n' "$SBX"
    exit 0
    ;;
esac

_bootstrap
_bootstrap_flows

for _f in \
  "$SBX"/lib/env.sh "$SBX"/lib/ui.sh "$SBX"/lib/prompt.sh "$SBX"/lib/derive.sh \
  "$SBX"/lib/state.sh "$SBX"/lib/validate.sh "$SBX"/lib/caddy.sh "$SBX"/lib/dns.sh \
  "$SBX"/tasks/index.sh "$SBX"/tasks/[0-9]*.sh "$SBX"/flow/*.sh; do
  # shellcheck disable=SC1090
  . "$_f" || die_early "cannot source $_f"
done

cli "$CMD"
