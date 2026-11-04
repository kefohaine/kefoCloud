#!/usr/bin/env bash
# scripts/lib/hooks-fresh.sh — the installed hooks must be the copies this
# checkout tracks, because a hook runs the WORKTREE's scripts/lib/… .
#
# A hook reaches .git/hooks by copy (`make install-hooks`) and is never updated
# again on its own, so after a commit reshapes a library the hook sources, the
# installed copy keeps calling what the library no longer has. Observed
# (lesson 2026-11-05): `prepare-commit-msg: commit_folder: command not found` /
# `SIGNIFICANT_FILE_THRESHOLD: unbound variable` after the ten-file limit
# replaced the folder rule, which surfaced as a rebase that would not advance.
#
# hooks_fresh [<repo>] — 0 when every installed hook matches its tracked copy
# (or is not installed at all), 1 after naming each stale pair.

hooks_fresh() {
  local repo="${1:-$PWD}" hooksdir h stale=0
  hooksdir="$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)/hooks" || return 0
  for h in pre-commit prepare-commit-msg pre-push; do
    [ -f "$repo/scripts/hooks/$h" ] || continue
    [ -f "$hooksdir/$h" ] || continue          # never installed: nothing to compare
    cmp -s "$repo/scripts/hooks/$h" "$hooksdir/$h" && continue
    echo "  stale hook: $hooksdir/$h is not the copy scripts/hooks/$h holds"
    stale=1
  done
  [ "$stale" = 0 ] && return 0
  echo "  the hook and the lib it sources must come from the same tree — run: make install-hooks"
  return 1
}
