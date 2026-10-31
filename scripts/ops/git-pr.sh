#!/usr/bin/env bash
# scripts/ops/git-pr.sh — the branch + pull-request workflow, in one place.
#
# `main` is write-once (AGENTS rule 30): every change is made on a branch named
# `temp-<N>` created off a freshly pulled `main`, pushed, and merged through a
# pull request that a HUMAN reviews and accepts on GitHub. Nothing here (or
# anywhere else in the repo) can push `main` — scripts/hooks/pre-push refuses
# that destination outright, so a mistake fails loudly instead of publishing.
#
# Delegate every step through the Makefile: `make git-start`, `make git-branch`,
# `make git-switch`, `make git-del`, `make git-branches`, `make git-issue`,
# `make git-pr` and `make git-land`. The naming scheme (temp-1, temp-2, … derived
# from the branches that exist) lives in scripts/lib/temp-branch.sh, the SAME
# definition the installer uses — it is never restated here.
#
# Usage:
#   git-pr.sh start  [--dry-run] [--name <branch>] [--base <branch>]
#                                   create + switch to a branch off origin/<base>
#                                   (default: the next free temp-<N> off origin/main)
#   git-pr.sh switch <branch> [--dry-run]
#                                   switch to an existing branch, tracking origin's
#   git-pr.sh delete <branch> [--force] [--dry-run]
#                                   delete a LOCAL branch (never the base, never the
#                                   current one; --force drops unmerged commits)
#   git-pr.sh list   [--dry-run]    local + origin branches and the next free name
#   git-pr.sh issue  [--dry-run] [--title <title>] [--labels <a,b>] [--body-file <path>]
#                                   file an issue in the GitHub tracker BEFORE the
#                                   branch that fixes it: the body (the problem, then
#                                   `**Fix:**`) comes from <path> or stdin, labels are
#                                   checked against .github/labels.yml (`type:` is
#                                   required, `status: triage` is added), and a title
#                                   that already exists is left alone
#   git-pr.sh status [--dry-run]    where this checkout stands (branch, commits, base)
#   git-pr.sh submit [--dry-run] [--issue N] [--base <branch>]
#                                   audit + push the branch + open the PR into <base>
#                                   (default main) with an authenticated gh, or print
#                                   the compare URL and PR body. --issue N writes
#                                   `Closes #N`, linking the issue to the PR.
#   git-pr.sh land   [--dry-run] [--base <branch>]
#                                   after the PR is merged: <base> fast-forward,
#                                   delete the local branch
#
# A --dry-run only reads and prints: nothing is fetched, created, committed,
# pushed or deleted. That is the mode an agent may exercise (AGENTS rule 29).
#
# The last step is always a HUMAN's: the agent ends at the opened/printed pull
# request and waits for review and merge. Nothing here merges or pushes main.

set -uo pipefail
export LC_ALL=C

REPO="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
. "$REPO/scripts/lib/temp-branch.sh"

info()  { "${REPO}/scripts/lib/mklog" info  "$*" 2>/dev/null || echo "info:  $*"; }
warn()  { "${REPO}/scripts/lib/mklog" warn  "$*" 2>/dev/null || echo "warn:  $*"; }
error() { "${REPO}/scripts/lib/mklog" error "$*" 2>/dev/null || echo "error: $*"; }

G() { git -C "$REPO" "$@"; }

cmd="${1:-status}"
shift 2>/dev/null || true
DRY=0
ISSUE_NUM="${ISSUE:-}"
NAME_ARG="${NAME:-}"
BASE="${BASE:-$TEMP_BASE_BRANCH}"
TITLE_ARG="${TITLE:-}"
LABEL_ARG="${LABEL:-}"
BODY_FILE="${BODY:-}"
FORCE=0
POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n) DRY=1 ;;
    --issue)   shift; ISSUE_NUM="${1:-}" ;;
    --issue=*) ISSUE_NUM="${1#--issue=}" ;;
    --name)    shift; NAME_ARG="${1:-}" ;;
    --name=*)  NAME_ARG="${1#--name=}" ;;
    --base)    shift; BASE="${1:-}" ;;
    --base=*)  BASE="${1#--base=}" ;;
    --title)   shift; TITLE_ARG="${1:-}" ;;
    --title=*) TITLE_ARG="${1#--title=}" ;;
    --label|--labels)     shift; LABEL_ARG="${1:-}" ;;
    --label=*|--labels=*) LABEL_ARG="${1#*=}" ;;
    --body-file)   shift; BODY_FILE="${1:-}" ;;
    --body-file=*) BODY_FILE="${1#--body-file=}" ;;
    --force|-f) FORCE=1 ;;
    --) shift; while [ $# -gt 0 ]; do POS+=("$1"); shift; done ;;
    -*) error "unknown argument '$1'"; exit 1 ;;
    *)  POS+=("$1") ;;
  esac
  shift
