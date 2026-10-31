#!/usr/bin/env bash
# scripts/ops/git-pr.sh — the branch + pull-request workflow, in one place.
#
# `main` is write-once (AGENTS rule 30): every change is made on a branch named
# `work-<N>` created off a freshly pulled `main`, pushed, and merged through a
# pull request that a HUMAN reviews and accepts on GitHub. Nothing here (or
# anywhere else in the repo) can push `main` — scripts/hooks/pre-push refuses
# that destination outright, so a mistake fails loudly instead of publishing.
#
# Delegate every step through the Makefile: `make git-start`, `make git-pr`,
# `make git-land`. The naming scheme (work-1, work-2, … derived from the
# branches that exist) lives in scripts/lib/work-branch.sh, the SAME definition
# the installer uses — it is never restated here.
#
# Usage:
#   git-pr.sh start  [--dry-run]   create + switch to the next work-<N> off origin/main
#   git-pr.sh status [--dry-run]   where this checkout stands (branch, commits, base)
#   git-pr.sh submit [--dry-run]   audit + push the branch + print the compare URL and PR body
#   git-pr.sh land   [--dry-run]   after the PR is merged: main fast-forward, delete the local branch
#
# A --dry-run only reads and prints: nothing is fetched, created, committed,
# pushed or deleted. That is the mode an agent may exercise (AGENTS rule 29).

set -uo pipefail
export LC_ALL=C

REPO="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
. "$REPO/scripts/lib/work-branch.sh"

info()  { "${REPO}/scripts/lib/mklog" info  "$*" 2>/dev/null || echo "info:  $*"; }
warn()  { "${REPO}/scripts/lib/mklog" warn  "$*" 2>/dev/null || echo "warn:  $*"; }
error() { "${REPO}/scripts/lib/mklog" error "$*" 2>/dev/null || echo "error: $*"; }

G() { git -C "$REPO" "$@"; }

cmd="${1:-status}"
shift 2>/dev/null || true
DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run|-n) DRY=1 ;;
    *) error "unknown argument '$a'"; exit 1 ;;
  esac
done
run() { if [ "$DRY" = 1 ]; then printf '  would run: %s\n' "$*"; else "$@"; fi; }

# The base branch and the remote it lives on, derived from the checkout.
BASE="$WORK_BASE_BRANCH"
REMOTE=origin

# owner/repo from the origin URL, for the compare link — derived, never hardcoded.
owner_repo() {
  local url
  url="$(G remote get-url "$REMOTE" 2>/dev/null)" || return 1
  printf '%s\n' "$url" \
    | sed -e 's#^git@github\.com:##' -e 's#^ssh://git@github\.com/##' -e 's#^https\?://github\.com/##' \
    | sed -e 's#\.git$##' -e 's#/$##'
}

current_branch() { G rev-parse --abbrev-ref HEAD 2>/dev/null; }

require_clean() {
  [ -z "$(G status --porcelain)" ] && return 0
  error "the working tree has uncommitted changes — commit or stash them first (rule 26 wants one change per commit)"
  G status --short | sed 's/^/  /'
  return 1
}

# ─────────────────────────────── start ────────────────────────────────────
cmd_start() {
  local branch
  branch="$(work_branch_next "$REPO")"
  if ! require_clean; then return 1; fi
  if work_branch_is_work "$(current_branch)" \
     && [ -n "$(G rev-list "$BASE..HEAD" 2>/dev/null)" ]; then
    error "already on $(current_branch) with commits ahead of $BASE — keep working there, or 'make git-pr' to submit it"
    return 1
  fi
  printf 'start: %s from %s/%s\n' "$branch" "$REMOTE" "$BASE"
  run G fetch "$REMOTE" --prune || return 1
  if ! G rev-parse --verify -q "$REMOTE/$BASE" >/dev/null; then
    error "$REMOTE/$BASE does not exist — the base branch must exist before a work branch can start"
    return 1
  fi
  run G checkout -B "$branch" "$REMOTE/$BASE" || return 1
  [ "$DRY" = 1 ] || info "on $branch — make your changes, commit with 'make git-com MSG=\"…\"' (one change per commit), then 'make git-pr'"
}

