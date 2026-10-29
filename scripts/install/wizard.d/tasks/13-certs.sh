# wizard.d/tasks/13-certs.sh — `SSL Certificates`: LE issuance per public vhost + Mailu cert copy.

# ── ttyd door TLS ──────────────────────────────────────────────────────────
# ttyd.$DOMAIN is attempted through Let's Encrypt like every other vhost (the
# operator asked for a trusted cert there too — no `tls internal` any more).
# Unlike the public vhosts, its failure is NEVER fatal and never blocks smoke:
#   * the name is first auto-checked for public resolution — with no public
#     record there is no usable ACME identifier, so the order is skipped;
#   * a failed order (typically the Let's Encrypt per-identifier rate limit)
#     sets TAIL_TLS_FALLBACK, and the success block lists ONE follow-up:
#     run scripts/ops/tailscale-https.sh, which serves the door over
#     Tailscale HTTPS instead (web address becomes
#     https://<machine>.<tailnet>.ts.net — different by design).

# Issuer of the cert Caddy presents for one vhost, polled while ACME finishes.
cert_issuer_now() {
  # Single-shot check (no polling): is a cert already being served for $1.$DOMAIN?
  echo | timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "$1.$DOMAIN" 2>/dev/null \
    | openssl x509 -noout -issuer 2>/dev/null | cut -d'=' -f2-
}

cert_issuer() {
  local h="$1" i=0 iss=""
  while [ $i -lt 45 ]; do
    iss=$(echo | timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "$h.$DOMAIN" 2>/dev/null \
      | openssl x509 -noout -issuer 2>/dev/null | cut -d'=' -f2-)
    # Any non-empty issuer counts: the vhost tls blocks carry a fallback chain
    # (Let's Encrypt -> Buypass -> ZeroSSL), so a rate-limited LE order is
    # legitimately replaced by another free provider's cert — that is success,
    # not a stuck order (2026-10-19).
    [ -n "$iss" ] && break
    i=$((i+2)); sleep 2
  done
  echo "$iss"
}

issue_certs() {
  local hosts="" h iss pending=()
  TAIL_TLS_FALLBACK=false
  hosts="www"
  mod_on cloud   && hosts="$hosts cloud"
  mod_on cloud   && hosts="$hosts nextcloud"
  mod_on cloud && [ "${VIDEO_CALLING:-true}" != "false" ] && hosts="$hosts talk"
  mod_on vault   && hosts="$hosts vault"
  mod_on monitor && hosts="$hosts kuma"
  mod_on home    && hosts="$hosts home"
  mod_on mail    && hosts="$hosts mail"
  mod_on mail    && hosts="$hosts mailu"
  # ttyd.$DOMAIN joins the attempt like every other vhost. DNS-01 does not
  # need a public A record (Caddy answers the TXT challenge directly), and NO
  # DNS record is created for ttyd.$DOMAIN by design — it stays tailnet-only.
  # Every provider in the fallback chain gets its one attempt before the
  # tailscale-https follow-up is even considered (2026-10-19).
  hosts="$hosts ttyd"
  # Never re-issue an already-successful cert: a host that already serves one
  # is skipped entirely — no trigger request, no order, no poll (each ACME
  # order counts against provider rate limits even when answered from cache,
  # 2026-10-19).
  local fresh=() iss
  for h in $hosts; do
    iss=$(cert_issuer_now "$h")
    if [ -n "$iss" ]; then
      detail "  $h.$DOMAIN cert already issued ($iss) — not re-issuing"
    else
      fresh+=("$h")
    fi
  done
  hosts="${fresh[*]}"
  [ -z "$hosts" ] && return 0
  for h in $hosts; do
    curl -sk --resolve "$h.$DOMAIN:443:127.0.0.1" -o /dev/null "https://$h.$DOMAIN/" >>"$LOG" 2>&1 || true
    sleep 3
  done
  # The trigger requests above only wake Caddy up — the first DNS-01 issuance
  # is not instant, so cert_issuer polls before declaring failure. The two
  # outcomes are NOT the same and must not be treated as one:
  #   * empty issuer  = Caddy has not finished issuing yet (normal warm-up);
  #                     wait it out, never restart the edge for it.
  #     Any non-empty issuer is success — the fallback chain (LE -> Buypass ->
  #     ZeroSSL) may legitimately serve a non-LE cert when LE rate-limits.
  # Restarting on the empty case alone killed every live connection for nothing.
  local stuck=() h2
  for h in $hosts; do
    iss=$(cert_issuer "$h")
    case "$iss" in
      "") pending+=("$h") ;;
      *)  detail "  $h.$DOMAIN cert issued by: $iss";;
    esac
  done
  if [ ${#pending[@]} -gt 0 ]; then
    detail "  ${#pending[@]} cert(s) still issuing (${pending[*]}) — waiting for Caddy to finish"
    for h2 in "${pending[@]}"; do
      case "$(cert_issuer "$h2")" in "" ) stuck+=("$h2");; esac
    done
  fi
  # ONE issuance attempt per provider per run: the trigger round above is the
  # only wake-up, and Caddy's fallback chain (LE -> Buypass -> ZeroSSL) is
  # tried exactly once. There is deliberately NO restart/re-attempt — repeated
  # order attempts are what piles up against the per-provider rate limits
  # (LE 429, 2026-10-19). If an order is still pending, we only WAIT (the
  # final loop polls again); if every provider exhausted its one attempt, the
  # run fails with the follow-up, not another order.
  for h in $hosts; do
    [ "$h" = ttyd ] && continue   # non-fatal: handled below
    iss=$(cert_issuer "$h")
    case "$iss" in
      "" ) fail "cert_$h" "no cert issued for $h.$DOMAIN (one attempt per issuer made — wait out the provider rate limit and re-run)";;
      *)   detail "  $h.$DOMAIN cert issuer: $iss";;
    esac
  done
  # ttyd.$DOMAIN: a failed order must not abort the install. tailscale-https
  # is ONLY a last resort — advised as a WARN after every provider in the
  # fallback chain had its single attempt (2026-10-19).
  case " $hosts " in *" ttyd "*)
    if [ -z "$(cert_issuer ttyd)" ]; then
      TAIL_TLS_FALLBACK=true
      if docker logs caddy 2>&1 | grep -qi "rate limit"; then
        warn cert_ttyd "ttyd.$DOMAIN no issuer in the fallback chain issued a cert (rate-limited) — last resort: scripts/ops/tailscale-https.sh"
      else
        warn cert_ttyd "ttyd.$DOMAIN cert did not issue from any fallback issuer — last resort: scripts/ops/tailscale-https.sh"
      fi
    else
      detail "  ttyd.$DOMAIN cert issued by: $(cert_issuer ttyd)"
    fi
  ;; esac
}


