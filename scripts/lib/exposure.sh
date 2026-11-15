#!/usr/bin/env bash
# scripts/lib/exposure.sh — the per-vhost exposure answers, for SCRIPTS. SOURCED.
#
# Every Caddy vhost is ONE of two doors, chosen at install time and recorded in
# data/instance.conf as one key per vhost FILE:
#
#   tailnet-vpn     no public A record; the machine dnsmasq answers the name for
#                   tailnet clients (config/dnsmasq/10-tailnet.conf) and the
#                   vhost refuses every other source with `@not_tailnet` before
#                   the proxy runs.
#   cloudflare-dns  a public A record pointing at this host; no gate, so the app
#                   is reachable from the internet.
#
# The key is the vhost file's basename, uppercased, non-alphanumerics -> `_`
# (livekit-jwt.matrix.caddy -> LIVEKIT_JWT_MATRIX_EXPOSURE). One file may
# declare several hostnames — www.caddy carries the apex and www — and both
# hosts share that file's answer.
#
# Two doors are FIXED, never chosen: ttyd (an unauthenticated root shell) is
# always tailnet-vpn, and the core www/apex pages belong to no module and are
# always cloudflare-dns.
#
# THE ONE ACCESSOR: no caller re-parses instance.conf for these keys, and a
# vhost with no recorded answer returns EMPTY — never a default.
#
# Requires instance.sh first (REPO_DIR, DATA_DIR, DOMAIN).
# Functions:
#   exposure_valid <value>       exit 0/1 — tailnet-vpn | cloudflare-dns
#   exposure_key <vhost>         the instance.conf key for a vhost file
#   exposure_of <vhost>          the recorded value ('' when unanswered)
#   exposure_hosts <vhost>       every hostname the template declares (FQDN)
#   exposure_of_host <hostname>  the value of the vhost that declares it
#   exposure_all                 every vhost file, ttyd included
#   exposure_targets             every vhost file a run may choose (no ttyd)

_EXP_SELF="$(readlink -f "${BASH_SOURCE[0]:-$0}")"
: "${REPO_DIR:=$(cd "$(dirname "$_EXP_SELF")/../.." && pwd)}"
: "${DATA_DIR:=$REPO_DIR/data}"
EXPOSURE_VHOST_DIR="${EXPOSURE_VHOST_DIR:-$REPO_DIR/modules/caddy/vhosts}"
_EXP_CONF="${INSTANCE_CONF:-$DATA_DIR/instance.conf}"

exposure_valid() { case "$1" in tailnet-vpn|cloudflare-dns) return 0 ;; esac; return 1; }

# The instance.conf key for a vhost file: basename, upper case, every
# non-alphanumeric a `_` — the same rule the installer writes with.
exposure_key() { local k="${1^^}"; printf '%s' "${k//[^A-Z0-9]/_}"; }

# One raw instance.conf value ('' when the file or the key is absent).
_exposure_raw() {
  [ -f "$_EXP_CONF" ] || return 1
  sed -n "s/^$1=//p" "$_EXP_CONF" 2>/dev/null | tail -1
}

exposure_of() { _exposure_raw "$(exposure_key "$1")_EXPOSURE"; }

_exposure_domain() { local d; d="$(_exposure_raw DOMAIN)"; printf '%s' "${d:-${DOMAIN:-}}"; }

exposure_all() {
  local f
  for f in "$EXPOSURE_VHOST_DIR"/*.caddy; do
    [ -f "$f" ] || continue
    basename "$f" .caddy
  done
}

exposure_targets() {
  local v
  exposure_all | while IFS= read -r v; do
    [ "$v" = ttyd ] || printf '%s\n' "$v"
  done
}

# Every hostname the template declares, derived from its `https://<host>{{DOMAIN}} {`
# line(s) — no hardcoded roster. The apex form (`https://{{DOMAIN}} {`) yields
# the bare domain.
exposure_hosts() {
  local f="$EXPOSURE_VHOST_DIR/$1.caddy" dom pfx
  [ -f "$f" ] || return 1
  dom="$(_exposure_domain)"
  [ -n "$dom" ] || return 1
  sed -n 's|^https://\([A-Za-z0-9._-]*\){{DOMAIN}}[[:space:]]*{.*|\1|p' "$f" |
    while IFS= read -r pfx; do printf '%s%s\n' "$pfx" "$dom"; done
}

# The answer for the vhost that declares <hostname>; exit 1 when no template
# declares it (a name this repo has no door for).
exposure_of_host() {
  local host="$1" v h
  for v in $(exposure_all); do
    for h in $(exposure_hosts "$v"); do
      [ "$h" = "$host" ] && { exposure_of "$v"; return 0; }
    done
  done
  return 1
}
