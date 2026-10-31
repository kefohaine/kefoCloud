#!/usr/bin/env bash
# scripts/lib/temp-branch.sh — the ONE definition of the working-branch naming
# scheme. SOURCED by the installer (wizard.d/lib/github.sh, wizard.d/tasks/07-repo.sh),
# scripts/ops/git-pr.sh and the hooks, so the name a change lands on is decided
# in exactly one place.
#
# Every change reaches the base branch through a branch named `temp-<N>`, N a
# counter: temp-1, temp-2, temp-3 … Nothing may push to `main` (AGENTS rule 30);
# the branch is created off a freshly pulled `main`, pushed, and merged through a
# human-reviewed pull request. The counter is always DERIVED from the branches
# that exist (local and on `origin`) — never stored in a file, never hardcoded,
# so two checkouts cannot pick the same name.
#
# SOURCED, never executed.

# The branch every change is based on and merged back into.
TEMP_BASE_BRANCH=main

# temp_branch_numbers <path-to-repo> — print every existing temp-<N> number
# (local branches plus origin's), one per line, unsorted.
temp_branch_numbers() {
  local repo="${1:-.}"
  git -C "$repo" for-each-ref --format='%(refname:short)' \
    refs/heads refs/remotes/origin 2>/dev/null \
    | sed -n 's#^\(origin/\)\{0,1\}temp-\([0-9][0-9]*\)$#\2#p'
}

# temp_branch_next <path-to-repo> — print the next free name: temp-<max+1>.
temp_branch_next() {
  local repo="${1:-.}" n max=0
  for n in $(temp_branch_numbers "$repo"); do
    [ "$n" -gt "$max" ] 2>/dev/null && max="$n"
  done
  printf 'temp-%s\n' "$((max + 1))"
}

# temp_branch_is_base <ref> — 0 when the ref names the base branch (any form:
# main, refs/heads/main, origin/main, refs/remotes/origin/main). Used by the
# guards that must never touch the base.
temp_branch_is_base() {
  case "${1:-}" in
    "$TEMP_BASE_BRANCH"|refs/heads/"$TEMP_BASE_BRANCH"|origin/"$TEMP_BASE_BRANCH"|refs/remotes/origin/"$TEMP_BASE_BRANCH") return 0 ;;
  esac
  return 1
}

# temp_branch_is_temp <ref> — 0 when the ref is a temp-<N> branch (short form).
temp_branch_is_temp() {
  case "${1:-}" in temp-[0-9]*) return 0 ;; esac
  return 1
}

# temp_branch_name <ref-or-number> — print the short branch name, so every verb
# accepts the forms a human types: 3, temp-3, refs/heads/temp-3, origin/temp-3.
temp_branch_name() {
  local b="${1:-}"
  b="${b#refs/heads/}"
  b="${b#refs/remotes/}"
  b="${b#origin/}"
  printf '%s\n' "$b"
}

# temp_branch_exists <path-to-repo> <branch> — 0 when <branch> exists locally
# or on origin.
temp_branch_exists() {
  local repo="${1:-.}" b="$2"
  git -C "$repo" rev-parse --verify -q "refs/heads/$b" >/dev/null 2>&1 && return 0
  git -C "$repo" rev-parse --verify -q "refs/remotes/origin/$b" >/dev/null 2>&1
}
