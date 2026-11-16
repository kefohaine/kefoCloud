#!/usr/bin/env bash
# scripts/ops/vhost-exposure.sh — change one door's exposure, then make it true.
#
#   make vhost-exposure TARGET=<vhost> VALUE=tailnet-vpn|cloudflare-dns
#
# The answer is one key in data/instance.conf (<VHOST>_EXPOSURE, read by
# scripts/lib/exposure.sh). Besides the installer this is the only writer of
# that file, and it is an operator action: it restarts the edge, rewrites the
# zone and reprobes the door. `DRYRUN=1` prints the plan — same refusals, same
# steps, nothing written — and stops before the first mutation.
#
# The four parts of one exposure change, in order — a change that stops after
# any of them is half applied:
#   1. the answer, in instance.conf;
#   2. the render, into data/rendered/;
#   3. the edge — `make dok-restart TARGET=caddy`, because the edge runs
#      `admin off` (modules/caddy/Caddyfile) and `caddy reload` has no admin API
#      to talk to. The restart briefly drops EVERY door, not just this one;
#      certificates live in caddy_data and are not re-issued;
#   4. the zone record (created for cloudflare-dns, removed for tailnet-vpn) and
#      the dnsmasq split-DNS answer — both rendered from the same value;
#   5. a probe from both sides, then `make smoke`. A failing probe stops the run
#      (the change is NOT applied); a failing smoke suite is reported as a
#      separate verdict — the five steps above are already on the host.
#
# TARGET is a vhost FILE basename (vault, admin.mail, livekit-jwt.matrix …).
# ttyd is refused (an unauthenticated root shell is never published) and so is
# www (the core pages, always cloudflare-dns). Publishing a door
# (tailnet-vpn -> cloudflare-dns) asks for the literal word `yes`;
# `CONFIRM=yes` answers it, so an unattended run fails on a missing answer
# instead of hanging.

set -uo pipefail

WIZ_DIR="$(cd "$(dirname "$(readlink -f "$0")")/../install" && pwd)"

# The wizard's libs are written to be SOURCED (one process, shared globals), so
# load them in the same order and reuse their functions — env.sh also sources
# scripts/lib/modules.sh, which brings the exposure accessor.
. "$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)/lib/dryrun.sh"
for _f in lib/env.sh lib/log.sh lib/state.sh lib/cloudflare.sh lib/errors.sh; do
  # shellcheck disable=SC1090  # the paths are relative to WIZ_DIR on purpose
  . "$WIZ_DIR/wizard.d/$_f" || { echo "vhost-exposure: cannot source $_f" >&2; exit 1; }
done
unset _f

install -d -m 0755 "$LOG_DIR"
LOG="$LOG_DIR/vhost-exposure.log"
chmod 600 "$LOG" 2>/dev/null || true

load_state || true
# wizard.state is 0600 root:root; a non-root run reads the copy Caddy uses.
if [ -z "${CF_API_TOKEN:-}" ] && sudo -n test -s "$DATA/caddy_data/CF_API_TOKEN" 2>/dev/null; then
  CF_API_TOKEN="$(sudo -n sed -n 's/^CF_API_TOKEN=//p' "$DATA/caddy_data/CF_API_TOKEN")"
fi
[ -n "${CF_API_TOKEN:-}" ] || { echo "vhost-exposure: no Cloudflare token in $INSTALL_STATE or $DATA/caddy_data/CF_API_TOKEN" >&2; exit 1; }
[ -n "${DOMAIN:-}" ] || { echo "vhost-exposure: DOMAIN is empty in $INSTALL_STATE" >&2; exit 1; }

TARGET="${TARGET:-}"; VALUE="${VALUE:-}"
die() { echo "vhost-exposure: $*" >&2; exit 1; }

case "$TARGET" in
  '')      die "usage: make vhost-exposure TARGET=<vhost> VALUE=tailnet-vpn|cloudflare-dns";;
  ttyd)    die "ttyd is fixed at tailnet-vpn: it serves an unauthenticated root shell, so publishing it is not a choice this repo offers";;
  www)     die "the core www/apex pages are fixed at cloudflare-dns: they belong to no module";;
