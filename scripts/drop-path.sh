#!/usr/bin/env bash
# Plumbing path-drop for this repo's multi-root DAG (filter tools drop the
# jehpok-era side here — see docs/GUIDE.md lesson 2026-09-02). Removes the
# given paths from EVERY commit's tree, preserving identities, messages,
# dates, merges, both roots and all other content byte-exact.
# Usage: drop-path.sh <repo-dir> <path...>
set -euo pipefail
repo=$1; shift
cd "$repo"
tip=$(git rev-parse HEAD)
declare -A map
mapfile -t commits < <(git rev-list --reverse --topo-order "$tip")
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
