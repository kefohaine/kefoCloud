#!/usr/bin/env bash
# Live smoke test for every vhost + the mail platform + the host services —
# run ONLY on a finished install, structured per MODULE.
#
# GATE: data/wizard.state must record finished=true, else the suite refuses to
# run (exit 1) before checking anything. smoke is the LAST "is everything done?"
# source, not a diagnostic for a host mid-install — and there is NO bypass
# (a pre-push hook on an unfinished host therefore always fails: intentional).

#
# Module awareness: the roster comes from config/modules.conf; the enabled set
# from data/wizard.state via scripts/lib/modules.sh — the ONE accessor. Every
# check still runs factually. The CORE sections (edge, host) and every
# installed (enabled) module section print inline, and only they decide the
# exit code. A NOT-INSTALLED module's section is buffered and never printed
# inline: if any of its checks failed, that whole section appears ONCE more, at
# the end, under one "Not installed / ignored" heading — listed but not
# counted. No check prints twice.
#
# VOCABULARY: an installed module is expected; a not-installed one is ABSENT —
# no container, no data, no route.
#
# Fails (exit 1) when an enabled module stops serving its real app (e.g. a bare
# `respond "ok"` stub — the 2026-08-28 incident), the edge misbehaves,
# the mail platform or a container is down, or the host units/firewall drift.
# Run after any change to modules/caddy/ or after `docker restart caddy`. The
# pre-push hook runs this automatically.

. "$(dirname "$(readlink -f "$0")")/../lib/instance.sh" 2>/dev/null || true
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/scripts/lib/modules.sh"
mod_in() { mod_installed "$1"; }

# ttyd.$DOMAIN is not probed at all (see the core section below).

FIN="$(mod_finished)"
if [ "$FIN" != "true" ]; then
  echo "smoke: wizard.state is not finished ('${FIN:-absent}') — refusing to run."
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
echo "modules installed: ${inst:-none}${mods_absent:+· not installed: ${mods_absent% }} (wizard.state)"

fails=0
IGNORED=""
ignored_total=0
sec_mod=core
sec_title=""
sec_fails=0
sec_buf=""
sec_buf_on=""
sec_disabled=""

# say <line> — print now for a core/enabled section, buffer for a not-installed
# one.
say() {
  if [ -n "$sec_buf_on" ]; then sec_buf+="$1"$'\n'
  else printf '%s\n' "$1"; fi
}
bad() { sec_fails=$((sec_fails+1)); }

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
# The host's own Tailscale address — the SOURCE for tailnet-only probes
# (vault.$DOMAIN, mail.$DOMAIN).
TS_IP="$(tailscale ip -4 2>/dev/null | head -n1)"

# check <name> <host> <path> <want-codes...> [html] [desc]
# want-codes: space-separated acceptable HTTP codes; trailing "html" asserts
# the response must NOT be text/plain (the ok-stub signature). desc is a
# short plain-words description printed after `ok` so the suite reads as a
# checklist, not a table of paths.
check() {
  local name="$1" host="$2" path="$3" codes="$4" want_html="${5:-}" desc="${6:-}" insecure="${7:-}"
  local code ct
  local args=(--resolve "$host:443:127.0.0.1")
  [ "$insecure" = insecure ] && args+=(-k)
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

# check_tn <name> <host> <path> <want-codes> [html] [desc] — same probe, but
# sourced from the host's Tailscale address, so it arrives on tailnet-only
# routes (the @not_tailnet guard sees 100.64.0.0/10). Used for vault.$DOMAIN,
# whose door only exists inside the tailnet.
check_tn() {
  local name="$1" host="$2" path="$3" codes="$4" want_html="${5:-}" desc="${6:-}"
  local code ct
  local args=(--interface "$TS_IP" --resolve "$host:443:$TS_IP")
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 "${args[@]}" "https://$host$path")
  ct=$(curl -s -o /dev/null -w '%{content_type}' --max-time 12 "${args[@]}" "https://$host$path")
  local ok=0 c
  for c in $codes; do [ "$code" = "$c" ] && ok=1; done
  if [ "$ok" != 1 ]; then
    say "FAIL $name: got HTTP $code (want: $codes) — tailnet https://$host$path"; bad
  elif [ "$want_html" = html ] && [ "$code" = "200" ] && [[ "$ct" == text/plain* ]]; then
    say "FAIL $name: 200 text/plain response (stubbed?) — tailnet https://$host$path"; bad
  else
    say "ok   $name: $code $ct${desc:+ — }$desc"
  fi
}

