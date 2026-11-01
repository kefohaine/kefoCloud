# wizard.d/modules/kopia/setup.sh — the backup module: repository readiness.
#
# `make kopia-gen` (Stack Config) wrote the repository password and the web UI
# account into modules/kopia/.env; the container creates the filesystem
# repository on its first start. This step proves the repository opens and
# snapshots can be listed, so a green row means restores are possible.
# Idempotent.

kopia_setup() {
  cd "$REPO" || exit 1
  . modules/kopia/.env

  local i=0
  while [ $i -lt 300 ]; do
    if docker exec -e KOPIA_PASSWORD="$KOPIA_PASSWORD" kopia \
         kopia --config-file=/data/config/repository.config repository status >/dev/null 2>&1; then
      break
    fi
    [ $((i % 30)) -eq 0 ] && log "  waiting for the backup repository (${i}s)"
    sleep 2; i=$((i+2))
  done
  if ! docker exec -e KOPIA_PASSWORD="$KOPIA_PASSWORD" kopia \
       kopia --config-file=/data/config/repository.config repository status >/dev/null 2>&1; then
    fail kopia_setup "repository does not open — see: docker logs kopia"
    return
  fi
  detail "  repository opens and lists snapshots"

  if curl -sk --max-time 15 "https://kopia.$DOMAIN/" >/dev/null 2>&1; then
    detail "  web UI answers on kopia.$DOMAIN (tailnet-only)"
  else
    log "  kopia.$DOMAIN did not answer over the tailnet — check DNS after the run"
  fi
  detail "  UI account: ${KOPIA_SERVER_USERNAME} (password in modules/kopia/.env, printed in the summary)"
}
