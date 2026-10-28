# wizard.d/modules/nextcloud/talk.sh — Talk call wiring: our own HPB signalling
# and coturn TURN/STUN for EVERY call, and the removal path when video calling is
# switched off in wizard.state. Called from nextcloud_setup (modules/nextcloud/
# setup.sh) once the app container is up; needs DOMAIN, SIGNALING_SECRET,
# TURN_SECRET, VIDEO_CALLING and $LOG (all shared globals — one process).
talk_wiring() {
  if [ "${VIDEO_CALLING:-true}" != "false" ]; then
    # Talk signaling — ONE entry (the public URL): NC 34 deprecates multiple
    # high-performance backends. Clients get wss://talk.$DOMAIN/signaling/spreed; the
    # signaling server reaches NC back via its own [backend1] urls (extra_hosts),
    # so no internal URL registration is needed.
    local sig
    sig=$(docker exec -u www-data nextcloud php occ talk:signaling:list 2>/dev/null)
    if ! echo "$sig" | grep -q "https://talk.$DOMAIN/signaling"; then
      docker exec -u www-data nextcloud php occ talk:signaling:add "https://talk.$DOMAIN/signaling" "$SIGNALING_SECRET" >/dev/null 2>&1 || true
    fi
    docker exec -u www-data nextcloud php occ talk:signaling:remove "http://172.22.0.12:8080" >/dev/null 2>&1 || true

    # Talk TURN/STUN — udp+tcp on 3478, tls on 5349 (secret matches turnserver.conf).
    local trn
    trn=$(docker exec -u www-data nextcloud php occ talk:turn:list 2>/dev/null)
    # talk:turn:add <schemes> <server> <protocols> — protocols are POSITIONAL;
    # the old --udp/--tcp flags don't exist, so the call always failed and TURN
    # was never registered.
    if ! echo "$trn" | grep -q "talk.$DOMAIN:3478"; then
      docker exec -u www-data nextcloud php occ talk:turn:add turn "talk.$DOMAIN:3478" "udp,tcp" --secret "$TURN_SECRET" >/dev/null 2>&1 || true
    fi
    if ! echo "$trn" | grep -q "talk.$DOMAIN:5349"; then
      docker exec -u www-data nextcloud php occ talk:turn:add turns "talk.$DOMAIN:5349" "tcp" --secret "$TURN_SECRET" >/dev/null 2>&1 || true
    fi
    # Every call goes through the HPB + our own coturn, not just media calls:
    # signaling_mode pins the external signalling server (no internal fallback
    # when the server list looks empty), stun_servers replaces the third-party
    # default (stun.nextcloud.com:443) with this host's coturn.
    docker exec -u www-data nextcloud php occ config:app:set spreed signaling_mode \
      --value external >/dev/null 2>&1 || true
    docker exec -u www-data nextcloud php occ config:app:set spreed stun_servers \
      --value "[\"stun:talk.$DOMAIN:3478\"]" >/dev/null 2>&1 || true
  else
    # wizard.state is the source of truth: VIDEO_CALLING toggled OFF in a repair
    # removes the live pieces (app, signaling + TURN entries) — not just skips.
    docker exec -u www-data nextcloud php occ app:remove spreed >>"$LOG" 2>&1 \
      || docker exec -u www-data nextcloud php occ app:disable spreed >>"$LOG" 2>&1 || true
    docker exec -u www-data nextcloud php occ talk:signaling:remove "https://talk.$DOMAIN/signaling" >/dev/null 2>&1 || true
    log "  video calling disabled — spreed/signaling/TURN removed"
  fi
  return 0
}
