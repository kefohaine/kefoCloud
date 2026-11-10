#!/usr/bin/env bash
# History rewrite: removes the given paths from EVERY commit's tree, preserving
# identities, messages, dates, the graph's shape and all other content
# byte-exact. It replays the commits through the plumbing (commit-tree) because
# `filter-branch` and `filter-repo` rewrite the graph instead of replaying it.
# Operator action: it updates refs/heads/main in the clone and pushes nothing.
# Usage: drop-path.sh <repo-dir> <path...>
#   Add --dry-run (or DRYRUN=1) to print the commit count and the ref it would
#   update, rewriting nothing.

. "$(dirname "$(readlink -f "$0")")/../lib/instance.sh" 2>/dev/null || true
# Plan mode (--dry-run / DRYRUN=1): the gate below prints the plan, writes nothing.
. "$(dirname "$(readlink -f "$0")")/../lib/dryrun.sh"
set -euo pipefail
dryrun_wanted "$@" && DRY=1
dryrun_args "$@"; set -- "${DRYRUN_ARGS[@]}"
repo=$1; shift
cd "$repo"
tip=$(git rev-parse HEAD)
declare -A map
mapfile -t commits < <(git rev-list --reverse --topo-order "$tip")

if [ "${DRY:-0}" = 1 ]; then
  dryrun_plan "drop $* from every tree across ${#commits[@]} commits reachable from $tip in $repo"
  dryrun_plan "update ref refs/heads/main to the rebuilt tip (nothing pushed)"
  dryrun_end
fi

echo "rebuilding ${#commits[@]} commits, dropping: $*"
idx=$(mktemp); rawf=$(mktemp)
for c in "${commits[@]}"; do
  git cat-file commit "$c" > "$rawf"
  IFS= read -r -d '' raw < "$rawf" || true
  hdr=${raw%%$'\n\n'*}
  msg=${raw:${#hdr}+2}
  present=0
  for p in "$@"; do [ -n "$(git ls-tree "$c" -- "$p")" ] && present=1; done
  if [ "$present" = 1 ]; then
    rm -f "$idx"
    GIT_INDEX_FILE=$idx git read-tree "$c^{tree}"
    for p in "$@"; do GIT_INDEX_FILE=$idx git rm --cached -q -- "$p" 2>/dev/null || true; done
    newtree=$(GIT_INDEX_FILE=$idx git write-tree)
  else
    newtree=$(git rev-parse "$c^{tree}")
  fi
  out=""
  while IFS= read -r line; do
    case "$line" in
      '') ;;
      parent\ *) p=${line#parent }; out+="parent ${map[$p]}"$'\n' ;;
      tree\ *) out+="tree $newtree"$'\n' ;;
      *) out+="$line"$'\n' ;;
    esac
  done <<< "$hdr"
  new=$( { printf '%s' "$out"; printf '\n'; printf '%s' "$msg"; } | git hash-object -t commit -w --stdin )
  map[$c]=$new
done
rm -f "$idx" "$rawf"
git update-ref refs/heads/main "${map[$tip]}"
echo "done: $(git rev-list --count HEAD) commits, tip ${map[$tip]}"
