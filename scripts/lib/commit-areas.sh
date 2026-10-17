#!/usr/bin/env bash
# scripts/lib/commit-areas.sh — the ONE definition of a commit's AREA and of
# what makes a commit SIGNIFICANT. SOURCED by the commit-hygiene tools so the
# checker and the rewriter never drift: scripts/info/git-audit.sh judges a
# range against these, scripts/info/git-split.sh rewrites a range to satisfy
# them.
#
# AREA (AGENTS rule 26, "one change per commit"): the unit a commit is judged
# and split on — `topdir/subdir` for a nested path, the path itself otherwise.
# Docs (`docs/*`, any `*.md`) are NOT an area: they describe the change they
# ride with, so they never make a commit a bundle.
#
# SIGNIFICANT (AGENTS rule 10): a security / structure / performance path — a
# change here can take a service offline or change how the box is reached, so
# its commit must ship a `Revert:` recipe. Monitoring-only scripts (scripts/info)
# are deliberately NOT significant.
#
# SOURCED, never executed.

# commit_area <path> — print the path's AREA, or return 1 for a doc path.
commit_area() {
  local p="$1" rest
  case "$p" in docs/*|*.md) return 1 ;; esac
  rest="${p#*/}"
  if [ "$rest" != "$p" ] && [ "${rest#*/}" != "$rest" ]; then
    printf '%s\n' "${p%%/*}/${rest%%/*}"
  else
    printf '%s\n' "$p"
  fi
}

# significant_path <path> — return 0 when the path is significant (rule 10).
significant_path() {
  case "$1" in
    Makefile) return 0 ;;
    modules/caddy/*) return 0 ;;
    modules/*/docker-compose.yml) return 0 ;;
    config/ssh/*|config/sysctl/*|config/systemd/*|config/docker/*|config/dnsmasq/*|config/cron/*|config/goose/*) return 0 ;;
    scripts/hooks/*|scripts/lib/*|scripts/install/*|scripts/render/*|scripts/stack/*|scripts/ops/*|scripts/access/*|scripts/modules/*) return 0 ;;
  esac
  return 1
}

# commit_areas <commit> — print the commit's sorted, unique AREAs (one per line).
# Renames are split into their delete + add so each side lands in its own area
# and no path is left unstaged when the commit is rewritten.
commit_areas() {
  local ns line p a
  ns=$(git diff-tree -r --name-status --no-commit-id --no-renames --root "$1" 2>/dev/null) || return 1
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    p="${line#*$'\t'}"; p="${p##*$'\t'}"
    a=$(commit_area "$p") || continue
    printf '%s\n' "$a"
  done <<< "$ns" | sort -u
}

# revert_parent_sha <commit> — the SHA named in the commit's
# `Revert: git reset --hard <sha>` line (rule 10), or nothing. Reads the real
# SHA so a rewriter can tell a stale recipe (names an old parent) from a fresh
# one. ${REPO:-.} lets the callers run from any cwd.
revert_parent_sha() {
  git -C "${REPO:-.}" log -1 --format='%B' "$1" 2>/dev/null \
    | sed -nE 's/^[[:space:]]*Revert:[[:space:]]*git reset --hard[[:space:]]+([0-9a-f]{7,40}).*/\1/p' \
    | head -1
}

# strip_revert — filter: drop `Revert:` lines. A rewriter replays a message and
# appends its OWN fresh recipe, so the old line (possibly now stale) must go.
strip_revert() { grep -vE '^[[:space:]]*Revert:'; }

# commit_revert_ok <commit> — 0 when the commit carries a `git reset --hard`
# Revert recipe naming its CURRENT parent (present and not stale). A root commit
# (no parent) is trivially ok.
commit_revert_ok() {
  local want got
  want=$(git -C "${REPO:-.}" rev-parse -q --verify "$1^" 2>/dev/null) || return 0
  got=$(revert_parent_sha "$1"); [ -n "$got" ] || return 1
  got=$(git -C "${REPO:-.}" rev-parse -q --verify "$got" 2>/dev/null) || return 1
  [ "$got" = "$want" ]
}
