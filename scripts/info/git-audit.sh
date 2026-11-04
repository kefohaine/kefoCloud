#!/usr/bin/env bash
#
# scripts/info/git-audit.sh — monitor the git history for the commit-hygiene
# rule a commit cannot check about itself: AGENTS rule 26 (one change per
# commit: one folder, at most one subfolder inside it). READ-ONLY: it reports,
# it never rewrites history.
#
# Why it exists: the pre-commit hook only sees ONE staged change, and a commit
# made in the GitHub web editor runs no hook at all. This walks a finished
# revision range — the pre-push hook runs it over every pushed range — so a
# bundle is caught on the way OUT as well as in.
#
# Range: `git-audit.sh <range>` or RANGE=<range> (default: what a push would
# publish, i.e. `@{upstream}..HEAD`, falling back to `origin/main..HEAD`).
# Audit the whole published history with RANGE=origin/main.
#
# Checks (exit 1 when any is found, so a hook can gate on it):
#   BUNDLE  the diff spans more than one unit (rule 26) — the unit the
#           pre-commit hook splits on: the top-level folder, or `folder/subdir`
#           when that folder has several subfolders involved, ignoring `*.md`
#           and docs/ (the docs that describe a change ride with it). Order
#           changes so each stands alone.
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

# SCOPE (rule 26) comes from scripts/lib/commit-areas.sh — the same definition
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

echo "${B}git-audit${N}: ${C}$range${N} ${D}($n commits)${N}"

bundles=0
for c in $commits; do
  short=${c:0:9}
  subject=$(G log -1 --format='%s' "$c")
  # name-status of the commit's own diff (renames detected, root-safe).
  ns=$(G diff-tree -r --name-status --no-commit-id -M --root "$c" 2>/dev/null)
  [ -z "$ns" ] && continue

  paths=''
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    p=${line#*$'\t'}; p=${p##*$'\t'}                  # R100\told\tnew -> new
    paths="$paths$p"$'\n'
  done <<< "$ns"

  units=$(printf '%s' "$paths" | commit_units | paste -sd, -)
  nunits=$(printf '%s' "$units" | tr ',' '\n' | grep -c . || true)
  if [ "${nunits:-0}" -gt 1 ]; then
    bundles=$((bundles + 1))
    printf '  %sBUNDLE%s %s  %s\n' "$Y" "$N" "$short" "$subject"
    printf '         %sunits:%s %s\n' "$D" "${units}" "$N"
    printf '         %ssplit it: git rebase -i %s^  →  one change per commit (rule 26)%s\n' "$D" "$c" "$N"
  fi
done

if [ "${HISTORY_AUDIT_OVERRIDE:-}" = "1" ]; then
  echo "${D}HISTORY_AUDIT_OVERRIDE=1 — ${bundles} bundle(s) reported, not enforced${N}"
  exit 0
fi
if [ "$bundles" -ne 0 ]; then
  echo ""
  echo "${R}$bundles bundle(s)${N} — rule 26 wants one change per commit (one folder, at most one subfolder)."
  exit 1
fi
echo "  ${B}clean${N} ${D}— every commit is one change${N}"
exit 0
