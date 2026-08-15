# Agent operating guide

This file tells agents how to work in this repo. Read it before making changes.

## System overview

Self-hosted infrastructure on a Debian VPS. Caddy in Docker fronts four public subdomains (`www`, `app`, `api`, `cloud`) and one Tailscale-only subdomain (`vps`). Nextcloud runs in a separate container. CoreDNS serves Tailscale split-DNS. Full architecture, request flows, and rationale are in `README.md` — read it first.

## Repository structure

```
services/          Docker compose files + configs (checked into git)
  domain/          Caddy (TLS termination, reverse proxy, static files)
  cloud/           Nextcloud (PHP-FPM, SQLite)
  tailnet/         CoreDNS (Tailscale split-DNS, bound to 100.81.245.77:53)
content/domain/    Static site files served by Caddy
.github/workflows/ CI/CD (self-hosted runner on the VPS)
AGENTS.md          This file
ISSUES.md          Known problems and improvements to fix
```

Host-side paths (not in git):
```
/var/www/github/jehpok.com/repo/       The cloned repo (Caddy mounts it as /srv)
/var/www/github/jehpok.com/certs/      Cloudflare Origin cert + key
/var/www/github/jehpok.com/cloud/data/ Nextcloud data dir (bind-mounted into container)
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

Containers: `domain` (Caddy), `cloud` (Nextcloud FPM), `tailnet` (CoreDNS).

## Deployment

Pushes to `main` trigger `.github/workflows/deploy.yml` on a self-hosted GitHub Actions runner on the VPS. The workflow uses path-filtered jobs: only the service(s) whose files changed get redeployed.

- `services/domain/**` or `.github/**` changed → redeploy `domain`
- `services/tailnet/**` changed → redeploy `tailnet`
- `services/cloud/**` changed → redeploy `cloud`

The runner pulls the latest `main` before each deploy. Do not push broken configs to `main` — they go live immediately.

## Git remotes

- `jehpok.com` — SSH remote (`git@github.com:friedutch/jehpok.com.git`). **Use this one for pushes.**
- `origin` — HTTPS remote with a PAT embedded in the URL. Do not use for pushes (403). See ISSUES.md for rotating this token.

```bash
git push jehpok.com main
```

## Conventions

- **File ownership**: the repo is owned by `runner:runner` (the GitHub Actions runner user). If you edit as a different user, use `sudo` to write — do NOT `chown` the repo to your user, or the runner will lose access and CI breaks.
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
5. Commit with a clear message and push to `jehpok.com/main`.

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