# Security headers: every app vhost must serve EXACTLY ONE of each — Caddy's
# `header` directive appends to upstream values (a same-field delete+set even
# ends up deleted), so the fix is header_down at the proxy + a set-only
# snippet. A regression (missing or duplicated XFO/XCTO/HSTS — the
# header scans flag) must fail the smoke and block the push.
check_sec_headers() {
  local name="$1" host="$2" path="${3:-/}" desc="${4:-}"
  local args=(--resolve "$host:443:127.0.0.1" -sI --max-time 12)
  local hdrs xfo xcto hsts
  hdrs=$(curl "${args[@]}" "https://$host$path")
  xfo=$(grep -icE '^x-frame-options: SAMEORIGIN' <<<"$hdrs")
  xcto=$(grep -icE '^x-content-type-options: nosniff' <<<"$hdrs")
  hsts=$(grep -icE '^strict-transport-security: max-age=31536000' <<<"$hdrs")
  if [ "$xfo" != 1 ] || [ "$xcto" != 1 ] || [ "$hsts" != 1 ]; then
    say "FAIL $name sec-headers: xfo=$xfo xcto=$xcto hsts=$hsts (want exactly 1 each) — https://$host$path"; bad
  else
    say "ok   $name sec-headers${desc:+ — }$desc"
  fi
}