done
if [ -n "$ISSUE_NUM" ] && ! printf '%s' "$ISSUE_NUM" | grep -qE '^[0-9]+$'; then
  error "ISSUE must be an issue number (got '$ISSUE_NUM')"
  exit 1
fi
BASE="$(temp_branch_name "$BASE")"
if [ -z "$BASE" ]; then
  error "BASE must name a branch (got an empty value)"
  exit 1
fi
run() { if [ "$DRY" = 1 ]; then printf '  would run: %s\n' "$*"; else "$@"; fi; }

# The remote the base branch lives on, derived from the checkout.
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

# Open the pull request through the GitHub REST API with GITHUB_TOKEN (or
# GH_TOKEN) — the path for a host without `gh`. Prints the pull request URL and
# returns 0 when one is open (created now, or already open for the same head);
# returns 1 and explains on stderr when the API refused. The token is the
# operator's: nothing here reads, stores or prints it.
open_pr_api() {
  local slug="$1" head="$2" base="$3" title="$4"
  TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}" SLUG="$slug" HEAD_BRANCH="$head" \
  BASE_BRANCH="$base" PR_TITLE="$title" PR_BODY="${5:-}" python3 - <<'PY'
import json, os, sys, urllib.error, urllib.request

token = os.environ.get("TOKEN", "")
slug, head = os.environ["SLUG"], os.environ["HEAD_BRANCH"]
base, title = os.environ["BASE_BRANCH"], os.environ["PR_TITLE"]
body = os.environ.get("PR_BODY", "")
api = "https://api.github.com/repos/%s" % slug


def call(method, path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(api + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Accept", "application/vnd.github+json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"{}")
        except ValueError:
            return e.code, {}


status, res = call("POST", "/pulls",
                   {"title": title, "head": head, "base": base, "body": body})
if status in (200, 201):
    print(res.get("html_url", ""))
    sys.exit(0)
if status == 422:  # a pull request for this head is already open
    owner = slug.split("/")[0]
    st, prs = call("GET", "/pulls?state=open&head=%s:%s" % (owner, head))
    if st == 200 and prs:
        print(prs[0].get("html_url", ""))
        sys.exit(0)
print("%s (HTTP %s)" % (res.get("message", "the API refused the request"), status),
      file=sys.stderr)
sys.exit(1)
PY
}

# ─────────────────────────────── start ────────────────────────────────────
# Create + switch to a branch off a freshly pulled base. Bare `start` picks the
# next free temp-<N>; --name picks an explicit branch (same verb, so `make
# git-start` and `make git-branch NAME=…` share one implementation).
cmd_start() {
  local branch cur ahead
  branch="$(temp_branch_name "${NAME_ARG:-$(temp_branch_next "$REPO")}")"
  if temp_branch_is_base "$branch"; then
    error "refusing to create '$TEMP_BASE_BRANCH' — it is write-once; a change goes on a temp branch"
    return 1
  fi
  require_clean || return 1
  cur="$(current_branch)"
  ahead="$(G rev-list "$BASE..HEAD" 2>/dev/null)"
  if [ -n "$ahead" ] && [ -z "$NAME_ARG" ] && temp_branch_is_temp "$cur"; then
    error "already on $cur with commits ahead of $BASE — keep working there, or 'make git-pr' to submit it"
    return 1
  fi
  if [ -n "$ahead" ] && [ "$branch" = "$cur" ]; then
    error "already on $branch with commits ahead of $BASE — 'make git-pr' to submit it, or pick another name"
    return 1
  fi
  if [ "$DRY" != 1 ] && G rev-parse --verify -q "refs/heads/$branch" >/dev/null; then
    error "branch '$branch' already exists — 'make git-switch BRANCH=$branch' to use it, or pick another name"
    return 1
  fi
  printf 'start: %s from %s/%s\n' "$branch" "$REMOTE" "$BASE"
  run G fetch "$REMOTE" --prune || return 1
  if ! G rev-parse --verify -q "$REMOTE/$BASE" >/dev/null; then
    error "$REMOTE/$BASE does not exist — the base branch must exist before a working branch can start"
    return 1
  fi
  run G checkout -B "$branch" "$REMOTE/$BASE" || return 1
  [ "$DRY" = 1 ] || info "on $branch — make your changes, commit with 'make git-com MSG=\"…\"' (one change per commit), then 'make git-pr'"
}

