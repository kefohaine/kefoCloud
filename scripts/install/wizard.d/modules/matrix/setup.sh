# wizard.d/modules/matrix/setup.sh — the chat module: admin account, readiness.
#
# Synapse and Element are configured by `make matrix-gen` (Stack Config) and
# started by the containers task. What is left here is the ACCOUNT layer: the
# admin bot the `make matrix-*` recipes authenticate as, plus a readiness probe
# so a broken homeserver fails its row instead of being reported green.
# Every step is idempotent.

matrix_setup() {
  cd "$REPO" || exit 1
  . modules/matrix/.env

  # Synapse answers /health only after it has migrated its PostgreSQL schema,
  # so this is the one probe that means "the homeserver is actually usable".
  local i=0
  while [ $i -lt 600 ]; do
    if docker exec matrix-synapse python3 -c \
        'import urllib.request,sys; sys.exit(0 if urllib.request.urlopen("http://127.0.0.1:8008/health").status == 200 else 1)' \
        >/dev/null 2>&1; then
      break
    fi
    [ $((i % 30)) -eq 0 ] && log "  waiting for the homeserver to finish starting (${i}s)"
    sleep 2; i=$((i+2))
  done
  if ! docker exec matrix-synapse python3 -c \
      'import urllib.request,sys; sys.exit(0 if urllib.request.urlopen("http://127.0.0.1:8008/health").status == 200 else 1)' \
      >/dev/null 2>&1; then
    fail matrix_setup "homeserver did not answer /health — see: docker logs matrix-synapse"
    return
  fi
  detail "  homeserver answers /health"

  # MAS (ESS CE) is the identity provider now: every token Synapse accepts is
  # minted there, so the row is only green once its discovery document answers.
  local j=0
  while [ $j -lt 120 ]; do
    curl -sk --max-time 5 "https://auth.matrix.$DOMAIN/.well-known/openid-configuration" \
      | grep -q '"issuer"' && break
    sleep 2; j=$((j+2))
  done
  if curl -sk --max-time 10 "https://auth.matrix.$DOMAIN/.well-known/openid-configuration" | grep -q '"issuer"'; then
    detail "  MAS answers discovery on auth.matrix.$DOMAIN"
  else
    fail matrix_setup "MAS did not answer https://auth.matrix.$DOMAIN/.well-known/openid-configuration — see: docker logs matrix-mas"
    return
  fi

  # The admin account lives in MAS: it is registered once (a second register is
  # refused), becomes a MAS admin (-a) so it may drive the admin API Element
  # Admin calls, and is then flagged a Synapse server admin by `matrix-add`.
  docker exec matrix-mas mas-cli manage -c /data/config.yaml register-user \
    --yes -a -p "$SYNAPSE_ADMIN_PASSWORD" "$SYNAPSE_ADMIN_USER" >/dev/null 2>&1 || true
  if docker exec matrix-mas-db psql -U mas -d mas -tAc \
      "select username from users where username='$SYNAPSE_ADMIN_USER'" 2>/dev/null \
      | grep -qx "$SYNAPSE_ADMIN_USER"; then
    log "  the admin account @${SYNAPSE_ADMIN_USER}:matrix.${DOMAIN} exists in MAS"
  else
    fail matrix_setup "MAS has no @${SYNAPSE_ADMIN_USER} account — see: docker logs matrix-mas, make matrix-logs"
    return
  fi

  # Element is a static app: a 200 with an HTML body is the whole contract.
  if curl -sk --max-time 15 "https://chat.$DOMAIN/" | grep -qi '<title>'; then
    detail "  Element answers on chat.$DOMAIN"
  else
    fail matrix_element "chat.$DOMAIN did not serve Element — see: docker logs matrix-element"
    return
  fi
  detail "  accounts: @<name>:matrix.$DOMAIN — add one with: make matrix-add USER=<name>"
}
