-- First-time Kuma monitor seed. Idempotent — safe to re-run.
-- Apply with:
--   docker exec -i ut-kuma sqlite3 /app/data/kuma.db < services/ut-kuma/seed-monitors.sql
--
-- Adjust user_id (1) if your admin is not id=1
-- (check: docker exec ut-kuma sqlite3 /app/data/kuma.db "SELECT id,username FROM user;").
--
-- Schema differences vs older Kuma: docker_host has user_id/docker_type/docker_daemon
-- (no endpoint/type), group has no user_id. If your schema differs, edit the columns.

-- ── Docker host (kuma talks to /var/run/docker.sock, bind-mounted ro) ────

INSERT INTO docker_host (user_id, name, docker_type, docker_daemon)
SELECT 1, 'local', 'socket', '/var/run/docker.sock'
WHERE NOT EXISTS (SELECT 1 FROM docker_host WHERE name = 'local');

-- ── HTTP monitors (public hostnames via Cloudflare → VPS → Caddy) ────────

INSERT INTO monitor (name, type, url, interval, retry_interval, maxretries, active, user_id, description)
SELECT 'http: www', 'http', 'https://www.jehpok.com', 60, 60, 0, 1, 1, 'Homer dashboard'
WHERE NOT EXISTS (SELECT 1 FROM monitor WHERE name = 'http: www');

INSERT INTO monitor (name, type, url, interval, retry_interval, maxretries, active, user_id, description)
SELECT 'http: share', 'http', 'https://share.jehpok.com', 60, 60, 0, 1, 1, 'URL shortener + file sharing'
WHERE NOT EXISTS (SELECT 1 FROM monitor WHERE name = 'http: share');

INSERT INTO monitor (name, type, url, interval, retry_interval, maxretries, active, user_id, description)
SELECT 'http: api', 'http', 'https://api.jehpok.com', 60, 60, 0, 1, 1, 'API placeholder vhost'
WHERE NOT EXISTS (SELECT 1 FROM monitor WHERE name = 'http: api');

INSERT INTO monitor (name, type, url, interval, retry_interval, maxretries, active, user_id, description)
SELECT 'http: vault', 'http', 'https://vault.jehpok.com', 60, 60, 0, 1, 1, 'Vaultwarden'
WHERE NOT EXISTS (SELECT 1 FROM monitor WHERE name = 'http: vault');

INSERT INTO monitor (name, type, url, interval, retry_interval, maxretries, active, user_id, description)
SELECT 'http: cloud', 'http', 'https://cloud.jehpok.com', 60, 60, 0, 1, 1, 'Nextcloud'
WHERE NOT EXISTS (SELECT 1 FROM monitor WHERE name = 'http: cloud');

-- http: status omitted — Kuma's own status page is the dashboard; self-check is noise.

-- ── TCP / ping monitors (tailnet-only reachability) ──────────────────────
-- NOTE: tcp: vps 443 and ping: vps removed. tcp was unreachable (kuma container
-- has no Tailscale); ping was redundant once we trust the docker socket.

-- ── Docker container monitors ───────────────────────────────────────────

INSERT INTO monitor (name, type, interval, retry_interval, maxretries, active, user_id, docker_host, docker_container, description)
SELECT 'docker: domain', 'docker', 3600, 60, 0, 1, 1, d.id, 'vhosts', 'Caddy reverse proxy'
FROM docker_host d WHERE d.name = 'local'
  AND NOT EXISTS (SELECT 1 FROM monitor WHERE name = 'docker: domain');

INSERT INTO monitor (name, type, interval, retry_interval, maxretries, active, user_id, docker_host, docker_container, description)
SELECT 'docker: cloud', 'docker', 3600, 60, 0, 1, 1, d.id, 'nextcloud', 'Nextcloud PHP-FPM'
FROM docker_host d WHERE d.name = 'local'
  AND NOT EXISTS (SELECT 1 FROM monitor WHERE name = 'docker: cloud');

INSERT INTO monitor (name, type, interval, retry_interval, maxretries, active, user_id, docker_host, docker_container, description)
SELECT 'docker: share', 'docker', 3600, 60, 0, 1, 1, d.id, 'share-flask', 'Flask shortener'
FROM docker_host d WHERE d.name = 'local'
  AND NOT EXISTS (SELECT 1 FROM monitor WHERE name = 'docker: share');

INSERT INTO monitor (name, type, interval, retry_interval, maxretries, active, user_id, docker_host, docker_container, description)
SELECT 'docker: vault', 'docker', 3600, 60, 0, 1, 1, d.id, 'vaultwarden', 'Vaultwarden'
FROM docker_host d WHERE d.name = 'local'
  AND NOT EXISTS (SELECT 1 FROM monitor WHERE name = 'docker: vault');

INSERT INTO monitor (name, type, interval, retry_interval, maxretries, active, user_id, docker_host, docker_container, description)
SELECT 'docker: homer', 'docker', 3600, 60, 0, 1, 1, d.id, 'homer', 'Homer dashboard'
FROM docker_host d WHERE d.name = 'local'
  AND NOT EXISTS (SELECT 1 FROM monitor WHERE name = 'docker: homer');

-- docker: kuma omitted — Kuma's own container; self-check is noise (the
-- dashboard is the result you care about).

-- ── Groups ──────────────────────────────────────────────────────────────

INSERT INTO "group" (name) SELECT 'Public'     WHERE NOT EXISTS (SELECT 1 FROM "group" WHERE name = 'Public');
INSERT INTO "group" (name) SELECT 'Containers' WHERE NOT EXISTS (SELECT 1 FROM "group" WHERE name = 'Containers');

INSERT INTO monitor_group (monitor_id, group_id)
SELECT m.id, g.id
FROM monitor m, "group" g
WHERE g.name = 'Public'
  AND m.name IN ('http: www','http: share','http: api','http: vault','http: cloud')
  AND NOT EXISTS (SELECT 1 FROM monitor_group mg WHERE mg.monitor_id = m.id AND mg.group_id = g.id);

INSERT INTO monitor_group (monitor_id, group_id)
SELECT m.id, g.id
FROM monitor m, "group" g
WHERE g.name = 'Containers'
  AND m.name LIKE 'docker: %'
  AND NOT EXISTS (SELECT 1 FROM monitor_group mg WHERE mg.monitor_id = m.id AND mg.group_id = g.id);
