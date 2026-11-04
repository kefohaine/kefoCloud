#!/usr/bin/env bash
# scripts/lib/commit-areas.sh — the ONE definition of a commit's SCOPE.
# SOURCED by the commit-hygiene tools so the checker and the rewriter never
# drift: scripts/info/git-audit.sh judges a range against these,
# scripts/info/git-split.sh rewrites a range to satisfy them.
#
# SCOPE (AGENTS rule 26): a commit edits at most COMMIT_MAX_FILES tracked files
# (10). Nothing else is bounded — no folder, no subfolder, no change type. A
# wider change is split automatically into consecutive chunks of the sorted
# path list, so a chunk is the unit a commit is judged and split on.
#
# SOURCED, never executed.

COMMIT_MAX_FILES="${COMMIT_MAX_FILES:-10}"

# commit_unit_map — stdin: paths, one per line. Sorts them and prints
# `chunk<TAB>path`, chunking the sorted list into groups of at most
# COMMIT_MAX_FILES. Blank lines are ignored.
commit_unit_map() {
  awk 'NF' | LC_ALL=C sort -u \
    | awk -v max="$COMMIT_MAX_FILES" '{ printf "%d\t%s\n", int((NR - 1) / max) + 1, $0 }'
}

# commit_units — stdin: paths, one per line. Prints the commit's sorted, unique
# chunks. More than one means the change is wider than one commit may be.
commit_units() { commit_unit_map | cut -f1 | sort -un; }

# commit_units_for <commit> — print the commit's sorted, unique chunks.
# Renames are split into their delete + add.
commit_units_for() {
  local ns
  ns=$(git -C "${REPO:-.}" diff-tree -r --name-status --no-commit-id --no-renames --root "$1" 2>/dev/null) || return 1
  [ -n "$ns" ] || return 0
  printf '%s\n' "$ns" | cut -f2 | commit_units
}
