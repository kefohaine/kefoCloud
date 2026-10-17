#!/usr/bin/env bash
#
# scripts/info/git-split.sh — satisfy the two commit-hygiene rules (AGENTS
# rule 26 "one change per commit", rule 10 "a revert recipe on every
# significant commit") by REWRITING history: split a bundle commit into one
# commit per AREA and fill in the `Revert:` line of every significant commit
# with its real parent SHA (auto rebase + auto SHA).
#
# It is the automation behind the two hooks:
#   * pre-commit calls it with --staged — the staged change is committed as one
#     commit per AREA, then the outer `git commit` is aborted (the work is
#     already committed).
#   * pre-push calls it over the range a push would publish — bundles are split
#     and missing revert recipes are inserted (a replay/rebase), then the hook
#     aborts so the operator re-runs `git push` on the rewrapped history.
#
# AREA / SIGNIFICANT come from scripts/lib/commit-areas.sh — the same
# definitions git-audit.sh checks against, so the splitter and the auditor
# never drift.
#
# SAFETY (AGENTS rule 17): rewriting PUBLISHED history is an operator decision,
# so this refuses to touch any commit already reachable from a remote-tracking
# branch. It rewrites only the LOCAL commits a push would add. Worktree must be
# clean.
#
# Usage:
#   git-split.sh [<base>..<head>]   replay+split a local range (default @{upstream}..HEAD)
#   git-split.sh --staged           split the index into per-AREA commits
#   git-split.sh --dry-run ...      report what would change, rewrite nothing
#
# The message for --staged comes from $GIT_SPLIT_MESSAGE, else the commit
# editor's .git/COMMIT_EDITMSG.

. "$(dirname "$(readlink -f "$0")")/../lib/instance.sh" 2>/dev/null || true
. "$(dirname "$(readlink -f "$0")")/../lib/commit-areas.sh"
set -uo pipefail

REPO="${REPO_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)}"
G() { git -C "$REPO" "$@"; }
AUTHOR="$(G log -1 --format='%an <%ae>' 2>/dev/null || true)"

die() { printf 'git-split: %s\n' "$*" >&2; exit 1; }

# commit_is_significant <commit> — 0 when any changed path is significant
# (rule 10), or the commit renames/deletes anything.
commit_is_significant() {
  local ns line st p
  ns=$(G diff-tree -r --name-status --no-commit-id --no-renames --root "$1" 2>/dev/null) || return 1
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    st="${line%%$'\t'*}"; p="${line#*$'\t'}"; p="${p##*$'\t'}"
    case "$st" in D*|R*) return 0 ;; esac
    significant_path "$p" && return 0
  done <<< "$ns"
  return 1
}

