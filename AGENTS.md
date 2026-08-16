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
5. **After completing a big sequence of tasks, update every `.md` file (`README.md`, `AGENTS.md`, `ISSUES.md`) to reflect the current system state, then commit and `git push jehpok.com main`.** This is a milestone — see rule 3.
6. **When an issue is explicitly intended by the operator or documented in `README.md` as a deliberate feature/design choice, document it in `README.md` (if not already there) instead of treating it as a bug in `ISSUES.md`.** Do not fix intended behavior; record the rationale so future agents don't "correct" it.
7. **When every task from a prompt is completed and no issues are left to currently fix, commit and `git push jehpok.com main`.** Do not wait for the operator to ask — pushing at the end of a completed prompt is mandatory.

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
/var/www/github/jehpok.com/cloud/html/    Nextcloud html root (3rdparty, core, apps, config, occ)
/var/www/github/jehpok.com/cloud/users/   Nextcloud datadirectory (user files, owncloud.db, nextcloud.log)
/etc/ssh/sshd_config.d/50-cloud-init.conf  SSH hardening (key-only, no root, debian only)
/etc/systemd/system/ollama.service     Ollama systemd unit (DO NOT DELETE — see Safety rules)
```

## Running services on the VPS

Prefer the `Makefile` recipes (canonical entrypoints) over raw `docker compose` invocations:

```bash
make up-all                          # start/recreate tailnet, domain, cloud (in that order)
make up-<service>                    # up-domain | up-cloud | up-tailnet (force-recreate)
make restart-<service>               # restart without recreating (after editing a mounted config)
make logs-<service>                  # docker logs <name> --tail 50 -f
make status                          # docker ps table
make push MSG="message"              # git add -A && commit && git push jehpok.com main
make backup                          # Nextcloud maintenance mode on → rsync data → off
make backup-secrets                  # bundle certs, SSH keys, Ollama unit, Tailscale state
make setup-host                      # copy reference configs to /etc and enable Ollama+sshd
make migrate                         # print full VPS-to-VPS migration runbook
```

Containers: `domain` (Caddy), `cloud` (Nextcloud FPM), `tailnet` (CoreDNS). The `net` bridge network is `external: true` — create once with `docker network create net` on a fresh host. Log rotation (json-file with size caps) and healthchecks are pinned in each compose file; see README for the per-service values. Deployment is manual (no CI/CD): `make restart-<service>` for a mounted config edit, `make up-<service>` when the compose file or image changed (force-recreate).

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
- A sentence ending in "?" is a question, not an order. Answer it (yes/no/how) before doing anything. Only act when the operator explicitly tells you to. If the question is ambiguous, rephrase it back and ask for confirmation.

## Before finishing a task

1. Verify the change works: `make up-<service>` (or `make restart-<service>` for a mounted config edit) and `make logs-<service>` / `make status`.
2. Update `README.md` if the architecture, request flow, or service details changed.
3. Update or resolve items in `ISSUES.md` if you fixed something listed there.
4. Add new issues you discovered to `ISSUES.md`.
5. Commit and `git push jehpok.com main` (required at milestones and before critical tasks — see Safety rules).

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