esac
case " $(exposure_targets | paste -sd' ' -) " in
  *" $TARGET "*) ;;
  *) die "'$TARGET' is not a door: expected one of $(exposure_targets | paste -sd' ' -)";;
esac
exposure_valid "$VALUE" || die "'$VALUE' is not an exposure: use tailnet-vpn or cloudflare-dns"

CUR="$(exposure_of "$TARGET")"
[ -n "$CUR" ] || die "$TARGET has no recorded exposure in $DATA/instance.conf — run the installer (repair) once"
[ "$CUR" = "$VALUE" ] && { echo "vhost-exposure: $TARGET is already $VALUE — nothing to do."; exit 0; }

HOSTS="$(exposure_hosts "$TARGET")"
[ -n "$HOSTS" ] || die "$TARGET declares no hostname in modules/caddy/vhosts/$TARGET.caddy"

echo ""
echo "  door     $TARGET — $(printf '%s ' $HOSTS)"
echo "  from     $CUR"
echo "  to       $VALUE"
case "$VALUE" in
  cloudflare-dns)
    echo "           the door gets a public A record and NO gate: anyone on the internet reaches it,"
    echo "           at this machine's own address (no Cloudflare proxy is created)." ;;
  tailnet-vpn)
    echo "           the public A record is removed and the vhost refuses every non-tailnet source;"
    echo "           the name keeps resolving through this machine's dnsmasq for tailnet clients." ;;
esac
echo "           the edge is restarted (every door drops for a second), then the record, dnsmasq"
echo "           and a two-sided probe follow."
echo ""

# The plan: every step a real run would take, in the order it takes them, with
# the same refusals already applied above. Nothing is written and the
# confirmation below is not asked (a plan decides nothing).
if dryrun_wanted "$@"; then
  KEY="$(exposure_key "$TARGET")_EXPOSURE"
  dryrun_plan "write $KEY=$VALUE to $DATA/instance.conf (mode 0600, other keys untouched)"
  dryrun_plan "render (make render)"
  dryrun_plan "restart the edge (make dok-restart TARGET=caddy) — every door drops for a second"
  for _h in $HOSTS; do
    _rel="${_h%."$DOMAIN"}"; [ "$_rel" = "$_h" ] && _rel="(apex)"
    case "$VALUE" in
      cloudflare-dns) dryrun_plan "converge the Cloudflare A record for $_rel to \$HOST_IP (proxied untouched)";;
      tailnet-vpn)    dryrun_plan "delete the Cloudflare A record for $_rel";;
    esac
  done
  dryrun_plan "install the dnsmasq answers (make install-dnsmasq-conf) and reload dnsmasq"
  dryrun_plan "probe the door from a public source and from the tailnet, then make smoke"
  [ "$CUR" = tailnet-vpn ] && [ "$VALUE" = cloudflare-dns ] \
    && dryrun_note "a real run asks for the literal word 'yes' before publishing this door (CONFIRM=yes answers it)"
  dryrun_end "nothing changed"
fi

# Leaving tailnet-vpn is the one direction that publishes a door: the literal
# word `yes` is required (no shortcut, no default — a typo aborts).
if [ "$CUR" = tailnet-vpn ] && [ "$VALUE" = cloudflare-dns ]; then
  case "${CONFIRM:-no}" in
    yes) detail "  publishing $TARGET at this machine — CONFIRM=yes" ;;
    *)
      printf '  Type yes to publish %s at this machine: ' "$TARGET"
      # A closed stdin is not a `no` answer: say so, or a scripted run dies
      # here with no explanation at all.
      if ! read -r _reply; then
        echo ""
        die "no answer to the publish prompt (stdin closed) — nothing changed; run interactively or pass CONFIRM=yes"
      fi
      [ "$_reply" = yes ] || die "not confirmed — nothing changed."
      ;;
  esac
fi

