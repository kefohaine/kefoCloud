#!/usr/bin/env bash
# scripts/ops/git-prune.sh — drop LOCAL branches whose pull request has landed.
#
# GitHub deletes the branch on `origin` when a pull request is merged, so the
# local copy is left pointing at a remote branch that no longer exists: `git
# branch -vv` shows `[gone]`, and `make git-branch` then refuses because the
# checkout sits on a temp branch with commits ahead of the base. This script
# removes exactly those, and nothing else.
#
# A branch is deleted only when BOTH hold:
#   * its upstream is gone after `fetch --prune` (the record of a landed pull
#     request), and
#   * the work is verifiably in the base — either its commits are ancestors of
#     `origin/<base>` (fast-forward / merge commit), or the tracker reports a
#     MERGED pull request for that head (what a squash merge leaves behind).
# A gone branch that is neither is KEPT and named in the output: losing commits
# is never the cheaper mistake. The base and the current branch are never
# touched, and nothing here reaches the remote beyond `fetch --prune`.
#
# Run by kefocloud.timer once a night (skipped there when no GitHub credential is
# usable); the plan is `DRYRUN=1 bash scripts/ops/git-prune.sh`.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
. "$ROOT/scripts/lib/instance.sh" 2>/dev/null || true
. "$ROOT/scripts/lib/temp-branch.sh"
. "$ROOT/scripts/lib/dryrun.sh"

REPO="${REPO_DIR:-$ROOT}"
BASE="$TEMP_BASE_BRANCH"
REMOTE=origin
# A stalled network must fail this window, not hold it: the fetch is the only
# thing here that can block.
FETCH_BUDGET=120
GH_BUDGET=30

say() { printf 'git-prune: %s\n' "$*"; }

dryrun_wanted "$@" && DRY=1
dryrun_args "$@"

git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
  || { say "$REPO is not a git checkout — nothing to prune"; exit 1; }

if ! timeout "$FETCH_BUDGET" git -C "$REPO" fetch "$REMOTE" --prune --quiet 2>/dev/null; then
  say "cannot reach $REMOTE — kept every local branch this run"
  exit 1
fi

git -C "$REPO" rev-parse --verify -q "refs/remotes/$REMOTE/$BASE" >/dev/null \
  || { say "$REMOTE/$BASE is missing — no safe merge target, nothing pruned"; exit 1; }

cur="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)"

# tracker_merged <branch> — 0 when GitHub reports a merged pull request whose
# head was <branch>. gh absent or unsigned means "cannot tell", never "yes".
tracker_merged() {
  command -v gh >/dev/null 2>&1 || return 1
  ( cd "$REPO" && timeout "$GH_BUDGET" gh pr list --state merged --head "$1" \
      --limit 1 --json number --jq '.[0].number' 2>/dev/null ) | grep -q '[0-9]'
}

pruned=0 kept=0

# Candidates are the branches whose upstream tracking info is exactly `[gone]`
# — the marker `fetch --prune` leaves behind. Deriving them here, rather than
# from a stored list, means a branch that reappears on origin simply stops
# being a candidate.
while read -r b; do
  [ -n "$b" ] || continue
  temp_branch_is_base "$b" && continue
  [ "$b" = "$cur" ] && { say "current branch $b — kept"; continue; }

  if ! git -C "$REPO" merge-base --is-ancestor "refs/heads/$b" "refs/remotes/$REMOTE/$BASE" 2>/dev/null \
     && ! tracker_merged "$b"; then
    say "$b: upstream gone, but no merged pull request and no commits in $BASE — kept"
    kept=$((kept + 1))
    continue
  fi

  if [ "${DRY:-0}" = 1 ]; then
    dryrun_plan "delete local branch $b (landed)"
    pruned=$((pruned + 1))
    continue
  fi

  if git -C "$REPO" branch -D "$b" >/dev/null 2>&1; then
    say "deleted local branch $b"
    pruned=$((pruned + 1))
  else
    say "$b: delete refused (checked out in another worktree?) — kept"
    kept=$((kept + 1))
  fi
done < <(git -C "$REPO" for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads \
          | awk '$2 == "[gone]" { print $1 }')

[ "${DRY:-0}" = 1 ] && dryrun_end "$pruned branch(es) would go, $kept kept"
say "$pruned branch(es) pruned, $kept kept"
