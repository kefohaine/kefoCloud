#!/usr/bin/env bash
# Live smoke test for every fxmq.net vhost + the mail platform + the host
# services. Fails (exit 1) if an app vhost stops serving its real app — e.g.
# someone stubs it with `respond "ok"` (the 2026-08-28 incident) — or if the
# edge misbehaves (tail 403 / /ttyd auth), the mail platform or a container
# is down, or the host units/firewall drifted. Run after any change to
# services/fxmq.net/ or after `docker restart fxmq.net`. The pre-push hook
# runs this automatically (override with SKIP_SMOKE=1 — not on a whim).
set -uo pipefail

fails=0
# check <name> <host> <path> <want-codes...> [html] [desc]
# want-codes: space-separated acceptable HTTP codes; trailing "html" asserts
# the response must NOT be text/plain (the ok-stub signature). desc is a
# short plain-words description printed after `ok` so the suite reads as a
# checklist, not a table of paths.
check() {
  local name="$1" host="$2" path="$3" codes="$4" want_html="${5:-}" desc="${6:-}"
  local code ct
  local args=(--resolve "$host:443:127.0.0.1")
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 "${args[@]}" "https://$host$path")
  ct=$(curl -s -o /dev/null -w '%{content_type}' --max-time 12 "${args[@]}" "https://$host$path")
  local ok=0 c
  for c in $codes; do
    [ "$code" = "$c" ] && ok=1
  done
  if [ "$ok" != 1 ]; then
    echo "FAIL $name: got HTTP $code (want: $codes) — https://$host$path"; fails=1
  elif [ "$want_html" = html ] && [ "$code" = "200" ] && [[ "$ct" == text/plain* ]]; then
    # The ok-stub signature is a 200 with a text/plain body. A 3xx redirect
    # legitimately carries a text/plain (empty) body — only flag 200s.
    echo "FAIL $name: 200 text/plain response (stubbed?) — https://$host$path"; fails=1
  else
    echo "ok   $name: $code $ct${desc:+ — }$desc"
  fi
}

hdr() { echo ""; echo "== $1 =="; }

# Security headers: every app vhost must serve EXACTLY ONE of each — Caddy's
# `header` directive appends to upstream values (a same-field delete+set even
# ends up deleted), so the fix is header_down at the proxy + a set-only
# snippet. A regression (missing or duplicated XFO/XCTO/HSTS — the
# scan.nextcloud.com flags) must fail the smoke and block the push.
check_sec_headers() {
  local name="$1" host="$2" path="${3:-/}" desc="${4:-}"
  local args=(--resolve "$host:443:127.0.0.1" -sI --max-time 12)
  local xfo xcto hsts
  xfo=$(curl "${args[@]}" "https://$host$path" | grep -icE '^x-frame-options: SAMEORIGIN')
  xcto=$(curl "${args[@]}" "https://$host$path" | grep -icE '^x-content-type-options: nosniff')
  hsts=$(curl "${args[@]}" "https://$host$path" | grep -icE '^strict-transport-security: max-age=31536000')
  if [ "$xfo" != 1 ] || [ "$xcto" != 1 ] || [ "$hsts" != 1 ]; then
    echo "FAIL $name sec-headers: xfo=$xfo xcto=$xcto hsts=$hsts (want exactly 1 each) — https://$host$path"; fails=1
  else
    echo "ok   $name sec-headers${desc:+ — }$desc"
  fi
}

hdr "Edge — public vhosts"
# App vhosts must answer with real content, never text/plain.
check cloud "cloud.fxmq.net" "/"        "200 301 302 307 308" html "Nextcloud answers"
check vault "vault.fxmq.net" "/"        "200 301 302 307 308" html "Vaultwarden answers"
check kuma  "kuma.fxmq.net"  "/"        "200 301 302 307 308" html "Uptime Kuma answers"

# talk.fxmq.net — Talk HPB + TURN. The backend API must answer with the
# signaling server's Welcome JSON and the client websocket route must reject
# an unauthenticated handshake (400/426/101). A bare `respond "ok"` stub
# returns 200 on both and fails here — the ok-stub guard for Talk.
check talk-root "talk.fxmq.net" "/" "200" "" "Talk signaling served"
talk_welcome=$(curl -s --max-time 12 --resolve "talk.fxmq.net:443:127.0.0.1" "https://talk.fxmq.net/signaling/api/v1/welcome" 2>/dev/null)
if ! echo "$talk_welcome" | grep -q '"Welcome"'; then
  echo "FAIL talk-signaling: /signaling/api/v1/welcome is not the signaling server: $(echo "$talk_welcome" | head -c 80)"; fails=1
else
  echo "ok   talk-signaling — HPB backend API answers"
fi
talk_ws=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 --resolve "talk.fxmq.net:443:127.0.0.1" \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  "https://talk.fxmq.net/signaling/spreed" 2>/dev/null)
if [ "$talk_ws" != "400" ] && [ "$talk_ws" != "426" ] && [ "$talk_ws" != "101" ]; then
  echo "FAIL talk-signaling: websocket handshake got HTTP $talk_ws (want 400/426/101 — signaling server must answer)"; fails=1