# split_from_status <subject> <body> — stdin is `git diff-tree --name-status`
# lines. HEAD is at the parent; `git reset` has not run yet. Stages one commit
# per AREA (docs ride with the largest area) and gives each significant one a
# Revert: line naming its real parent. Returns 3 when there is nothing to split.
split_from_status() {
  local subject="$1" body="$2"
  body=$(printf '%s\n' "$body" | strip_revert)          # the recipe is re-added fresh
  local lines; lines=$(cat)
  local paths; paths=$(printf '%s\n' "$lines" | cut -f2)
  local areas; areas=$(printf '%s\n' "$paths" | while IFS= read -r p; do commit_area "$p" || true; done \
                        | grep -v '^$' | sort -u)
  local n; n=$(printf '%s\n' "$areas" | grep -c .)
  [ "${n:-0}" -le 1 ] && return 3

  # primary = the area with the most changed files; docs attach to it.
  local a c primary='' best=0
  for a in $areas; do
    c=$(printf '%s\n' "$paths" | while IFS= read -r p; do
          [ "$(commit_area "$p" 2>/dev/null)" = "$a" ] && echo x
        done | grep -c .)
    if [ "${c:-0}" -gt "$best" ]; then best=$c; primary=$a; fi
  done

  G reset -q || return 1

  local st p ap files rev sig subj msg
  for a in $areas; do
    files=()
    while IFS=$'\t' read -r st p; do
      [ -z "$p" ] && continue
      ap=$(commit_area "$p" || true)
      if [ "$ap" = "$a" ] || { [ -z "$ap" ] && [ "$a" = "$primary" ]; }; then files+=("$p"); fi
    done <<< "$lines"
    [ "${#files[@]}" -eq 0 ] && continue

    G add -A -- "${files[@]}" >/dev/null 2>&1 || return 1

    sig=0
    for p in "${files[@]}"; do significant_path "$p" && sig=1; done
    while IFS=$'\t' read -r st p; do
      [ -z "$p" ] && continue
      ap=$(commit_area "$p" || true)
      if [ "$ap" = "$a" ] || { [ -z "$ap" ] && [ "$a" = "$primary" ]; }; then
        case "$st" in D*|R*) sig=1 ;; esac
      fi
    done <<< "$lines"

    rev=''; [ "$sig" = 1 ] && rev=$(G rev-parse HEAD)
    subj="$subject"; [ "$n" -gt 1 ] && subj="$subject ($a)"
    msg="$subj"
    [ -n "$body" ] && msg="${msg}"$'\n\n'"${body}"
    [ -n "$rev" ] && msg="${msg}"$'\n\n'"Revert: git reset --hard ${rev}"
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

  local n; n=$(printf '%s\n' "$ns" | cut -f2 \
               | while IFS= read -r p; do commit_area "$p" || true; done \
               | grep -v '^$' | sort -u | grep -c .)
  if [ "${n:-0}" -le 1 ]; then
    echo "git-split: staged change is a single area — nothing to split"
    return 0
  fi

  local rc
  printf '%s\n' "$ns" | split_from_status "$subject" "$body"; rc=$?
  [ "$rc" = 0 ] || die "split failed"
  echo "git-split: staged change split into $n commits (one per area)"
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
  for c in $commits; do
    if G branch -r --contains "$c" 2>/dev/null | grep -q .; then
      die "commit ${c:0:9} is already published on a remote — refusing to rewrite published history (rule 17)"
    fi
  done

  local need=0 n
  for c in $commits; do
    n=$(commit_areas "$c" | grep -c .)
    if [ "$n" -gt 1 ]; then need=1; continue; fi
    if commit_is_significant "$c"; then
      commit_revert_ok "$c" || need=1
    fi
  done
  if [ "$need" = 0 ]; then
    echo "git-split: range '$range' already satisfies rules 26/10 — nothing to do"
    return 0
  fi

  if [ "${DRY_RUN:-0}" = 1 ]; then
    echo "git-split: would rewrite $range (dry-run)"
    for c in $commits; do
      n=$(commit_areas "$c" | grep -c .)
      printf '  %s  %s%s\n' "${c:0:9}" "$(G log -1 --format=%s "$c")" \
        "$([ "$n" -gt 1 ] && echo "  [bundle: $(commit_areas "$c" | paste -sd, -)]" \
           || { commit_is_significant "$c" && ! commit_revert_ok "$c" && echo "  [revert recipe]"; })"
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
  local subject body ns rc
  for c in $commits; do
    subject=$(G log -1 --format=%s "$c")
    body=$(G log -1 --format=%b "$c")
    AUTHOR=$(G log -1 --format='%an <%ae>' "$c")
    ns=$(G diff-tree -r --name-status --no-commit-id --no-renames --root "$c")
    n=$(commit_areas "$c" | grep -c .)

    if [ "$n" -gt 1 ]; then
      G cherry-pick --no-commit "$c" >/dev/null 2>&1 || { restore; die "conflict splitting ${c:0:9} — resolve manually"; }
      printf '%s\n' "$ns" | split_from_status "$subject" "$body"; rc=$?
      if [ "$rc" != 0 ] && [ "$rc" != 3 ]; then restore; die "split of ${c:0:9} failed"; fi
    elif commit_is_significant "$c"; then
      # auto-SHA: replay with the recipe recomputed for the NEW parent — the
      # old line (kept from the original message) may name a rewritten-away SHA.
      G cherry-pick --no-commit "$c" >/dev/null 2>&1 || { restore; die "conflict on ${c:0:9} — resolve manually"; }
      local rev msg
      rev=$(G rev-parse HEAD)
      body=$(printf '%s\n' "$body" | strip_revert)
      msg="$subject"; [ -n "$body" ] && msg="${msg}"$'\n\n'"${body}"
      msg="${msg}"$'\n\n'"Revert: git reset --hard ${rev}"
      printf '%s\n' "$msg" | G commit -q --no-verify --author="$AUTHOR" -F - || { restore; die "commit failed on ${c:0:9}"; }
    else
      G cherry-pick "$c" >/dev/null 2>&1 || { restore; die "conflict replaying ${c:0:9} — resolve manually"; }
    fi
  done

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
