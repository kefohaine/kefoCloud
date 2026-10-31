#!/usr/bin/env bash
# Import the issue migration into the GitHub Issues tab.
#
#   .github/labels.yml          -> labels (created, or updated in place)
#   .github/issues/import.jsonl -> issues (one per line: {"title","labels","body"})
#
# GitHub only creates labels and issues through its API or the web UI; committing
# these files does nothing by itself. This script is that API call.
#
# Auth, in this order:
#   1. `gh auth login` (the installer installs gh) — every call goes through
#      `gh api`, which uses the CLI's own stored credential. Nothing here reads
#      or prints a token.
#   2. GITHUB_TOKEN / GH_TOKEN with `Issues: read and write` + `Metadata: read`
#      on this repository, called through the REST API. SSH remotes cannot
#      authenticate the API, so there is no key-based alternative.
#
# Idempotent: a label that already exists is PATCHed to the manifest's colour and
# description; an issue is created only when no issue (open or closed) already
# carries the same title. Safe to re-run.
#
# Usage: scripts/ops/import-issues.sh [--dry-run]
set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  mode=gh
elif [ -n "$token" ]; then
  mode=token
else
  echo "import-issues: no credential — run 'gh auth login' (gh is installed by the installer)," >&2
  echo "  or export GITHUB_TOKEN (fine-grained PAT: Issues read/write + Metadata read)." >&2
  exit 1
fi

slug="$(git -C "$REPO" remote get-url origin \
  | sed -e 's#^git@github\.com:##' -e 's#^ssh://git@github\.com/##' -e 's#^https\?://github\.com/##' \
  | sed -e 's#\.git$##' -e 's#/$##')"
[ -n "$slug" ] || { echo "import-issues: cannot derive owner/repo from origin" >&2; exit 1; }

MODE="$mode" GITHUB_TOKEN="$token" SLUG="$slug" DRY="$DRY" python3 - "$REPO" <<'PY'
import json, os, subprocess, sys, urllib.error, urllib.parse, urllib.request

repo = sys.argv[1]
slug = os.environ["SLUG"]
dry = os.environ["DRY"] == "1"
mode = os.environ["MODE"]
api = "https://api.github.com/repos/" + slug
hdr = {
    "Authorization": "Bearer " + os.environ["GITHUB_TOKEN"],
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "kefoCloud-import-issues",
}


def gh_api(method, path, payload=None):
    """The gh path: `gh api` owns the credential, so no token enters this process."""
    data = json.dumps(payload).encode() if payload is not None else None
    r = subprocess.run(["gh", "api", "--include", "-X", method, "repos/" + slug + path],
                       input=data, capture_output=True)
    out = r.stdout.decode(errors="replace")
    sep = "\r\n\r\n" if "\r\n\r\n" in out else "\n\n"
    head, _, body = out.partition(sep)
    try:
        status = int(head.split()[1])
    except (IndexError, ValueError):
        status = 0
    try:
        parsed = json.loads(body) if body.strip() else None
    except ValueError:
        parsed = {"message": body.strip()}
    if status == 0:
        parsed = {"message": r.stderr.decode(errors="replace").strip() or "gh api failed"}
    return status, parsed


def call(method, path, payload=None):
    if mode == "gh":
        return gh_api(method, path, payload)
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(api + path, data=data, headers=hdr, method=method)
    try:
        with urllib.request.urlopen(req) as r:
            body = r.read()
            return r.status, (json.loads(body) if body else None)
    except urllib.error.HTTPError as e:
        raw = e.read().decode(errors="replace")
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, {"message": raw}

# --- labels ---------------------------------------------------------------
import re
labels = []
cur = None
for line in open(os.path.join(repo, ".github/labels.yml"), encoding="utf-8"):
    s = line.strip()
    m = re.match(r'^- name:\s*"?([^"#]+?)"?\s*$', s)
    if m:
        if cur: labels.append(cur)
        cur = {"name": m.group(1)}
        continue
    if cur is None or s.startswith("#"):
        continue
    for key in ("color", "description"):
        m = re.match(r'^%s:\s*"?(.*?)"?\s*$' % key, s)
        if m:
            cur[key] = m.group(1)
if cur: labels.append(cur)

# GitHub's own two labels ship with every repository; recreating them would fail.
native = {"good first issue", "help wanted"}
created = updated = 0
for lab in labels:
    if lab["name"].lower() in native:
        continue
    payload = {"color": lab.get("color", "ededed"), "description": lab.get("description", "")[:100]}
    if dry:
        print("label: would upsert %r" % lab["name"])
        continue
    st, _ = call("POST", "/labels", dict(payload, name=lab["name"]))
    if st == 201:
        created += 1
    elif st == 422:
        st2, _ = call("PATCH", "/labels/" + urllib.parse.quote(lab["name"], safe=""), payload)
        if st2 != 200:
            sys.exit("label %r exists but could not be updated (HTTP %s)" % (lab["name"], st2))
        updated += 1
    else:
        sys.exit("label %r could not be created (HTTP %s)" % (lab["name"], st))

# --- issues ---------------------------------------------------------------
have = set()
page = 1
while not dry:
    st, batch = call("GET", "/issues?state=all&per_page=100&page=%d" % page)
    if st != 200:
        sys.exit("cannot list issues (HTTP %s)" % st)
    for it in batch:
        if "pull_request" not in it:
            have.add(it["title"].strip())
    if len(batch) < 100:
        break
    page += 1

rows = [json.loads(l) for l in open(os.path.join(repo, ".github/issues/import.jsonl"), encoding="utf-8") if l.strip()]
opened = skipped = 0
for r in rows:
    if r["title"].strip() in have:
        skipped += 1
        continue
    if dry:
        print("issue: would open %r %s" % (r["title"], r.get("labels", [])))
        continue
    st, body = call("POST", "/issues", {"title": r["title"], "body": r.get("body", ""), "labels": r.get("labels", [])})
    if st != 201:
        sys.exit("issue %r failed (HTTP %s: %s)" % (r["title"], st, (body or {}).get("message")))
    opened += 1
    print("  #%s %s" % (body["number"], r["title"]))

if dry:
    print("dry run: %d labels, %d issues in the manifest" % (len(labels), len(rows)))
else:
    print("labels: %d created, %d updated | issues: %d opened, %d already present" % (created, updated, opened, skipped))
    print("https://github.com/%s/issues" % slug)
PY
