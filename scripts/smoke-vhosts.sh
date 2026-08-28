#!/usr/bin/env bash
# Live smoke test for every fxmq.net vhost + the mail platform.
# Fails (exit 1) if an app vhost stops serving its real app — e.g. someone
# stubs it with `respond "ok"` (the 2026-08-28 incident) or the container
# serving it is down. Run after any change to services/fxmq.net/ or after
# `docker restart fxmq.net`. The pre-push hook runs this automatically
# (override with SKIP_SMOKE=1 — not on a whim).
set -uo pipefail

fails=0
# check <name> <host> <path> <want-codes...> [html]
# want-codes: space-separated acceptable HTTP codes; trailing "html" asserts
# the response must NOT be text/plain (the ok-stub signature).
check() {
  local name="$1" host="$2" path="$3" codes="$4" want_html="${5:-}"
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
    echo "ok   $name: $code $ct"
  fi
}

# Public vhosts. App vhosts must answer with real content, never text/plain.
check cloud "cloud.fxmq.net" "/"        "200 301 302 307 308" html
check vault "vault.fxmq.net" "/"        "200 301 302 307 308" html
check kuma  "kuma.fxmq.net"  "/"        "200 301 302 307 308" html
check mc-root     "mc.fxmq.net" "/"           "200 301 302 307 308" html
check mc-panel    "mc.fxmq.net" "/panel"      "200 301 302 307 308" html
check mc-download "mc.fxmq.net" "/download/"  "200 301 302 307 308" html
check mail  "mail.fxmq.net" "/"        "200 301 302 307 308" html
# www is a health/landing stub BY DESIGN — just needs to answer.
check www   "www.fxmq.net" "/" "200 301 302 307 308"
# shell is Tailscale-only: a non-tailnet source (this host's 127.0.0.1) must get 403.
check shell "shell.fxmq.net" "/" "403"

# TLS issuer must stay Let's Encrypt (per-vhost DNS-01 ACME).
issuer=$(echo | timeout 6 openssl s_client -connect 127.0.0.1:443 -servername cloud.fxmq.net 2>/dev/null \
  | openssl x509 -noout -issuer 2>/dev/null)
if [[ "$issuer" != *"Let's Encrypt"* ]]; then
  echo "FAIL tls: cloud.fxmq.net cert issuer is not Let's Encrypt: $issuer"; fails=1
else
  echo "ok   tls: Let's Encrypt cert on cloud.fxmq.net"
fi

# Mail platform: SMTP 25/587 + IMAPS 993 must answer.
for port in 25 587; do
  banner=$(timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port; head -1 <&3" 2>/dev/null)
  if [[ "$banner" != 220* ]]; then
    echo "FAIL smtp:$port — no 220 banner: '$banner'"; fails=1
  else
    echo "ok   smtp:$port 220 banner"
  fi
done
imaps=$(timeout 6 openssl s_client -connect 127.0.0.1:993 -quiet 2>/dev/null | head -1)
if [[ "$imaps" != "* OK"* ]]; then
  echo "FAIL imaps:993 — no Dovecot banner"; fails=1
else
  echo "ok   imaps:993 Dovecot banner"
fi

if [ "$fails" = 1 ]; then
  echo "SMOKE FAILED — the edge is not serving the apps. Fix before committing/pushing."
  exit 1
fi
echo "SMOKE PASSED — every vhost serves its real app."
