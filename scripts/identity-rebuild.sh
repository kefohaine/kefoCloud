#!/usr/bin/env bash
# Plumbing identity rebuild for this repo's multi-root merge DAG.
# filter-branch AND filter-repo both drop the second root's line (131 commits,
# the jehpok era) on this history — only a parents-first plumbing rebuild
# preserves it exactly (see docs/GUIDE.md "History rewrites", lesson 2026-09-02).
# Rewrites author+committer EMAIL on every commit reachable from HEAD,
# preserving trees, dates, messages (byte-exact), merges and both roots.
# Usage: scripts/identity-rebuild.sh <old-email> <new-email>
#   (run inside a clone; updates refs/heads/main; push with --force yourself,
#    then run `make gh-web-health` — see docs/GUIDE.md lesson 2026-09-03.)
# Verify after every run: uniform identities, unchanged tip tree, byte-identical
# messages/dates, 2 roots / 9 merges / full commit count, `git fsck` clean.
set -euo pipefail
old_email=$1; new_email=$2
tip=$(git rev-parse HEAD)
declare -A map
mapfile -t commits < <(git rev-list --reverse --topo-order "$tip")
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
