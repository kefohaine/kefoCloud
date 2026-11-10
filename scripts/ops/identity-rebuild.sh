#!/usr/bin/env bash
# History rewrite: replaces the author+committer EMAIL on every commit reachable
# from HEAD, preserving trees, dates, messages (byte-exact) and the graph's
# shape. It replays the commits through the plumbing (commit-tree) because
# `filter-branch` and `filter-repo` rewrite the graph instead of replaying it.
# Usage: scripts/ops/identity-rebuild.sh <old-email> <new-email>
#   (run inside a clone; updates refs/heads/main; push with --force yourself,
#    then run `make gh-web-health`.)
#   Add --dry-run (or DRYRUN=1) to print the commit count and the ref it would
#   update, rewriting nothing.
# Verify after every run: uniform identities, unchanged tip tree, byte-identical
# messages/dates, the same commit set, `git fsck` clean.

. "$(dirname "$(readlink -f "$0")")/../lib/instance.sh" 2>/dev/null || true
# Plan mode (--dry-run / DRYRUN=1): the gate below prints the plan, writes nothing.
. "$(dirname "$(readlink -f "$0")")/../lib/dryrun.sh"
set -euo pipefail
dryrun_wanted "$@" && DRY=1
dryrun_args "$@"; set -- "${DRYRUN_ARGS[@]}"
old_email=$1; new_email=$2
tip=$(git rev-parse HEAD)
declare -A map
mapfile -t commits < <(git rev-list --reverse --topo-order "$tip")

if [ "${DRY:-0}" = 1 ]; then
  dryrun_plan "rewrite author+committer email <$old_email> -> <$new_email> on all ${#commits[@]} commits reachable from $tip (trees, dates, messages and the graph's shape preserved)"
  dryrun_plan "update ref refs/heads/main to the rebuilt tip (then push with --force yourself and run make gh-web-health)"
  dryrun_end
fi

tf=$(mktemp)
echo "rebuilding $((${#commits[@]})) commits"
for c in "${commits[@]}"; do
  git cat-file commit "$c" > "$tf"
  IFS= read -r -d '' raw < "$tf" || true  # byte-exact; read exits 1 at EOF (no NUL), value is fully populated
  hdr=${raw%%$'\n\n'*}
  msg=${raw:${#hdr}+2}                    # byte-exact message
  out=""
  while IFS= read -r line; do
    case "$line" in
      '') ;;
      parent\ *) p=${line#parent }; out+="parent ${map[$p]}"$'\n' ;;
      author\ *|committer\ *) out+="${line/<*>/<$new_email>}"$'\n' ;;
      *) out+="$line"$'\n' ;;
    esac
  done <<< "$hdr"
  new=$( { printf '%s' "$out"; printf '\n'; printf '%s' "$msg"; } | git hash-object -t commit -w --stdin )
  map[$c]=$new
done
rm -f "$tf"
git update-ref refs/heads/main "${map[$tip]}"
echo "done: $(git rev-list --count HEAD) commits, tip ${map[$tip]}"