# ─────────────────────────────── status ───────────────────────────────────
cmd_status() {
  local b; b="$(current_branch)"
  printf '  branch      : %s\n' "${b:-<detached>}"
  if work_branch_is_main "$b"; then
    printf '  state       : on %s — a change needs a work branch: make git-start\n' "$BASE"
    return 0
  fi
  printf '  base        : %s/%s\n' "$REMOTE" "$BASE"
  printf '  commits     : %s ahead of %s\n' "$(G rev-list --count "$REMOTE/$BASE..HEAD" 2>/dev/null || echo '?')" "$BASE"
  printf '  changes     : %s\n' "$(G status --porcelain | wc -l | tr -d ' ')"
  [ -n "$(G rev-list "$BASE..HEAD" 2>/dev/null)" ] && G log --oneline "$BASE..HEAD" | sed 's/^/  /'
  return 0
}

# ─────────────────────────────── submit ───────────────────────────────────
cmd_submit() {
  local b range or url
  b="$(current_branch)"
  if work_branch_is_main "$b"; then
    error "refusing to submit $BASE itself — a change goes on a work-<N> branch (make git-start)"
    return 1
  fi
  work_branch_is_work "$b" \
    || warn "branch '$b' is not named work-<N> — the workflow expects the branch 'make git-start' created"
  require_clean || return 1
  range="$REMOTE/$BASE..HEAD"
  if [ -z "$(G rev-list "$range" 2>/dev/null)" ]; then
    error "no commits ahead of $REMOTE/$BASE — nothing to submit"
    return 1
  fi
  # The same rule the pre-push hook enforces, run here so a violation is named
  # before the push rather than after it.
  if ! bash "$REPO/scripts/info/git-audit.sh" "$range"; then
    error "the branch breaks the commit-hygiene rules — run 'make git-split' and push again"
    return 1
  fi
  or="$(owner_repo)" || { error "cannot read the origin URL"; return 1; }
  url="https://github.com/$or/compare/$BASE...$b?expand=1"

  if [ "$DRY" = 1 ]; then
    printf '  would run: git push -u %s %s\n' "$REMOTE" "$b"
  else
    G push -u "$REMOTE" "$b" || { error "push failed — nothing was published"; return 1; }
  fi

  echo ""
  echo "  Commit(s) in this pull request:"
  G log --format='  %h %s' "$range"
  echo ""
  echo "  Open the pull request (paste the body below):"
  echo "    $url"
  echo ""
  cat <<EOF
  ─── pull request body ───────────────────────────────────────────────
$(submit_body "$range")
  ─────────────────────────────────────────────────────────────────────
EOF
}

# submit_body <range> — the PR body for the commits in <range>: an issue link
# (the preferred form) is taken from a 'Closes #N' / '(#N)' mention in the
# commits; without one, the body states the new feature, how it works, its
# benefits and its risks, which is the other accepted form.
submit_body() {
  local range="$1" n
  n="$(G log --format='%s%n%b' "$range" | grep -oE '(Closes|Fix(es|ed)?|Resolves) #[0-9]+|#[0-9]+' | grep -oE '[0-9]+' | head -1)"
  if [ -n "$n" ]; then
    cat <<EOF
  Closes #$n

  ## What changed
$(G log --format='  - %s' "$range")

  ## Why
  <one paragraph: the behaviour this fixes and how to see it>

  ## How it was verified
  <the commands you ran and their verdict>
EOF
  else
    cat <<EOF
  ## What changed
$(G log --format='  - %s' "$range")

  ## New feature: how it works
  <what it does, which files implement it, and how to use it>

  ## Benefits
  <what this makes possible or safer>

  ## Risks
  <what can break, and how to revert it>

  ## How it was verified
  <the commands you ran and their verdict>
EOF
  fi
}

# ──────────────────────────────── land ────────────────────────────────────
cmd_land() {
  local b; b="$(current_branch)"
  work_branch_is_main "$b" && { error "already on $BASE — nothing to land"; return 1; }
  require_clean || return 1
  printf 'land: %s -> %s/%s (only after the pull request was MERGED on GitHub)\n' "$b" "$REMOTE" "$BASE"
  run G fetch "$REMOTE" --prune || return 1
  run G checkout "$BASE" || return 1
  run G merge --ff-only "$REMOTE/$BASE" \
    || { error "$BASE did not fast-forward — the pull request is not merged yet (or it was merged with a merge commit: pull it by hand)"; return 1; }
  run G branch -d "$b" || warn "the branch was not deleted — it still has commits $BASE does not have"
  [ "$DRY" = 1 ] || info "on $BASE at $(G log --format='%h %s' -1) — start the next change with 'make git-start'"
}

case "$cmd" in
  start)  cmd_start ;;
  status) cmd_status ;;
  submit) cmd_submit ;;
  land)   cmd_land ;;
  *) echo "usage: $0 <start|status|submit|land> [--dry-run]" >&2; exit 1 ;;
esac
