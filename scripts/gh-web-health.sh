#!/usr/bin/env bash
# GitHub web git-data health check for this repo's push remote.
# After a full-history rewrite + force-push, GitHub's web git-data index can
# 500/404 (web root, /tree, /commits — "Page not found") while git itself
# stays healthy; that was the 2026-09-03 kefohaine/server incident. Fix: push
# a nudge commit, which triggers GitHub's rebuild (allow ~10-20 min of
# intermittent 500s while it settles).
# Run `make gh-web-health` after any history rewrite; the pre-push hook warns
# when a push is about to replace remote history.
set -uo pipefail

fails=0

# owner/repo derived from the live push remote — never hardcoded (rule 12).
remote=$(git config --get "branch.$(git symbolic-ref --short HEAD 2>/dev/null).remote" 2>/dev/null || true)
[ -z "$remote" ] && remote=$(git remote 2>/dev/null | head -1)
if [ -z "$remote" ]; then echo "FAIL: no git remote — cannot derive the GitHub repo"; exit 1; fi
url=$(git remote get-url "$remote" 2>/dev/null) || { echo "FAIL: no URL for remote '$remote'"; exit 1; }
repo=$(printf '%s' "$url" | sed -E 's#(^git@github\.com:|^https://github\.com/|^ssh://git@github\.com/)##; s#\.git$##')
case "$repo" in */*) ;; *) echo "FAIL: remote '$remote' is not a github.com repo ($url)"; exit 1;; esac
branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo main)

api="https://api.github.com/repos/$repo"
attempts="${GH_WEB_ATTEMPTS:-5}"
gap="${GH_WEB_GAP:-4}"

echo "checking GitHub web git-data health: $repo (branch $branch, remote '$remote', up to $attempts attempts)"

# 1. Repo metadata must resolve.
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$api")
if [ "$code" = "200" ]; then echo "PASS repo metadata (HTTP $code)"; else echo "FAIL repo metadata: HTTP $code — $api"; fails=1; fi

# 2. Commits API must return 200 with a non-empty body — poll, the rebuild
#    settles over minutes and answers intermittently while doing so.
ok=0
for i in $(seq 1 "$attempts"); do
  body=$(curl -s --max-time 15 -w '\n%{http_code}' "$api/commits?per_page=1")
  code=${body##*$'\n'}
  if [ "$code" = "200" ] && [ "${#body}" -gt 20 ]; then ok=1; break; fi
  [ "$i" -lt "$attempts" ] && sleep "$gap"
done
if [ "$ok" = "1" ]; then echo "PASS commits API (HTTP 200, non-empty body)"; else echo "FAIL commits API: no 200 with a body after $attempts attempts — $api/commits"; fails=1; fi

# 3. The current branch ref must resolve.
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$api/git/ref/heads/$branch")
if [ "$code" = "200" ]; then echo "PASS branch ref heads/$branch (HTTP $code)"; else echo "FAIL branch ref heads/$branch: HTTP $code"; fails=1; fi

# 4. The web page must render.
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://github.com/$repo")
if [ "$code" = "200" ]; then echo "PASS web page (HTTP $code)"; else echo "FAIL web page: HTTP $code — https://github.com/$repo"; fails=1; fi

if [ "$fails" != "0" ]; then
  echo ""
  echo "GitHub web git-data index is unhealthy — likely a recent full-history rewrite."
  echo "Remedy: push a nudge commit to trigger GitHub's rebuild, then re-run this check:"
  echo "  git commit --allow-empty -m 'chore: nudge GitHub web git-data rebuild' && git push $remote $branch"
  echo "The rebuild settles in ~10-20 min with intermittent 500s — poll with: GH_WEB_ATTEMPTS=10 make gh-web-health"
  echo "If it is still failing after that, contact GitHub support (https://support.github.com)."
  exit 1
fi
exit 0
