#!/usr/bin/env bash
# scripts/lib/work-branch.sh — the ONE definition of the work-branch naming
# scheme. SOURCED by the installer (wizard.d/lib/github.sh), scripts/ops/git-pr.sh
# and the hooks, so the name a change lands on is decided in exactly one place.
#
# Every change reaches `main` through a branch named `work-<N>`, N a counter:
# work-1, work-2, work-3 … Nothing may push to `main` (AGENTS rule 30); the
# branch is created off a freshly pulled `main`, pushed, and merged through a
# human-reviewed pull request. The counter is always DERIVED from the branches
# that exist (local and on `origin`) — never stored in a file, never hardcoded,
# so two checkouts cannot pick the same name.
#
# SOURCED, never executed.

# The branch every change is based on and merged back into.
WORK_BASE_BRANCH=main

# work_branch_find <path-to-repo> — print every existing work-<N> number
# (local branches plus origin's), one per line, unsorted.
work_branch_numbers() {
  local repo="${1:-.}"
  git -C "$repo" for-each-ref --format='%(refname:short)' \
    refs/heads refs/remotes/origin 2>/dev/null \
    | sed -n 's#^\(origin/\)\{0,1\}work-\([0-9][0-9]*\)$#\2#p'
}

# work_branch_next <path-to-repo> — print the next free name: work-<max+1>.
work_branch_next() {
  local repo="${1:-.}" n max=0
  for n in $(work_branch_numbers "$repo"); do
    [ "$n" -gt "$max" ] 2>/dev/null && max="$n"
  done
  printf 'work-%s\n' "$((max + 1))"
}

# work_branch_is_main <ref> — 0 when the ref names the base branch (any form:
# main, refs/heads/main, origin/main, refs/remotes/origin/main). Used by the
# guards that must never touch main.
work_branch_is_main() {
  case "${1:-}" in
    "$WORK_BASE_BRANCH"|refs/heads/"$WORK_BASE_BRANCH"|origin/"$WORK_BASE_BRANCH"|refs/remotes/origin/"$WORK_BASE_BRANCH") return 0 ;;
  esac
  return 1
}

# work_branch_is_work <ref> — 0 when the ref is a work-<N> branch (short form).
work_branch_is_work() {
  case "${1:-}" in work-[0-9]*) return 0 ;; esac
  return 1
}
