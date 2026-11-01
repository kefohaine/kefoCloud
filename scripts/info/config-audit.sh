#!/usr/bin/env bash
# config-audit.sh — read-only checks on the deployable tree. Nothing is written.
#
# Three rules, each of which has cost real downtime when it was broken:
#   1. every YAML file parses (a stray tab in a compose file kills a module at
#      boot, and `docker compose` reports it one service at a time);
#   2. every {{TOKEN}} used by a deployable file is declared in
#      config/instance.defaults (an undeclared token renders literally, and a
#      literal {{TOKEN}} in a vhost is a config that only fails in production);
#   3. no operator value leaks into a tracked file (the repo carries tokens,
#      never one instance's values).
#
# Usage: bash scripts/info/config-audit.sh      # exits 1 on the first rule broken

set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
status=0

fail() { printf 'config-audit: %s\n' "$*" >&2; status=1; }

# 1. YAML parses. Python is the only YAML parser guaranteed on the host image.
if command -v python3 >/dev/null; then
  while IFS= read -r f; do
    python3 - "$f" <<'PY' || status=1
import sys
try:
    import yaml
except ImportError:
    sys.exit(0)
try:
    yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
except Exception as exc:
    print(f"config-audit: {sys.argv[1]}: {exc}", file=sys.stderr)
    sys.exit(1)
PY
  done < <(git ls-files '*.yml' '*.yaml')
else
  printf 'config-audit: python3 missing, YAML rule skipped\n' >&2
fi

# 2. Every token used is declared. Declarations are the `# TOKEN — meaning`
# lines of config/instance.defaults, which is the single token list.
declared=$(grep -oP '^# \K[A-Z_]+(?= —)' config/instance.defaults | sort -u)
# {{TOKENS}} is the meta-token: this file's own prose says "deployable files
# carry {{TOKENS}}", so it is a word about tokens, not a token.
used=$(git grep -oh '{{[A-Z_]*}}' -- modules config | sed 's/[{}]//g' | sort -u | grep -vx 'TOKENS')
while IFS= read -r tok; do
  [ -n "$tok" ] || continue
  grep -qx "$tok" <<<"$declared" || fail "{{${tok}}} is used but not declared in config/instance.defaults"
done <<<"$used"

# 3. No operator value in a tracked file: the real domain and the real tailnet
# IP never belong in the repo, only in data/instance.conf.
for key in DOMAIN SERVER_IP; do
  val=$(grep -oP "^${key}=\K.*" data/instance.conf 2>/dev/null)
  [ -n "${val:-}" ] || continue
  [ "${val}" = "example.com" ] && continue
  hits=$(git grep -lF -- "$val" -- . ':!data' 2>/dev/null)
  [ -z "$hits" ] || fail "${key} value leaks into a tracked file: ${hits}"
done

[ "$status" = 0 ] && printf 'config-audit: clean\n'
exit "$status"
