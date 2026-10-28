# wizard.d/lib/svc.sh — service helpers shared by tasks and modules (container probes, credential change notes).

docker_net() {
  # Create the bridge only when it is missing: the plain `create ... || true`
  # logged "Error response from daemon: network with name net already exists"
  # on every re-run, which reads like a failure in wizard.log for a no-op.
  docker network inspect net >/dev/null 2>&1 \
    || docker network create net --subnet=172.22.0.0/16 >>"$LOG" 2>&1 || true
}


# ── repair-mode skip helpers ────────────────────────────────────────────────
# A REPAIR run must honor what is already applied: a service whose containers
# are all running AND whose inputs hash unchanged since the run that brought
# them up is left alone. Fresh runs always recreate — fresh has nothing to
# compare against. The
# hash covers everything that shapes the runtime config: the rendered instance
# values plus every file in the module directory (compose files, .env,
# Caddyfile/vhosts, Dockerfile, configs). It is recorded per service group in
# data/.svc-<group>.sha by whichever run applied it, so a later repair that
# finds the operator tweaked wizard.state or instance.conf re-applies exactly
# the changed groups and skips the rest.
container_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]
}

svc_inputs() { # svc_inputs <module-dir>... (relative to $REPO) -> sha256
  {
    printf -- '--- instance.conf\n'
    cat "$DATA/instance.conf" 2>/dev/null
    local d f
    for d in "$@"; do
      [ -d "$REPO/$d" ] || continue
      while IFS= read -r -d '' f; do
        printf -- '--- %s\n' "${f#"$REPO"/}"
        cat "$f"
      done < <(find "$REPO/$d" -type f -print0 2>/dev/null | sort -z)
    done
  } | sha256sum | cut -d' ' -f1
}

svc_skip_repair() { # svc_skip_repair <group> <dir>... -- <container>...
  [ "${REPAIR:-false}" = true ] || return 1   # only repair honors applied state
  local group=$1; shift
  local dirs=() c old h
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do dirs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  for c in "$@"; do container_running "$c" || return 1; done
  h="$(svc_inputs "${dirs[@]}")"
  old="$(cat "$DATA/.svc-$group.sha" 2>/dev/null || true)"
  [ "$h" = "$old" ]
}

svc_note_applied() { # svc_note_applied <group> <dir>... -- (containers unused)
  local group=$1; shift
  local dirs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do dirs+=("$1"); shift; done
  svc_inputs "${dirs[@]}" > "$DATA/.svc-$group.sha" 2>/dev/null || true
}

# ── credential change detection ──
# wizard.state is the source of truth: a credential (TS_AUTHKEY, CF_API_TOKEN)
# whose value differs from the one recorded when it was last APPLIED is redone
# on a repair; an unchanged credential is not re-applied. The value itself is
# never written — only its sha256, in data/.cred-<name>.sha.
cred_hash() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
cred_changed() { # cred_changed <name> <value> -> 0 when changed (or never recorded)
  [ "${REPAIR:-false}" = true ] || return 1
  [ "$(cred_hash "$2")" != "$(cat "$DATA/.cred-$1.sha" 2>/dev/null || true)" ]
}
cred_note() { cred_hash "$2" > "$DATA/.cred-$1.sha" 2>/dev/null || true; }

# Toggling a module OFF in wizard.state (repair) hands the granular teardown to
# uninstall.sh (--granular, WIZARD_REPAIR=1) — that mode is RESERVED for this
# call: it removes only the disabled modules' containers, compose stacks, data
# dirs and stale .svc hashes, and deletes disabled doors' CF A records.
# true->false applies just like false->true; enabled modules are untouched and
# the repair run below converges the rest itself.
module_off_teardown() {
  [ "${REPAIR:-false}" = true ] || return 0
  log "  hand-off: granular teardown (uninstall.sh --granular)"
  WIZARD_REPAIR=1 bash "$REPO/scripts/install/uninstall.sh" --granular >>"$LOG" 2>&1 \
    || log "  granular teardown reported errors — see uninstall.log"
  return 0
}
