#!/usr/bin/env bash
#
# scripts/info/pr-guard.sh — catch the two shapes that make a pull request land
# nothing or arrive CONFLICTING at review time. READ-ONLY: it reports, it never
# rewrites or merges.
#
# Why it exists (lesson 2026-11-05):
#   EMPTY   #76's branch had been rebased onto a revert, so its tree EQUALLED the
#           base; the squash merge produced no change and the work had to be
#           re-delivered as #79 while the pull request still read "merged".
#   RENAME  #79 renamed a vhost while the base had edited that same path.
#           GitHub reads a rename as a delete of a modified file and calls the
#           pull request CONFLICTING although a local merge resolves clean —
#           and a local rebase can resolve it toward the branch's blob, which
#           silently drops the base's change to the renamed file.
#
# Range: pr-guard.sh <range> (default: BASE=<ref> .. HEAD, BASE defaulting to
# origin/main). Exit 1 on EMPTY or RENAME, so a hook, a recipe and CI can gate
# on it; STALE is a warning. PR_GUARD_OVERRIDE=1 reports and exits 0.

. "$(dirname "$(readlink -f "$0")")/../lib/instance.sh" 2>/dev/null || true
set -uo pipefail

REPO="${REPO_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)}"
G() { git -C "$REPO" "$@"; }

BASE="${BASE:-origin/main}"
range="${1:-}"

if [ -n "$range" ]; then
  case "$range" in
    *...*) base_ref="${range%%...*}" tip_ref="${range##*...}" ;;
    *..*)  base_ref="${range%%..*}"  tip_ref="${range##*..}" ;;
    *)     echo "usage: pr-guard.sh <base>..<tip>   (or BASE=<ref>)"; exit 2 ;;
  esac
else
  base_ref="$BASE" tip_ref="HEAD"
fi

G rev-parse --verify -q "$base_ref" >/dev/null 2>&1 \
  || { echo "pr-guard: $base_ref does not exist — fetch it first (make fetch)"; exit 2; }
tip=$(G rev-parse --verify -q "$tip_ref" 2>/dev/null) \
  || { echo "pr-guard: $tip_ref is not a revision"; exit 2; }
mb=$(G merge-base "$base_ref" "$tip" 2>/dev/null) \
  || { echo "pr-guard: $base_ref and $tip_ref share no history"; exit 1; }

echo "pr-guard: $tip_ref against $base_ref (merge base $(G rev-parse --short "$mb"))"
findings=0 warnings=0

# EMPTY — the squash merge would change no file, so the pull request would read
# "merged" while main kept the base's tree. Compare trees, not commits: the
# commit list can be long and still change nothing.
if G diff --quiet "$base_ref" "$tip"; then
  echo "  EMPTY   the tree equals $base_ref — the squash merge would change nothing."
  echo "          Rebase onto $base_ref and re-apply the work there; a re-delivery is a FRESH branch."
  findings=$((findings + 1))
fi

# RENAME — the branch renames (or copies over) a path the base changed since the
# merge base. GitHub's merge compares the base's path against the branch's
# delete, so it reports delete/modify; a local resolution must carry the base's
# version of the file forward by hand, never the branch's pre-rename blob.
renames=$(G diff -M --name-status "$mb" "$tip" 2>/dev/null | awk -F'\t' '$1 ~ /^R/ {print $2"\t"$3}')
if [ -n "$renames" ]; then
  while IFS=$'\t' read -r old new; do
    [ -n "${old:-}" ] || continue
    moved=$(G diff --name-only "$mb" "$base_ref" -- "$old" 2>/dev/null)
    [ -n "$moved" ] || continue
    echo "  RENAME  $old -> $new: $base_ref changed $old since the merge base, so the"
    echo "          pull request reads CONFLICTING (delete/modify). Carry $base_ref's"
    echo "          version of the file into $new by hand before submitting:"
    G log --format='            %h %s' "$mb..$base_ref" -- "$old" | head -5
    findings=$((findings + 1))
  done <<< "$renames"
fi

# STALE (warning) — a path both sides changed. Git resolves it, GitHub may not;
# a rebase before review keeps the pull request reviewable and its diff small.
both=$(comm -12 \
  <(G diff --name-only "$mb" "$tip" 2>/dev/null | sort -u) \
  <(G diff --name-only "$mb" "$base_ref" 2>/dev/null | sort -u))
if [ -n "$both" ]; then
  echo "  STALE   both sides changed these paths — rebase onto $base_ref before submitting:"
  printf '%s\n' "$both" | head -10 | sed 's/^/            /'
  nboth=$(printf '%s\n' "$both" | grep -c .)
  [ "$nboth" -gt 10 ] && echo "            … and $((nboth - 10)) more"
  warnings=$((warnings + 1))
fi

if [ "$findings" -gt 0 ]; then
  echo "pr-guard: $findings blocking finding(s) — the branch is not submittable as it stands."
  [ "${PR_GUARD_OVERRIDE:-}" = "1" ] && { echo "  PR_GUARD_OVERRIDE=1 — reporting only."; exit 0; }
  exit 1
fi
[ "$warnings" -gt 0 ] && echo "pr-guard: clean of blocking findings ($warnings warning(s))." \
                      || echo "pr-guard: clean."
exit 0
