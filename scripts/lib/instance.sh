#!/usr/bin/env bash
# scripts/lib/instance.sh — the instance values, for SCRIPTS.
#
# Templates (config/**, modules/caddy/**, docs/**, compose files) carry
# {{TOKENS}} or ${VARS} and are rendered by scripts/render/render.sh. Scripts are CODE:
# they must not be templates, so they source this file and use plain variables.
#
# Values come from data/instance.conf (untracked, written by install.sh). Each
# variable falls back to a sane default, so a script still works on a fresh
# clone before the installer has ever run.
#
# SOURCED, never executed. Defines: DOMAIN, NODE_NAME, GITHUB_USER, REPO_NAME,
# REPO_DIR, DATA_DIR, LOG_DIR, STATE_DIR, TAILNET_SUBNET, SERVER_IP, EMAIL.
# Variables already set by the caller win (`: "${X:=...}"` semantics), which is
# how install.sh passes what it just prompted for.
#
# NOTE: the machine name is NODE_NAME, not HOSTNAME — HOSTNAME is a bash
# builtin that already holds the live hostname and clobbering it is confusing.

_INSTANCE_SELF="$(readlink -f "${BASH_SOURCE[0]:-$0}")"
# REPO_DIR is the checkout root. It is derived from this file's OWN location —
# never hardcoded — so the repo can be renamed or moved without editing
# anything: prefer the git toplevel (works from any depth), else walk up two
# levels (scripts/lib/instance.sh -> repo root).
: "${REPO_DIR:=$({ git -C "$(dirname "$_INSTANCE_SELF")" rev-parse --show-toplevel 2>/dev/null \
                     || (cd "$(dirname "$_INSTANCE_SELF")/../.." && pwd); })}"
: "${DATA_DIR:=$REPO_DIR/data}"
_INSTANCE_CONF="${INSTANCE_CONF:-$DATA_DIR/instance.conf}"

if [ -f "$_INSTANCE_CONF" ]; then
  while IFS= read -r _il || [ -n "$_il" ]; do
    case "$_il" in ''|'#'*) continue ;; esac
    _ik="${_il%%=*}"; _iv="${_il#*=}"
    case "$_ik" in
      DOMAIN|HOSTNAME|GITHUB_USER|REPO_NAME|REPO_DIR|DATA_DIR|LOG_DIR|STATE_DIR|TAILNET_SUBNET|SERVER_IP|EMAIL) ;;
      *) continue ;;
    esac
    [ "$_ik" = HOSTNAME ] && _ik=NODE_NAME
    printf -v "$_ik" '%s' "$_iv"
  done < "$_INSTANCE_CONF"
fi

: "${DOMAIN:=example.com}"
: "${NODE_NAME:=$(hostname -s 2>/dev/null || echo server)}"
: "${GITHUB_USER:=exampleuser}"
: "${REPO_NAME:=kefoServer}"
: "${LOG_DIR:=/var/log/kefohaine}"
: "${STATE_DIR:=/var/lib/kefohaine}"
: "${TAILNET_SUBNET:=100.64.0.0/10}"
: "${SERVER_IP:=}"
: "${EMAIL:=admin@$DOMAIN}"

unset _INSTANCE_SELF _INSTANCE_CONF _il _ik _iv 2>/dev/null || true
