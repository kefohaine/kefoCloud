-- First-time Kuma monitor seed. Idempotent — safe to re-run.
-- Apply with:
--   docker exec -i uptimekuma sqlite3 /app/data/kuma.db < services/uptimekuma/seed-monitors.sql
--
-- Adjust user_id (1) if your admin is not id=1
-- (check: docker exec uptimekuma sqlite3 /app/data/kuma.db "SELECT id,username FROM user;").
--
-- Schema differences vs older Kuma: docker_host has user_id/docker_type/docker_daemon
-- (no endpoint/type), group has no user_id. If your schema differs, edit the columns.

-- ── Docker host (kuma talks to /var/run/docker.sock, bind-mounted ro) ────

INSERT INTO docker_host (user_id, name, docker_type, docker_daemon)
SELECT 1, 'local', 'socket', '/var/run/docker.sock'
WHERE NOT EXISTS (SELECT 1 FROM docker_host WHERE name = 'local');

-- ── HTTP monitors (public hostnames via Cloudflare → VPS → Caddy) ────────
-- NOTE: no monitor uses https://mail.fxmq.net — docker's embedded DNS resolves
-- that name to the mailserver container (hostname: mail.fxmq.net → 172.22.0.9),
-- which has no :443 (Caddy owns HTTPS on the host). Monitor roundcube on the
-- bridge instead.

INSERT INTO monitor (name, type, url, interval, retry_interval, maxretries, active, user_id, description)
SELECT 'http: vault', 'http', 'https://vault.fxmq.net', 60, 60, 0, 1, 1, 'Vaultwarden'
WHERE NOT EXISTS (SELECT 1 FROM monitor WHERE name = 'http: vault');

INSERT INTO monitor (name, type, url, interval, retry_interval, maxretries, active, user_id, description)
SELECT 'http: mail', 'http', 'http://172.22.0.10:80/', 60, 60, 0, 1, 1, 'Roundcube webmail (bridge)'
WHERE NOT EXISTS (SELECT 1 FROM monitor WHERE name = 'http: mail');

INSERT INTO monitor (name, type, url, interval, retry_interval, maxretries, active, user_id, description)
SELECT 'http: cloud', 'http', 'https://cloud.fxmq.net', 60, 60, 0, 1, 1, 'Nextcloud'
WHERE NOT EXISTS (SELECT 1 FROM monitor WHERE name = 'http: cloud');

-- http: status omitted — Kuma's own status page is the dashboard; self-check is noise.

-- ── TCP / ping monitors (tailnet-only reachability) ──────────────────────
-- NOTE: tcp: vps 443 and ping: vps removed. tcp was unreachable (kuma container
-- has no Tailscale); ping was redundant once we trust the docker socket.

-- ── Docker container monitors ───────────────────────────────────────────

INSERT INTO monitor (name, type, interval, retry_interval, maxretries, active, user_id, docker_host, docker_container, description)
SELECT 'docker: fxmq.net', 'docker', 3600, 60, 0, 1, 1, d.id, 'fxmq.net', 'Caddy reverse proxy'
FROM docker_host d WHERE d.name = 'local'
  AND NOT EXISTS (SELECT 1 FROM monitor WHERE name = 'docker: fxmq.net');

INSERT INTO monitor (name, type, interval, retry_interval, maxretries, active, user_id, docker_host, docker_container, description)
SELECT 'docker: nextcloud', 'docker', 3600, 60, 0, 1, 1, d.id, 'nextcloud', 'Nextcloud PHP-FPM'
FROM docker_host d WHERE d.name = 'local'
  AND NOT EXISTS (SELECT 1 FROM monitor WHERE name = 'docker: nextcloud');

INSERT INTO monitor (name, type, interval, retry_interval, maxretries, active, user_id, docker_host, docker_container, description)
SELECT 'docker: vaultwarden', 'docker', 3600, 60, 0, 1, 1, d.id, 'vaultwarden', 'Vaultwarden'
FROM docker_host d WHERE d.name = 'local'
  AND NOT EXISTS (SELECT 1 FROM monitor WHERE name = 'docker: vaultwarden');

INSERT INTO monitor (name, type, interval, retry_interval, maxretries, active, user_id, docker_host, docker_container, description)
SELECT 'docker: mailserver', 'docker', 3600, 60, 0, 1, 1, d.id, 'mailserver', 'Docker Mailserver'
FROM docker_host d WHERE d.name = 'local'
  AND NOT EXISTS (SELECT 1 FROM monitor WHERE name = 'docker: mailserver');

INSERT INTO monitor (name, type, interval, retry_interval, maxretries, active, user_id, docker_host, docker_container, description)
SELECT 'docker: roundcube', 'docker', 3600, 60, 0, 1, 1, d.id, 'roundcube', 'Roundcube webmail'
FROM docker_host d WHERE d.name = 'local'
  AND NOT EXISTS (SELECT 1 FROM monitor WHERE name = 'docker: roundcube');

-- docker: kuma omitted — Kuma's own container; self-check is noise (the
-- dashboard is the result you care about).

-- ── Groups ──────────────────────────────────────────────────────────────

INSERT INTO "group" (name) SELECT 'Public'     WHERE NOT EXISTS (SELECT 1 FROM "group" WHERE name = 'Public');
INSERT INTO "group" (name) SELECT 'Containers' WHERE NOT EXISTS (SELECT 1 FROM "group" WHERE name = 'Containers');

INSERT INTO monitor_group (monitor_id, group_id)
SELECT m.id, g.id
FROM monitor m, "group" g
WHERE g.name = 'Public'
  AND NOT EXISTS (SELECT 1 FROM monitor_group mg WHERE mg.monitor_id = m.id AND mg.group_id = g.id);

INSERT INTO monitor_group (monitor_id, group_id)
SELECT m.id, g.id
FROM monitor m, "group" g
WHERE g.name = 'Containers'
  AND m.name LIKE 'docker: %'
  AND NOT EXISTS (SELECT 1 FROM monitor_group mg WHERE mg.monitor_id = m.id AND mg.group_id = g.id);
