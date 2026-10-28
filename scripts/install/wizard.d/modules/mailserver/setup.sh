# wizard.d/modules/mailserver/setup.sh — DKIM key, mailboxes and quotas on the mailserver module.

# Idempotently create one Mailu mailbox (Mailu replaced Docker Mailserver).
# The admin container owns the SQLite config and exposes the `flask mailu` CLI:
#   flask mailu domain <domain>              ensure the domain exists
#   flask mailu user <local> <domain> <pw>   create/update a mailbox
#   flask mailu config-export -j             read the live config (JSON)
# Readiness probes the CLI itself, not a mailbox list.
mail_wait_ready() {
  local i=0
  while [ $i -lt 60 ]; do
    # `flask mailu --help` trips a Flask 2.2 context-pop assertion in Mailu 2.0
    # and always fails — probe with a real, idempotent command instead.
    if docker exec mailu-admin true >/dev/null 2>&1 \
       && docker exec mailu-admin flask mailu config-export -j >/dev/null 2>&1; then
      # Only worth a log line when the caller actually had to wait: every
      # re-run of vaultwarden/nextcloud/dkim_setup probes this again and the
      # per-caller "ready after 0s" line just spams the log (2026-10-19).
      [ "$i" -gt 0 ] && log "  Mailu admin CLI ready after ${i}s"
      # Ensure the primary domain object exists before any mailbox is created.
      docker exec mailu-admin flask mailu domain "$DOMAIN" >/dev/null 2>&1 || true
      return 0
    fi
    if ! docker exec mailu-admin true >/dev/null 2>&1; then
      log "  mailu-admin not running — recreating (attempt $((i/5+1)))"
      make dok-recreate-mailserver >>"$LOG" 2>&1 || true
    fi
    sleep 5; i=$((i+5))
  done
  fail mailserver "Mailu admin CLI did not answer after 60s"
  return 1
}

# Is the address in Mailu's exported config? config-export --json prints the
# whole object tree; matching localpart+domain keeps it independent of the
# exact JSON shape.
mailbox_exists() {
  local localpart="${1%@*}" dom="${1#*@}"
  docker exec mailu-admin flask mailu config-export -j 2>/dev/null \
    | jq -e --arg l "$localpart" --arg d "$dom" \
        '[.. | objects | select((.email? // "") == ($l + "@" + $d))] | length > 0' \
        >/dev/null 2>&1
}

# Add one mailbox FOR REAL — never a silent skip. Mailu's `user` command is
# idempotent (an existing user is updated), and its output is logged.
mailbox_add() {
  local addr="$1" pass="${2:-}" quota="${3:-}" i=0 out localpart dom
  localpart="${addr%@*}"; dom="${addr#*@}"
  while [ $i -lt 90 ]; do
    if mailbox_exists "$addr"; then
      detail "  mailbox present: $addr"
      [ -n "$quota" ] && mail_quota_set "$addr" "$quota"
      return 0
    fi
    out="$(docker exec mailu-admin flask mailu domain "$dom" 2>&1 || true)"
    out="$(docker exec mailu-admin flask mailu user "$localpart" "$dom" "$pass" 2>&1)"
    log "  flask mailu user $localpart $dom -> rc=$? ${out:+| $(printf '%s' "$out" | tail -2 | tr '\n' ' ')}"
    if mailbox_exists "$addr"; then
      detail "  mailbox created: $addr"
      [ -n "$quota" ] && mail_quota_set "$addr" "$quota"
      return 0
    fi
    if printf '%s' "$out" | grep -qiE 'permission denied|read-only file system|cannot open|unable to (write|create)'; then
      log "  Mailu config store not writable — recreating admin"
      make dok-recreate-mailserver >>"$LOG" 2>&1 || true
      mail_wait_ready
    fi
    if ! docker exec mailu-admin true >/dev/null 2>&1; then
      log "  mailu-admin not running — recreating before the next attempt"
      make dok-recreate-mailserver >>"$LOG" 2>&1 || true
      mail_wait_ready
    fi
    sleep 5; i=$((i+5))
  done
  log "  mailbox $addr NOT created after ${i}s (last output above)"
  return 1
}

