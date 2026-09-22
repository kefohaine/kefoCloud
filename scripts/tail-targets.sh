#!/usr/bin/env bash
#
# scripts/tail-targets.sh — GENERATE the tail terminal's navigation catalogue
# from the Caddy vhost files, so nothing about the vhosts or their pages is
# hardcoded anywhere: add a vhost file (or a public path inside one) and it
# shows up in the terminal's prediction after the next run.
#
# Output: services/<domain>/www/targets.json (GENERATED — do not hand-edit).
# Refresh: `make tail-targets` (also run by `make install-config`).
#
# How a page is derived, structurally (no value lists):
#   * each vhost file's `https://<host> {` address becomes a target
#   * `handle_path <p>` / `handle <p>` with a single clean segment becomes a page
#   * `@name path <a> [<b> [<c>]]` (<= 3 paths) + `handle @name` becomes pages,
#     which picks up curated top-level routes (e.g. www's /welcome) while broad
#     internal matchers (many paths) are ignored
#   * every session in data/ttyd-devices.conf becomes a card on the terminal
#     page (/ttyd?arg=<name>) — per-device shells, managed by
#     `make ttyd-add/ttyd-rm` (scripts/ttyd-devices.sh). No vhost, no port.
set -uo pipefail

# Instance values (DOMAIN, REPO_DIR, DATA_DIR) come from data/instance.conf via
# scripts/instance.sh — the generator below reads them from the environment.
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
. "$ROOT/scripts/instance.sh"

export REPO_DIR DATA_DIR INSTANCE_CONF

python3 - <<'PYEOF'
import glob, os, json, os, re, sys

# Per-device web-terminal sessions (make ttyd-add / ttyd-rm). One ttyd
# listener serves them all as /ttyd?arg=<name>, so a device adds a CARD here,
# never a vhost and never a port.
def device_sessions():
    reg = os.path.join(os.environ.get("DATA_DIR", "."), "ttyd-devices.conf")
    if not os.path.exists(reg):
        return []
    return [l.strip() for l in open(reg, encoding="utf-8")
            if l.strip() and not l.strip().startswith("#")]

pages_out, vhosts = [], 0
for path in sorted(glob.glob(os.path.join(os.environ.get("REPO_DIR","."),"services/caddy/vhosts/*.caddy"))):
    src = open(path, encoding="utf-8").read()
    m = re.search(r"^https://([A-Za-z0-9.-]+)\s*\{", src, re.M)
    if not m:
        continue
    host = m.group(1)
    short = host.split(".")[0]

    matchers = {}
    for mm in re.finditer(r"^[ \t]*@([A-Za-z0-9_-]+)\s+path\s+([^\n{]+)", src, re.M):
        ps = mm.group(2).split()
        if 0 < len(ps) <= 3:
            matchers[mm.group(1)] = ps

    pages = {}
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

    if short == "tail":
        for dev in device_sessions():
            pages["ttyd?arg=%s" % dev] = "/ttyd?arg=%s" % dev
    url = "/" if short == "tail" else "https://%s/" % host
    pages_out.append({"name": short, "host": host, "url": url,
                      "pages": {k: pages[k] for k in sorted(pages)}})
    vhosts += 1

out_dir = os.path.join(os.environ.get("DATA_DIR","."), "rendered/caddy/www")
os.makedirs(out_dir, exist_ok=True)
out = os.path.join(out_dir, "targets.json")
with open(out, "w", encoding="utf-8") as fh:
    json.dump({"_generated": "scripts/tail-targets.sh — do not hand-edit",
               "targets": pages_out}, fh, indent=2, sort_keys=False)
    fh.write("\n")
print("wrote %s (%d vhosts)" % (out, vhosts))
PYEOF
