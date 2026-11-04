#!/usr/bin/env bash
#
# scripts/info/git-split.sh — satisfy the commit-hygiene rule (AGENTS rule 26)
# by REWRITING history: split an oversized commit into consecutive chunks of at
# most COMMIT_MAX_FILES files (auto rebase).
#
# It is the automation behind the two hooks:
#   * prepare-commit-msg calls it with --staged — the staged change is committed
#     as one commit per chunk, then the outer `git commit` is aborted (the work is
#     already committed). It is prepare-commit-msg, not pre-commit, because
#     pre-commit runs before git composes the message.
#   * pre-push calls it over the range a push would publish — oversized commits are split
#     (a replay/rebase), then the hook aborts so the operator re-runs `git push`
#     on the rewrapped history.
#
# SCOPE comes from scripts/lib/commit-areas.sh — the same definition
# git-audit.sh checks against, so the splitter and the auditor never drift.
#
# SAFETY (AGENTS rule 17): rewriting PUBLISHED history is an operator decision,
# so this refuses to touch any commit already reachable from a remote-tracking
# branch unless REWRITE_PUBLISHED=1 says the operator asked for exactly that.
# Worktree must be clean.
#
# Usage:
#   git-split.sh [<base>..<head>]   replay+split a range (default @{upstream}..HEAD)
#   git-split.sh --staged           split the index into per-chunk commits
#   git-split.sh --dry-run ...      report what would change, rewrite nothing
#
# The message for --staged comes from $GIT_SPLIT_MESSAGE, else the commit
# editor's .git/COMMIT_EDITMSG.

. "$(dirname "$(readlink -f "$0")")/../lib/instance.sh" 2>/dev/null || true
. "$(dirname "$(readlink -f "$0")")/../lib/commit-areas.sh"
set -uo pipefail
# Our own replay runs `git cherry-pick` in a detached mid-rebase tree where the
# hooks' helper (scripts/lib/commit-areas.sh) may not exist yet, and re-splitting
# a replayed commit is wrong anyway — so tell every hook to stand down.
export GIT_SPLIT_INTERNAL=1

REPO="${REPO_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)}"
G() { git -C "$REPO" "$@"; }
AUTHOR="$(G log -1 --format='%an <%ae>' 2>/dev/null || true)"

die() { printf 'git-split: %s\n' "$*" >&2; exit 1; }

# split_from_status <subject> <body> — stdin is `git diff-tree --name-status`
# lines. HEAD is at the parent; `git reset` has not run yet. Stages one commit
# per chunk of at most COMMIT_MAX_FILES files (rule 26). Returns 3 when there is
# nothing to split.
split_from_status() {
  local subject="$1" body="$2"
  local lines; lines=$(cat)
  local map; map=$(printf '%s\n' "$lines" | cut -f2 | commit_unit_map)
  local units; units=$(printf '%s\n' "$map" | cut -f1 | sort -un)
  local n; n=$(printf '%s\n' "$units" | grep -c .)
  [ "${n:-0}" -le 1 ] && return 3

  # path -> chunk, so one pass over the status lines serves files AND sig.
  local -A unitof=()
  while IFS=$'\t' read -r u p; do [ -n "$p" ] && unitof["$p"]="$u"; done <<< "$map"

  G reset -q || return 1

  local u st p files subj msg
  for u in $units; do
    files=()
    while IFS=$'\t' read -r st p; do
      [ -z "$p" ] && continue
      [ "${unitof[$p]:-}" = "$u" ] || continue
      files+=("$p")
    done <<< "$lines"
    [ "${#files[@]}" -eq 0 ] && continue

    G add -A -- "${files[@]}" >/dev/null 2>&1 || return 1

    subj="$subject"; [ "$n" -gt 1 ] && subj="$subject (part $u/$n)"
    msg="$subj"
    [ -n "$body" ] && msg="${msg}"$'\n\n'"${body}"
    printf '%s\n' "$msg" | G commit -q --no-verify --author="$AUTHOR" -F - || return 1
  done
  return 0
}

# ── --staged: split the index ────────────────────────────────────────────────
split_staged() {
  local msgfile="${GIT_SPLIT_MESSAGE_FILE:-$REPO/.git/COMMIT_EDITMSG}"
  [ -n "${GIT_SPLIT_MESSAGE:-}" ] && msgfile=$(mktemp) && printf '%s\n' "$GIT_SPLIT_MESSAGE" > "$msgfile"
  [ -f "$msgfile" ] || die "no commit message (set GIT_SPLIT_MESSAGE or commit from an editor)"

  local raw subject body
  raw=$(sed -e '/^#/d' "$msgfile" | sed -e 's/[[:space:]]*$//')
  subject=$(printf '%s\n' "$raw" | sed -n '1p')
  body=$(printf '%s\n' "$raw" | sed -n '2,$p' | awk 'NF{seen=1} seen' | sed -e '1{/^$/d}')
  [ -n "$subject" ] || die "empty commit subject in $msgfile"

  local ns; ns=$(G diff --cached --name-status --no-renames)
  [ -z "$ns" ] && { echo "git-split: nothing staged"; return 0; }

  local n; n=$(printf '%s\n' "$ns" | cut -f2 | commit_units | grep -c .)
  if [ "${n:-0}" -le 1 ]; then
    echo "git-split: staged change fits in one commit ($COMMIT_MAX_FILES files) — nothing to split"
    return 0
  fi

  local rc
  printf '%s\n' "$ns" | split_from_status "$subject" "$body"; rc=$?
  [ "$rc" = 0 ] || die "split failed"
  echo "git-split: staged change split into $n commits (at most $COMMIT_MAX_FILES files each)"
}

