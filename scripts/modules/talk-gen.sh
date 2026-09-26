#!/usr/bin/env bash
# Generate the Nextcloud-stack secrets + Talk service configs.
#
# Writes any missing secrets into modules/nextcloud/.env (idempotent —
# existing values are kept) and renders the signaling + coturn configs into
# the gitignored runtime dir $ROOT/data/talk/.
# Prints nothing sensitive.
#
# Recipe: make talk-gen   (also sets POSTGRES_*/REDIS_HOST defaults in .env)

. "$(dirname "$(readlink -f "$0")")/../lib/instance.sh" 2>/dev/null || true
set -euo pipefail

# NOTE: REPO here is the DATA dir (historical name), derived not hardcoded.
REPO="$DATA_DIR"
ENV="$REPO_DIR/modules/nextcloud/.env"
TALK="$REPO/talk"

mkdir -p "$TALK"
touch "$ENV"
chmod 600 "$ENV"

set_env() {
  local k="$1" v="$2"
  grep -q "^${k}=" "$ENV" || echo "${k}=${v}" >> "$ENV"
}

# Secrets (only appended when absent — a rerun never rotates live values).
[ -n "${POSTGRES_PASSWORD:-}" ] || set_env POSTGRES_PASSWORD "$(openssl rand -hex 24)"
set_env SIGNALING_SECRET "$(openssl rand -hex 32)"
# The Go signaling server counts string length: hashkey must be 32 or 64
# chars, blockkey 16/24/32 chars. hex-32 = 64 chars, hex-16 = 32 chars.
set_env SIGNALING_HASH_KEY "$(openssl rand -hex 32)"
set_env SIGNALING_BLOCK_KEY "$(openssl rand -hex 16)"
set_env SIGNALING_INTERNAL_SECRET "$(openssl rand -hex 32)"
set_env TURN_SECRET "$(openssl rand -hex 32)"
# Password for the nextcloud@$DOMAIN mailbox used as NC's SMTP sender.
set_env SMTP_PASSWORD "$(openssl rand -hex 16)"

# Non-secret stack wiring.
set_env POSTGRES_DB nextcloud
set_env POSTGRES_USER nextcloud
set_env POSTGRES_HOST 172.22.0.15
set_env REDIS_HOST redis

# Render the Talk configs from the committed templates. The templates live in
# the CHECKOUT ($REPO_DIR), not under the data dir — $REPO is $DATA_DIR here
# (historical name), and the old "$REPO/repo/..." path never existed, so the
# render aborted (set -e) AFTER the secrets were written and left a 0-byte
# server.conf behind (2026-09-25 fresh install: talk-hpb then crash-looped on
# "open /config/server.conf: permission denied").
. "$ENV"
TPL="$REPO_DIR/modules/nextcloud/talk"
for f in "$TPL/server.conf.example" "$TPL/turnserver.conf.example"; do
  [ -r "$f" ] || { echo "missing template: $f" >&2; exit 1; }
done
# docker compose creates a DIRECTORY as the bind-mount source when the source
# file does not exist yet (seen 2026-09-25: data/talk/turnserver.conf was a
# dir, which then breaks the render). Clear that placeholder first.
for f in "$TALK/server.conf" "$TALK/turnserver.conf"; do
  [ -d "$f" ] && rmdir "$f" 2>/dev/null || true
done
sed -e "s/__SIGNALING_HASH_KEY__/$SIGNALING_HASH_KEY/g" \
    -e "s/__SIGNALING_BLOCK_KEY__/$SIGNALING_BLOCK_KEY/g" \
    -e "s/__SIGNALING_INTERNAL_SECRET__/$SIGNALING_INTERNAL_SECRET/g" \
    -e "s/__SIGNALING_SECRET__/$SIGNALING_SECRET/g" \
    "$TPL/server.conf.example" > "$TALK/server.conf"
sed -e "s/__TURN_SECRET__/$TURN_SECRET/g" \
    "$TPL/turnserver.conf.example" > "$TALK/turnserver.conf"
chmod 600 "$TALK/turnserver.conf"
# 644 not 600: the signaling container drops to uid 850 (spreedbackend) via
# su-exec and must be able to read this file through the :ro bind mount.
chmod 644 "$TALK/server.conf"

echo "Talk configs written to $TALK/ (server.conf, turnserver.conf); secrets in $ENV"
