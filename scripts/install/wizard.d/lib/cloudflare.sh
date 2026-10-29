# wizard.d/lib/cloudflare.sh — the Cloudflare API: A records (converging), SSL mode, mail MX/SPF/DMARC.

ssl_mode_full() {
  # API first (needs Zone Settings read on the token); fall back to a
  # behavior probe — Flexible/Off makes CF reach the origin over HTTP and
  # Caddy answers a 308 back to the same https URL (redirect loop).
  local mode hdrs code loc
  mode=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings/ssl" 2>/dev/null \
    | jq -r '.result.value // empty' 2>/dev/null)
  case "$mode" in full|strict) return 0 ;; esac
  [ -n "$mode" ] && return 1
  hdrs=$(curl -sI --max-time 15 "https://cloud.$DOMAIN" 2>/dev/null | tr -d '\r')
  code=$(echo "$hdrs" | awk 'NR==1{print $2}')
  loc=$(echo "$hdrs" | awk 'tolower($1)=="location:"{print $2; exit}')
  [ "$code" = "308" ] && [[ "$loc" == *"cloud.$DOMAIN"* ]] && return 1
  return 0
}

cf_mail_record() { # $1=type(TXT/MX) $2=relative name (or apex) $3=content $4=priority(MX only)
  local type="$1" name="$2" content="$3" prio="${4:-0}" fqdn="$2" records rid current payload response
  [ "$name" = "$DOMAIN" ] || fqdn="$name.$DOMAIN"
  records=$(curl -fsS -G -H "Authorization: Bearer $CF_API_TOKEN" \
    --data-urlencode "type=$type" --data-urlencode "name=$fqdn" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records") || {
    fail dns_mail_txt "Cloudflare $type lookup failed for $fqdn"; return 1;
  }
  rid=$(printf '%s' "$records" | jq -r '.result[0].id // empty')
  current=$(printf '%s' "$records" | jq -r '.result[0].content // empty')
  [ -n "$rid" ] && [ "$current" = "$content" ] && return 0
  payload=$(jq -nc --arg content "$content" --arg name "$fqdn" --arg type "$type" --argjson prio "$prio" \
    '{type:$type,name:$name,content:$content,ttl:1} + (if $type == "MX" then {priority:$prio} else {} end)')
  if [ -n "$rid" ]; then
    response=$(curl -fsS -X PUT -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$rid" -d "$payload") || {
      fail dns_mail_txt "Cloudflare $type update failed for $fqdn"; return 1;
    }
  else
    response=$(curl -fsS -X POST -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" -d "$payload") || {
      fail dns_mail_txt "Cloudflare $type create failed for $fqdn"; return 1;
    }
  fi
  if [ "$(printf '%s' "$response" | jq -r '.success // false')" != "true" ]; then
    fail dns_mail_txt "Cloudflare $type publish failed for $fqdn"
    return 1
  fi
  detail "  $type record ensured: $fqdn"
  return 0
}
# Only the records the mail module needs: the MX that receives inbound mail
# (pointing at the mail vhost — Postfix's virtual_mailbox_domains accepts $DOMAIN
# there) and the SPF policy that authorizes the Docker Mailserver host to send.
# TTL 1 is Cloudflare's "Auto". Both are idempotent: a record already carrying
# the wanted content is left untouched, so a re-check never rewrites the zone.
cf_mail_dns() {
  local mx="mail.$DOMAIN" spf cur
  # SPF must list the sending host. v=spf1 -all (all senders rejected) is the
  # "domain sends no mail" policy and would fail every inbound spam check on our
  # own outbound, so only -all is left alone (an operator's deliberate choice);
  # anything else (stub, an old policy) is replaced by the a:mx policy.
  cur=$(curl -fsS -G -H "Authorization: Bearer $CF_API_TOKEN" \
    --data-urlencode "type=TXT" --data-urlencode "name=$DOMAIN" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" 2>/dev/null \
    | jq -r '[.result[]?.content // empty] | map(select(startswith("v=spf1"))) | first // empty' 2>/dev/null)
  spf="v=spf1 a:$mx mx -all"
  case "$cur" in
    "$spf"|"v=spf1 -all") ;;
    *) cf_mail_record TXT "$DOMAIN" "$spf" ;;
  esac
  cf_mail_record MX "$DOMAIN" "$mx" 10
  # No wildcard *._domainkey placeholder: dkim_setup publishes the only record
  # that matters, dkim._domainkey with the real public key. An empty
  # "v=DKIM1; p=" wildcard is a revoked-key record and only confuses the zone.
  cf_mail_record TXT '_dmarc' 'v=DMARC1; p=reject; sp=reject; adkim=s; aspf=s;'
  # SPF/DKIM/DMARC still can't authorize a relay by themselves without a
  # published PTR, but only the provider can create it — reported in the
  # success block's additional steps.
  return 0
}

  cf_dns() {
  HOST_IP=$(curl -s4 ifconfig.me)
  ZONE_ID=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" | jq -r '.result[0].id // empty')
  if [ -z "$ZONE_ID" ]; then
    fail zone
    return
  fi
  cf_record() { # $1=host $2=proxied(true/false)
    # Idempotent = CONVERGES, not just "creates once": the record's content and
    # proxied flag are driven to the wanted values on every run. Create-only
    # (the old form) left a stale A record pointing at the machine's OLD public
    # IP after an IP change — the re-run reported success while the zone was
    # wrong. A record already carrying the wanted content+proxied is untouched.
    local rec rid cur prox fqdn
    # An empty host means the zone apex: "$DOMAIN", never ".$DOMAIN".
    fqdn="${1:+$1.}$DOMAIN"
    rec=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$fqdn")
    rid=$(printf '%s' "$rec" | jq -r '.result[0].id // empty')
    cur=$(printf '%s' "$rec" | jq -r '.result[0].content // empty')
    prox=$(printf '%s' "$rec" | jq -r '.result[0].proxied // empty')
    if [ -z "$rid" ]; then
      curl -s -X POST -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -d "{\"type\":\"A\",\"name\":\"$fqdn\",\"content\":\"$HOST_IP\",\"ttl\":1,\"proxied\":$2}" \
        >>"$LOG" 2>&1 || fail "dns_${1:-apex}"
      return 0
    fi
    [ "$cur" = "$HOST_IP" ] && [ "$prox" = "$2" ] && return 0
    detail "  A record $fqdn: $cur/$prox -> $HOST_IP/$2 (updating)"
    curl -s -X PUT -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$rid" \
      -d "{\"type\":\"A\",\"name\":\"$fqdn\",\"content\":\"$HOST_IP\",\"ttl\":1,\"proxied\":$2}" \
      >>"$LOG" 2>&1 || fail "dns_${1:-apex}"
  }
  cf_a_del() { # cf_a_del <host> — remove an A record whose door was disabled
    local fqdn rid
    fqdn="${1:+$1.}$DOMAIN"
    rid=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$fqdn" \
      | jq -r '.result[0].id // empty')
    [ -n "$rid" ] || return 0
    curl -s -X DELETE -H "Authorization: Bearer $CF_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$rid" >>"$LOG" 2>&1 || true
    detail "  A record removed: $fqdn (disabled in wizard.state)"
  }
  # proxied (orange cloud): the apex + kuma/www. talk rides on the cloud door.
  for h in "" cloud kuma www; do
    case "$h" in
      "")    cf_record "" true;;
      cloud) mod_on cloud && cf_record "$h" false || cf_a_del cloud;;
      kuma)  mod_on monitor && cf_record "$h" true || cf_a_del kuma;;
      www)   cf_record "$h" true;;
    esac
  done
  # vault.$DOMAIN is TAILNET-ONLY (operator choice 2026-10-28): the name is
  # answered by the machine dnsmasq and gated by @not_tailnet in the vhost, so
  # the public zone must hold NO record for it. A leftover proxied record would
  # hand every visitor a 403 page.
  cf_a_del vault
  # blog.$DOMAIN is WriteFreely on its own hostname (proxied like cloud/kuma).
  mod_on blog && cf_record blog true || cf_a_del blog
  mod_on home && cf_record home true || cf_a_del home
  # photos.$DOMAIN is Immich, DNS-ONLY (grey cloud): uploads and video streams
  # must not pass through the CF proxy.
  mod_on photos && cf_record photos false || cf_a_del photos
  # home.$DOMAIN is Homarr (Next.js root-absolute assets, so it cannot live
  # under www/home); proxied like cloud/kuma.
  # talk MUST be DNS-only (grey cloud): TURN relays media over UDP/TCP
  # 3478/5349 + 49160-49200, which the CF proxy cannot carry. Caddy still gets
  # its LE cert via DNS-01. talk exists only when video calling was enabled.
  mod_on cloud && [ "${VIDEO_CALLING:-true}" != "false" ] && cf_record talk false
  mod_on cloud && [ "${VIDEO_CALLING:-true}" = "false" ] && cf_a_del talk
  # mail.$DOMAIN is the public mail door: Roundcube's web UI AND the name
  # mailu-front publishes 25/465/587/993 on and serves the SMTP/IMAP cert for
  # (the MX and SPF point at it). DNS-ONLY (grey cloud) — the CF proxy carries
  # no SMTP/IMAP, so a proxied record would leave every mail client talking to
  # Cloudflare instead of the origin. Caddy still gets its LE cert via DNS-01.
  mod_on mail && cf_record mail false || cf_a_del mail
  # mailu.$DOMAIN is Mailu's platform door (admin UI + SSO) and is TAILNET-ONLY
  # (same model as vault): the name is answered by the machine dnsmasq and gated
  # by @not_tailnet in the vhost, so the public zone must hold NO record for it
  # (DNS-01 only needs the TXT record for the certificate).
  cf_a_del mailu
  mod_on mail && cf_mail_dns
  curl -s -X PATCH -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings/ssl" -d '{"value":"full"}' >>"$LOG" 2>&1 || true
  # DNS-only tokens can't set SSL mode; surface it as an expected manual step.
  if ! ssl_mode_full; then
    fail sslmode
  fi
}
