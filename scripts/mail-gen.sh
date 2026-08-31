#!/usr/bin/env bash
# Disposable mailbox generator: random 7-letter local part (e.g.
# qkzfwbc@fxmq.net) + random 16-char password, created on the Docker
# Mailserver instance. Credentials are printed once and stored nowhere.
# The local part is ALWAYS generated — there is no way to pass a custom
# name, so human-chosen/guessable addresses can't sneak in.
# Usage: make mail-gen
set -euo pipefail

DOMAIN=fxmq.net

# Default quota for disposable mailboxes — read from
# services/mailserver/default-quota (set with make mail-default-quota-set);
# falls back to 1G on a fresh clone.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEFAULT_QUOTA=$(cat "$SCRIPT_DIR/../services/mailserver/default-quota" 2>/dev/null || echo 1G)
echo "$DEFAULT_QUOTA" | grep -qE '^([0-9]+(B|k|M|G|T)|0)$' || DEFAULT_QUOTA=1G

# 7 random lowercase letters. Loop instead of `tr | head -c 7` (head closing
# the pipe SIGPIPEs tr, and pipefail turns that into a script failure).
rand_local() {
  local s=""
  while [ "${#s}" -lt 7 ]; do
    s+=$(openssl rand -base64 48 | tr -dc 'a-z')
  done
  printf '%s' "${s:0:7}"
}

addr=""
for _ in $(seq 1 10); do
  candidate=$(rand_local)
  if ! docker exec mailserver setup email list 2>/dev/null \
       | grep -qiE "^[* ] *$candidate@$DOMAIN( |\$|\[)"; then
    addr="$candidate@$DOMAIN"
    break
  fi
done
[ -n "$addr" ] || { echo "mail-gen: no unique address found after 10 tries"; exit 1; }

# 16 chars from openssl (base64 of 12 random bytes). Fed via stdin so the
# password never appears in the process list or shell history.
pw=$(openssl rand -base64 12 | tr -d '\n')
printf '%s\n%s\n' "$pw" "$pw" | docker exec -i mailserver setup email add "$addr" >/dev/null

# Disposable mailboxes get the default quota (services/mailserver/default-quota,
# make mail-default-quota-set) — transient addresses stay bounded; `make
# mail-del-user` removes the quota entry along with the mailbox.
docker exec mailserver setup quota set "$addr" "$DEFAULT_QUOTA" >/dev/null

echo "Disposable mailbox created:"
echo "  address : $addr"
echo "  password: $pw"
echo "  quota   : $DEFAULT_QUOTA (default for disposable mailboxes)"
echo "  login   : https://mail.fxmq.net   (username: ${addr%@*})"
echo "  delete  : make mail-del-user USER=$addr"