# ─────────────────────────────── switch ───────────────────────────────────
cmd_switch() {
  local b
  b="$(temp_branch_name "${POS[0]:-${NAME_ARG:-}}")"
  if [ -z "$b" ]; then
    error "usage: git-pr.sh switch <branch>   (or make git-switch BRANCH=<branch>)"
    return 1
  fi
  if [ "$b" = "$(current_branch)" ]; then
    info "already on $b"
    return 0
  fi
  require_clean || return 1
  run G fetch "$REMOTE" --prune || return 1
  if G rev-parse --verify -q "refs/heads/$b" >/dev/null; then
    run G checkout "$b" || return 1
  elif G rev-parse --verify -q "refs/remotes/$REMOTE/$b" >/dev/null; then
    run G checkout -b "$b" --track "$REMOTE/$b" || return 1
  else
    error "no branch '$b' locally or on $REMOTE — create it with 'make git-branch NAME=$b'"
    return 1
  fi
  [ "$DRY" = 1 ] || info "on $b"
}

# ─────────────────────────────── delete ───────────────────────────────────
cmd_delete() {
  local b cur
  b="$(temp_branch_name "${POS[0]:-${NAME_ARG:-}}")"
  if [ -z "$b" ]; then
    error "usage: git-pr.sh delete <branch> [--force]   (or make git-del BRANCH=<branch>)"
    return 1
  fi
  if temp_branch_is_base "$b"; then
    error "refusing to delete '$b' — the base branch is write-once and never deleted"
    return 1
  fi
  cur="$(current_branch)"
  if [ "$b" = "$cur" ]; then
    error "'$b' is the current branch — switch away first: make git-switch BRANCH=<other>"
    return 1
  fi
  if ! G rev-parse --verify -q "refs/heads/$b" >/dev/null; then
    error "no local branch '$b' (the remote copy is removed by GitHub when the pull request is merged)"
    return 1
  fi
  if [ "$FORCE" != 1 ] && ! G merge-base --is-ancestor "refs/heads/$b" HEAD 2>/dev/null; then
    error "'$b' has commits HEAD does not have — its pull request is not merged. Land it with 'make git-land', or FORCE=1 to discard those commits"
    return 1
  fi
  if [ "$FORCE" = 1 ]; then run G branch -D "$b"; else run G branch -d "$b"; fi || return 1
  [ "$DRY" = 1 ] || info "deleted local branch $b"
}

# ─────────────────────────────── list ─────────────────────────────────────
cmd_list() {
  local b cur ahead seen
  cur="$(current_branch)"
  printf '  base        : %s/%s   next free branch: %s\n' "$REMOTE" "$BASE" "$(temp_branch_next "$REPO")"
  printf '  local       :\n'
  for b in $(G for-each-ref --sort=refname --format='%(refname:short)' refs/heads); do
    ahead="$(G rev-list --count "refs/heads/$b" --not "$REMOTE/$BASE" 2>/dev/null || echo '?')"
    printf '    %s %-30s %s commit(s) not in %s\n' \
      "$([ "$b" = "$cur" ] && printf '*' || printf ' ')" "$b" "$ahead" "$BASE"
  done
  seen=''
  for b in $(G for-each-ref --format='%(refname:short)' "refs/remotes/$REMOTE" 2>/dev/null \
             | sed -e "s#^$REMOTE/##" -e '/^HEAD$/d'); do
    if G rev-parse --verify -q "refs/heads/$b" >/dev/null; then
      seen="$seen $b"
      continue
    fi
    printf '    %s %-30s %s only\n' ' ' "$b" "$REMOTE"
  done
  return 0
}

# ─────────────────────────────── issue ────────────────────────────────────
# File an issue in the GitHub tracker, BEFORE the branch that fixes it. The body
# is required — the house shape is the problem, then `**Fix:**` — read from
# --body-file/BODY or stdin. Labels are validated against .github/labels.yml (the
# one label list): a `type:` label is mandatory and `status: triage` is applied
# when no other status is named, exactly what the issue templates do. An issue
# whose title already exists (open or closed) is left alone, so re-running cannot
# duplicate one — the same idempotency scripts/ops/import-issues.sh has.
manifest_labels() {
  sed -n 's/^- name: "\(.*\)"$/\1/p' "$REPO/.github/labels.yml"
  printf 'good first issue\nhelp wanted\n'
}

