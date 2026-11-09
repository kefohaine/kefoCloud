#!/usr/bin/env bash
#
# scripts/info/git-audit.sh — monitor the git history for the commit-hygiene
# rule a commit cannot check about itself: a commit edits at
# most ten files). READ-ONLY: it reports, it never rewrites history.
#
# Why it exists: the pre-commit hook only sees ONE staged change, and a commit
# made in the GitHub web editor runs no hook at all. This walks a finished
# revision range — the pre-push hook runs it over every pushed range — so an
# oversized commit is caught on the way OUT as well as in.
#
# Range: `git-audit.sh <range>` or RANGE=<range> (default: what a push would
# publish, i.e. `@{upstream}..HEAD`, falling back to `origin/main..HEAD`).
# Audit the whole published history with RANGE=origin/main.
#
# Checks (exit 1 when any is found, so a hook can gate on it):
#   TOO BIG  the commit edits more than COMMIT_MAX_FILES files —
#            the limit the prepare-commit-msg hook splits on.
#
# HISTORY_AUDIT_OVERRIDE=1 reports and exits 0.

. "$(dirname "$(readlink -f "$0")")/../lib/instance.sh" 2>/dev/null || true
. "$(dirname "$(readlink -f "$0")")/../lib/commit-areas.sh"
set -uo pipefail

REPO="${REPO_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)}"
G() { git -C "$REPO" "$@"; }

range="${1:-${RANGE:-}}"
if [ -z "$range" ]; then
  up=$(G rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
  for cand in "$up" origin/main origin/master; do
    [ -n "$cand" ] && G rev-parse --verify -q "$cand" >/dev/null 2>&1 \
      && { range="$cand..HEAD"; break; }
  done
fi
if [ -z "$range" ]; then
  echo "usage: git-audit.sh <range>   (or RANGE=<range>; no upstream to default to)" >&2
  exit 2
fi

# SCOPE comes from scripts/lib/commit-areas.sh — the same limit
# git-split.sh rewrites against, so the two never drift.

commits=$(G rev-list --reverse "$range" 2>/dev/null || true)
if [ -z "$commits" ]; then
  echo "git-audit: range '$range' is empty — nothing to check"
  exit 0
fi
n=$(printf '%s\n' "$commits" | grep -c . || true)

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m' D=$'\033[2m' R=$'\033[31m' Y=$'\033[33m' C=$'\033[36m' N=$'\033[0m'
else
  B='' D='' R='' Y='' C='' N=''
fi

echo "${B}git-audit${N}: ${C}$range${N} ${D}($n commits, max $COMMIT_MAX_FILES files each)${N}"

oversize=0
for c in $commits; do
  short=${c:0:9}
  subject=$(G log -1 --format='%s' "$c")
  # name-status of the commit's own diff (renames detected, root-safe).
  ns=$(G diff-tree -r --name-status --no-commit-id -M --root "$c" 2>/dev/null)
  [ -z "$ns" ] && continue

  nfiles=$(printf '%s\n' "$ns" | grep -c . || true)
  if [ "${nfiles:-0}" -gt "$COMMIT_MAX_FILES" ]; then
    oversize=$((oversize + 1))
    printf '  %sTOO BIG%s %s  %s\n' "$Y" "$N" "$short" "$subject"
    printf '         %s%d files (max %d)%s\n' "$D" "$nfiles" "$COMMIT_MAX_FILES" "$N"
    printf '         %ssplit it: make git-split RANGE=%s^..%s%s\n' "$D" "$c" "$c" "$N"
  fi
done

if [ "${HISTORY_AUDIT_OVERRIDE:-}" = "1" ]; then
  echo "${D}HISTORY_AUDIT_OVERRIDE=1 — ${oversize} oversized commit(s) reported, not enforced${N}"
  exit 0
fi
if [ "$oversize" -ne 0 ]; then
  echo ""
  echo "${R}$oversize oversized commit(s)${N} — at most $COMMIT_MAX_FILES files per commit."
  exit 1
fi
echo "  ${B}clean${N} ${D}— every commit is within the file limit${N}"
exit 0