# 1 — the answer, in place: the other keys keep their order.
KEY="$(exposure_key "$TARGET")_EXPOSURE"
if grep -q "^$KEY=" "$DATA/instance.conf"; then
  sed -i "s|^$KEY=.*|$KEY=$VALUE|" "$DATA/instance.conf"
else
  printf '%s=%s\n' "$KEY" "$VALUE" >>"$DATA/instance.conf"
fi
chmod 600 "$DATA/instance.conf"
detail "  $KEY=$VALUE written to $DATA/instance.conf"

# 2/3 — render, then restart the edge (no admin API, so no reload).
make -C "$REPO" --no-print-directory render       >>"$LOG" 2>&1 || die "render failed — see $LOG"
make -C "$REPO" --no-print-directory dok-restart TARGET=caddy >>"$LOG" 2>&1 || die "edge restart failed — see $LOG"

# 4 — the zone record, through the installer's own convergence, then dnsmasq.
HOST_IP=$(curl -s4 ifconfig.me)
ZONE_ID=$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" | jq -r '.result[0].id // empty')
[ -n "$ZONE_ID" ] || die "the Cloudflare zone $DOMAIN was not found"
for host in $HOSTS; do
  rel="${host%.$DOMAIN}"; [ "$rel" = "$host" ] && rel=""
  case "$VALUE" in
    cloudflare-dns) cf_record "$rel" ;;
    tailnet-vpn)    cf_a_del "$rel" ;;
  esac
done
make -C "$REPO" --no-print-directory install-dnsmasq-conf >>"$LOG" 2>&1 || die "dnsmasq install failed — see $LOG"

# 5 — both sides of the door, then the whole suite. A failing probe means the
# change is NOT done.
TS_IP="$(tailscale ip -4 2>/dev/null | head -n1)"
fails=0
pub_ok="200 301 302 307 308"
probe_pub() { curl -s -o /dev/null -w '%{http_code}' --max-time 12 --resolve "$1:443:127.0.0.1" "https://$1/"; }
probe_tn()  { curl -s -o /dev/null -w '%{http_code}' --max-time 12 --interface "$TS_IP" --resolve "$1:443:$TS_IP" "https://$1/"; }

for host in $HOSTS; do
  pub="$(probe_pub "$host")"
  case "$VALUE" in
    tailnet-vpn)
      if [ -z "$TS_IP" ]; then
        echo "FAIL $host: no Tailscale IPv4 — cannot probe the tailnet side"; fails=$((fails+1))
      else
        tn="$(probe_tn "$host")"
        case " $pub_ok " in *" $tn "*) echo "ok   $host: tailnet $tn";; *) echo "FAIL $host: tailnet source got $tn"; fails=$((fails+1));; esac
      fi
      [ "$pub" = 403 ] && echo "ok   $host: public source refused (403)" \
                       || { echo "FAIL $host: public source got $pub (want 403)"; fails=$((fails+1)); } ;;
    cloudflare-dns)
      # "Served", not "healthy": any answered status but a refusal or a dead
      # connection proves the gate is gone (the app itself is `make smoke`'s job).
      case "$pub" in
        000|403) echo "FAIL $host: public source got $pub (want any served status)"; fails=$((fails+1)) ;;
        *)       echo "ok   $host: public $pub" ;;
      esac ;;
  esac
done

[ "$fails" = 0 ] || die "$fails probe(s) failed — the change is NOT applied; inspect $LOG and 'make dok-logs TARGET=caddy'"
echo ""
echo "  $TARGET is $VALUE — recorded, rendered, the edge restarted, the zone record and the"
echo "  dnsmasq answer converged, both sides probed. Running the full smoke test:"
# The suite's verdict is the SUITE's: a check that fails elsewhere on this host
# does not undo a change already applied above, and saying so is the difference
# between "the flip failed" and "the flip landed, something else is red".
if ! make -C "$REPO" --no-print-directory smoke; then
  die "$TARGET IS $VALUE — the change above is applied; the smoke suite failed on other check(s), see its report"
fi