# SSL Certificates: trigger + verify LE issuance for every vhost.
# Mailu front expects /certs/cert.pem + key.pem (TLS_FLAVOR=mail). Copy the
# mail.$DOMAIN LE cert out of caddy_data after issuance and restart front so it
# picks the renewed file up. Idempotent.
mail_tls_certs() {
  mod_on mail || return 0
  # One name, one cert: mail.$DOMAIN is mailu-front's own hostname — Roundcube's
  # public web door, the name the MX/SPF point at, and the cert the front loads
  # for SMTP/IMAP (TLS_FLAVOR=mail), so SNI and CN agree. The cert may sit under ANY
  # issuer directory (LE acme-v02, Buypass or ZeroSSL fallback), so search them
  # all instead of hard-coding the LE path.
  local d="" base f
  for f in "$DATA"/caddy_data/caddy/certificates/*/mail.$DOMAIN/mail.$DOMAIN.crt; do
    [ -s "$f" ] && { d="${f%/*}"; break; }
  done
  local i=0
  while [ $i -lt 30 ] && [ -z "$d" ]; do
    sleep 2; i=$((i+2))
    for f in "$DATA"/caddy_data/caddy/certificates/*/mail.$DOMAIN/mail.$DOMAIN.crt; do
      [ -s "$f" ] && { d="${f%/*}"; break; }
    done
  done
  [ -n "$d" ] || { log "  mail cert not issued yet — Mailu keeps the previous cert"; return 0; }
  install -d -m 0755 "$DATA/mailserver/certs"
  # Idempotency: restart mailu-front only when the cert actually changed
  # (byte-identical cert/key on a re-run must not bounce the mail edge).
  if cmp -s "$d/mail.$DOMAIN.crt" "$DATA/mailserver/certs/cert.pem" \
     && cmp -s "$d/mail.$DOMAIN.key" "$DATA/mailserver/certs/key.pem"; then
    detail "  TLS cert unchanged (mail.$DOMAIN — SMTP/IMAP cert) — no restart"
    return 0
  fi
  cp -f "$d/mail.$DOMAIN.crt" "$DATA/mailserver/certs/cert.pem"
  cp -f "$d/mail.$DOMAIN.key" "$DATA/mailserver/certs/key.pem"
  chmod 0644 "$DATA/mailserver/certs/cert.pem"
  chmod 0600 "$DATA/mailserver/certs/key.pem"
  docker restart mailu-front >>"$LOG" 2>&1 || true
  detail "  TLS cert installed (mail.$DOMAIN — SMTP/IMAP cert on the public mail door)"
}

task_certs() {
  task_start
  issue_certs
  mail_tls_certs
  task_end
}
