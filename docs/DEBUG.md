# Deep scan & debugging runbook

How to run an occasional deep scan or triage an incident on this system. **The rules live in `docs/AGENTS.md`; the project facts (paths, recipes, hostnames, limits) live in `docs/GUIDE.md`** — this file is the procedure that uses them. Read-only until a finding is confirmed.

## Operating discipline
- **Read-only first.** Inspect before changing; understand dependencies before touching a service.
- **One logical change at a time.** Baseline → hypothesis → smallest change → retest. Never stack unrelated changes.
- **Validate before applying, verify after.** Syntax-check (`caddy validate`, `docker compose -f <file> config -q`, `bash -n <script>`) *and* prove the outcome with a probe.
- **Rollback first.** Every risky change ships with a one-line revert recipe in the commit message (AGENTS safety rule 10).
- If a change makes things worse: stop, restore the last known-good state, verify, report — never compound it.
- No fabrication: never report a result you did not actually observe; say so when a test could not run.

## 1. Layer ladder (resolve in order, stop at the first failure)
1. **DNS** — `dig +short <host>`; tailnet name not resolving → `make systemd-restart-dnsmasq`.
2. **TCP** — `curl -sS -o /dev/null -w '%{http_code}\n' --connect-timeout 5 https://<host>/`.
3. **TLS** — issuer/dates on a fresh handshake *from the host* (`openssl s_client … -servername <host>`), not through Cloudflare.
4. **Edge / proxy** — `make dok-logs-fxmq.net`; config valid (`docker exec fxmq.net caddy validate …`); `make smoke`.
5. **Upstream / app** — `docker ps` health, `docker logs --since 10m <ctn>`, `journalctl -u <unit>`.
6. **Access control** — the code tells the layer: 403 = matcher/ACL, 401 = auth, 404 = route, 502 = upstream down.

## 2. Standard scan (read-only)
```
make status                   # AIO dashboard: perf, modules, git, units, docker, tmux, backups, mail, tailnet
make smoke                    # every vhost must serve its real app; module-aware (installed-modules.conf — absent modules' failed sections don't fail the run)
docker ps --format '{{.Names}}	{{.Status}}'
ss -tlnp                      # listeners — compare with GUIDE "Domains and access model"
sudo ufw status verbose
findmnt -R /var/www/custom/projects/homelab   # mounts, incl. the NFS datadirectory
free -m; df -h /              # memory / disk headroom
sudo journalctl -p err --since "-3 days" | tail -30
```

## 3. Repo-consistency probes (does the running system match the repo?)
```
git status
make nc-check                                     # Nextcloud setup checks
bash scripts/optimize.sh --verify                  # host tuning converged
bash scripts/storage.sh                            # NFS datadirectory re-check (prompts)
bash scripts/gh-web-health.sh                      # after any history rewrite
```

## 4. Prove the outcome, not the config
Decide what "healthy" means *before* changing anything, then demonstrate it. Examples: a vhost is healthy when `make smoke` passes; Nextcloud is healthy when `occ status` reports installed + no maintenance and a file write round-trips; the NFS datadirectory is healthy when `findmnt` shows the mount and a real file reads at expected speed.

## 5. Where the answers already are
- Symptom → cause map: `docs/GUIDE.md` "Operational gotchas" (e.g. NFS client-helper failure, the `respond "ok"` edge stub, force-recreate name collisions).
- Open problems and their status: `docs/ISSUES.md`.
- Migration/rebuild path: `docs/MIGRATE.md`.

## 6. Report template
What changed · what was tested · did the tests pass · remaining issues · security/operational notes. Cite the probe output, not an assumption.
