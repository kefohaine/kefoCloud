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
  # The homeserver needs its database reachable before it migrates its schema,
  # so the whole matrix unit is one compose invocation (depends_on enforces the
  # order inside it). Caddy's DNS-01 issuance runs at startup, so the
  # mail/matrix certs are on disk by the time those containers start.
  if mod_on chat; then
    if svc_skip_repair matrix matrix -- matrix-synapse matrix-element matrix-db; then
      detail "  matrix stack already up, inputs unchanged — skipped"
    else
      log "  recreate: matrix stack"
      make dok-recreate-matrix-synapse >>"$LOG" 2>&1 || fail matrix
    fi
    svc_note_applied matrix matrix --
  fi
  # Element Admin: a static panel, no database — it only needs the edge up so
  # the tailnet door answers.
  if mod_on admin; then
    if svc_skip_repair admin element-admin -- element-admin; then
      detail "  element-admin already up, inputs unchanged — skipped"
    else
      log "  recreate: element-admin"; make dok-recreate-element-admin >>"$LOG" 2>&1 || fail admin
    fi
    svc_note_applied admin element-admin --
  fi
  if mod_on ocis; then
    if svc_skip_repair ocis ocis -- ocis; then
      detail "  ocis already up, inputs unchanged — skipped"
    else
      log "  recreate: ocis"; make dok-recreate-ocis >>"$LOG" 2>&1 || fail ocis
    fi
    svc_note_applied ocis ocis --
  fi
  if mod_on kopia; then
    if svc_skip_repair kopia kopia -- kopia; then
      detail "  kopia already up, inputs unchanged — skipped"
    else
      log "  recreate: kopia"; make dok-recreate-kopia >>"$LOG" 2>&1 || fail kopia
    fi
    svc_note_applied kopia kopia --
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
  if mod_on blog; then
    if svc_skip_repair writefreely writefreely -- writefreely; then
      detail "  writefreely already up, inputs unchanged — skipped"
    else
      log "  recreate: writefreely"; make dok-recreate-writefreely >>"$LOG" 2>&1 || fail writefreely
    fi
    svc_note_applied writefreely writefreely --
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
}


# Docker Containers: bring the compose stack up and re-check every container.
#
# The module setup rows after this one (mail, matrix, vault, monitor, kopia) and
# the smoke pass at the end all assume the containers are actually SERVING, not
# merely created. oCIS migrates its IDM store, Immich initialises its PostgreSQL
# and Homarr/WriteFreely run their first-boot setup — minutes on a fresh host —
# so without this wait the first `make smoke` raced those first boots and left a
# green pipeline recorded as unfinished. Bounded, and idempotent: an already
# healthy stack returns immediately.
CTN_WAIT_MAX=420

# The containers this run is responsible for: the edge + every enabled module.
enabled_containers() {
  local m c _decl
  printf '%s' caddy
  while IFS= read -r m; do
    mod_on "$m" || continue
    _decl="$(awk -v x="$m" '$1 !~ /^#/ && $1 == x { $1=""; $2=""; $3=""; sub(/^ +/,""); print; exit }' "$REPO/config/modules.conf" 2>/dev/null)"
    for c in $_decl; do printf ' %s' "$c"; done
  done < <(awk '$1 !~ /^#/ && NF { print $1 }' "$REPO/config/modules.conf" 2>/dev/null)
}

# wait_containers — bounded wait until every one runs (and reports healthy when
# its compose file declares a healthcheck). Returns 1 on timeout.
wait_containers() {
  local i=0 c state health bad
  local ctns; ctns="$(enabled_containers)"
  while [ "$i" -lt "$CTN_WAIT_MAX" ]; do
    bad=""
    for c in $ctns; do
      state=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)
      health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$c" 2>/dev/null || true)
      case "$state" in
        running) [ -z "$health" ] || [ "$health" = healthy ] || bad="$bad $c:$health" ;;
        *) bad="$bad $c:$state" ;;
      esac
    done
    [ -z "$bad" ] && { detail "  every enabled container is up and healthy"; return 0; }
    [ "$i" -gt 0 ] && [ $((i % 30)) -eq 0 ] && log "  waiting for containers:${bad} (${i}s)"
    sleep 2; i=$((i+2))
  done
  CTN_NOT_READY="$bad"
  return 1
}

task_containers() {
  task_start
  cd "$REPO" || exit 1
  containers_up
  wait_containers || fail containers "not up/healthy after ${CTN_WAIT_MAX}s:${CTN_NOT_READY}"
  task_end
}
