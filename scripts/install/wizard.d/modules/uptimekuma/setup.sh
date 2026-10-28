# wizard.d/modules/uptimekuma/setup.sh — the monitor module: the Kuma admin account seed.

kuma_seed() {
  # Wait for the SCHEMA, not for the file. Kuma 2.5+ serves its "Setup
  # Database" wizard (port open, healthcheck green, kuma.db still 0 bytes) when
  # it can neither read db-config.json nor find a kuma.db — the compose file
  # now sets UPTIME_KUMA_DB_TYPE=sqlite so the main server starts and creates
  # the tables. Polling `test -f` was a trap: the poll timed out, sqlite3 then
  # CREATED an empty kuma.db and every seed statement failed with "no such
  # table" (2026-09-25).
  local i=0 ready=""
  while [ $i -lt 150 ]; do
    if docker exec uptimekuma sqlite3 /app/data/kuma.db \
         "SELECT 1 FROM sqlite_master WHERE type='table' AND name='user';" 2>/dev/null | grep -q 1; then
      ready=1; break
    fi
    sleep 2; i=$((i+2))
  done
  if [ -z "$ready" ]; then
    fail kuma_seed "kuma.db has no schema after 5 min (Kuma still in Setup Database)"
    return
  fi
  local n
  n=$(docker exec uptimekuma sqlite3 /app/data/kuma.db "SELECT COUNT(*) FROM user WHERE username='admin';" 2>/dev/null | tr -d '\n')
  if [ "$n" = "0" ]; then
    # Mint the password ONLY when the admin is actually created. Generating it
    # unconditionally made a re-run print a fresh random value in the success
    # block that was never written — the operator then held a Kuma password
    # that does not work. On a re-run KUMA_PASS stays empty and the success
    # block prints its "(already set …)" fallback (idempotent, same as before).
    KUMA_PASS=$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)
    local HASH
    HASH=$(htpasswd -bnBC 10 "" "$KUMA_PASS" 2>/dev/null | tr -d ':\n')
    if [ -n "$HASH" ]; then
      docker exec uptimekuma sqlite3 /app/data/kuma.db \
        "INSERT OR IGNORE INTO user (username,password,active,timezone) VALUES ('admin','$HASH',1,'UTC');" \
        >>"$LOG" 2>&1 || fail kuma_admin
    fi
  fi
  docker exec -i uptimekuma sqlite3 /app/data/kuma.db < modules/uptimekuma/seed-monitors.sql \
    >>"$LOG" 2>&1 || fail kuma_seed
}
