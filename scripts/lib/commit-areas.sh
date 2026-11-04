#!/usr/bin/env bash
# scripts/lib/commit-areas.sh — the ONE definition of a commit's SCOPE.
# SOURCED by the commit-hygiene tools so the checker and the rewriter never
# drift: scripts/info/git-audit.sh judges a range against these,
# scripts/info/git-split.sh rewrites a range to satisfy them.
#
# SCOPE (AGENTS rule 26, "one change per commit"): a commit may touch ONE
# top-level folder and at most ONE subfolder inside it:
#   folder_a/file_1 + folder_a/file_2 + folder_a/sub_1/file_3   allowed
#   folder_a/file_1 + folder_a/sub_1/file_2 + folder_a/sub_2/f  forbidden
# The unit a commit is judged and split on is therefore the folder itself when
# the folder has one (or no) subfolder involved, and `folder/subfolder` when it
# has several — then each subfolder is its own unit and the folder's own files
# form one more. A repo-root file is a unit of its own folder `.`. Docs
# (`docs/*`, any `*.md`) are NOT part of the rule: they describe the change
# they ride with, so they never make a commit a bundle.
#
# SOURCED, never executed.

# commit_folder <path> — print the path's top-level folder (`.` for a repo-root
# file), or return 1 for a doc path (docs/`, any `*.md`), which has no scope.
commit_folder() {
  local p="$1"
  case "$p" in docs/*|*.md) return 1 ;; esac
  case "$p" in
    */*) printf '%s\n' "${p%%/*}" ;;
    *)   printf '.\n' ;;
  esac
}

# commit_subdir <path> — print the path's second-level folder, or nothing when
# the path is the folder's own file (or a repo-root file). Doc paths return 1.
commit_subdir() {
  local p="$1" rest
  case "$p" in docs/*|*.md) return 1 ;; esac
  rest="${p#*/}"
  [ "$rest" = "$p" ] && return 0           # repo-root file: no subfolder
  case "$p" in
    */*/*) printf '%s\n' "${rest%%/*}" ;;  # folder/sub/file or deeper
  esac
  return 0
}

# commit_unit_map — stdin: paths, one per line. Prints `unit<TAB>path` for every
# non-doc path. The unit is the folder, except inside a folder that has several
# subfolders involved: there each subfolder and the folder's own files are their
# own units (a `folder/subfolder` commit and a `folder` one).
commit_unit_map() {
  local -a paths=() folders=() subs=()
  local p f s i j u uniq nsub
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    f=$(commit_folder "$p") || continue
    s=$(commit_subdir "$p") || s=''
    paths+=("$p"); folders+=("$f"); subs+=("$s")
  done
  for i in "${!paths[@]}"; do
    f=${folders[$i]} uniq='' nsub=0
    for j in "${!paths[@]}"; do
      [ "${folders[$j]}" = "$f" ] || continue
      s=${subs[$j]}
      [ -n "$s" ] || continue
      case " $uniq " in *" $s "*) continue ;; esac
      uniq="$uniq $s" nsub=$((nsub + 1))
    done
    if [ -n "${subs[$i]}" ] && [ "$nsub" -gt 1 ]; then u="$f/${subs[$i]}"; else u="$f"; fi
    printf '%s\t%s\n' "$u" "${paths[$i]}"
  done
  return 0
}

# commit_units — stdin: paths, one per line. Prints the commit's sorted, unique
# units. ONE unit is exactly the rule: one folder, at most one subfolder.
commit_units() { commit_unit_map | cut -f1 | sort -u; }

# commit_units_for <commit> — print the commit's sorted, unique units. Renames
# are split into their delete + add so each side lands in its own unit.
commit_units_for() {
  local ns
  ns=$(git -C "${REPO:-.}" diff-tree -r --name-status --no-commit-id --no-renames --root "$1" 2>/dev/null) || return 1
  [ -n "$ns" ] || return 0
  printf '%s\n' "$ns" | cut -f2 | commit_units
}
