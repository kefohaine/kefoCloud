#!/usr/bin/env bash
# Live smoke test for every vhost + the mail platform + the host services —
# run ONLY on a finished install, structured per MODULE.
#
# GATE: data/install.state must record finished=true, else the suite refuses to
# run (exit 1) before checking anything. smoke is the LAST "is everything done?"
# source, not a diagnostic for a host mid-install — and there is NO bypass
# (a pre-push hook on an unfinished host therefore always fails: intentional).

#
# Module awareness: the roster comes from config/modules.conf; the enabled set
# from data/install.state via scripts/lib/modules.sh — the ONE accessor. Every
# check still runs factually. The CORE sections (edge, host) and every
# installed (enabled) module section print inline, and only they decide the
# exit code. A NOT-INSTALLED module's section is buffered and never printed
# inline: if any of its checks failed, that whole section appears ONCE more, at
# the end, under one "Not installed / ignored" heading — listed but not
# counted. No check prints twice. The same buffered-ignored treatment is used
# for one CORE block when install.state says the tail door is on an emergency
# Tailscale cert (soft_begin/soft_end): its failures are moved aside, never
# counted.
#
# VOCABULARY: an installed module is expected; a not-installed one is ABSENT —
# no container, no data, no route. It is NOT "tailnet-only" (a property of the
# one route that really is tailnet-only, tail.$DOMAIN, checked in the edge).
#
# Fails (exit 1) when an enabled module stops serving its real app (e.g. a bare
# `respond "ok"` stub — the 2026-08-28 incident), the edge misbehaves (tail 403),
# the mail platform or a container is down, or the host units/firewall drift.
# Run after any change to modules/caddy/ or after `docker restart caddy`. The
# pre-push hook runs this automatically.

. "$(dirname "$(readlink -f "$0")")/../lib/instance.sh" 2>/dev/null || true
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/scripts/lib/modules.sh"
mod_in() { mod_installed "$1"; }

# The tail door's TLS state, read from install.state (the installer is its sole
# writer): normally tail.$DOMAIN on a Let's Encrypt cert, but after an LE
# per-identifier rate limit that ONE door is rolled back to the machine's own
# Tailscale HTTPS name with an emergency `tailscale cert`. The cert check stays
# CORE whatever the door; the functional tail checks stay on tail.$DOMAIN and,
# while the door is rolled back, their failures are moved to the ignored
# section. No other vhost reads this.
TAIL_CERT_ISSUER="$(state_get TAIL_CERT_ISSUER)"; TAIL_CERT_ISSUER="${TAIL_CERT_ISSUER:-acme}"
TS_CERT_HOST="$(state_get TS_CERT_HOST)"
TAIL_ROLLBACK=0
if [ "$TAIL_CERT_ISSUER" = tailscale ] && [ -n "$TS_CERT_HOST" ]; then
  TAIL_ROLLBACK=1; TAIL_DOOR="$TS_CERT_HOST"
else
  TAIL_DOOR="tail.$DOMAIN"
fi

FIN="$(mod_finished)"
if [ "$FIN" != "true" ]; then
  echo "smoke: install.state is not finished ('${FIN:-absent}') — refusing to run."
  echo "  make smoke only runs on a finished install (enabled_modules + finished=true in $INSTALL_STATE)."
  echo "  Finish an install first; there is no bypass."
  exit 1
fi

inst=""
mods_absent=""          # declared: the end section reads it under `set -u`,
                        # and with every module installed nothing assigns it
while read -r m; do
  [ -n "$m" ] || continue
  mod_installed "$m" && inst+="$m " || mods_absent="${mods_absent:-}${m} "
done < <(mod_all)
echo "modules installed: ${inst:-none}${mods_absent:+· not installed: ${mods_absent% }} (install.state)"

fails=0
IGNORED=""
ignored_total=0
sec_mod=core
sec_title=""
sec_fails=0
sec_buf=""
sec_buf_on=""
sec_disabled=""

soft_on=""; soft_fails=0; soft_buf=""; soft_reason=""

# say <line> — print now for a core/enabled section, buffer for a not-installed
# one, or buffer for a soft (ignored-on-failure) block.
say() {
  if [ -n "$soft_on" ]; then soft_buf+="$1"$'\n'
  elif [ -n "$sec_buf_on" ]; then sec_buf+="$1"$'\n'
  else printf '%s\n' "$1"; fi
}
bad() {
  if [ -n "$soft_on" ]; then soft_fails=$((soft_fails+1)); else sec_fails=$((sec_fails+1)); fi
}

