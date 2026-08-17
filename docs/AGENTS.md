# Agent operating guide

This file tells agents how to work in this repo. Read it before making changes.

## System overview

Self-hosted infrastructure on a Debian VPS. Caddy in Docker fronts four public subdomains (`www`, `app`, `api`, `cloud`) and one Tailscale-only subdomain (`vps`). Nextcloud runs in a separate container. dnsmasq runs as a host systemd service serving Tailscale split-DNS. Ollama runs as a host systemd service (`/etc/systemd/system/ollama.service`, enabled, see **Safety rules** below). Full architecture, request flows, and rationale are in `README.md` — read it first.

## Safety rules

These are non-negotiable. Follow them on every task.

1. **Never delete or disable any critical service or file.** This includes the Ollama systemd unit (`/etc/systemd/system/ollama.service`, enabled, running as `ollama serve`), the dnsmasq resolver on the host (`/etc/dnsmasq.d/10-tailnet.conf` + the systemd drop-in, bound to `100.81.245.77:53`), the Cloudflare Origin cert/key, SSH keys, Nextcloud data, and the `net` Docker network. Do not `systemctl stop/disable`, remove unit files, `daemon-reload` after editing, or replace host services with containers. If a task seems to require removing any of these, stop and ask the user. If you need to restart Ollama after a legit config change, use `systemctl restart ollama`; for dnsmasq use `make restart-dns` (or `systemctl restart dnsmasq`).
2. **Stay silent while doing tasks.** Do not narrate progress, do not print status updates, do not summarize what you just did. Run commands, edit files, and only emit text when you need a decision from the user or are reporting a blocker. Output should be minimal — the work product speaks for itself.
3. **Push at milestones, before destructive ops, and when the prompt is done.** Before any hard-to-reverse operation (deleting files, force-recreating containers, `systemctl` changes, DB/schema changes, firewall edits), first commit and `git push jehpok.com main`. After reaching a milestone (feature, resolved issue, doc sync) or completing the prompt, also commit and push. Don't wait for the operator to ask. If a push fails, fix it before proceeding. When completing a big sequence of tasks, first update every `.md` file (`README.md`, `docs/AGENTS.md`, `docs/ISSUES.md`) to reflect the current system state, then commit and push.
4. **Minimize token usage.** Be extremely efficient: short, accurate, and understanding. No filler, no preamble, no restating the question, no recaps of what you just did. Batch tool calls that can run in parallel. Read only the file regions you need. Prefer one precise edit over rewriting whole sections. Answer in as few words as the task allows without sacrificing correctness.
5. **When an issue is explicitly intended by the operator or documented in `README.md` as a deliberate feature/design choice, document it in `README.md` (if not already there) instead of treating it as a bug in `docs/ISSUES.md`.** Do not fix intended behavior; record the rationale so future agents don't "correct" it.

## Repository structure

```
services/          Docker compose files + configs (checked into git)
  domain/          Caddy (TLS termination, reverse proxy, static files)
  cloud/           Nextcloud (PHP-FPM, SQLite)
  link/            URL shortener (Flask, SQLite, admin UI at vps.jehpok.com/link)
setup/             Reference copies of host-level configs (Ollama unit, SSH hardening, dnsmasq)
content/domain/    Static site files served by Caddy
docs/AGENTS.md          This file
docs/ISSUES.md          Known problems and improvements to fix
```

Host-side paths (not in git):
```
/var/www/github/jehpok.com/repo/       The cloned repo (Caddy mounts it as /srv)
/var/www/github/jehpok.com/certs/      Cloudflare Origin cert + key
/var/www/github/jehpok.com/cloud/html/    Nextcloud html root (3rdparty, core, apps, config, occ)
/var/www/github/jehpok.com/cloud/users/   Nextcloud datadirectory (user files, owncloud.db, nextcloud.log)
/var/www/github/jehpok.com/link/db/links.db  Shortener SQLite DB (bind-mounted into the link container as /data)
/etc/ssh/sshd_config.d/50-cloud-init.conf  SSH hardening (key-only, no root, debian only)
/etc/dnsmasq.d/10-tailnet.conf         dnsmasq Tailscale split-DNS (DO NOT DELETE — see Safety rules)
/etc/systemd/system/dnsmasq.service.d/override.conf  systemd drop-in (Restart=always, After=tailscaled)
/etc/systemd/system/ollama.service     Ollama systemd unit (DO NOT DELETE — see Safety rules)
```

