#!/usr/bin/env bash
#
# scripts/goose-tokens.sh — apply config/goose/token-policy.yaml to the live
# goose settings store, idempotently.
#
# The live store (normally ~/.config/goose/config.yaml) is host state, not a
# repo file: goose rewrites it from `goose configure` and from provider
# selection, so the repo keeps the policy and this script merges it back in.
# Only the keys named in the policy are touched — provider blocks, keys goose
# manages itself and anything else already in the file survive untouched.
#
# The one computed key is GOOSE_MOIM_MESSAGE_FILE, pointed at this repo's
# config/goose/briefing.md (the per-turn output constraints), so the policy
# stays portable and the path is derived, never hardcoded.
#
# Usage:
#   scripts/goose-tokens.sh           apply the policy (backs up the live file)
#   scripts/goose-tokens.sh --check   report drift only, change nothing
#                                     exit 1 when the live store is stale
#
# Runs as `make goose-tokens` and as the last step of `make install-config` /
# `make deploy`, so a restored host picks the policy up unattended.

set -uo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
policy="$repo_dir/config/goose/token-policy.yaml"
briefing="$repo_dir/config/goose/briefing.md"
mode="${1:-apply}"

case "$mode" in
  apply|--check) ;;
  *) scripts/mklog error "usage: $0 [--check]"; exit 2 ;;
esac

[ -s "$policy" ] || { scripts/mklog error "missing policy file: $policy"; exit 1; }
[ -s "$briefing" ] || { scripts/mklog error "missing briefing file: $briefing"; exit 1; }

# Derive the live store path from goose itself (it knows its config dir —
# XDG, GOOSE_* overrides and all), falling back to the default location.
live="$(goose info 2>/dev/null | awk '/^Config yaml:/{print $NF}')"
live="${live:-$HOME/.config/goose/config.yaml}"

PY_OUT="$(python3 - "$policy" "$live" "$briefing" "$mode" <<'PY'
import os, sys
from datetime import datetime
import yaml

policy_path, live_path, briefing, mode = sys.argv[1:5]

with open(policy_path) as fh:
    policy = yaml.safe_load(fh) or {}
# Computed key: the briefing path always follows this repo checkout.
policy["GOOSE_MOIM_MESSAGE_FILE"] = briefing

live = {}
if os.path.exists(live_path):
    with open(live_path) as fh:
        live = yaml.safe_load(fh) or {}
    if not isinstance(live, dict):
        sys.exit("live config is not a mapping — refusing to touch it")

changed = []

def merge(dst, src, prefix=""):
    for key, val in src.items():
        path = f"{prefix}{key}"
        if isinstance(val, dict):
            if not isinstance(dst.get(key), dict):
                dst[key] = {}
            merge(dst[key], val, f"{path}.")
        elif dst.get(key) != val:
            dst[key] = val
            changed.append(f"{path}={val}")

merge(live, policy)
rendered = yaml.safe_dump(live, sort_keys=False, default_flow_style=False, allow_unicode=True)

current = ""
if os.path.exists(live_path):
    with open(live_path) as fh:
        current = fh.read()

if mode == "--check":
    if current == rendered:
        print("IN_SYNC " + str(len(str(policy))))
    else:
        print("DRIFT " + (" | ".join(changed) if changed else "format-only"))
    sys.exit(0)

if current == rendered:
    print("IN_SYNC")
    sys.exit(0)

if current:
    backup = f"{live_path}.bak-{datetime.now():%Y%m%d%H%M%S}"
    with open(backup, "w") as fh:
        fh.write(current)
    print("BACKUP " + backup)

os.makedirs(os.path.dirname(live_path), exist_ok=True)
tmp = live_path + ".tmp"
with open(tmp, "w") as fh:
    fh.write(rendered)
os.replace(tmp, live_path)
print("APPLIED " + " | ".join(changed))
PY
)"
rc=$?

case "$rc" in
  0) ;;
  *) scripts/mklog error "goose-tokens: could not merge the policy into $live"; exit 1 ;;
esac

backup="$(printf '%s\n' "$PY_OUT" | awk '/^BACKUP /{print $2}')"
status="$(printf '%s\n' "$PY_OUT" | awk '/^IN_SYNC|^APPLIED|^DRIFT/{print; exit}')"

[ -n "$backup" ] && scripts/mklog info "live goose config backed up to $backup"

case "$status" in
  IN_SYNC*) scripts/mklog info "goose token policy already in sync in $live" ;;
  DRIFT*)   scripts/mklog warn "goose token policy drifted: ${status#DRIFT }"; exit 1 ;;
  APPLIED*) scripts/mklog info "applied: ${status#APPLIED }" ;;
  *)        scripts/mklog warn "goose-tokens: unexpected result: $PY_OUT"; exit 1 ;;
esac

# The tom extension reads GOOSE_MOIM_MESSAGE_FILE from the process environment,
# NOT from the settings store: the store key alone injects nothing (verified
# 2026-09-20 — an env-supplied MOIM text landed in the reply, a store-only one
# did not), so publish it into both environments goose runs in. The unit reads
# /etc/goose/goose.env through EnvironmentFile= — append only, never read it
# back (it holds the server secret); ttyd and interactive CLI sessions get a
# login shell via /etc/profile.d/. goose reads the environment at process
# start, so a running `goose serve` needs `make systemd-restart-goose`.
if [ "$mode" = apply ]; then
  env_file=/etc/goose/goose.env
  env_line="GOOSE_MOIM_MESSAGE_FILE=$briefing"
  if sudo test -s "$env_file"; then
    if ! sudo grep -qxF "$env_line" "$env_file"; then
      printf '%s\n' "$env_line" | sudo tee -a "$env_file" >/dev/null &&
        scripts/mklog info "added GOOSE_MOIM_MESSAGE_FILE to $env_file (restart goose to apply)"
    fi
  else
    scripts/mklog warn "$env_file is missing (run make install-config first) — the serve unit has no briefing"
  fi

  profile=/etc/profile.d/goose-token-caps.sh
  tmp="$(mktemp)"
  {
    echo "# GENERATED by scripts/goose-tokens.sh — do not edit."
    echo "# Per-turn output constraints for goose sessions started from a login"
    echo "# shell (the ttyd web terminal). Refresh: make goose-tokens."
    printf 'export GOOSE_MOIM_MESSAGE_FILE=%s\n' "$briefing"
  } >"$tmp"
  if ! sudo cmp -s "$tmp" "$profile" 2>/dev/null; then
    sudo install -m 0644 "$tmp" "$profile" &&
      scripts/mklog info "wrote $profile"
  fi
  rm -f "$tmp"
fi