# check_tls <host> — the per-vhost DNS-01 ACME chain must keep issuing certs.
# The vhost tls blocks carry a fallback issuer chain (Let's Encrypt -> Buypass
# Go SSL -> ZeroSSL), so any non-empty issuer is success; a rate-limited LE
# order is legitimately replaced by another free provider.
check_tls() {
  local host="$1" issuer
  issuer=$(echo | timeout 6 openssl s_client -connect 127.0.0.1:443 -servername "$host" 2>/dev/null \
    | openssl x509 -noout -issuer 2>/dev/null)
  if [[ -z "$issuer" ]]; then
    say "FAIL tls:$host — no cert served"; bad
  elif [[ "$issuer" != *"Let's Encrypt"* ]]; then
    say "ok   tls:$host — fallback issuer: $(printf '%s' "$issuer" | head -c 120)"
  else
    say "ok   tls:$host — Let's Encrypt"
  fi
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
# Core — the Caddy edge and www. Always expected.
# ─────────────────────────────────────────────────────────────────────────────
hdr core "Edge — Caddy · www (core)"
check_ctns edge "caddy"

# www: the instance homepage + the drop folder + every page the operator has
# actually put in the web root ($DATA/pages/www). Derived from the files present, so
# no page name is hardcoded and a fresh install (placeholder page only) passes.
check apex         "$DOMAIN"     "/"          "200 301 302 307 308" ""    "bare domain reaches the homepage"
check www          "www.$DOMAIN" "/"          "200 301 302 307 308" ""    "homepage"
check www-download "www.$DOMAIN" "/download/" "200 301 302 307 308" html "public drop folder browses"
for f in "$ROOT/data/pages/www"/*.html; do
  [ -f "$f" ] || continue
  pg="$(basename "$f" .html)"
  case "$pg" in index) continue ;; esac
  check "www-$pg" "www.$DOMAIN" "/$pg" "200 301 302 307 308" html "$pg page"
done
check_tls "www.$DOMAIN"
# chat.$DOMAIN and matrix.$DOMAIN belong to the chat module and are asserted in
# its own section below.


# ttyd.$DOMAIN is deliberately NOT in smoke: it is tailnet-only and its LE
# order may legitimately be pending or rate-limited (the remedy is the
# scripts/ops/tailscale-https.sh follow-up), so it must never gate a push.
# The host unit behind it is asserted in the Host section.
end_sec

# ─────────────────────────────────────────────────────────────────────────────
# Module: ocis — ownCloud Infinite Scale (single container, own store).
# cloud.$DOMAIN is its door: oCIS serves its own web UI at / and generates
# root-absolute URLs from OCIS_URL, so any other path prefix would break it.
# ─────────────────────────────────────────────────────────────────────────────
hdr ocis "Cloud — ownCloud Infinite Scale (module: ocis) · cloud.$DOMAIN"
check ocis "cloud.$DOMAIN" "/" "200 301 302 307 308" html "oCIS web UI answers"
check_sec_headers ocis "cloud.$DOMAIN" "/" "one of each"
check_tls "cloud.$DOMAIN"
check_ctns ocis ocis
end_sec

# ─────────────────────────────────────────────────────────────────────────────
# Module: chat — Matrix (Synapse + Element + PostgreSQL). chat.$DOMAIN serves
# Element (a static browser app), matrix.$DOMAIN serves the homeserver's
# client-server API. Both are public: Element is proxied, Synapse is DNS-only.
# ─────────────────────────────────────────────────────────────────────────────
hdr chat "Chat — Matrix (module: chat) · chat.$DOMAIN + matrix.$DOMAIN"
check chat "chat.$DOMAIN" "/" "200 301 302 307 308" html "Element answers"
check_sec_headers chat "chat.$DOMAIN" "/" "one of each"
check_tls "chat.$DOMAIN"
# /_matrix/client/versions is the one route every client calls first; a bare
# `respond "ok"` stub answers 200 text/plain and fails this html-typed check.
check matrix-api "matrix.$DOMAIN" "/_matrix/client/versions" "200" "" "Synapse client API answers"
check_sec_headers matrix "matrix.$DOMAIN" "/_matrix/client/versions" "one of each"
check_tls "matrix.$DOMAIN"
check_ctns chat matrix-synapse matrix-element matrix-db
end_sec

# ─────────────────────────────────────────────────────────────────────────────
# Module: kopia — backup server. kopia.$DOMAIN is TAILNET-ONLY: both halves are
# asserted (a public source gets 403, a tailnet source gets the UI), so a
# half-applied change fails here instead of passing on one side.
# ─────────────────────────────────────────────────────────────────────────────
hdr kopia "Backup — Kopia (module: kopia) · kopia.$DOMAIN (tailnet-only)"
if [ -z "$TS_IP" ]; then
  say "FAIL kopia: no Tailscale IPv4 — cannot probe the tailnet-only door"; bad
else
  check_tn kopia "kopia.$DOMAIN" "/" "200 301 302 307 308" html "Kopia UI answers on the tailnet"
fi
check kopia-public "kopia.$DOMAIN" "/" "403" "" "public sources are refused"
check_tls "kopia.$DOMAIN"
check_ctns kopia kopia
end_sec

# ─────────────────────────────────────────────────────────────────────────────
# Module: vault — Vaultwarden.
# ─────────────────────────────────────────────────────────────────────────────
hdr vault "Vault — Vaultwarden (module: vault)"
# Tailnet-only since 2026-10-28 — and both halves are asserted, so a
# half-applied change (gate added, route gone, or the reverse) fails here
# instead of passing on one side: a public source gets 403, a tailnet source
# gets Vaultwarden itself.
if [ -z "$TS_IP" ]; then
  say "FAIL vault: no Tailscale IPv4 — cannot probe a tailnet-only door"; bad
else
  check_tn vault "vault.$DOMAIN" "/" "200 301 302 307 308" html "Vaultwarden answers on the tailnet"
  check vault-public "vault.$DOMAIN" "/" "403" "" "public sources are refused"
fi
check_sec_headers vault "vault.$DOMAIN" "/" "one of each"
check_tls "vault.$DOMAIN"
check_ctns vault vaultwarden
end_sec

# ─────────────────────────────────────────────────────────────────────────────
# Module: home — Homarr at home.$DOMAIN.
# ─────────────────────────────────────────────────────────────────────────────
hdr home "Home — Homarr dashboard (module: home)"
# Homarr is a Next.js app: its assets are ROOT-absolute (/_next/...), so it
# cannot be served under a path and owns a hostname of its own.
check home "home.$DOMAIN" "/" "200 301 302 307 308" "" "Homarr answers (board or login redirect)"
check home-login "home.$DOMAIN" "/auth/login" "200" html "Homarr login page renders"
check_sec_headers home "home.$DOMAIN" "/"
check_tls "home.$DOMAIN"
check_ctns home homarr
end_sec

# ─────────────────────────────────────────────────────────────────────────────
# Module: blog — WriteFreely on its own vhost.
# ─────────────────────────────────────────────────────────────────────────────
hdr blog "Blog — WriteFreely (module: blog)"
check blog "blog.$DOMAIN" "/" "200" html "WriteFreely answers"
check blog-login "blog.$DOMAIN" "/login" "200" html "WriteFreely login page"
check_sec_headers blog "blog.$DOMAIN" "/" "one of each"
check_tls "blog.$DOMAIN"
check_ctns blog writefreely
end_sec

# ─────────────────────────────────────────────────────────────────────────────
# Module: photos — Immich (DNS-only vhost, its own PostgreSQL + Redis).
# ─────────────────────────────────────────────────────────────────────────────
hdr photos "Photos — Immich (module: photos)"
check photos "photos.$DOMAIN" "/" "200 301 302 307 308" html "Immich web answers"
check photos-api "photos.$DOMAIN" "/api/server/ping" "200" "" "Immich API answers"
check_sec_headers photos "photos.$DOMAIN" "/" "one of each"
check_tls "photos.$DOMAIN"
check_ctns photos immich-server immich-db immich-redis
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
# Module: mail — Mailu (front/smtp/imap/antispam/admin/redis) + Roundcube webmail.
# ─────────────────────────────────────────────────────────────────────────────
hdr mail "Mail — Mailu platform + Roundcube webmail (module: mail)"
# mail.$DOMAIN is the PUBLIC mail door (Roundcube's web UI, and the name
# mailu-front publishes 25/465/587/993 on); mailu.$DOMAIN is the platform door
# and TAILNET-ONLY (same model as vault): no public A record, and the vhost 403s
# every source outside 100.64.0.0/10. Both halves are asserted, so a
# half-applied change fails here instead of passing.
check mail "mail.$DOMAIN" "/" "200 301 302 307 308" html "Roundcube webmail"
check_sec_headers mail "mail.$DOMAIN" "/" "one of each"
check_tls "mail.$DOMAIN"
if [ -z "$TS_IP" ]; then
  say "FAIL mailu: no Tailscale IPv4 — cannot probe a tailnet-only door"; bad
else
  check_tn mailu "mailu.$DOMAIN" "/" "200 301 302 307 308" html "Mailu platform door answers on the tailnet"
fi
check mailu-public "mailu.$DOMAIN" "/" "403" "" "public sources are refused"
check_sec_headers mailu "mailu.$DOMAIN" "/" "one of each"
check_tls "mailu.$DOMAIN"

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

check_ctns mail mailu-front mailu-imap mailu-smtp mailu-antispam mailu-admin mailu-redis roundcube
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
# smoke never touches wizard.state: its exit code IS the verdict, and the ONLY
# thing that may act on that verdict is the installer (the sole writer of
# wizard.state). An operator's `make smoke` and the pre-push hook just report.
if [ "$fails" -gt 0 ]; then
  echo "SMOKE FAILED — $fails failing check(s) in core / enabled modules. Fix before committing/pushing."
  exit 1
fi
echo "SMOKE PASSED — core + every enabled module serves its real app."
exit 0
