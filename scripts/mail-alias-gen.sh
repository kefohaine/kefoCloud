#!/usr/bin/env bash
# Disposable forwarding alias generator: random 7-digit local part (e.g.
# 4839201@fxmq.net) forwarding to TO. No mailbox is consumed — mail to the
# alias lands in TO (any address, internal or external). The alias is ALWAYS
# generated — TO is the only argument; custom aliases aren't accepted.
# Usage: make mail-alias-gen TO=target@example.com
set -euo pipefail

DOMAIN=fxmq.net
TO="${1:-}"
[ -n "$TO" ] || { echo "Usage: make mail-alias-gen TO=target@example.com"; exit 1; }

# 7 random digits. Loop instead of `tr | head -c 7` (head closing the pipe
# SIGPIPEs tr, and pipefail turns that into a script failure).
rand_local() {
  local s=""
  while [ "${#s}" -lt 7 ]; do
    s+=$(openssl rand -base64 48 | tr -dc '0-9')
  done
  printf '%s' "${s:0:7}"
}

alias_addr=""
for _ in $(seq 1 10); do
  candidate=$(rand_local)
  if ! docker exec mailserver setup alias list 2>/dev/null \
       | grep -qiE "^[* ] *$candidate@$DOMAIN "; then
    alias_addr="$candidate@$DOMAIN"
    break
  fi
done
[ -n "$alias_addr" ] || { echo "mail-alias-gen: no unique alias found after 10 tries"; exit 1; }

docker exec mailserver setup alias add "$alias_addr" "$TO" >/dev/null

echo "Disposable forwarding alias created:"
echo "  alias    : $alias_addr"
echo "  forwards : $TO"
echo "  delete   : make mail-alias-del ALIAS=$alias_addr TO=$TO"