# has_label_prefix <prefix> <label>... — true when one label starts with <prefix>
# (a `type:`/`status:` present check, without a pipeline that pipefail can trip).
has_label_prefix() {
  local p="$1" x
  shift
  for x in "$@"; do
    case "$x" in "$p"*) return 0 ;; esac
  done
  return 1
}

cmd_issue() {
  local title body or url enc n l known
  local -a labels=()
  title="${TITLE_ARG:-${POS[*]:-}}"
  if [ -z "${title// /}" ]; then
    error "no title — make git-issue TITLE=\"<what is wrong>\" LABEL=\"type: bug,…\" BODY=<file>"
    return 1
  fi
  if [ -n "$BODY_FILE" ]; then
    [ -r "$BODY_FILE" ] || { error "BODY='$BODY_FILE' is not a readable file"; return 1; }
    body="$(cat "$BODY_FILE")"
  elif [ ! -t 0 ]; then
    body="$(cat)"
  else
    body=''
  fi
  if [ -z "${body//[[:space:]]/}" ]; then
    error "no issue body — set BODY=<file> (or pipe it in): the problem, then '**Fix:**'"
    return 1
  fi
  known="$(manifest_labels)"
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    if ! grep -Fxq -- "$l" <<< "$known"; then
      error "unknown label '$l' — .github/labels.yml is the only label list"
      return 1
    fi
    labels+=("$l")
  done <<< "$(printf '%s' "$LABEL_ARG" | tr ',' '\n' \
               | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d')"
  if ! has_label_prefix 'type: ' "${labels[@]}"; then
    error "no type: label — the templates apply one (type: bug | feature | refactor | docs)"
    return 1
  fi
  if ! has_label_prefix 'status: ' "${labels[@]}"; then
    labels+=("status: triage")
  fi
  or="$(owner_repo)" || { error "cannot read the origin URL"; return 1; }

  printf 'issue: %s\n' "$title"
  printf '  labels: %s\n' "$(printf '%s, ' "${labels[@]}" | sed 's/, $//')"
  if [ "$DRY" = 1 ]; then
    printf '  would run: gh issue create --title "%s" %s--body-file -\n' \
      "$title" "$(printf -- '--label "%s" ' "${labels[@]}")"
    printf '  ─── issue body ─────────────────────────────────────────────────────\n'
    printf '%s\n' "$body" | sed 's/^/  /'
    printf '  ─────────────────────────────────────────────────────────────────────\n'
    return 0
  fi

  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    n="$(gh issue list --state all --search "\"$title\" in:title" --limit 100 \
           --template '{{range .}}{{.number}}{{"\t"}}{{.title}}{{"\n"}}{{end}}' 2>/dev/null \
          | awk -F'\t' -v t="$title" '$2 == t { print $1; exit }')"
    if [ -n "$n" ]; then
      info "issue #$n already carries this title — nothing filed, edit that one instead"
      return 0
    fi
    local -a args=()
    for l in "${labels[@]}"; do args+=(--label "$l"); done
    if printf '%s\n' "$body" | gh issue create --title "$title" "${args[@]}" --body-file -; then
      info "issue filed — fix it on a temp branch ('make git-start') and link the pull request with 'make git-pr ISSUE=<n>'"
      return 0
    fi
    warn "gh could not file the issue — falling back to the new-issue URL"
  fi

  enc="$(python3 -c 'import sys,urllib.parse as u;print(u.urlencode({"title":sys.argv[1],"labels":sys.argv[2],"body":sys.argv[3]}))' \
        "$title" "$(printf '%s,' "${labels[@]}" | sed 's/,$//')" "$body" 2>/dev/null)"
  url="https://github.com/$or/issues/new"
  [ -n "$enc" ] && url="$url?$enc"
  echo ""
  echo "  File the issue (paste the body below), then start the change with 'make git-start':"
  echo "    $url"
  echo ""
  printf '  ─── issue body ─────────────────────────────────────────────────────\n'
  printf '%s\n' "$body" | sed 's/^/  /'
  printf '  ─────────────────────────────────────────────────────────────────────\n'
  return 0
}

# ─────────────────────────────── status ───────────────────────────────────
cmd_status() {
  local b; b="$(current_branch)"
  printf '  branch      : %s\n' "${b:-<detached>}"
  if temp_branch_is_base "$b"; then
    printf '  state       : on %s — a change needs a temp branch: make git-start\n' "$BASE"
    return 0
  fi
  printf '  base        : %s/%s   next free branch: %s\n' "$REMOTE" "$BASE" "$(temp_branch_next "$REPO")"
  printf '  commits     : %s ahead of %s\n' "$(G rev-list --count "$REMOTE/$BASE..HEAD" 2>/dev/null || echo '?')" "$BASE"
  printf '  changes     : %s\n' "$(G status --porcelain | wc -l | tr -d ' ')"
  [ -n "$(G rev-list "$BASE..HEAD" 2>/dev/null)" ] && G log --oneline "$BASE..HEAD" | sed 's/^/  /'
  return 0
}

