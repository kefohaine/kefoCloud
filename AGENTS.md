# Agent operating guide

This file tells agents how to work in this repo. Read it before making changes.

## System overview

Self-hosted infrastructure on a Debian VPS. Caddy in Docker fronts four public subdomains (`www`, `app`, `api`, `cloud`) and one Tailscale-only subdomain (`vps`). Nextcloud runs in a separate container. CoreDNS serves Tailscale split-DNS. Ollama runs as a host systemd service (`/etc/systemd/system/ollama.service`, enabled, see **Safety rules** below). Full architecture, request flows, and rationale are in `README.md` — read it first.

## Safety rules

These are non-negotiable. Follow them on every task.

1. **Never delete or disable the Ollama systemd service.** The unit at `/etc/systemd/system/ollama.service` is enabled and running (`ollama serve`). Do not `systemctl stop/disable ollama`, do not remove the unit file, do not `systemctl daemon-reload` after editing it, and do not replace it with a container. If a task seems to require removing Ollama, stop and ask the user instead of proceeding. If you need to restart it after a legit config change, use `systemctl restart ollama`.
2. **Stay silent while doing tasks.** Do not narrate progress, do not print status updates, do not summarize what you just did. Run commands, edit files, and only emit text when you need a decision from the user or are reporting a blocker. Output should be minimal — the work product speaks for itself.
3. **Back up with `git push` at milestones and before critical tasks.**
   - Before any destructive or hard-to-reverse operation (deleting files, force-recreating containers, `systemctl` changes, DB/schema changes, firewall edits), first commit pending work and run `git push jehpok.com main`.
   - After reaching a meaningful milestone (a working feature, a resolved issue, a doc sync), commit and push.
   - This is in addition to the normal commit step — pushing is now **required**, not optional, at these points. If a push fails (network/auth), fix the push before proceeding with the critical task.
4. **Minimize token usage.** Be extremely efficient: short, accurate, and understanding. No filler, no preamble, no restating the question, no recaps of what you just did. Batch tool calls that can run in parallel. Read only the file regions you need. Prefer one precise edit over rewriting whole sections. Answer in as few words as the task allows without sacrificing correctness.

## Repository structure

```
services/          Docker compose files + configs (checked into git)
  domain/          Caddy (TLS termination, reverse proxy, static files)
  cloud/           Nextcloud (PHP-FPM, SQLite)
  tailnet/         CoreDNS (Tailscale split-DNS, bound to 100.81.245.77:53)
content/domain/    Static site files served by Caddy
AGENTS.md          This file
ISSUES.md          Known problems and improvements to fix
```

Host-side paths (not in git):
```
/var/www/github/jehpok.com/repo/       The cloned repo (Caddy mounts it as /srv)
/var/www/github/jehpok.com/certs/      Cloudflare Origin cert + key
/var/www/github/jehpok.com/cloud/data/ Nextcloud data dir (bind-mounted into container)
/etc/ssh/sshd_config.d/50-cloud-init.conf  SSH hardening (key-only, no root, debian only)
/etc/systemd/system/ollama.service     Ollama systemd unit (DO NOT DELETE — see Safety rules)
```

## Running services on the VPS

```bash
# All compose files use the external 'net' bridge network (except tailnet)
docker network create net  # one-time

# Start / recreate a service
docker compose -f /var/www/github/jehpok.com/repo/services/<service>/docker-compose.yml up -d --force-recreate

# Restart without recreating (after editing a mounted config)
docker compose -f /var/www/github/jehpok.com/repo/services/<service>/docker-compose.yml restart

# View logs
docker logs <container_name> --tail 50 -f

# Check status
docker ps
```

Containers: `domain` (Caddy), `cloud` (Nextcloud FPM), `tailnet` (CoreDNS). All three currently running with log rotation applied.

## Log rotation

All three services pin json-file logging in their compose files with a size cap
to prevent unbounded growth on the host:

- `domain`: `max-size: 10m`, `max-file: 3` (≈30 MB cap)
- `cloud`:  `max-size: 10m`, `max-file: 3` (≈30 MB cap)
- `tailnet`: `max-size: 5m`,  `max-file: 2` (≈10 MB cap)

Tweak these in `services/<service>/docker-compose.yml`. The defaults assume a
small-volume personal VPS; raise them if you need longer log history.

## Deployment

Deployment is manual. There is no CI/CD. Edit files on the VPS, then recreate or restart the affected service with `docker compose`.

## Git remotes

- `jehpok.com` — SSH remote (`git@github.com:friedutch/jehpok.com.git`). Use this for pushes and pulls.
- `origin` — HTTPS remote with a PAT embedded in the URL. Do not use for pushes (403). See ISSUES.md for rotating this token.

```bash
git push jehpok.com main
```

## Conventions

- **File ownership**: the repo is owned by `debian:debian` (the SSH/login user). Edit directly when signed in as `debian`; use `sudo` only if acting as another user. Do not `chown` the repo to a different user.
- Never commit secrets. `services/cloud/.env` is gitignored and holds Nextcloud admin credentials.
- Never hardcode the Tailscale IP (`100.81.245.77`) in logic — it's in the Corefile and compose ports only.
- Bind services to the narrowest interface possible. CoreDNS binds to the Tailscale IP only, not `0.0.0.0`.
- Use `expose` (not `ports`) for inter-container services. Only `domain` (80/443) and `tailnet` (53 on Tailscale IP) publish host ports.
- The `net` Docker network is `external: true`. Do not let compose files create their own private networks for inter-service communication.
- Do not add comments to code unless asked.

## Before finishing a task

1. Verify the change works: `docker compose ... up -d --force-recreate` and check `docker logs`.
2. Update `README.md` if the architecture, request flow, or service details changed.
3. Update or resolve items in `ISSUES.md` if you fixed something listed there.
4. Add new issues you discovered to `ISSUES.md`.
5. Commit with a clear message and push to `jehpok.com/main` (required at milestones and before critical tasks — see Safety rules).

## ISSUES.md workflow

`ISSUES.md` is the task tracker. When you pick up an issue:

1. Move it under a `## In progress` heading (or just start working).
2. Follow the **Fix** steps in the issue entry.
3. Verify the fix.
4. Remove the entry from `ISSUES.md` when fully resolved, or update it with notes if partially done.
5. Commit with a message referencing what was fixed.

When you discover a new problem, append it to `ISSUES.md` under the appropriate severity heading (`High` / `Medium` / `Low`) with the same format:
```
### Short title
- **File**: path/to/file
- **Problem**: what's wrong and why it matters
- **Fix**: concrete steps to resolve
```