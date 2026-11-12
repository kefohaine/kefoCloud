#!/usr/bin/env bash
# scripts/ops/kopia-snapshot.sh — one Kopia snapshot, run by kopia-snapshot.timer.
#
# Kopia runs as an idle client container with no server: this script is the only
# thing that makes it do work. It refuses to guess — a missing module or a
# container that is down is one thing, a repository it cannot open is another —
# and exits non-zero on a real failure so systemd records it (`systemctl --failed`,
# `journalctl -u kopia-snapshot`).
#
# Container name, snapshot source and repository config are read from the running
# container (scripts/lib/kopia-env.sh): nothing here names a path or a container.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
. "$ROOT/scripts/lib/instance.sh" 2>/dev/null || true
. "$ROOT/scripts/lib/modules.sh"
. "$ROOT/scripts/lib/kopia-env.sh"

# A module that is not installed is ABSENT (no container, no repository, no
# route) — there is nothing to back up, and a failing unit every day would be a
# lie about this host.
mod_installed kopia || { echo "kopia-snapshot: module kopia is not installed — nothing to do"; exit 0; }

kopia_live \
  || { echo "kopia-snapshot: container '$(mod_containers kopia)' is absent — snapshots stopped" >&2; exit 1; }

docker ps --format '{{.Names}}' | grep -qx "$KOPIA_CTN" \
  || { echo "kopia-snapshot: container '$KOPIA_CTN' is not running — snapshots stopped" >&2; exit 1; }

# The repository password lives in the module's .env (make kopia-gen seeded it).
ENVF="${REPO_DIR:-$ROOT}/modules/kopia/.env"
if [ -f "$ENVF" ]; then . "$ENVF"; fi
[ -n "${KOPIA_PASSWORD:-}" ] || { echo "kopia-snapshot: KOPIA_PASSWORD is unset in $ENVF — run 'make kopia-gen'" >&2; exit 1; }

# One snapshot at a time: a manual `make backup` in progress means this data is
# already being captured, so this run steps aside instead of racing it.
kopia_lock -n \
  || { echo "kopia-snapshot: another snapshot is running — skipping this window"; exit 0; }

k() { docker exec -e KOPIA_PASSWORD="$KOPIA_PASSWORD" "$KOPIA_CTN" kopia --config-file="$KOPIA_CONFIG" "$@"; }

k repository status >/dev/null 2>&1 \
  || { echo "kopia-snapshot: repository unreachable (off-box disk asleep, unmounted, or key refused) — run 'make kopia-status'" >&2; exit 1; }

# What is excluded is a POLICY on the source (set by `make kopia-init`), not a
# flag here: `kopia snapshot create` has no --exclude.
exec docker exec -e KOPIA_PASSWORD="$KOPIA_PASSWORD" "$KOPIA_CTN" \
  kopia --config-file="$KOPIA_CONFIG" snapshot create "$KOPIA_SOURCE"