# Set a mailbox quota. Mailu takes bytes; accept 100M / 2G / 0 (unlimited).
mail_quota_set() {
  local addr="$1" q="$2" bytes localpart dom
  localpart="${addr%@*}"; dom="${addr#*@}"
  bytes=$(numfmt --from=iec "$q" 2>/dev/null || echo "$q")
  printf 'users:\n  - localpart: %s\n    domain: %s\n    quota_bytes: %s\n' \
    "$localpart" "$dom" "$bytes" \
    | docker exec -i mailu-admin flask mailu config-update >/dev/null 2>&1
}


# Publish the mail platform's DKIM key as a TXT record via the Cloudflare API.
# Mailu generates the per-domain key when the domain is created; the admin CLI's
# `config-export --dns` emits the full DNS set, from which the DKIM record is
# extracted. Runs after Mailu is up (task_mail) and never writes a truncated key.
dkim_setup() {
  cd "$REPO" || exit 1
  local rec value zone id sel=dkim i=0
  # Wait for the admin CLI (a real command: `flask mailu --help` trips a Flask
  # 2.2 context-pop assertion in Mailu 2.0 and always fails), then make sure the
  # domain row exists.
  while [ $i -lt 30 ]; do
    docker exec mailu-admin flask mailu config-export -j >/dev/null 2>&1 && break
    sleep 2; i=$((i+2))
  done
  docker exec mailu-admin flask mailu domain "$DOMAIN" >/dev/null 2>&1 || true
  # `flask mailu domain` only creates the row — it never generates a DKIM key,
  # and Mailu writes the private key to /dkim/<domain>.<selector>.key (not a
  # .txt next to it) and hides dkim_key from config-export. Go through the ORM:
  # generate the key when missing, then read its public part.
  rec=$(docker exec -e DOMAIN="$DOMAIN" mailu-admin python3 -c '
from mailu import create_app, models
app = create_app()
with app.app_context():
    d = models.Domain.query.get(__import__("os").environ["DOMAIN"])
    if not d:
        raise SystemExit(1)
    if not d.dkim_key:
        d.generate_dkim_key()
        models.db.session.commit()
    print(d.dkim_publickey)
' 2>/dev/null | tr -d '\r\n')
  [ -n "$rec" ] || { fail dkim_setup "no public key (Mailu refused to generate one for $DOMAIN)"; return 1; }
  value="v=DKIM1; k=rsa; p=$rec"
  zone=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result'][0]['id'] if d.get('result') else '')" 2>/dev/null)
  [ -n "$zone" ] || { fail dkim_setup "zone lookup"; return 1; }
  for id in $(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/zones/$zone/dns_records?type=TXT&name=$sel._domainkey.$DOMAIN" \
      | python3 -c "import sys,json; [print(r['id']) for r in (json.load(sys.stdin).get('result') or [])]" 2>/dev/null); do
    curl -s -X DELETE -H "Authorization: Bearer $CF_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/zones/$zone/dns_records/$id" >/dev/null
  done
  python3 - "$CF_API_TOKEN" "$zone" "$value" "$sel" <<'EOF' || { fail dkim_setup "record publish"; return 1; }
import sys, json, urllib.request
tok, zone, val, sel = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
req = urllib.request.Request(f"https://api.cloudflare.com/client/v4/zones/{zone}/dns_records",
  data=json.dumps({"type": "TXT", "name": f"{sel}._domainkey", "content": val, "ttl": 1, "proxied": False}).encode(),
  headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"}, method="POST")
sys.exit(0 if json.loads(urllib.request.urlopen(req).read().decode()).get("success") else 1)
EOF
  detail "DKIM published: $sel._domainkey TXT for $DOMAIN (PTR remains provider-side)"
  # Drop the retired empty "*._domainkey v=DKIM1; p=" wildcard left by older
  # installs: it reads as a revoked key for every selector that has no exact
  # record, and the only record that matters is dkim._domainkey above.
  for id in $(curl -s -G -H "Authorization: Bearer $CF_API_TOKEN" \
      --data-urlencode "type=TXT" --data-urlencode "name=*._domainkey.$DOMAIN" \
      "https://api.cloudflare.com/client/v4/zones/$zone/dns_records" \
      | python3 -c 'import sys,json
for r in (json.load(sys.stdin).get("result") or []):
    if (r.get("content") or "").strip() == "v=DKIM1; p=":
        print(r["id"])' 2>/dev/null); do
    curl -s -X DELETE -H "Authorization: Bearer $CF_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/zones/$zone/dns_records/$id" >/dev/null
  done
}
