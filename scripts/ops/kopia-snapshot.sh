#!/usr/bin/env bash
# scripts/ops/kopia-snapshot.sh — one Kopia snapshot, run by kefocloud.timer.
#
# Kopia runs as an idle client container with no server: this script is the only
# thing that makes it do work. It refuses to guess — a missing module or a
# container that is down is one thing, a repository it cannot open is another —
# and exits non-zero on a real failure so a manual run says so and can be fixed.
#
# Container name, snapshot source and repository config are read from the running
# container (scripts/lib/kopia-env.sh): nothing here names a path or a container.
#
# TWO CONTEXTS, one script. A SCHEDULED run (kefocloud-nightly.sh sets
# SCHEDULED=1 for its own call — the ONLY signal, since every systemd-started
# shell inherits INVOCATION_ID and a manual `make backup` run from such a shell
# would then skip silently) SKIPS instead of failing: an asleep storage host, an expired key or a stopped container must
# not turn every night into a red unit, and the skip is still written to the
# journal. A MANUAL run (`make backup`, or the script run by hand) keeps failing
# loudly — that is the run whose outcome the operator is waiting for.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
. "$ROOT/scripts/lib/instance.sh" 2>/dev/null || true
. "$ROOT/scripts/lib/modules.sh"
. "$ROOT/scripts/lib/kopia-env.sh"

# Scheduled context: the nightly window's explicit flag, nothing inferred.
scheduled=0
[ "${SCHEDULED:-}" = 1 ] && scheduled=1

# die <message> — the ONE exit path for "cannot snapshot". Scheduled runs log
# the reason and exit 0 (the window continues); manual runs exit 1.
die() {
  if [ "$scheduled" = 1 ]; then
    printf 'kopia-snapshot: %s — skipped (scheduled run)\n' "$1"
    exit 0
  fi
  printf 'kopia-snapshot: %s\n' "$1" >&2
  exit 1
}

# A module that is not installed is ABSENT (no container, no repository, no
# route) — there is nothing to back up, and a failing unit every day would be a
# lie about this host.
mod_installed kopia || { echo "kopia-snapshot: module kopia is not installed — nothing to do"; exit 0; }

kopia_live \
  || die "container '$(mod_containers kopia)' is absent — snapshots stopped"

docker ps --format '{{.Names}}' | grep -qx "$KOPIA_CTN" \
  || die "container '$KOPIA_CTN' is not running — snapshots stopped"

# The repository password lives in the module's .env (make kopia-gen seeded it).
ENVF="${REPO_DIR:-$ROOT}/modules/kopia/.env"
if [ -f "$ENVF" ]; then . "$ENVF"; fi
[ -n "${KOPIA_PASSWORD:-}" ] || die "KOPIA_PASSWORD is unset in $ENVF — run 'make kopia-gen'"

# One snapshot at a time: a manual `make backup` in progress means this data is
# already being captured, so this run steps aside instead of racing it.
kopia_lock -n \
  || { echo "kopia-snapshot: another snapshot is running — skipping this window"; exit 0; }

k() { docker exec -e KOPIA_PASSWORD="$KOPIA_PASSWORD" "$KOPIA_CTN" kopia --config-file="$KOPIA_CONFIG" "$@"; }

k repository status >/dev/null 2>&1 \
  || die "repository unreachable (storage host asleep, volume unmounted, or key refused) — run 'make kopia-status'"

# What is excluded is a POLICY on the source (set by `make kopia-init`), not a
# flag here: `kopia snapshot create` has no --exclude.
# The upload itself is the last thing that can fail (storage full, link dropped
# mid-transfer): captured, then routed through the same exit path.
if ! out="$(docker exec -e KOPIA_PASSWORD="$KOPIA_PASSWORD" "$KOPIA_CTN" \
              kopia --config-file="$KOPIA_CONFIG" snapshot create "$KOPIA_SOURCE" 2>&1)"; then
  printf '%s\n' "$out"
  die "snapshot create failed"
fi
printf '%s\n' "$out"
