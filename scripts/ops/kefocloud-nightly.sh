#!/usr/bin/env bash
# scripts/ops/kefocloud-nightly.sh — the project's own nightly pair, one window.
#
# Run by kefocloud.timer shortly before midnight, ahead of maintenance.timer:
#   * one Kopia snapshot — the restore point that PREDATES the upgrade the
#     maintenance window applies minutes later, and the long, fragile step
#     (tailnet + external storage) started while the link and the disk are idle;
#   * one local-branch prune — the branches whose pull requests landed.
#
# Both steps are ADAPTIVE and neither is fatal here. The kopia step is skipped
# when the module is not installed, the prune when no GitHub credential is
# usable (an authenticated `gh`, or GITHUB_TOKEN/GH_TOKEN); whichever is absent
# is named in the journal and the window still exits 0. That is the trade this
# unit makes: a nightly run must not turn into a failed unit every day because a
# module is not installed or a token expired — the manual commands keep failing
# loudly (`make backup`, `make git-prune`).
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
. "$ROOT/scripts/lib/instance.sh" 2>/dev/null || true
. "$ROOT/scripts/lib/modules.sh"
. "$ROOT/scripts/lib/dryrun.sh"

say() { printf 'kefocloud: %s\n' "$*"; }

dryrun_wanted "$@" && DRY=1
dryrun_args "$@"

# github_ok — 0 when a credential the git recipes can actually use is present.
# `gh auth status` is the only honest test for a gh login; the token variables
# are what the REST fallback in scripts/ops/git-pr.sh reads.
github_ok() {
  [ -n "${GITHUB_TOKEN:-}${GH_TOKEN:-}" ] && return 0
  command -v gh >/dev/null 2>&1 || return 1
  timeout 30 gh auth status >/dev/null 2>&1
}

kopia_wanted=0
mod_installed kopia && kopia_wanted=1

[ "${DRY:-0}" = 1 ] && {
  dryrun_note "kopia module installed: $([ "$kopia_wanted" = 1 ] && echo yes || echo no) — snapshot $([ "$kopia_wanted" = 1 ] && echo 'would run' || echo 'skipped')"
  dryrun_note "github credential usable: $(github_ok && echo yes || echo no) — prune $(github_ok && echo 'would run' || echo 'skipped')"
  dryrun_end "nothing changed"
}

# The two steps share one lock with maintenance.sh, so a snapshot still
# uploading at midnight makes the upgrade window wait instead of racing it.
[ -d "${DATA_DIR:-$ROOT/data}" ] || { say "${DATA_DIR:-$ROOT/data} is missing — nothing to do"; exit 0; }
exec 9>"${DATA_DIR:-$ROOT/data}/.nightly.lock" || { say "cannot open the nightly lock"; exit 0; }
flock -w 30 9 || { say "the nightly lock is held — another window is running"; exit 0; }

if [ "$kopia_wanted" = 1 ]; then
  SCHEDULED=1 "$ROOT/scripts/ops/kopia-snapshot.sh" \
    || say "snapshot step reported a problem — see the lines above (scheduled runs skip instead of failing)"
else
  say "module kopia is not installed — no snapshot this window"
fi

if github_ok; then
  "$ROOT/scripts/ops/git-prune.sh" \
    || say "prune step could not reach the remote — kept every local branch this window"
else
  say "no usable GitHub credential (no authenticated gh, no GITHUB_TOKEN/GH_TOKEN) — branch prune skipped"
fi

exit 0
