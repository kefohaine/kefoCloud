# wizard.d/modules/redis/setup.sh — the cloud cache door sanity check (which redis the cache points at).

# ── cloud cache door ────────────────────────────────────────────────────────
# cloud and mail share the external `net` bridge. When the mail cache is again
# published under the name `redis`, the cloud container resolves that name to
# BOTH caches, phpredis round-robins onto Mailu's instance and every Nextcloud
# session SET waits on its MISCONF error — all php-fpm children end up blocked
# and nextcloud.$DOMAIN stops answering, while `occ status` (a separate CLI process)
# still looks healthy. That is exactly the 2026-10-19 smoke failure (cloud HTTP
# 000 + xfo/xcto/hsts=0) and the reason notify_push:setup never succeeded.
# Detect the duplicate name (and a cache that refuses writes), drop the alias by
# recreating the mail stack, restart nextcloud to kill the wedged workers and
# their dead phpredis connections, then verify. Idempotent: a healthy stack
# logs one line and touches nothing.
redis_door_sanity() {
  mod_on cloud || return 0
  docker exec nextcloud true >/dev/null 2>&1 || return 0
  local ips set i=0
  ips=$(docker exec nextcloud getent hosts redis 2>/dev/null | awk '{print $1}' | sort -u | wc -l)
  set=$(_redis_probe)
  if [ "${ips:-0}" -le 1 ] && [ "$set" = ok ]; then
    detail "  cloud cache redis: single address, writes accepted"
    return 0
  fi
  log "  cloud cache redis UNHEALTHY: ${ips:-?} address(es) for 'redis', write=${set:-failed} — repairing"
  # The duplicate alias can only come from the mail stack; its compose file now
  # names that service mailu-redis, so a recreate removes the bogus `redis` name.
  # A RENAMED service keeps its old container under the same container_name, and
  # compose refuses to create the new one ("name is already in use") before
  # --remove-orphans gets a chance — drop the stale container first.
  if mod_on mail; then
    local svc
    svc=$(docker inspect mailu-redis --format '{{index .Config.Labels "com.docker.compose.service"}}' 2>/dev/null || true)
    if [ -n "$svc" ] && [ "$svc" != mailu-redis ]; then
      log "  mail cache container still labelled '${svc}' — removing it before the recreate"
      docker rm -f mailu-redis >>"$LOG" 2>&1 || true
    fi
    make dok-recreate-mailserver >>"$LOG" 2>&1 || log "  mailserver recreate failed — see $LOG"
  fi
  # Blocked workers never recover and hold a dead phpredis connection: only a
  # restart drops them.
  docker restart nextcloud >>"$LOG" 2>&1 || log "  nextcloud restart failed — see $LOG"
  while [ $i -lt 60 ]; do
    set=$(_redis_probe)
    if [ "$set" = ok ]; then
      ips=$(docker exec nextcloud getent hosts redis 2>/dev/null | awk '{print $1}' | sort -u | wc -l)
      if [ "${ips:-0}" -le 1 ]; then
        detail "  cloud cache redis: repaired (single address, writes accepted)"
        return 0
      fi
    fi
    sleep 2; i=$((i+2))
  done
  fail redis_door_sanity "'redis' still ambiguous or read-only inside the cloud container — check modules/mailserver/docker-compose.yml (service must be mailu-redis) and that data/mailserver/redis is owned 999:1000"
}

# _redis_probe → ok | misconf | rejected | unreachable (echoed, never fatal).
_redis_probe() {
  timeout 25 docker exec -u www-data nextcloud php -r '
try {
  $r = new Redis();
  if (!$r->connect("redis", 6379, 2)) { echo "unreachable"; exit; }
  echo $r->set("kefo:probe", 1) ? "ok" : "rejected";
} catch (Throwable $e) {
  echo strpos($e->getMessage(), "MISCONF") !== false ? "misconf" : "unreachable";
}' 2>/dev/null || echo unreachable
}
