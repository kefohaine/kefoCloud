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

  # The admin bot: created once. register_new_matrix_user refuses an existing
  # account, which is exactly the idempotence this step needs.
  if docker exec matrix-synapse register_new_matrix_user \
       -u "$SYNAPSE_ADMIN_USER" -p "$SYNAPSE_ADMIN_PASSWORD" -a \
       -c /data/homeserver.yaml http://127.0.0.1:8008 >/dev/null 2>&1; then
    log "  created the admin account @${SYNAPSE_ADMIN_USER}:${DOMAIN}"
  else
    detail "  admin account @${SYNAPSE_ADMIN_USER}:${DOMAIN} already exists"
  fi

  # Element is a static app: a 200 with an HTML body is the whole contract.
  if curl -sk --max-time 15 "https://chat.$DOMAIN/" | grep -qi '<title>'; then
    detail "  Element answers on chat.$DOMAIN"
  else
    fail matrix_element "chat.$DOMAIN did not serve Element — see: docker logs matrix-element"
    return
  fi
  detail "  accounts: @<name>:$DOMAIN — add one with: make matrix-add USER=<name>"
}