else
  echo "ok   talk-signaling — websocket endpoint answers ($talk_ws)"
fi

check mc-root     "mc.fxmq.net" "/"           "200 301 302 307 308" html "PufferPanel vhost home"
check mc-panel    "mc.fxmq.net" "/panel"      "200 301 302 307 308" html "panel SPA answers"
# In-browser Minecraft: /play must serve the eaglercraft client page. The
# /play/server websocket is not smoke-tested: the game server is not run
# 24/7, so a 502 when it's stopped is expected and must not fail the smoke.
check mc-play "mc.fxmq.net" "/play/" "200 301 302 307 308" html "browser Minecraft client"
check mail  "mail.fxmq.net" "/"        "200 301 302 307 308" html "Roundcube webmail"

# www: empty homepage (redirects to /welcome) + download drop folder.
check www          "www.fxmq.net" "/" "200 301 302 307 308" "" "homepage"
check www-download "www.fxmq.net" "/download/" "200 301 302 307 308" html "public drop folder browses"
check www-welcome "www.fxmq.net" "/welcome" "200 301 302 307 308" html "welcome page"

# Security-header integrity (the scan.nextcloud.com XFO/XCTO checks) — the
# header_down fix regressed once; these assertions make a regression fatal.
check_sec_headers cloud  "cloud.fxmq.net"  "/" "one of each"
check_sec_headers vault  "vault.fxmq.net"  "/" "one of each"
check_sec_headers kuma   "kuma.fxmq.net"   "/" "one of each"
check_sec_headers mail   "mail.fxmq.net"   "/" "one of each"
check_sec_headers mc     "mc.fxmq.net"     "/" "one of each"

hdr "Tailnet edge — tail.fxmq.net"
# tail is Tailscale-only: a non-tailnet source (this host's 127.0.0.1) must get 403.
check tail "tail.fxmq.net" "/" "403" "" "non-tailnet sources get 403"
# From the tailnet side (the host's own Tailscale IP passes the @not_tailnet
# matcher): the terminal serves unauthenticated, /ttyd challenges without
# credentials. A cached credential never short-circuits these — Caddy decides.
ts_ip="$(tailscale ip -4 2>/dev/null | head -1)"
if [ -n "$ts_ip" ]; then
  ta=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 --resolve "tail.fxmq.net:443:$ts_ip" "https://tail.fxmq.net/" 2>/dev/null)
  if [ "$ta" != 200 ] && [ "$ta" != 301 ] && [ "$ta" != 308 ]; then
    echo "FAIL tail-terminal: from a tailnet source got $ta (want 200)"; fails=1
  else
    echo "ok   tail-terminal: $ta — terminal serves tailnet devices"
  fi
  tt=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 --resolve "tail.fxmq.net:443:$ts_ip" "https://tail.fxmq.net/ttyd" 2>/dev/null)
  if [ "$tt" != "401" ]; then
    echo "FAIL tail-ttyd-auth: /ttyd without credentials got $tt (want 401 — basic auth must challenge)"; fails=1
  else
    echo "ok   tail-ttyd-auth: 401 — /ttyd challenges without credentials"
  fi
else
  echo "FAIL tailnet-edge: no Tailscale IP on this host — tailnet-side checks skipped"; fails=1
fi

hdr "TLS + mail platform"
# TLS issuer must stay Let's Encrypt (per-vhost DNS-01 ACME).
issuer=$(echo | timeout 6 openssl s_client -connect 127.0.0.1:443 -servername cloud.fxmq.net 2>/dev/null \
  | openssl x509 -noout -issuer 2>/dev/null)
if [[ "$issuer" != *"Let's Encrypt"* ]]; then
  echo "FAIL tls: cloud.fxmq.net cert issuer is not Let's Encrypt: $issuer"; fails=1
else
  echo "ok   tls — Let's Encrypt cert on cloud.fxmq.net"
fi

# SMTP 25/587 + IMAPS 993 must answer.
for port in 25 587; do
  banner=$(timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port; head -1 <&3" 2>/dev/null)
  if [[ "$banner" != 220* ]]; then
    echo "FAIL smtp:$port — no 220 banner: '$banner'"; fails=1
  else
    echo "ok   smtp:$port — Postfix 220 banner"
  fi
done
imaps=$(timeout 6 openssl s_client -connect 127.0.0.1:993 -quiet 2>/dev/null | head -1)
if [[ "$imaps" != "* OK"* ]]; then
  echo "FAIL imaps:993 — no Dovecot banner"; fails=1
else
  echo "ok   imaps:993 — Dovecot IMAPS banner"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PufferPanel lockdown — registration must stay closed and the admin account
# must exist. The 2026-08-30 incident: backend registration was open (the
# toggle lives in puffer/data/config.json, not the DB) and the edge 403 only
# covered the UI path, so POST /panel/auth/register (the API) was reachable.
# ─────────────────────────────────────────────────────────────────────────────
hdr "Panel lockdown"
check mc-reg-ui "mc.fxmq.net" "/panel/register" "403" "" "register UI blocked at the edge"
reg_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 --resolve "mc.fxmq.net:443:127.0.0.1" \
  -X POST "https://mc.fxmq.net/panel/auth/register" -H 'Content-Type: application/json' \
  -d '{"username":"smokeprobe","email":"smokeprobe@example.com","password":"smokeprobe"}' 2>/dev/null)