# ─────────────────────────────── submit ───────────────────────────────────
cmd_submit() {
  local b range or url
  b="$(current_branch)"
  if temp_branch_is_base "$b"; then
    error "refusing to submit $b itself — a change goes on a temp branch (make git-start)"
    return 1
  fi
  if [ "$b" = "$BASE" ]; then
    error "the pull request would go from $b into itself — set BASE=<target branch> (default main)"
    return 1
  fi
  temp_branch_is_temp "$b" \
    || warn "branch '$b' is not named temp-<N> — the workflow expects the branch 'make git-start' created"
  require_clean || return 1
  G rev-parse --verify -q "$REMOTE/$BASE" >/dev/null \
    || { error "$REMOTE/$BASE does not exist — fetch the target branch first (make fetch)"; return 1; }
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

  local body title
  body="$(submit_body "$range" "$ISSUE_NUM")"
  title="$(G log --format='%s' -1 "$range")"

  echo ""
  printf '  Pull request: %s -> %s\n' "$b" "$BASE"
  echo "  Commit(s) in this pull request:"
  G log --format='  %h %s' "$range"

  # Open the PR from here when a credential exists — an authenticated `gh`, or a
  # GITHUB_TOKEN/GH_TOKEN for the REST API on a host without gh. Otherwise hand
  # the human the compare URL and a ready body. Either way the merge is theirs.
  local pr_url=""
  if [ "$DRY" = 1 ]; then
    printf '  would run: gh pr create --base %s --head %s --title %q --body-file - (or POST /repos/%s/pulls with GITHUB_TOKEN)\n' "$BASE" "$b" "$title" "$or"
  elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if printf '%s\n' "$body" | gh pr create --base "$BASE" --head "$b" --title "$title" --body-file -; then
      echo ""
      echo "  Pull request opened — a human reviews and merges it. The agent stops here."
      return 0
    fi
    warn "gh could not open the pull request — falling back to the compare URL"
  elif [ -n "${GITHUB_TOKEN:-${GH_TOKEN:-}}" ]; then
    if pr_url="$(open_pr_api "$or" "$b" "$BASE" "$title" "$body")" && [ -n "$pr_url" ]; then
      echo ""
      printf '  Pull request opened: %s\n' "$pr_url"
      echo "  A human reviews and merges it. The agent stops here."
      return 0
    fi
    warn "the GitHub API could not open the pull request — falling back to the compare URL"
  fi

  echo ""
  echo "  Open the pull request (paste the body below), then stop — a human merges:"
  echo "    $url"
  echo ""
  printf '  ─── pull request body ───────────────────────────────────────────────\n'
  printf '%s\n' "$body" | sed 's/^/  /'
  printf '  ─────────────────────────────────────────────────────────────────────\n'
}

# submit_body <range> [issue] — the PR body for the commits in <range>: an issue
# link (the preferred form) is taken from an explicit issue number or a
# 'Closes #N' mention in the commits; without one, the body states the new
# feature, how it works, its benefits and its risks, which is the other
# accepted form.
submit_body() {
  local range="$1" explicit="${2:-}" n
  n="${explicit:-$(G log --format='%s%n%b' "$range" | grep -oE '(Closes|Fix(es|ed)?|Resolves) #[0-9]+|#[0-9]+' | grep -oE '[0-9]+' | head -1)}"
  if [ -n "$n" ]; then
    cat <<EOF
Closes #$n

## What changed
$(G log --format='- %s' "$range")

## Why
<one paragraph: the behaviour this fixes and how to see it>

## How it was verified
<the commands you ran and their verdict>
EOF
  else
    cat <<EOF
## What changed
$(G log --format='- %s' "$range")

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
  temp_branch_is_base "$b" && { error "already on $b — nothing to land"; return 1; }
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
  switch) cmd_switch ;;
  delete) cmd_delete ;;
  list)   cmd_list ;;
  issue)  cmd_issue ;;
  status) cmd_status ;;
  submit) cmd_submit ;;
  land)   cmd_land ;;
  *) echo "usage: $0 <start|switch|delete|list|issue|status|submit|land> [--dry-run]" >&2; exit 1 ;;
esac
