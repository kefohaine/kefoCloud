#!/usr/bin/env bash
#
# scripts/access/tail-targets.sh — GENERATE the tail terminal's navigation catalogue
# from the Caddy vhost files, so nothing about the vhosts or their pages is
# hardcoded anywhere: add a vhost file (or a public path inside one) and it
# shows up in the terminal's prediction after the next run.
#
# Output: $DATA_DIR/www/targets.json (GENERATED — do not hand-edit).
# Refresh: `make tail-targets` (also run by `make install-config`).
#
# WHAT IS IN IT: only the TAILNET-only routes of this instance — the routes of
# the tail vhost itself (the shell, one card per registered device session),
# derived from modules/caddy/vhosts/tail.caddy. PUBLIC routes are deliberately
# NOT listed any more (operator request 2026-09-22): this page is the tailnet
# door list, not a directory of everything the domain serves. Nothing is
# hardcoded — add a route to tail.caddy (or a device with `make ttyd-add`) and
# it appears here after the next run.
#
# Reminder on the vocabulary: a module that is NOT INSTALLED has no route at
# all and never appears here — this list is about routes that exist and are
# reachable only inside the tailnet.
set -uo pipefail

# Instance values (DOMAIN, REPO_DIR, DATA_DIR) come from data/instance.conf via
# scripts/lib/instance.sh — the generator below reads them from the environment.
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
. "$ROOT/scripts/lib/instance.sh"

export REPO_DIR DATA_DIR INSTANCE_CONF

python3 - <<'PYEOF'
import glob, os, json, re

DATA = os.environ.get("DATA_DIR", ".")
REPO = os.environ.get("REPO_DIR", ".")

# The tail vhost file is identified by its server address (a `tail.` label),
# never by a filename.
def tail_vhost():
    # Prefer the RENDERED vhosts (what the edge actually loads, real hostnames);
    # fall back to the tracked skeleton before the first `make render`.
    vdir = os.path.join(DATA, "rendered/caddy/vhosts")
    if not os.path.isdir(vdir):
        vdir = os.path.join(REPO, "modules/caddy/vhosts")
    for path in sorted(glob.glob(os.path.join(vdir, "*.caddy"))):
        src = open(path, encoding="utf-8").read()
        m = re.search(r"^https://([A-Za-z0-9.-]+)\s*\{", src, re.M)
        if m and m.group(1).split(".")[0] == "tail":
            return m.group(1), src
    return None, None

# Per-device web-terminal sessions (make ttyd-add / ttyd-rm). One ttyd listener
# serves them all as /ttyd?arg=<name>, so a device adds a CARD here, never a
# vhost and never a port.
def device_sessions():
    reg = os.path.join(DATA, "ttyd-devices.conf")
    if not os.path.exists(reg):
        return []
    return [l.strip() for l in open(reg, encoding="utf-8")
            if l.strip() and not l.strip().startswith("#")]

host, src = tail_vhost()
pages = {}
if src:
    matchers = {}
    for mm in re.finditer(r"^[ \t]*@([A-Za-z0-9_-]+)\s+path\s+([^\n{]+)", src, re.M):
        ps = mm.group(2).split()
        if 0 < len(ps) <= 3:
            matchers[mm.group(1)] = ps

    def add(p):
        p = p.strip().rstrip("*").rstrip("/")
        seg = p.strip("/")
        if not re.fullmatch(r"[a-z0-9][a-z0-9_\-]*", seg or ""):
            return
        pages[seg] = p

    for h in re.finditer(r"^[ \t]*handle(?:_path)?\s+(\S+)", src, re.M):
        arg = h.group(1)
        if arg.startswith("@"):
            for p in matchers.get(arg[1:], []):
                add(p)
        else:
            add(arg)

for dev in device_sessions():
    pages["ttyd?arg=%s" % dev] = "/ttyd?arg=%s" % dev

targets = []
if host:
    targets.append({"name": "tail", "host": host, "url": "/",
                    "pages": {k: pages[k] for k in sorted(pages)}})

out_dir = os.path.join(DATA, "www")
os.makedirs(out_dir, exist_ok=True)
out = os.path.join(out_dir, "targets.json")
with open(out, "w", encoding="utf-8") as fh:
    json.dump({"_generated": "scripts/access/tail-targets.sh — do not hand-edit",
               "scope": "tailnet-only routes", "targets": targets}, fh,
              indent=2, sort_keys=False)
    fh.write("\n")
print("wrote %s (%d tailnet route(s))" % (out, len(pages)))
PYEOF
