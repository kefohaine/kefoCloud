#!/usr/bin/env bash
# Plumbing string scrub for this repo's multi-root DAG (filter tools drop the
# jehpok-era side here — see docs/GUIDE.md lesson 2026-09-02). Replaces the
# given <old> <new> string pairs in EVERY blob's content across all history,
# preserving identities, messages, dates, merges, both roots and all paths.
# Used 2026-09-03 to censor the retired personal email addresses from doc
# history. Usage: scripts/replace-string.sh <repo-dir> <old> <new> [...]
set -euo pipefail
repo=$1; shift
cd "$repo"
tip=$(git rev-parse HEAD)
[ $# -ge 2 ] && [ $(( $# % 2 )) -eq 0 ] || { echo "need <old> <new> pairs"; exit 1; }
# collect pairs
olds=(); news=()
while [ $# -gt 0 ]; do olds+=("$1"); news+=("$2"); shift 2; done

# 1) build blob replacement map across all reachable blobs
declare -A bmap
tmpf=$(mktemp)
git rev-list --objects HEAD | awk '$2 != "" && $2 !~ /\/$/ {print $1}' | sort -u > "$tmpf"
while read -r b; do
  git cat-file blob "$b" > "$tmpf.blob" 2>/dev/null || continue
  hit=0
  for o in "${olds[@]}"; do grep -qF "$o" "$tmpf.blob" && hit=1 && break; done
  [ "$hit" = 1 ] || continue
  cp "$tmpf.blob" "$tmpf.out"
  for i in "${!olds[@]}"; do
    sed -i "s|${olds[$i]}|${news[$i]}|g" "$tmpf.out"
  done
  nb=$(git hash-object -w "$tmpf.out")
  [ "$nb" != "$b" ] && bmap[$b]=$nb
done < "$tmpf"
echo "blobs to replace: ${#bmap[@]}"

# 2) rebuild every commit, swapping replaced blobs in its tree
declare -A cmap
mapfile -t commits < <(git rev-list --reverse --topo-order "$tip")
idx=$(mktemp); rawf=$(mktemp)
for c in "${commits[@]}"; do
  git cat-file commit "$c" > "$rawf"
  IFS= read -r -d '' raw < "$rawf" || true
  hdr=${raw%%$'\n\n'*}
  msg=${raw:${#hdr}+2}
  newtree=""
  while read -r mode type sha path; do
    [ "$type" = blob ] && [ -n "${bmap[$sha]+x}" ] && { newtree=changed; break; }
  done < <(git ls-tree -r "$c")
  if [ "$newtree" = changed ]; then
    rm -f "$idx"
    GIT_INDEX_FILE=$idx git read-tree "$c^{tree}"
    while read -r mode type sha path; do
      [ "$type" = blob ] || continue
      if [ -n "${bmap[$sha]+x}" ]; then
        GIT_INDEX_FILE=$idx git update-index --cacheinfo "$mode,${bmap[$sha]},$path"
      fi
    done < <(git ls-tree -r "$c")
    newtree=$(GIT_INDEX_FILE=$idx git write-tree)
  else
    newtree=$(git rev-parse "$c^{tree}")
  fi
  out=""
  while IFS= read -r line; do
    case "$line" in
      '') ;;
      parent\ *) p=${line#parent }; out+="parent ${cmap[$p]}"$'\n' ;;
      tree\ *) out+="tree $newtree"$'\n' ;;
      *) out+="$line"$'\n' ;;
    esac
  done <<< "$hdr"
  nc=$( { printf '%s' "$out"; printf '\n'; printf '%s' "$msg"; } | git hash-object -t commit -w --stdin )
  cmap[$c]=$nc
done
rm -f "$idx" "$rawf" "$tmpf" "$tmpf.blob" "$tmpf.out"
git update-ref refs/heads/main "${cmap[$tip]}"
echo "done: $(git rev-list --count HEAD) commits, tip ${cmap[$tip]}"
