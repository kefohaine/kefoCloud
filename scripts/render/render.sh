#!/usr/bin/env bash
# scripts/render/render.sh — turn a SKELETON file into a deployable one.
#
# The repo is a skeleton: deployable files carry {{TOKENS}} ({{DOMAIN}},
# {{REPO_DIR}}, {{HOSTNAME}}, …), never one operator's real domain, hostname,
# paths or usernames. The values live in ONE untracked file, data/instance.conf,
# written by scripts/install/install.sh (or by hand — it is plain KEY=VALUE).
#
#   scripts/render/render.sh <input> [output]     # output defaults to stdout
#   scripts/render/render.sh --check <input>      # exit 1 if any token is unresolved
#   scripts/render/render.sh --reverse <in> <out> # live values -> {{TOKENS}} (for `make backup`)
#   scripts/render/render.sh --tokens             # list the tokens + the values in use
#
# Unknown tokens are left VERBATIM and reported on stderr — a missing value is
# loud, never a silently empty string in a config that then fails at runtime.
#
# Used by `make render` / `make install-config` for the Caddy tree, systemd
# units, dnsmasq, cron, the logrotate rule and the shell banner. Compose files
# are NOT rendered — they take the same values as ${VARS} from the untracked
# .env that `make render` writes next to each compose file.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
CONF="${INSTANCE_CONF:-$ROOT/data/instance.conf}"
DEFAULTS="$ROOT/config/instance.defaults"

MODE=render; IN=""; OUT=""
case "${1:-}" in
  --tokens) MODE=tokens ;;
  --check)  MODE=check; IN="${2:-}" ;;
  --reverse) MODE=reverse; IN="${2:-}"; OUT="${3:-}" ;;
  -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "")       echo "usage: scripts/render/render.sh <input> [output] | --check <input> | --tokens" >&2; exit 2 ;;
  *)        IN="$1"; OUT="${2:-}" ;;
esac

[ -f "$CONF" ] || {
  echo "render.sh: no $CONF" >&2
  echo "  Create it (scripts/install/install.sh writes it) with the values for THIS host:" >&2
  echo "  see config/instance.defaults for the token list." >&2
  exit 1
}
[ "$MODE" = render ] || [ "$MODE" = tokens ] || [ "$MODE" = check ] || [ "$MODE" = reverse ] || exit 2
[ -n "$IN" ] || [ "$MODE" = tokens ] || [ "$MODE" = render ] && [ -z "$IN" ] && IN="$CONF"
[ "$MODE" != tokens ] && [ -n "$IN" ] && [ ! -f "$IN" ] && { echo "render.sh: no such file: $IN" >&2; exit 1; }

MODE="$MODE" IN="$IN" OUT="$OUT" CONF="$CONF" DEFAULTS="$DEFAULTS" python3 - <<'PY'
import os, re, sys
mode, inp, outp = os.environ["MODE"], os.environ.get("IN",""), os.environ.get("OUT","")
conf, defaults = os.environ["CONF"], os.environ["DEFAULTS"]

def kv(path):
    d = {}
    try: lines = open(path, encoding="utf-8", errors="surrogateescape").read().splitlines()
    except FileNotFoundError: return d
    for l in lines:
        l = l.strip()
        if not l or l.startswith("#") or "=" not in l: continue
        k, _, v = l.partition("=")
        d[k.strip()] = v.strip()
    return d

V = kv(conf)
DOC = {}
for l in open(defaults, encoding="utf-8", errors="surrogateescape").read().splitlines():
    m = re.match(r"^#\s*([A-Z_]+)\s*[—:-]\s*(.*)$", l)
    if m: DOC[m.group(1)] = m.group(2).strip()

if mode == "tokens":
    for k in sorted(set(DOC) | set(V)):
        mark = "" if k in V else "  (NOT SET)"
        print(f"  {{{{{k}}}}}  = {V.get(k,'')!r}{mark}")
        if DOC.get(k): print(f"          {DOC[k]}")
    sys.exit(0)

data = open(inp, encoding="utf-8", errors="surrogateescape").read()

if mode == "reverse":
    # Live file -> template: replace each VALUE with its {{TOKEN}}. Used by
    # `make backup` so pulling config back from the host can never bake an
    # instance value into the skeleton. Only keys whose values are safe to match
    # textually are reversed (no TIMEZONE/OPERATOR: short or
    # generic values would rewrite unrelated words). Longest value first, so
    # /root/github/x/data is matched before /root/github/x.
    KEYS = ["REPO_DIR","DATA_DIR","STATE_DIR","LOG_DIR","GITHUB_USER","REPO_NAME",
            "HOSTNAME","SERVER_IP","EMAIL","DOMAIN"]
    for k in sorted((k for k in KEYS if V.get(k)), key=lambda k: -len(V[k])):
        data = data.replace(V[k], "{{%s}}" % k)
    if outp:
        with open(outp, "w", encoding="utf-8", errors="surrogateescape") as f: f.write(data)
        os.chmod(outp, 0o644)
    else:
        sys.stdout.write(data)
    sys.exit(0)
missing = []
def sub(m):
    k = m.group(1)
    if k in V: return V[k]
    missing.append(k); return m.group(0)
out = re.sub(r"\{\{([A-Z_][A-Z0-9_]*)\}\}", sub, data)
if missing:
    uniq = sorted(set(missing))
    print(f"render.sh: WARNING {inp} — unresolved token(s): {', '.join('{{'+u+'}}' for u in uniq)}", file=sys.stderr)
    print(f"render.sh:          (add them to {conf})", file=sys.stderr)
if mode == "check":
    sys.exit(1 if missing else 0)
if outp:
    with open(outp, "w", encoding="utf-8", errors="surrogateescape") as f: f.write(out)
    os.chmod(outp, 0o644)
else:
    sys.stdout.write(out)
PY
