#!/bin/bash
# Start the PufferPanel-managed Minecraft server via the panel daemon API, then
# stay alive until the game server goes down. lazymc treats its start command as
# the server process: it only considers the server stopped when this process
# exits. SIGTERM (lazymc's stop path) triggers a graceful panel stop first and
# keeps polling until the server is really gone, so the state settles cleanly.
# Auth: puffer_auth cookie (the session lives in the cookie, not the JSON body).
# Credentials: /etc/lazymc/panel-cred (root-only; never commit).
set -euo pipefail
CRED=/etc/lazymc/panel-cred
API=http://172.22.0.8:8080
JAR=$(mktemp)
trap 'rm -f "$JAR"' EXIT

server_up() {
    (exec 3<>/dev/tcp/127.0.0.1/25566) 2>/dev/null && { exec 3>&- 3<&-; return 0; } || return 1
}

on_term() {
    trap - TERM INT
    curl -fsS --max-time 30 -b "$JAR" -X POST "$API/api/servers/2ecfbe8c/stop" -o /dev/null || true
    for _ in $(seq 1 180); do
        server_up || exit 0
        sleep 2
    done
    exit 0
}
trap on_term TERM INT

email=$(sed -n 's/^email=//p' "$CRED")
pass=$(sed -n 's/^password=//p' "$CRED")
[ -n "$email" ] && [ -n "$pass" ] || { echo "lazymc: missing panel creds" >&2; exit 1; }
curl -fsS --max-time 15 -c "$JAR" -X POST -H 'Content-Type: application/json' \
  -d "{\"email\":\"$email\",\"password\":\"$pass\"}" "$API/auth/login" -o /dev/null || exit 1
curl -fsS --max-time 30 -b "$JAR" -X POST "$API/api/servers/2ecfbe8c/start" -o /dev/null || exit 1

# Phase 1: wait for the game server to come up (fresh container + world load).
for _ in $(seq 1 120); do
    if server_up; then break; fi
    sleep 2
done

# Phase 2: keep alive until the server goes down (SIGTERM handled above).
while true; do
    server_up || exit 0
    sleep 3
done
