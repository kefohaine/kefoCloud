#!/usr/bin/env bash
# Disposable mailbox generator: random-english-word@fxmq.net + random 16-char
# password, created on the Docker Mailserver instance. Credentials are printed
# once and stored nowhere — hand them over and forget them. Delete later with
# `make mail-del-user USER=<address>`.
# Usage: make mail-gen
set -euo pipefail

DOMAIN=fxmq.net
WORDFILE=/usr/share/dict/words
# Fallback word list (only used if /usr/share/dict/words is missing).
FALLBACK_WORDS=(amber ash aster briar brook cedar cloud coral cove crag dale dove dune
  elm ember falcon fern fig fir fox grove gull hawk heron holly ibis iris ivy jade
  juniper kite lark lilac linden maple meadow mist moss nettle oak onyx otter pebble
  pine poppy quill rabbit raven reed river sable salmon shale slate sparrow stone
  swift thistle tulip umber vale vine willow wren yarrow zephyr)

# Build a clean word list: lowercase, 4-9 letters (drops names, possessives, junk).
words_tmp=$(mktemp)
trap 'rm -f "$words_tmp"' EXIT
if [ -r "$WORDFILE" ]; then
  grep -E '^[a-z]{4,9}$' "$WORDFILE" | sort -u > "$words_tmp"
fi
if [ ! -s "$words_tmp" ]; then
  printf '%s\n' "${FALLBACK_WORDS[@]}" > "$words_tmp"
fi

# One random English word as the local part (e.g. quiet@fxmq.net). Retry on
# collisions with existing mailboxes.
addr=""
for _ in $(seq 1 10); do
  candidate=$(shuf -n1 "$words_tmp")
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

echo "Disposable mailbox created:"
echo "  address : $addr"
echo "  password: $pw"
echo "  login   : https://mail.fxmq.net   (username: ${addr%@*})"
echo "  delete  : make mail-del-user USER=$addr"