# ── range: replay + split local history ──────────────────────────────────────
replay_range() {
  local range="$1" base head
  base="${range%%..*}"; head="${range##*..}"
  [ "$base" != "$range" ] || die "range must be <base>..<head>"
  case "$base" in *0000000000000000000000000000000000000000*)
    die "range base is the zero sha (a brand-new branch) — cannot replay from nothing" ;; esac

  local commits; commits=$(G rev-list --reverse "$range" 2>/dev/null || true)
  [ -n "$commits" ] || { echo "git-split: range '$range' is empty"; return 0; }

  local c
  if [ "${REWRITE_PUBLISHED:-0}" != "1" ]; then
    for c in $commits; do
      if G branch -r --contains "$c" 2>/dev/null | grep -q .; then
        die "commit ${c:0:9} is already published on a remote — refusing to rewrite published history (rule 17; REWRITE_PUBLISHED=1 to apply an operator-approved rewrite)"
      fi
    done
  fi

  local need=0 n
  for c in $commits; do
    n=$(commit_units_for "$c" | grep -c .)
    [ "$n" -gt 1 ] && need=1
  done
  if [ "$need" = 0 ]; then
    echo "git-split: range '$range' already satisfies rule 26 ($COMMIT_MAX_FILES files per commit) — nothing to do"
    return 0
  fi

  if [ "${DRY_RUN:-0}" = 1 ]; then
    echo "git-split: would rewrite $range (dry-run)"
    for c in $commits; do
      n=$(commit_units_for "$c" | grep -c .)
      printf '  %s  %s%s\n' "${c:0:9}" "$(G log -1 --format=%s "$c")" \
        "$([ "$n" -gt 1 ] && echo "  [too big: $(G diff-tree -r --name-only --no-commit-id --root "$c" | grep -c .) files]")"
    done
    return 0
  fi

  [ -z "$(G status --porcelain)" ] || die "working tree is not clean — commit or stash first"

  local branch orig; branch=$(G symbolic-ref -q --short HEAD || true); orig=$(G rev-parse HEAD)

  restore() {
    G cherry-pick --abort >/dev/null 2>&1 || true
    if [ -n "$branch" ]; then G checkout -q -f "$branch"; else G checkout -q -f "$orig"; fi
  }

  G checkout -q --detach "$base" || die "cannot detach at $base"
  local subject body ns rc ad cd
  for c in $commits; do
    subject=$(G log -1 --format=%s "$c")
    body=$(G log -1 --format=%b "$c")
    AUTHOR=$(G log -1 --format='%an <%ae>' "$c")
    # a rewrite must not re-date the history it replays
    ad=$(G log -1 --format=%aI "$c"); cd=$(G log -1 --format=%cI "$c")
    export GIT_AUTHOR_DATE="$ad" GIT_COMMITTER_DATE="$cd"
    ns=$(G diff-tree -r --name-status --no-commit-id --no-renames --root "$c")
    n=$(commit_units_for "$c" | grep -c .)

    if [ "$n" -gt 1 ]; then
      G cherry-pick --no-commit "$c" >/dev/null 2>&1 || { restore; die "conflict splitting ${c:0:9} — resolve manually"; }
      printf '%s\n' "$ns" | split_from_status "$subject" "$body"; rc=$?
      if [ "$rc" != 0 ] && [ "$rc" != 3 ]; then restore; die "split of ${c:0:9} failed"; fi
    else
      G cherry-pick "$c" >/dev/null 2>&1 || { restore; die "conflict replaying ${c:0:9} — resolve manually"; }
    fi
  done

  unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE
  if [ -n "$branch" ]; then G branch -f "$branch" HEAD >/dev/null && G checkout -q "$branch"; fi
  echo "git-split: rewrote $range — re-run your command (git push / git status) on the new history"
}

# ── argument handling ────────────────────────────────────────────────────────
mode=range; range=''
while [ $# -gt 0 ]; do
  case "$1" in
    --staged) mode=staged ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) range="$1" ;;
  esac
  shift
done

if [ "$mode" = staged ]; then
  split_staged
  exit $?
fi

if [ -z "$range" ]; then
  up=$(G rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
  for cand in "$up" origin/main origin/master; do
    [ -n "$cand" ] && G rev-parse --verify -q "$cand" >/dev/null 2>&1 && { range="$cand..HEAD"; break; }
  done
fi
[ -n "$range" ] || die "no range given and no upstream to default to"

replay_range "$range"