# soft_begin <reason> / soft_end — a block of checks whose FAILURES must not
# fail the run: they are moved ONCE into the end-of-report "ignored" section
# (listed, not counted), while a clean block prints inline. Used for the tail
# door's functional checks once the installer has rolled that one door back to an
# emergency Tailscale cert (install.state TAIL_CERT_ISSUER=tailscale).
soft_begin() { soft_on=1; soft_fails=0; soft_buf=""; soft_reason="$1"; }
soft_end() {
  [ -n "$soft_on" ] || return 0
  if [ "$soft_fails" -gt 0 ]; then
    IGNORED+="== $soft_reason =="$'\n'"$soft_buf"$'\n'
    ignored_total=$((ignored_total + soft_fails))
  else
    printf '%s' "$soft_buf"
  fi
  soft_on=""; soft_fails=0; soft_buf=""
}

# hdr <module|core> <title> — core/enabled sections print their heading and
# every line immediately; a not-installed module's section is buffered instead.
hdr() {
  sec_mod="$1"; sec_title="$2"; sec_fails=0; sec_buf=""
  if [ "$1" != core ] && ! mod_in "$1"; then
    sec_buf_on=1; sec_disabled=1
  else
    sec_buf_on=""; sec_disabled=""
    echo ""; echo "== $2 =="
  fi
}
# end_sec — close the section: enabled/core failures count toward the exit;
# a not-installed module's failures move (once) into the end-of-report section and
# never count.
end_sec() {
  if [ -n "$sec_disabled" ]; then
    if [ "$sec_fails" -gt 0 ]; then
      IGNORED+="== $sec_title — module '$sec_mod' not installed (ignored) =="$'\n'"$sec_buf"$'\n'
      ignored_total=$((ignored_total + sec_fails))
    fi
    sec_buf=""; sec_buf_on=""; sec_disabled=""
    return
  fi
  fails=$((fails + sec_fails))
}

RUNNING="$(docker ps --format '{{.Names}}' 2>/dev/null)"

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
    say "FAIL $name: got HTTP $code (want: $codes) — https://$host$path"; bad
  elif [ "$want_html" = html ] && [ "$code" = "200" ] && [[ "$ct" == text/plain* ]]; then
    # The ok-stub signature is a 200 with a text/plain body. A 3xx redirect
    # legitimately carries a text/plain (empty) body — only flag 200s.
    say "FAIL $name: 200 text/plain response (stubbed?) — https://$host$path"; bad
  else
    say "ok   $name: $code $ct${desc:+ — }$desc"
  fi
}

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
    say "FAIL $name sec-headers: xfo=$xfo xcto=$xcto hsts=$hsts (want exactly 1 each) — https://$host$path"; bad
  else
    say "ok   $name sec-headers${desc:+ — }$desc"
  fi
}

# check_tls <host> — the per-vhost DNS-01 ACME must keep issuing LE certs.
check_tls() {
  local host="$1" issuer
  issuer=$(echo | timeout 6 openssl s_client -connect 127.0.0.1:443 -servername "$host" 2>/dev/null \
    | openssl x509 -noout -issuer 2>/dev/null)
  if [[ "$issuer" != *"Let's Encrypt"* ]]; then
    say "FAIL tls:$host — issuer is not Let's Encrypt: $issuer"; bad
  else
    say "ok   tls:$host — Let's Encrypt"
  fi
}

# check_tls_cert <host> — the door's cert must be the one the installer chose (from
# install.state): a Let's Encrypt cert (a normal DNS-01 cert AND a `tailscale
# cert` are both LE-issued) that actually COVERS the host. A missing or
# mismatched cert is what makes the functional checks return 000; failing here
# names the cause. Always a CORE check (the door's cert is never ignorable).
check_tls_cert() {
  local host="$1" pem iss san
  pem=$(echo | timeout 6 openssl s_client -connect 127.0.0.1:443 -servername "$host" 2>/dev/null)
  iss=$(printf '%s' "$pem" | openssl x509 -noout -issuer 2>/dev/null)
  san=$(printf '%s' "$pem" | openssl x509 -noout -ext subjectAltName 2>/dev/null)
  if [[ "$iss" != *"Let's Encrypt"* ]]; then
    say "FAIL tls:$host — issuer is not Let's Encrypt: ${iss:-<none>}"; bad; return
  fi
  if ! grep -q "DNS:$host" <<<"$san"; then
    say "FAIL tls:$host — cert does not cover $host (install.state: issuer=$TAIL_CERT_ISSUER)"; bad; return
  fi
  say "ok   tls:$host — Let's Encrypt cert covering the door ($TAIL_CERT_ISSUER)"
}

