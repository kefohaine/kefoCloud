#!/usr/bin/env bash
#
# scripts/info/git-audit.sh — monitor the git history for the two commit-hygiene
# rules a commit cannot check about itself: AGENTS rule 26 (one change per
# commit) and rule 10 (a revert recipe in the message of every significant
# commit). READ-ONLY: it reports, it never rewrites history.
#
# Why it exists: the pre-commit hook only sees ONE staged change, and a commit
# made in the GitHub web editor runs no hook at all. This walks a finished
# revision range — the pre-push hook runs it over every pushed range — so a
# bundle or a missing revert recipe is caught on the way OUT as well as in.
#
# Range: `git-audit.sh <range>` or RANGE=<range> (default: what a push would
# publish, i.e. `@{upstream}..HEAD`, falling back to `origin/main..HEAD`).
# Audit the whole published history with RANGE=origin/main.
#
# Checks (exit 1 when any is found, so a hook can gate on it):
#   BUNDLE  the diff spans more than one AREA (rule 26) — the unit the
#           pre-commit hook splits on: `topdir/subdir` for a nested path, the
#           path itself otherwise, ignoring `*.md` and docs/ (the docs that
#           describe a change ride with it). Order changes so each stands alone.
#   REVERT  the commit is SIGNIFICANT (rule 10) but its message has no
#           `Revert:` line. Significant = a security / structure / performance
#           path (below), or any deletion or rename.
#
# HISTORY_AUDIT_OVERRIDE=1 reports and exits 0.

. "$(dirname "$(readlink -f "$0")")/../lib/instance.sh" 2>/dev/null || true
. "$(dirname "$(readlink -f "$0")")/../lib/commit-areas.sh"
set -uo pipefail

REPO="${REPO_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)}"
G() { git -C "$REPO" "$@"; }

range="${1:-${RANGE:-}}"
if [ -z "$range" ]; then
  up=$(G rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
  for cand in "$up" origin/main origin/master; do
    [ -n "$cand" ] && G rev-parse --verify -q "$cand" >/dev/null 2>&1 \
      && { range="$cand..HEAD"; break; }
  done
fi
if [ -z "$range" ]; then
  echo "usage: git-audit.sh <range>   (or RANGE=<range>; no upstream to default to)" >&2
  exit 2
fi

# AREA (rule 26) and SIGNIFICANT (rule 10) come from scripts/lib/commit-areas.sh
# — the same definitions git-split.sh rewrites against, so the two never drift.

commits=$(G rev-list --reverse "$range" 2>/dev/null || true)
if [ -z "$commits" ]; then
  echo "git-audit: range '$range' is empty — nothing to check"
  exit 0
fi
n=$(printf '%s\n' "$commits" | grep -c . || true)

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m' D=$'\033[2m' R=$'\033[31m' Y=$'\033[33m' C=$'\033[36m' N=$'\033[0m'
else
  B='' D='' R='' Y='' C='' N=''
fi

echo "${B}git-audit${N}: ${C}$range${N} ${D}($n commits)${N}"

bundles=0 reverts=0
for c in $commits; do
  short=${c:0:9}
  subject=$(G log -1 --format='%s' "$c")
  # name-status of the commit's own diff (renames detected, root-safe).
  ns=$(G diff-tree -r --name-status --no-commit-id -M --root "$c" 2>/dev/null)
  [ -z "$ns" ] && continue

  areas='' sig=''
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    st=${line%%$'\t'*}; p=${line#*$'\t'}
    p=${p##*$'\t'}                                  # R100\told\tnew -> new
    case "$st" in D*|R*) sig=rename_or_delete ;; esac
    significant_path "$p" && sig="$sig $p"
    a=$(commit_area "$p") || continue
    case " $areas " in *" $a "*) ;; *) areas="$areas $a" ;; esac
  done <<< "$ns"

  nareas=$(printf '%s\n' $areas | grep -c . || true)
  if [ "${nareas:-0}" -gt 1 ]; then
    bundles=$((bundles + 1))
    printf '  %sBUNDLE%s %s  %s\n' "$Y" "$N" "$short" "$subject"
    printf '         %sareas:%s%s\n' "$D" "${areas}" "$N"
    printf '         %ssplit it: git rebase -i %s^  →  one change per commit (rule 26)%s\n' "$D" "$c" "$N"
  fi

  if [ -n "$sig" ]; then
    msg=$(G log -1 --format='%B' "$c")
    want=$(G rev-parse -q --verify "$c^" 2>/dev/null || true)
    if ! printf '%s\n' "$msg" | grep -qE '^[[:space:]]*Revert:'; then
      reverts=$((reverts + 1))
      printf '  %sREVERT%s %s  %s\n' "$R" "$N" "$short" "$subject"
      printf '         %ssignificant:%s%s\n' "$D" "${sig# }" "$N"
      printf '         %sadd: Revert: git reset --hard %s  (rule 10)%s\n' "$D" "$want" "$N"
    else
      # A recipe that names an OLD parent (a stale SHA after a rewrite) is as
      # useless as a missing one — the reset target would not be the parent.
      got=$(revert_parent_sha "$c")
      gote=$(G rev-parse -q --verify "${got:-x}" 2>/dev/null || true)
      if [ -n "$got" ] && [ -n "$want" ] && [ "$gote" != "$want" ]; then
        reverts=$((reverts + 1))
        printf '  %sREVERT%s %s  %s\n' "$R" "$N" "$short" "$subject"
        printf '         %sstale recipe: names %s, parent is %s%s\n' "$D" "${got:0:9}" "${want:0:9}" "$N"
        printf '         %sfix: Revert: git reset --hard %s  (rule 10)%s\n' "$D" "$want" "$N"
      fi
    fi
  fi
done

if [ "${HISTORY_AUDIT_OVERRIDE:-}" = "1" ]; then
  echo "${D}HISTORY_AUDIT_OVERRIDE=1 — ${bundles} bundle(s), ${reverts} missing revert recipe(s) reported, not enforced${N}"
  exit 0
fi
if [ "$bundles" -ne 0 ] || [ "$reverts" -ne 0 ]; then
  echo ""
  echo "${R}$bundles bundle(s), $reverts missing revert recipe(s)${N} — rule 26 wants one change per commit, rule 10 a revert recipe on every significant one."
  exit 1
fi
echo "  ${B}clean${N} ${D}— every commit is one change and significant ones carry a revert recipe${N}"
exit 0
