# wizard.d/lib/cloudflare.sh — the Cloudflare API: A records (converging from the
# recorded door exposure), mail MX/SPF/DMARC.
#
# The A records follow `scripts/lib/exposure.sh`: a `tailnet-vpn` door has NO
# public record, a `cloudflare-dns` door is converged to this host's address.
# Cloudflare PROXYING is not a repo value: a record is created DNS-only and an
# update touches only its content and TTL, so an operator's orange cloud
# survives every repair (Cloudflare's edge certificate and a proxied flag are
# not health signals, and a proxied two-label name fails the edge handshake).
#
# DRYRUN=1 (set by scripts/ops/dns-sync.sh --dry-run) turns every writer below into a
# printer: the same name/module table runs, one "would …" line per record lands on
# stdout, and no request that changes the zone is sent. Reads (the zone id, the public
# IP) still happen, so a plan never disagrees with a real run.
. "$(dirname "${BASH_SOURCE[0]}")/../../../lib/dryrun.sh"

cf_mail_record() { # $1=type(TXT/MX) $2=relative name (or apex) $3=content $4=priority(MX only)
  local type="$1" name="$2" content="$3" prio="${4:-0}" fqdn="$2" records rid current payload response
  [ "$name" = "$DOMAIN" ] || fqdn="$name.$DOMAIN"
  if [ "${DRYRUN:-0}" = 1 ]; then
    if [ "$type" = MX ]; then
      dryrun_plan "converge MX $fqdn -> $content (priority $prio)"
    else
      dryrun_plan "converge $type $fqdn -> $content"
    fi
    return 0
  fi
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

cf_record() { # cf_record <host relative name, '' for the apex>
  # CONVERGES the record's content, not just "creates once": create-only (the
  # old form) left a stale A record pointing at the machine's old public IP
  # after an IP change, and a re-run reported success while the zone was wrong.
  # `proxied` is written ONLY on create (DNS-only), never on update: the orange
  # cloud is the operator's dashboard setting, not this repo's.
  local rec rid cur fqdn
  fqdn="${1:+$1.}$DOMAIN"
  if [ "${DRYRUN:-0}" = 1 ]; then
    dryrun_plan "converge A $fqdn -> $HOST_IP (proxied left untouched)"
    return 0
  fi
  rec=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$fqdn")
  rid=$(printf '%s' "$rec" | jq -r '.result[0].id // empty')
  cur=$(printf '%s' "$rec" | jq -r '.result[0].content // empty')
  if [ -z "$rid" ]; then
    curl -s -X POST -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
      -d "{\"type\":\"A\",\"name\":\"$fqdn\",\"content\":\"$HOST_IP\",\"ttl\":1,\"proxied\":false}" \
      >>"$LOG" 2>&1 || fail "dns_${1:-apex}"
    return 0
  fi
  [ "$cur" = "$HOST_IP" ] && return 0
  detail "  A record $fqdn: $cur -> $HOST_IP (updating content only)"
  curl -s -X PATCH -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$rid" \
    -d "{\"type\":\"A\",\"name\":\"$fqdn\",\"content\":\"$HOST_IP\",\"ttl\":1}" \
    >>"$LOG" 2>&1 || fail "dns_${1:-apex}"
}

cf_a_del() { # cf_a_del <host relative name, '' for the apex> — a tailnet-vpn door
  local fqdn rid
  fqdn="${1:+$1.}$DOMAIN"
  if [ "${DRYRUN:-0}" = 1 ]; then
    dryrun_plan "remove the A record for $fqdn if present"
    return 0
  fi
  rid=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$fqdn" \
    | jq -r '.result[0].id // empty')
  [ -n "$rid" ] || return 0
  curl -s -X DELETE -H "Authorization: Bearer $CF_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$rid" >>"$LOG" 2>&1 || true
  detail "  A record removed: $fqdn (door exposure is tailnet-vpn)"
}

# The zone, from the answers: one loop over every Caddy vhost FILE and every
# hostname it declares (scripts/lib/exposure.sh) — never a hand-kept host list,
# which is how a door added later ended up with no record, or a gated door with
# a public one.
cf_dns() {
  HOST_IP=$(curl -s4 ifconfig.me)
  ZONE_ID=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" | jq -r '.result[0].id // empty')
  if [ -z "$ZONE_ID" ]; then
    fail zone
    return
  fi
  local v host rel
  for v in $(exposure_targets); do
    for host in $(exposure_hosts "$v"); do
      # The API takes a name relative to the zone: '' for the apex.
      rel="${host%."$DOMAIN"}"; [ "$rel" = "$host" ] && rel=""
      case "$(exposure_of "$v")" in
        tailnet-vpn)    cf_a_del "$rel" ;;
        cloudflare-dns) cf_record "$rel" ;;
        *)              fail "exposure_$v" ;;
      esac
    done
  done
  # Non-A records are unaffected by exposure: the mail platform's MX/SPF/DMARC.
  mod_on mail && cf_mail_dns
}