# check_ctns <desc> <names...> — every listed container must be running.
check_ctns() {
  local desc="$1"; shift
  local missing="" c
  for c in "$@"; do
    grep -qx "$c" <<<"$RUNNING" || missing="$missing $c"
  done
  if [ -n "$missing" ]; then
    say "FAIL containers($desc): not running:$missing"; bad
  else
    say "ok   containers($desc) — all $# up"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Core — the Caddy edge, www and the tailnet door. Always expected.
# ─────────────────────────────────────────────────────────────────────────────
hdr core "Edge — Caddy · www · tail (core)"
check_ctns edge "caddy"

# www: the instance homepage + the drop folder + every page the operator has
# actually put in the web root ($DATA/www). Derived from the files present, so
# no page name is hardcoded and a fresh install (placeholder page only) passes.
check www          "www.$DOMAIN" "/"          "200 301 302 307 308" ""    "homepage"
check www-download "www.$DOMAIN" "/download/" "200 301 302 307 308" html "public drop folder browses"
for f in "$ROOT/data/www"/*.html; do
  [ -f "$f" ] || continue
  pg="$(basename "$f" .html)"
  case "$pg" in index|tail) continue ;; esac
  check "www-$pg" "www.$DOMAIN" "/$pg" "200 301 302 307 308" html "$pg page"
done
check_tls "www.$DOMAIN"

# The tail door's cert — CORE: it must be the LE cert the installer chose,
# covering the door host install.state recorded (tail.$DOMAIN, or the machine's
# own Tailscale name after an LE rate-limit rollback).
check_tls_cert "$TAIL_DOOR"
say "     tail door: https://$TAIL_DOOR (issuer: $TAIL_CERT_ISSUER)"

# Functional tail checks — they probe the tail.$DOMAIN door. While the installer
# has it rolled back to an emergency cert (install.state issuer=tailscale) their
# failures are moved to the ignored section (the door is expected to differ) and
# only the cert check above counts; on a normal LE door they are core checks.
if [ "$TAIL_ROLLBACK" = 1 ]; then
  soft_begin "tail door rolled back to an emergency Tailscale cert (LE rate-limited tail.$DOMAIN — install.state)"
fi
# tail is Tailscale-only: a non-tailnet source (this host's 127.0.0.1) must get 403.
check tail "tail.$DOMAIN" "/" "403" "" "non-tailnet sources get 403"
# From the tailnet side (the host's own Tailscale IP passes the @not_tailnet
# matcher) everything on the vhost serves unauthenticated — including /ttyd:
# Tailscale membership is the ONLY gate (basic auth was removed 2026-09-22).
ts_ip="$(tailscale ip -4 2>/dev/null | head -1)"
if [ -n "$ts_ip" ]; then
  ta=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 --resolve "tail.$DOMAIN:443:$ts_ip" "https://tail.$DOMAIN/" 2>/dev/null)
  if [ "$ta" != 200 ] && [ "$ta" != 301 ] && [ "$ta" != 308 ]; then
    say "FAIL tail-terminal: from a tailnet source got $ta (want 200)"; bad
  else
    say "ok   tail-terminal: $ta — terminal serves tailnet devices"
  fi
  tt=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 --resolve "tail.$DOMAIN:443:$ts_ip" "https://tail.$DOMAIN/ttyd" 2>/dev/null)
  case "$tt" in
    200|301|302|307|308)
      say "ok   tail-ttyd: $tt — the shell serves tailnet devices without a second credential" ;;
    *)
      say "FAIL tail-ttyd: /ttyd got $tt (want a 2xx/3xx — the shell must NOT challenge; 401 means a credential crept back in)"; bad ;;
  esac
else
  say "FAIL tailnet-edge: no Tailscale IP on this host — tailnet-side checks skipped"; bad
fi
soft_end
end_sec

# ─────────────────────────────────────────────────────────────────────────────
# Module: cloud — Nextcloud (FPM app + PostgreSQL + Redis) + Talk HPB/TURN.
# ─────────────────────────────────────────────────────────────────────────────
hdr cloud "Cloud — Nextcloud + Talk (module: cloud)"
check cloud "cloud.$DOMAIN" "/" "200 301 302 307 308" html "Nextcloud answers"
check_sec_headers cloud "cloud.$DOMAIN" "/" "one of each"
check_tls "cloud.$DOMAIN"

# talk.$DOMAIN — Talk HPB + TURN. The backend API must answer with the
# signaling server's Welcome JSON and the client websocket route must reject
# an unauthenticated handshake (400/426/101). A bare `respond "ok"` stub
# returns 200 on both and fails here — the ok-stub guard for Talk.
check talk-root "talk.$DOMAIN" "/" "200" "" "Talk signaling served"
talk_welcome=$(curl -s --max-time 12 --resolve "talk.$DOMAIN:443:127.0.0.1" "https://talk.$DOMAIN/signaling/api/v1/welcome" 2>/dev/null)
if ! echo "$talk_welcome" | grep -q '"Welcome"'; then
  say "FAIL talk-signaling: /signaling/api/v1/welcome is not the signaling server: $(echo "$talk_welcome" | head -c 80)"; bad
else
  say "ok   talk-signaling — HPB backend API answers"
fi
talk_ws=$(curl -s -o /dev/null -w '%{http_code}' --http1.1 --max-time 12 --resolve "talk.$DOMAIN:443:127.0.0.1" \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  "https://talk.$DOMAIN/signaling" 2>/dev/null)
if [ "$talk_ws" != "400" ] && [ "$talk_ws" != "426" ] && [ "$talk_ws" != "101" ]; then
  say "FAIL talk-signaling: websocket handshake got HTTP $talk_ws (want 400/426/101 — signaling server must answer)"; bad
else
  say "ok   talk-signaling — websocket endpoint answers ($talk_ws)"
fi
check_tls "talk.$DOMAIN"

# coturn listeners: TURN (udp 3478) + TURNS (tcp 5349) must be bound. A re-run
# recreates the containers and smoke runs right after, so the relay may still be
# binding its ports — poll briefly (30 s) before failing, or a working install
# reports talk-ports on every re-run.
coturn_ok=""
for _ in $(seq 1 15); do
  if ss -lun 2>/dev/null | grep -q ':3478 ' && ss -ltn 2>/dev/null | grep -q ':5349 '; then
    coturn_ok=1; break
  fi
  sleep 2
done
if [ -n "$coturn_ok" ]; then
  say "ok   talk-ports — coturn listening on 3478/udp + 5349/tcp"
else
  say "FAIL talk-ports: coturn not listening on 3478/udp + 5349/tcp (is talk-relay up?)"; bad
fi

nc_status="$(docker exec -u www-data nextcloud php occ status --output=json 2>/dev/null)"
if ! grep -q '"installed":true' <<<"$nc_status" || grep -q '"maintenance":true' <<<"$nc_status"; then
  say "FAIL nc-status: Nextcloud not installed or stuck in maintenance mode"; bad
else
  say "ok   nc-status — Nextcloud installed, out of maintenance mode"
fi

check_ctns cloud nextcloud postgresql redis talk-hpb talk-relay
end_sec

# ─────────────────────────────────────────────────────────────────────────────
# Module: vault — Vaultwarden.
# ─────────────────────────────────────────────────────────────────────────────
hdr vault "Vault — Vaultwarden (module: vault)"
check vault "vault.$DOMAIN" "/" "200 301 302 307 308" html "Vaultwarden answers"
check_sec_headers vault "vault.$DOMAIN" "/" "one of each"
check_tls "vault.$DOMAIN"
check_ctns vault vaultwarden
end_sec

# ─────────────────────────────────────────────────────────────────────────────
# Module: monitor — Uptime Kuma.
# ─────────────────────────────────────────────────────────────────────────────
hdr monitor "Monitor — Uptime Kuma (module: monitor)"
check kuma "kuma.$DOMAIN" "/" "200 301 302 307 308" html "Uptime Kuma answers"
check_sec_headers kuma "kuma.$DOMAIN" "/" "one of each"
check_tls "kuma.$DOMAIN"
check_ctns monitor uptimekuma
end_sec

# ─────────────────────────────────────────────────────────────────────────────
# Module: mail — Docker Mailserver + Roundcube webmail.
# ─────────────────────────────────────────────────────────────────────────────
hdr mail "Mail — Docker Mailserver + Roundcube (module: mail)"
check mail "mail.$DOMAIN" "/" "200 301 302 307 308" html "Roundcube webmail"
check_sec_headers mail "mail.$DOMAIN" "/" "one of each"
check_tls "mail.$DOMAIN"

# SMTP 25/587 + IMAPS 993 must answer.
for port in 25 587; do
  banner=$(timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port; head -1 <&3" 2>/dev/null)
  if [[ "$banner" != 220* ]]; then
    say "FAIL smtp:$port — no 220 banner: '$banner'"; bad
  else
    say "ok   smtp:$port — Postfix 220 banner"
  fi
done
imaps=$(timeout 6 openssl s_client -connect 127.0.0.1:993 -quiet 2>/dev/null | head -1)
if [[ "$imaps" != "* OK"* ]]; then
  say "FAIL imaps:993 — no Dovecot banner"; bad
else
  say "ok   imaps:993 — Dovecot IMAPS banner"
fi

check_ctns mail mailserver roundcube
end_sec

# ─────────────────────────────────────────────────────────────────────────────
# Core — host services, firewall, storage and headroom. Always expected.
# ─────────────────────────────────────────────────────────────────────────────
hdr core "Host — units · firewall · storage · disk (core)"
down=""
for u in ttyd dnsmasq goose; do
  [ "$(systemctl is-active "$u" 2>/dev/null)" = active ] || down="$down $u"
done
if [ -n "$down" ]; then
  say "FAIL host-units: inactive:$down"; bad
else
  say "ok   host-units — ttyd, dnsmasq, goose all active"
fi

# git hooks — the repo guards must be installed (pre-commit: identity + edge
# stub guard; pre-push: smoke + history-rewrite warning). A missing hook means
# the guards are silently absent — the identity/edge protection is gone.
if [ -x "$ROOT/.git/hooks/pre-commit" ] && [ -x "$ROOT/.git/hooks/pre-push" ]; then
  say "ok   git-hooks — pre-commit + pre-push installed"
else
  say "FAIL git-hooks: pre-commit/pre-push not installed (run: make install-hooks)"; bad
fi

ufw_state="$(sudo ufw status 2>/dev/null | head -1)"
if [[ "$ufw_state" != *"Status: active"* ]]; then
  say "FAIL ufw: firewall not active ('$(sudo ufw status 2>/dev/null | head -1)')"; bad
else
  say "ok   ufw — firewall active"
fi

# NFS datadirectory: only asserted when fstab expects the mount (no fstab
# entry = storage not onboarded; the check then passes vacuously).
if grep -q 'cloud/users' /etc/fstab 2>/dev/null; then
  if ! findmnt -n $ROOT/data/cloud/users >/dev/null 2>&1; then
    say "FAIL nfs-datadir: fstab expects cloud/users but it is not mounted"; bad
  else
    say "ok   nfs-datadir — datadirectory mounted"
  fi
fi

disk_pcent="$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9')"
if [ -n "$disk_pcent" ] && [ "$disk_pcent" -ge 90 ]; then
  say "FAIL disk: / is ${disk_pcent}% full (want < 90%)"; bad
else
  say "ok   disk — / at ${disk_pcent:-?}% (< 90%)"
fi
end_sec

echo ""
# Every module not installed gets ONE shared section at the end, ALWAYS printed
# (informational only): its checks are listed, never counted toward the exit.
# The point is that a pending/failed install shows WHY in one place instead of
# scattering red across the report.
absent=""
for m in $mods_absent; do absent="$absent${absent:+, }$m"; done
if [ -n "${mods_absent:-}" ] || [ -n "$IGNORED" ]; then
  if [ -n "${mods_absent:-}" ]; then
    echo "== Not installed / ignored — module(s) not installed: ${mods_absent% } =="
    echo "   informational only, never counted — these modules are ABSENT (no container, no route)."
  else
    echo "== Not installed / ignored =="
    echo "   informational only, never counted."
  fi
  printf '%s' "$IGNORED"
  echo "   $ignored_total failing check(s) here, ${fails} failing check(s) in core / enabled modules."
  echo ""
fi
# smoke never touches install.state: its exit code IS the verdict, and the ONLY
# thing that may act on that verdict is the installer (the sole writer of
# install.state). An operator's `make smoke` and the pre-push hook just report.
if [ "$fails" -gt 0 ]; then
  echo "SMOKE FAILED — $fails failing check(s) in core / enabled modules. Fix before committing/pushing."
  exit 1
fi
echo "SMOKE PASSED — core + every enabled module serves its real app."
exit 0