## Running services on the VPS

Prefer the `Makefile` recipes (canonical entrypoints) over raw `docker compose`. The full recipe list with comments lives in `README.md` under "CMD Sheet"; the Makefile is the source of truth. The `net` bridge network is `external: true` — create once with `docker network create net` on a fresh host. Deployment is manual (no CI/CD): `make restart-<service>` for a mounted config edit, `make up-<service>` when the compose file or image changed (force-recreate).

## Service details

Per-service facts needed to edit safely. The compose files, Caddyfile, and `setup/dnsmasq/` configs are the source of truth; this is a quick reference. Architecture and rationale are in `README.md`.

### domain (Caddy 2) — `services/domain/`

- Image `caddy:2.11.4`, container `domain`. Publishes 80 (→ 308 redirect to HTTPS) and 443.
- TLS: Cloudflare Origin cert from `/certs/cert.pem` + `/certs/key.pem` (read-only bind mount of `/var/www/github/jehpok.com/certs/`).
- `admin off` globally — no runtime reconfiguration from the `net` bridge.
- Repo mounted read-only at `/srv`; static files served from `/srv/content/domain/{www,app,vps}`. Nextcloud html root mounted read-only at `/nextcloud` for static fallback.
- Vhosts: `www`/`app`/`vps` → static fileserver; `api` → responds `ok` (no backend, reserved); `cloud` → `php_fastcgi cloud:9000` (dial 10s, read/write 300s, aligned to PHP-FPM's 200s terminate timeout), blocks internal paths (`/data/*`, `/config/*`, `/lib/*`, `/3rdparty/*`, `/templates/*`, `/occ`, `/console.php`, `/db/*`, `/updater/*`), redirects carddav/caldav to `/remote.php/dav`, 10G body max, zstd/gzip. The `vps` vhost enforces Tailscale-only at the edge: a `@not_tailnet` matcher (`not remote_ip 100.64.0.0/10`) returns 403 for any non-tailnet source IP, on top of the DNS split.
- Security headers (HSTS, X-Content-Type-Options, X-Frame-Options, Referrer-Policy) on all vhosts.
- Edit the Caddyfile then `make restart-domain` (mounted, no recreate); `make up-domain` only if the compose file or image changed.

### dnsmasq (host systemd) — `setup/dnsmasq/`

- Runs on the host, not Docker. Config at `/etc/dnsmasq.d/10-tailnet.conf`; systemd drop-in at `/etc/systemd/system/dnsmasq.service.d/override.conf` (`After=tailscaled.service`, `Restart=always`, `RestartSec=3`).
- Binds `100.81.245.77:53` (tcp+udp) — the Tailscale IP only, not `0.0.0.0` (not an open resolver).
- `address=/vps.jehpok.com/100.81.245.77` overrides the one Tailscale-only hostname; everything else falls through to upstream forwarders `1.1.1.1 1.0.0.1 9.9.9.9` (`strict-order` → sequential). `no-resolv` prevents reading `/etc/resolv.conf`.
- Edit `setup/dnsmasq/10-tailnet.conf`, copy to `/etc/dnsmasq.d/10-tailnet.conf`, then `make restart-dns`. Logs via `journalctl -u dnsmasq` or `make logs-dns`.
- **Protected by Safety rule 1 — never delete or disable.** If a task seems to require removing it, stop and ask.

### cloud (Nextcloud) — `services/cloud/`

- Image `nextcloud:34.0.2-fpm` (PHP-FPM, not Apache), container `cloud`. SQLite (no `MYSQL_*`/`POSTGRES_*` vars) → `cloud/users/owncloud.db`.
- No published ports — `expose: 9000` on `net` only; Caddy is the sole entry point.
- Two host bind mounts, both owned by uid 33 (`www-data`) before first start:
  - `/var/www/github/jehpok.com/cloud/html` → `/var/www/html` (install: 3rdparty, core, apps, config, occ).
  - `/var/www/github/jehpok.com/cloud/users` → `/data` (datadirectory, set to `/data` in `config.php`; must contain a `.ncdata` marker or Nextcloud won't start). Mounted at a standalone path, **not** inside `/var/www/html`, to avoid a nested bind mount — the Nextcloud image declares `VOLUME ["/var/www/html"]` which makes nested mounts silently detach after long uptimes.
- Admin creds from `services/cloud/.env` (gitignored): `NEXTCLOUD_ADMIN_USER`, `NEXTCLOUD_ADMIN_PASSWORD`. Never hardcode.
- Env: `NEXTCLOUD_TRUSTED_DOMAINS=cloud.jehpok.com`, `NEXTCLOUD_OVERWRITEPROTOCOL=https`, `TRUSTED_PROXIES=172.22.0.0/16` (the `net` subnet), `OVERWRITECLIURL=https://cloud.jehpok.com`.
- PHP-FPM pool in `php-fpm.d/zz-custom.conf`: `ondemand`, `max_children=8`, `process_idle_timeout=10s`, `request_terminate_timeout=200s`.
- After editing the compose file or pulling a new image: `make up-cloud` (force-recreate). Nextcloud runs its own DB migrations on first request after an upgrade — no manual migration step.

### link (URL shortener) — `services/link/`

- Image `jehpok/link:1` (built locally from `Dockerfile`, `python:3.12-slim` + Flask 3.0.3), container `link`. No published ports — `expose: 5000` on `net` only; Caddy is the sole entry point.
- SQLite DB at `/var/www/github/jehpok.com/link/db/links.db`, bind-mounted into the container as `/data`. Table `links(slug TEXT PK, target TEXT, created_at INTEGER, hits INTEGER)`. Back up with `make backup-link`.
- Two Caddy vhosts route to it: `link.jehpok.com` (public — only slug routes `GET /<slug>` and `/` are proxied; `/link`, `/api/*`, `/healthz` return 404 via the `@admin` matcher; unknown slugs get `200 ok` via `handle_response` on upstream 404) and `vps.jehpok.com/link*` (Tailscale-only admin UI). Admin has no app-level auth — access is gated by `vps.jehpok.com` being unresolvable off tailnet plus the `@not_tailnet` source-IP check, same model as the rest of that vhost. If you ever want app-level auth, add Caddy `basic_auth` on the `/link*` matcher.
- `app.py` is a single Flask file: `GET /` returns `ok`, `GET /<slug>` redirects, `GET /link` renders admin, `POST /link` creates (auto-generates a 4-char slug if blank), `POST /link/<slug>` with `_method=DELETE` deletes, `GET /api/links` returns JSON, `GET /healthz` for the healthcheck. The source lives in `content/link/` (mounted read-only at `/app/src`) so edits take effect with `make restart-link` — no image rebuild needed. The image only holds the Python runtime + Flask.
- `up-all` runs `up-link` before `up-domain` so Caddy can resolve `link` on start.

### Ollama (host systemd) — `setup/ollama/`

- Runs on the host, not Docker. Unit at `/etc/systemd/system/ollama.service`: `enabled`, `Restart=always`, user `ollama`, listens `:11434`, models at `/home/ollama/.ollama/models`.
- Manage with `systemctl {start,stop,restart} ollama`; logs via `journalctl -u ollama`.
- **Protected by Safety rule 1 — never delete or disable.** If a task seems to require removing it, stop and ask. A legit config change uses `systemctl restart ollama`.

### Log rotation and healthchecks

All three compose files pin `json-file` with size caps: `domain` 10m×3, `cloud` 10m×3, `link` 5m×2. Healthchecks: `domain` `caddy version` /30s, `cloud` `php -r phpversion()` /30s, `link` fetches `/healthz` /30s. dnsmasq logs to journald (no log cap beyond the default `journalctl` rotation). Adjust under each service's `logging:` / `healthcheck:` block, or the systemd unit drop-in for dnsmasq.

## Git remotes

- `jehpok.com` — SSH remote (`git@github.com:friedutch/jehpok.com.git`). The only remote; use for pushes and pulls.

```bash
git push jehpok.com main
```

## Conventions

- **File ownership**: the repo is owned by `debian:debian` (the SSH/login user). Edit directly when signed in as `debian`; use `sudo` only if acting as another user. Do not `chown` the repo to a different user.
- Never commit secrets. `services/cloud/.env` is gitignored and holds Nextcloud admin credentials.
- Never hardcode the Tailscale IP (`100.81.245.77`) in logic — it's in `setup/dnsmasq/10-tailnet.conf` only.
- Bind services to the narrowest interface possible. dnsmasq binds to the Tailscale IP only, not `0.0.0.0`.
- Use `expose` (not `ports`) for inter-container services. Only `domain` (80/443) publishes host ports; dnsmasq is on the host, not Docker.
- The `net` Docker network is `external: true`. Do not let compose files create their own private networks for inter-service communication.
- **Container app sources live under `content/<container>/`**, not `services/<container>/`. `services/` holds only Dockerfile + compose + service-level configs; `content/` holds the code/static files the container runs or serves. Mount `content/<container>/` read-only into the container so edits take effect with `make restart-<container>` and the image only carries the runtime. Static-site vhosts (`www`/`app`/`vps`) follow the same pattern under `content/domain/`.
- Do not add comments to code unless asked.
- A sentence ending in "?" is a question, not an order. Answer it (yes/no/how) before doing anything. Only act when the operator explicitly tells you to. If the question is ambiguous, rephrase it back and ask for confirmation.
- Do not paste entire file contents (Caddyfile, dnsmasq config, compose files, Makefile) into `README.md` or other docs. Describe what they do in prose; the files are the source of truth. Command snippets (`make ...`, shell one-liners) are fine.

## `.md` writing rules

Follow these on every edit to any `.md` file in this repo.

1. **No duplicated content across files.** State each fact once, in the most appropriate file:
   - `README.md` — system architecture, rationale, request flows, operational gotchas, setup/migration runbooks. The "what and why".
   - `docs/AGENTS.md` — how to work in the repo: commands, conventions, safety rules, task workflow. The "how to act".
   - `docs/ISSUES.md` — only open problems and improvements, plus a Resolved section for history. Nothing else.
2. **No pasting repo file contents.** Don't copy Caddyfile/dnsmasq config/compose/Makefile blocks into docs. Describe in prose; link to the file path. Command snippets (`make ...`, shell one-liners) are fine.
3. **No duplicated prose within a file.** If a paragraph repeats what another section already said, delete one.
4. **Prose over code blocks.** Use a code block only for commands the reader will run, or a structure that genuinely needs monospace (the architecture diagram, the directory tree). Everything else is prose.
5. **One source of truth.** If a detail appears in two files, pick one and delete the other. Prefer the executable source (compose file, Makefile) as truth; docs summarize it.
6. **No runtime snapshots.** Don't write "all three currently running" or "healthy" — it drifts the moment a container stops. Describe the steady-state config, not the current transient state.
7. **Keep it short.** Every line should answer "would an agent miss this without help?" If not, cut it. No filler, no restating the obvious, no generic advice.
8. **Verify before writing.** Don't describe a path, port, or behavior you haven't checked in the actual file. Stale docs are worse than missing docs.
9. **Preserve verified useful guidance.** When editing an existing `.md`, keep what's accurate and high-signal; only delete fluff, duplicates, or stale claims. Don't rewrite blindly.
10. **Categorize `Solved` history by month.** In `docs/ISSUES.md`, group resolved items under `### Mon YYYY — short label` headings (e.g. `### Jul 2026 — early system build`). Add a new heading only when the month changes — never create a second heading for the same month; append to the existing one. **One line per resolved issue, aggressively short** — format: `- **Short title** — one-sentence summary.` Aim for ~80 chars after the dash; match the brevity of entries like `**SSH hardened** — password auth + root login disabled, \`AllowUsers debian\`.` or `**CoreDNS → dnsmasq** — container removed; host dnsmasq on \`100.81.245.77:53\`.` Never multi-line entries, sub-bullets, or paragraphs. The full root-cause / symptom / fix narrative belongs in an open issue entry while it's being worked; once resolved, collapse it to one short line.

## Before finishing a task

1. Verify the change works: `make up-<service>` (or `make restart-<service>` for a mounted config edit) and `make logs-<service>` / `make status`.
2. Update `README.md` if the architecture, request flow, or service details changed.
3. Update or resolve items in `docs/ISSUES.md` if you fixed something listed there.
4. Add new issues you discovered to `docs/ISSUES.md`.
5. Commit and `git push jehpok.com main` (required at milestones and before critical tasks — see Safety rules).

## docs/ISSUES.md workflow

`docs/ISSUES.md` is the task tracker. When you pick up an issue:

1. Move it under a `## In progress` heading (or just start working).
2. Follow the **Fix** steps in the issue entry.
3. Verify the fix.
4. Remove the entry from `docs/ISSUES.md` when fully resolved, or update it with notes if partially done.
5. Commit with a message referencing what was fixed.

When you discover a new problem, append it to `docs/ISSUES.md` under the appropriate severity heading (`High` / `Medium` / `Low`) with the same format:
```
### Short title
- **File**: path/to/file
- **Problem**: what's wrong and why it matters
- **Fix**: concrete steps to resolve
```