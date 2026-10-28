# wizard.d/tasks/12-containers.sh — `Docker Containers`: bring the enabled modules up (Caddy last).

containers_up() {
  # The checklist's own [EXEC] animation is the progress indicator, so the Caddy
  # build prints nothing here (its verbose output goes to $LOG). The dok-recreate
  # recipe already falls back to docker build + compose up when compose's buildx
  # is too old (Debian trixie).
  module_off_teardown
  if svc_skip_repair caddy caddy -- caddy; then
    # The inputs hash alone is not enough: a run that rendered new vhosts and
    # died before dok-recreate leaves a noted hash and an edge still running
    # the PREVIOUS config (live 2026-10-19: caddy skipped while LE 429-stalled
    # because the fallback-chain vhosts were never loaded). If the newest
    # rendered file is younger than the container, recreate anyway.
    local started newest
    started=$(docker inspect -f '{{.State.StartedAt}}' caddy 2>/dev/null | date -u -f - +%s 2>/dev/null || echo 0)
    newest=$(find "$DATA/rendered/caddy" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1)
    newest=${newest%%.*}
    if [ "${started:-0}" -ge "${newest:-0}" ]; then
      detail "  caddy already up, inputs unchanged — skipped"
    else
      detail "  caddy running config predates rendered vhosts — recreating"
      make dok-recreate-caddy >>"$LOG" 2>&1 || fail caddy
      detail "  Caddy image rebuilt with current rendered config"
    fi
  else
    log "  recreate: caddy (image build)"
    make dok-recreate-caddy >>"$LOG" 2>&1 || fail caddy
    detail "  Caddy image built"
  fi
  svc_note_applied caddy caddy --
  # PostgreSQL first — the nextcloud entrypoint's fresh install needs the DB
  # reachable (POSTGRES_HOST from .env, set by talk-gen above). Caddy's
  # DNS-01 issuance runs at startup, so the mail/turn certs the talk stack
  # and mailserver need are on disk by the time they start. Modules respect
  # the install-time choice (default: everything ON).
  if mod_on cloud; then
    if svc_skip_repair nextcloud nextcloud -- nextcloud postgresql; then
      detail "  nextcloud-db + nextcloud already up, inputs unchanged — skipped"
    else
      log "  recreate: nextcloud-db + nextcloud"
      # ONE compose invocation for BOTH files. They live in the same directory
    # (modules/nextcloud/), so compose treats them as one project — and running
    # `up --remove-orphans` on either file ALONE sees the other file's containers
    # as orphans and DELETES them. That is exactly what happened on 2026-10-15:
    # the app recreate removed the just-started postgresql, nextcloud could not
    # reach 172.22.0.15:5432, and `occ maintenance:install` died with
    # SQLSTATE[08006] "No route to host". Naming both -f files keeps every
    # service in the project, so nothing is ever an orphan.
    docker compose \
      -f "$REPO/modules/nextcloud/docker-compose.db.yml" \
      -f "$REPO/modules/nextcloud/docker-compose.yml" \
      up -d --force-recreate --remove-orphans >>"$LOG" 2>&1 \
      || { fail nextcloud_db; fail nextcloud; }
    fi
    svc_note_applied nextcloud nextcloud --
  fi
  if mod_on vault; then
    if svc_skip_repair vaultwarden vaultwarden -- vaultwarden; then
      detail "  vaultwarden already up, inputs unchanged — skipped"
    else
      log "  recreate: vaultwarden"; make dok-recreate-vaultwarden >>"$LOG" 2>&1 || fail vaultwarden
    fi
    svc_note_applied vaultwarden vaultwarden --
  fi
  if mod_on monitor; then
    if svc_skip_repair uptimekuma uptimekuma -- uptimekuma; then
      detail "  uptimekuma already up, inputs unchanged — skipped"
    else
      log "  recreate: uptimekuma";  make dok-recreate-uptimekuma  >>"$LOG" 2>&1 || fail kuma
    fi
    svc_note_applied uptimekuma uptimekuma --
  fi
  if mod_on mail; then
    if svc_skip_repair mailserver mailserver -- mailu-front; then
      detail "  mailserver already up, inputs unchanged — skipped"
    else
      log "  recreate: mailserver";  make dok-recreate-mailserver  >>"$LOG" 2>&1 || fail mailserver
    fi
    svc_note_applied mailserver mailserver --
  fi
  if mod_on home; then
    if svc_skip_repair homarr homarr -- homarr; then
      detail "  homarr already up, inputs unchanged — skipped"
    else
      log "  recreate: homarr"; make dok-recreate-homarr >>"$LOG" 2>&1 || fail homarr
    fi
    svc_note_applied homarr homarr --
  fi
  if mod_on homer; then
    if svc_skip_repair homer homer -- homer; then
      detail "  homer already up, inputs unchanged — skipped"
    else
      log "  recreate: homer"; make dok-recreate-homer >>"$LOG" 2>&1 || fail homer
    fi
    svc_note_applied homer homer --
  fi
  if mod_on blog; then
    if svc_skip_repair writefreely writefreely -- writefreely; then
      detail "  writefreely already up, inputs unchanged — skipped"
    else
      log "  recreate: writefreely"; make dok-recreate-writefreely >>"$LOG" 2>&1 || fail writefreely
    fi
    svc_note_applied writefreely writefreely --
  fi
  if mod_on beszel; then
    # One compose file declares hub + agent: recreating either brings both up.
    if svc_skip_repair beszel beszel -- beszel-hub beszel-agent; then
      detail "  beszel hub + agent already up, inputs unchanged — skipped"
    else
      log "  recreate: beszel hub + agent"; make dok-recreate-beszel-hub >>"$LOG" 2>&1 || fail beszel
    fi
    # The hub ships ZERO systems and its CLI cannot create one, so without this
    # the dashboard is empty after a fresh install. Idempotent (skipped when the
    # agent's address is already registered); a not-yet-reachable agent is a
    # soft failure — the hub is fine, only its own row is pending.
    log "  register: this machine in the beszel hub"
    make beszel-add-system >>"$LOG" 2>&1 || warn beszel_system
    svc_note_applied beszel beszel --
  fi
  if mod_on photos; then
    # immich-server declares the dependency order (db + redis), so it is the
    # one unit to recreate for the whole photo stack.
    if svc_skip_repair immich immich -- immich-server immich-db immich-redis; then
      detail "  immich already up, inputs unchanged — skipped"
    else
      log "  recreate: immich stack"; make dok-recreate-immich-server >>"$LOG" 2>&1 || fail immich
    fi
    svc_note_applied immich immich --
  fi
  redis_door_sanity
}


# Docker Containers: bring the compose stack up and re-check every container.
task_containers() {
  task_start
  cd "$REPO" || exit 1
  containers_up
  task_end
}