if [ "$reg_code" != "404" ] && [ "$reg_code" != "403" ]; then
  echo "FAIL panel-register-api: POST /panel/auth/register returned $reg_code (want 404/403 — registration must be closed)"; fails=1
else
  echo "ok   panel-register-api: $reg_code — API register path blocked"
fi

# Backend: config toggle off + admin account healthy (read-only, no hashes read).
if ! python3 - 2>&1 <<'PYEOF'
import json, sqlite3
cfg = json.load(open("/var/www/custom/projects/homelab/puffer/data/config.json"))
assert cfg.get("panel", {}).get("registrationenabled") is False, "panel.registrationenabled is not false"
con = sqlite3.connect("file:/var/www/custom/projects/homelab/puffer/data/pufferpanel.db?mode=ro", uri=True)
cur = con.cursor()
assert cur.execute("SELECT id FROM users WHERE id=1 AND email='admin@fxmq.net' AND password IS NOT NULL AND length(password)>=50").fetchone(), "admin user missing or hash empty"
assert cur.execute("SELECT id FROM permissions WHERE user_id=1 AND scopes LIKE '%admin%'").fetchone(), "admin permission missing"
con.close()
PYEOF
then
  echo "FAIL panel-lockdown: registration open or admin account broken (see above)"; fails=1
else
  echo "ok   panel-lockdown — registration closed + admin account healthy"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Host + containers — the stack the docs describe must actually be up: every
# running container, the three host units, the firewall, the NFS
# datadirectory (when fstab expects it), disk headroom and Nextcloud's
# maintenance state. Derived from the live system, not a hardcoded snapshot.
# ─────────────────────────────────────────────────────────────────────────────
hdr "Containers + host services"

expected=(fxmq.net nextcloud postgresql redis talk-hpb talk-relay vaultwarden uptimekuma pufferpanel mailserver roundcube)
missing=""
running="$(docker ps --format '{{.Names}}' 2>/dev/null)"
for c in "${expected[@]}"; do
  grep -qx "$c" <<<"$running" || missing="$missing $c"
done
if [ -n "$missing" ]; then
  echo "FAIL containers: not running:$missing"; fails=1
else
  echo "ok   containers — all ${#expected[@]} expected containers up"
fi

down=""
for u in ttyd dnsmasq goose; do
  [ "$(systemctl is-active "$u" 2>/dev/null)" = active ] || down="$down $u"
done
if [ -n "$down" ]; then
  echo "FAIL host-units: inactive:$down"; fails=1
else
  echo "ok   host-units — ttyd, dnsmasq, goose all active"
fi

ufw_state="$(sudo ufw status 2>/dev/null | head -1)"
if [[ "$ufw_state" != *"Status: active"* ]]; then
  echo "FAIL ufw: firewall not active ('$(sudo ufw status 2>/dev/null | head -1)')"; fails=1
else
  echo "ok   ufw — firewall active"
fi

# NFS datadirectory: only asserted when fstab expects the mount (no fstab
# entry = storage not onboarded; the check then passes vacuously).
if grep -q 'cloud/users' /etc/fstab 2>/dev/null; then
  if ! findmnt -n /var/www/custom/projects/homelab/cloud/users >/dev/null 2>&1; then
    echo "FAIL nfs-datadir: fstab expects cloud/users but it is not mounted"; fails=1
  else
    echo "ok   nfs-datadir — datadirectory mounted"
  fi
fi

disk_pcent="$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9')"
if [ -n "$disk_pcent" ] && [ "$disk_pcent" -ge 90 ]; then
  echo "FAIL disk: / is ${disk_pcent}% full (want < 90%)"; fails=1
else
  echo "ok   disk — / at ${disk_pcent:-?}% (< 90%)"
fi

nc_status="$(docker exec -u www-data nextcloud php occ status --output=json 2>/dev/null)"
if ! grep -q '"installed":true' <<<"$nc_status" || grep -q '"maintenance":true' <<<"$nc_status"; then
  echo "FAIL nc-status: Nextcloud not installed or stuck in maintenance mode"; fails=1
else
  echo "ok   nc-status — Nextcloud installed, out of maintenance mode"
fi

# coturn listeners: TURN (udp 3478) + TURNS (tcp 5349) must be bound.
if ss -lun 2>/dev/null | grep -q ':3478 ' && ss -ltn 2>/dev/null | grep -q ':5349 '; then
  echo "ok   talk-ports — coturn listening on 3478/udp + 5349/tcp"
else
  echo "FAIL talk-ports: coturn not listening on 3478/udp + 5349/tcp (is talk-relay up?)"; fails=1
fi

if [ "$fails" = 1 ]; then
  echo ""
  echo "SMOKE FAILED — the edge is not serving the apps. Fix before committing/pushing."
  exit 1
fi
echo ""
echo "SMOKE PASSED — every vhost serves its real app."