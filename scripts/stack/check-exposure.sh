#!/usr/bin/env bash
# scripts/stack/check-exposure.sh — one recorded answer, four things that must
# agree: the vhost's gate, the limiter's order behind it, the dnsmasq answer and
# the set of hostnames the accessor knows about.
#
# READ-ONLY: every render lands in a mktemp dir with a synthetic instance.conf;
# data/ is never touched and nothing is sent anywhere. Exit 0 = wired,
# 1 = a template, the skeleton or the accessor disagree.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
VHOSTS="$ROOT/modules/caddy/vhosts"
DNSMASQ="$ROOT/config/dnsmasq/10-tailnet.conf"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fails=0
bad()  { echo "FAIL $*"; fails=$((fails + 1)); }
ok()   { echo "ok   $*"; }

# A synthetic instance: every vhost file present, both answers rendered.
conf() { # conf <path> <tailnet-vpn|cloudflare-dns>
  {
    printf 'DOMAIN=example.com\nDATA_DIR=%s\nREPO_DIR=%s\nLOG_DIR=%s/logs\n' "$TMP" "$ROOT" "$TMP"
    printf 'CF_API_TOKEN=dummy\nGITHUB_USER=exampleuser\nREPO_NAME=kefoCloud\n'
    local v k
    for v in $(INSTANCE_CONF=/dev/null bash -c ". '$ROOT/scripts/lib/exposure.sh'; exposure_targets" | sort -u); do
      k="$(INSTANCE_CONF=/dev/null bash -c ". '$ROOT/scripts/lib/exposure.sh'; exposure_key $v" | tr '[:lower:]' '[:upper:]')"
      printf '%s_EXPOSURE=%s\n' "$k" "$2"
    done
  } >"$1"
}

# ── 1. one answer per vhost, and every hostname it declares is enumerated ──
KEYS="$(INSTANCE_CONF=/dev/null bash -c ". '$ROOT/scripts/lib/exposure.sh'; for v in \$(exposure_targets); do printf '%s_EXPOSURE\\n' \"\$(exposure_key \"\$v\")\"; done")"
for f in "$VHOSTS"/*.caddy; do
  v="$(basename "$f" .caddy)"
  [ "$v" = ttyd ] && continue   # the fixed door: never a choice, so no key
  grep -qx "$v" <<<"$(INSTANCE_CONF=/dev/null bash -c ". '$ROOT/scripts/lib/exposure.sh'; exposure_targets")" \
    || bad "$v.caddy is not an exposure target (scripts/lib/exposure.sh:exposure_targets)"
done
ok "every vhost file is an exposure target"

# ── 2. the tracked dnsmasq skeleton answers exactly the gated hosts ────────
for v in $(INSTANCE_CONF=/dev/null bash -c ". '$ROOT/scripts/lib/exposure.sh'; exposure_targets"); do
  [ "$v" = www ] && continue
  k="$(INSTANCE_CONF=/dev/null bash -c ". '$ROOT/scripts/lib/exposure.sh'; exposure_key $v" | tr '[:lower:]' '[:upper:]')_EXPOSURE"
  for h in $(INSTANCE_CONF=/dev/null bash -c ". '$ROOT/scripts/lib/exposure.sh'; exposure_hosts $v"); do
    rel="${h%.example.com}"
    if ! grep -q "{{IF $k=tailnet-vpn}}address=/$rel\.{{DOMAIN}}/" "$DNSMASQ"; then
      bad "$DNSMASQ has no guarded line for $rel.$DOMAIN ($v)"
    fi
  done
done
ok "dnsmasq skeleton: one guarded answer per gated host"

# ── 3. an orphan conditional fails: every {{IF <K>_EXPOSURE=…}} must be a key ─
for k in $(grep -rhoE '\{\{IF [A-Z0-9_]+_EXPOSURE=' "$ROOT/modules" "$ROOT/config" "$ROOT/scripts" 2>/dev/null \
           | sed 's/^{{IF //; s/=$//' | sort -u); do
  [ "$k" = TTYD_EXPOSURE ] && continue
  grep -qx "$k" <<<"$KEYS" || bad "template conditionals use $k, which no vhost owns"
done
ok "every * _EXPOSURE conditional belongs to a vhost"

# ── 4. render both answers: gate present on tailnet-vpn, absent otherwise, and
#      the gate precedes the limiter (a refused flood must not spend a window) ─
conf "$TMP/tn.conf" tailnet-vpn
conf "$TMP/pub.conf" cloudflare-dns
mkdir -p "$TMP/tn" "$TMP/pub"
for v in $(ls "$VHOSTS" | sed 's/\.caddy$//'); do
  INSTANCE_CONF="$TMP/tn.conf"  "$ROOT/scripts/render/render.sh" "$VHOSTS/$v.caddy" "$TMP/tn/$v.caddy" >/dev/null
  INSTANCE_CONF="$TMP/pub.conf" "$ROOT/scripts/render/render.sh" "$VHOSTS/$v.caddy" "$TMP/pub/$v.caddy" >/dev/null
  case "$v" in
    ttyd|www) ;;                      # fixed doors: one answer, never conditional
    *)
      grep -q "respond @not_tailnet 403" "$TMP/tn/$v.caddy" \
        || bad "$v.caddy renders no gate under tailnet-vpn"
      grep -q "respond @not_tailnet 403" "$TMP/pub/$v.caddy" \
        && bad "$v.caddy still renders a gate under cloudflare-dns"
      ;;
  esac
done
ok "every gated vhost: gate under tailnet-vpn, none under cloudflare-dns"

grep -rn "@not_tailnet" "$VHOSTS"/*.caddy >/dev/null 2>&1 || true
for f in "$TMP/tn"/*.caddy; do
  v="$(basename "$f" .caddy)"
  g="$(grep -n 'respond @not_tailnet 403' "$f" | head -1 | cut -d: -f1)"
  l="$(grep -n 'rate_limit' "$f" | head -1 | cut -d: -f1)"
  [ -z "$g" ] || [ -z "$l" ] && continue
  [ "$g" -lt "$l" ] || bad "$v.caddy: the limiter is rendered before the gate"
done
ok "gate rendered before the limiter"

# ── 5. the rendered sites parse as Caddy config, when the image is present ──
if docker image inspect caddy:local >/dev/null 2>&1; then
  mkdir -p "$TMP/site/vhosts"
  INSTANCE_CONF="$TMP/pub.conf" "$ROOT/scripts/render/render.sh" "$ROOT/modules/caddy/Caddyfile" "$TMP/site/Caddyfile" >/dev/null
  cp "$TMP/pub"/*.caddy "$TMP/site/vhosts/"
  if docker run --rm -e CF_API_TOKEN=abcdefghijklmnopqrstuvwxyz0123456789ABCD \
       -v "$TMP/site:/etc/caddy:ro" caddy:local \
       caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
    ok "the rendered edge validates (caddy validate)"
  else
    bad "the rendered edge does not validate — run caddy validate yourself"
  fi
else
  echo "skip caddy validate (no caddy:local image)"
fi

[ "$fails" = 0 ] && { echo "exposure wiring OK"; exit 0; }
echo "exposure wiring: $fails failure(s)"
exit 1
