# Manual

How to install, operate, back up, upgrade, migrate and fix this machine — and why it
is built the way it is. This is the project's single document: the system's parts and
traffic paths, its values and rendering, every procedure, the service reference, the
diagnostic runbook and the accumulated operational gotchas. For a one-screen pitch see
the repository front page; open problems live in the repository's Issues tab.

## What this machine is

A single Debian machine serving the apps declared in `config/modules.conf`, each as one
Docker Compose unit under `modules/`, behind one Caddy edge. This part describes the
system — its parts, its traffic paths and why each choice was made.

Each app is a module: `chat` (ESS CE — Synapse + Element + Matrix Authentication Service, with the Element Admin panel built in), `ocis` (ownCloud Infinite
Scale), `kopia` (Kopia backups), `vault` (Vaultwarden), `mail` (Mailu + Roundcube),
`monitor` (Uptime Kuma), `home` (Homarr), `blog` (WriteFreely) and `photos` (Immich). `config/modules.conf`
is the one place a module is declared: it maps the module name to its directory, its
host label and its container list, and every tool (`make fetch`, `make smoke`, the
installer, the `dok-*` recipes) derives its roster from it.

Beside the containers run host services: `ttyd` (web terminal on a single `tmux` session), `dnsmasq` (tailnet DNS), `fail2ban`, `sshd` (key-only, tailnet only), `ufw`, `cron`, and the Goose agent (`goose.service`). `kefo-stack.service` brings the deployed compose units back on boot.

**Module state is runtime, never documentation.** A module that is off has no container, no data and no route — its vhost answers 502 if one is deployed. That is *not* "tailnet-only": see "Module state vs route exposure".

### Request flow

```
                   ┌─────────────────────────────────────────────┐
    Public DNS ──► │            Cloudflare (proxy)               │
                   │     cloud / kuma / www / home / blog        │
                   └──────────────┬──────────────────────────────┘
                                  │ HTTPS (LE cert via DNS-01)
                                  ▼
                           ┌──────────────┐
                           │    Caddy     │  port 80 → 308 redirect
                           │  ($DOMAIN)   │  port 443 (per-vhost LE)
                           └──────┬───────┘  custom image + caddy-dns/cloudflare
                ┌─────────────────┼─────────────────┐
                ▼                 ▼                 ▼
           reverse_proxy    reverse_proxy      reverse_proxy
           oCIS (cloud)     uptime-kuma        Synapse (matrix)
           (172.22.0.27:9200) (172.22.0.6:3001) (172.22.0.28:8008)
           (also: Element 172.22.0.29:80 for chat.$DOMAIN,
            roundcube 172.22.0.10:80 for mail.$DOMAIN; the mail platform
            Postfix/Dovecot at 172.22.0.9 owns ports 25/465/587/993)

    ttyd.$DOMAIN is tailnet-only (not in public DNS) — "/" IS the host shell:
    the single `main` tmux session, no second credential (Tailscale membership
    only); anything off the tailnet gets 403 first. vault.$DOMAIN,
    admin.matrix.$DOMAIN and admin.mail.$DOMAIN are tailnet-only the same way.

                     ┌─────────────────────────────────────────────┐
                     │ Tailscale split DNS forwards $DOMAIN        │
                     │ queries to this machine's resolver          │
                     └──────────────┬──────────────────────────────┘
                                    │ UDP/TCP <tailnet IP>:53
                                    ▼
                             ┌──────────────┐
                             │   dnsmasq    │  host systemd service
                             │  (host)      │  (not a container)
                             └──────────────┘
```

### Access model

| Hostname | Module | Cloudflare | Reachable by | Serves |
|---|---|---|---|---|
| `cloud.` | `ocis` | proxied | anyone | oCIS |
| `chat.` | `chat` | proxied | anyone | Element web client |
| `matrix.` | `chat` | DNS-only | anyone | Synapse homeserver (client-server + federation API) + `/.well-known/matrix/*` |
| `auth.matrix.` | `chat` | DNS-only | anyone | Matrix Authentication Service (login, OAuth2, admin API) |
| `admin.matrix.` | `chat` | not in public DNS | tailnet only | Element Admin panel |
| `call.matrix.` | `chat` | DNS-only | anyone | Element Call app (the widget Element embeds) |
| `livekit.matrix.` | `chat` | DNS-only | anyone | LiveKit SFU signalling; media is UDP 7882 / TCP 7881 |
| `livekit-jwt.matrix.` | `chat` | DNS-only | anyone | SFU token service (Matrix OpenID → LiveKit token) |
| `vault.` | `vault` | not in public DNS | tailnet only | Vaultwarden |
| `kuma.` | `monitor` | proxied | anyone | Uptime Kuma |
| `www.` | — | proxied | anyone | instance pages in `$DATA_DIR/pages/www` (`/welcome`, …), `/download` drop folder |
| `home.` | `home` | proxied | anyone | Homarr |
| `blog.` | `blog` | proxied | anyone | WriteFreely |
| `photos.` | `photos` | DNS-only | anyone | Immich |
| `mail.` | `mail` | DNS-only | anyone | Roundcube webmail + the SMTP/IMAP name (MX/SPF point here) |
| `admin.mail.` | `mail` | not in public DNS | tailnet only | Mailu admin (`/admin`) |
| `ttyd.` | — (host unit) | not in public DNS | tailnet only | the host shell at `/` |

grey-cloud at Cloudflare, and a tailnet hostname never enters public DNS — `dnsmasq`
answers it for tailnet clients and Caddy's `@not_tailnet` matcher 403s every other
source, so a forged Host header against the public IP gets nothing.

#### Module state vs route exposure

| Axis | Values | Truth |
|---|---|---|
| module state | `installed` / `not installed` | `enabled_modules` in `wizard.state` |
| route exposure | `public` / `tailnet-only` | the vhost; `exposure()` in `scripts/lib/modules.sh` classifies |

An uninstalled module has no route at all — `kuma.` answering 502 means the monitor is not installed, never that it is tailnet-only. Tailnet-only describes a route that exists and is reachable only from the tailnet. `make fetch` prints `modules 8 / 9 enabled` — the count is the textual tell, so a turned-off module is never read as "tailnet-only" — and `make fetch-more` prints a `routes` row that classifies each deployed vhost.

### Design rationale

**ESS CE: Synapse + Matrix Authentication Service + Element, with PostgreSQL.** Element is a static browser app on `chat.$DOMAIN`; Synapse serves the client-server and federation API on `matrix.$DOMAIN`, and that name is the homeserver a client is given (it IS the identity domain — no delegation needed for itself). Matrix Authentication Service owns every credential, password and token on `auth.matrix.$DOMAIN`, and Synapse validates against it; each side has its own PostgreSQL. The Element Admin panel on `admin.matrix.$DOMAIN` (tailnet-only) drives both admin APIs. Every container carries `mem_limit`/`memswap_limit` ceilings (not allocations — idle stays low) so a runaway process cannot reach the host.

**Kopia, not tarballs.** One backup client snapshots every module's data dir plus the rendered config into a repository on an off-box disk, reached over SFTP across the tailnet — no host-side tarball script drifting from the module layout, and no backup server: no UI, no API, no listener to defend. The repository is not on this host; `$DATA_DIR/kopia` holds only the client config, the repository password and the SFTP key, and the sources are mounted read-only into the container. If the disk is asleep or unmounted the snapshot fails loudly (`systemctl --failed`), it never silently skips.

**Admin doors off public DNS.** `ttyd.` is reachable only from the operator's devices, so public DNS would hand every bot a port that isn't public. Tailscale split-DNS means the name resolves the moment a device joins, with a normal LE cert by DNS-01 (same fallback issuer chain as every vhost: Buypass, then ZeroSSL) — trusted by browsers, no port forward, no firewall hole. The machine also advertises exit-node routes; IPv4/IPv6 forwarding is in `config/sysctl/99-kefo.conf`.

**Mail: Mailu.** Postfix + Dovecot in active release with DKIM/DMARC/Rspamd/fail2ban built in, plus the official Roundcube image — the lightest trusted option (Mailcow costs roughly 6–8 GB RAM).

**dnsmasq on the host, bound to the Tailscale IP.** One small file answers the tailnet names and forwards everything else. On the host it survives `docker stop`, image pulls and `systemctl restart docker` — the failures a container restart policy cannot cover — with `Restart=always` as the only supervisor. It binds port 53 to the Tailscale IP only, never `0.0.0.0`, so the machine is not an open resolver. The split-DNS route only reaches this host if the host's own `/etc/resolv.conf` asks Tailscale (tracked copy applied by `make install-resolv`); otherwise every public name resolves while the tailnet names answer NXDOMAIN on the machine that serves them.

**One `net` bridge.** Inter-container DNS needs a user-defined bridge; Docker's embedded resolver answers container names, so no service registry is needed. One shared `172.22.0.0/16` network (`external: true`) is reused by every compose file so the pinned bridge IPs attach cleanly.


### Repository layout

```
Makefile      the command surface (recipes call scripts/ or one command)
modules/      one dir per app: docker-compose.yml (+ Dockerfiles, caddy/vhosts/*.caddy)
config/       catalogue (modules.conf, instance.defaults) + tracked host configs
scripts/      install/ (wizard + uninstall), ops/, stack/, render/, modules/,
              lib/, hooks/, info/
recipes/      Goose agent tasks (read-only inspection + reports)
data/         instance state, written at install time — never committed
```

`config/` holds catalogues and reference copies of host-level configs (systemd units, SSH hardening, dnsmasq, ttyd, docker daemon, sysctl, logrotate, tmux); `make render` renders them with instance values and `make install-config` pushes them live. Web pages are not in the repo — they are instance data under `$DATA_DIR/pages/`.

## Instance values, tokens and rendering

Deployable files carry `{{TOKENS}}`; the values live in `data/instance.conf`; `make
render` writes `data/rendered/` and every script reads values through
`scripts/lib/instance.sh`. This repo is a **skeleton**: the real values exist only on a
live host, and no instance value is ever committed. That is what makes a fresh clone
installable anywhere, and a rename a value change instead of a refactor.

### How a value reaches a file

Three mechanisms, one table:

| Kind of file | Mechanism | Where the value comes from |
|---|---|---|
| Templates: `config/**`, `modules/caddy/**` | `{{TOKEN}}` + `scripts/render/render.sh` | `data/instance.conf` |
| Compose files (`modules/*/docker-compose*.yml`) | `${VAR}` (docker compose substitution) | the instance block `make render` writes into `modules/*/.env` |
| Scripts (`scripts/**`) | plain shell variables, never tokens | `scripts/lib/instance.sh`, sourced from `data/instance.conf` |
| Filenames | domain-free by construction (`vhosts/cloud.caddy`, `kefo-stack.service`, `config/logrotate/instance`) | — |

Docs use plain variables (`$DOMAIN`, `$DATA_DIR`, …), never tokens. `recipes/**` carry
`{{TOKEN}}` only in their `contact:` metadata, which nothing renders — a recipe is read
by the agent, not substituted.

### The tokens

| Token | Meaning |
|---|---|
| `{{DOMAIN}}` | public domain: every vhost, cert and mail address |
| `{{HOSTNAME}}` | machine name and tailnet node name |
| `{{OPERATOR}}` | the single login user on the box |
| `{{GITHUB_USER}}` | GitHub account that owns the repos |
| `{{REPO_NAME}}` | repository name |
| `{{REPO_DIR}}` | absolute path of the checkout |
| `{{DATA_DIR}}` | all untracked instance state (`$REPO_DIR/data`) |
| `{{LOG_DIR}}` | every log the project writes |
| `{{SERVER_IP}}` | the host's public IPv4 (DNS + mail PTR checks) |
| `{{EMAIL}}` | operator contact address |
| `{{TIMEZONE}}` | IANA zone for containers and cron |

`config/instance.defaults` (tracked) is the documentation for that list — it is
never installed; it is what a new operator reads to know what to provide. To
see every token with its current live value:

```
scripts/render/render.sh --tokens
```

### The one file with real values

`data/instance.conf` (untracked, mode 0600) is the only place an instance value
lives. The installer writes it from what it prompts and detects
(the domain is prompted, `{{GITHUB_USER}}` is read from the checkout's `origin`
remote, paths come from its own location); it is plain `KEY=VALUE` and safe to
edit by hand (`make render` afterwards).

### Rendering

```
make render          # rebuild data/rendered/ + refresh the .env instance blocks
```

`make render` produces:

- `data/rendered/caddy/` — the Caddyfile and `vhosts/*.caddy`. **The edge
  container mounts this directory, never the tracked one**; pointing it at the
  tracked tree starts Caddy on a literal `www.{{DOMAIN}}` and it serves nothing
  (see "Operational gotchas").
- `data/rendered/config/` — every file under `config/`, rendered. `make
  install-config` installs from here.
- `$DATA_DIR/pages/` — the instance web roots: `pages/www/` (operator pages,
  edited in place; the repo ships none and render never touches them). The edge
  mounts `pages` at `/srv/pages` read-only; no other vhost serves files.

`scripts/stack/stack-up.sh` renders first, in every mode, so a fresh clone, a
`git pull` or an edited `instance.conf` can never deploy stale config.

### Adding a token

1. add the name + a one-line description to `config/instance.defaults`
2. add the value to your `data/instance.conf`
3. use `{{NAME}}` in a template, `${NAME}` in a compose file, or `$NAME` in a
   script (after sourcing `scripts/lib/instance.sh`)

`render.sh --check <file>` exits 1 if a token is unresolved, so a typo is a
failed render rather than an empty string in a live config. Unresolved tokens
are always left verbatim and reported on stderr — never silently blanked.
`config/instance.defaults` is documentation, not an installable template, so
`render-all` excludes it from the rendered tree.

### Renaming or moving the instance

Everything above exists so that renaming is a value change, not a refactor:

```bash
# 1. new values
$EDITOR data/instance.conf          # REPO_DIR=… REPO_NAME=… HOSTNAME=…
# 2. the checkout itself (same filesystem, so running mounts stay valid)
mv <old-checkout> <new-checkout>
# 3. re-render + re-create what mounts a path
make render && make update
```

### Compose substitution, in practice

`make render` appends a marked block to each `modules/*/.env`:

```
# >>> instance values (generated by 'make render' from data/instance.conf — do not edit)
DOMAIN=…
HOSTNAME=…
OPERATOR=…
GITHUB_USER=…
REPO_NAME=…
REPO_DIR=…
DATA_DIR=…
SERVER_IP=…
EMAIL=…
TIMEZONE=…
# <<< instance values
```

The block is replaced, never duplicated; the module's own secrets stay above it
in the same `.env` next to the compose file, which is why the repo's compose files
can use `${DOMAIN}` with no real value anywhere in git history.

### Rules that go with the skeleton

- Docs use the *variables* (`$DOMAIN`, `$DATA_DIR`, …) and templates use the
  tokens; nothing in git names a real host, domain, path or user.
- Secrets never belong in git; `data/instance.conf` is 0600, and rendered
  output (`data/rendered/`) is where live config actually comes from.

## Install, repair, uninstall

```bash
sudo bash scripts/install/wizard.sh        # fresh install, or repair a finished one
sudo bash scripts/install/uninstall.sh     # take it apart (module by module, --interactive)
```

The installer asks `Do you wish to continue?` and, on a machine that already has a finished install, offers repair instead. All inputs are collected before any work and each is persisted immediately, so an aborted run resumes: locale country, GitHub collaborator opt-in (+ a `name email` commit identity and a push key it verifies automatically), the device's public SSH key, Tailscale auth key, Cloudflare API token, domain, and the modules as one space-separated line (any of the names `config/modules.conf` declares, any order, `all` for every one). Affirmations accept only `yes`/`no`; the answer is stored as `true`/`false`.


Repair is idempotent and add-only for every module the operator keeps: it skips services whose inputs are unchanged, recreates Caddy only when the rendered config is newer, never re-issues a certificate that is already served, and hands a module the operator turned off to `uninstall.sh --granular`, which removes only that module — its containers, its data dirs and its Cloudflare A records (and the mail ports from the firewall) — so a turned-off app stops serving instead of staying reachable. A resume re-runs the whole pipeline (every step is safe to repeat) and asks only for values it is missing; the module set is always asked so a repair can change the selection. A run started fresh asks every prompt again and ignores the saved answers without deleting them, so a later run can still resume. There is no prompt-defaults file.

Uninstall is the exact opposite in the same style: three consequence confirmations by default, or `--interactive` to pick the scope (modules, the whole framework, or cancel). SSH hardening is deliberately kept and operator data is never deleted without a per-category confirm; the tailnet membership goes last so the session survives. The run prints how to rebuild.

Logs: `$LOG_DIR/wizard.log` (truncated at every run), `uninstall.log`, module logs; the run state is described under "State, logs, ownership". The installer reads the repo owner from the checkout's own `origin`, never a prompt.

## Migration (new machine, new domain)

The primary path is the installer: a **root-only**, prompt-once-unattended script. The
prompt order and the run's behaviour are in "Install, repair, uninstall"; this section is
the migration procedure. `make migrate` prints it.

### Run it

The installer runs from a checkout — it sources `scripts/install/wizard.d/` and derives
`$REPO` from its own path, so a lone copied file does not work:

```bash
git clone https://github.com/$GITHUB_USER/$REPO_NAME.git
cd $REPO_NAME && bash scripts/install/wizard.sh
```

Every input is collected before any work and persisted as it is given, so an interrupted
run resumes instead of re-asking. Then the run is unattended through the pipeline
"Install, repair, uninstall" describes — host services, the stack from
`config/modules.conf`, the Cloudflare records, the certificates and the module setup
steps — and ends with `write_state` (`finished=true`) → one `make smoke`, whose exit code
is the verdict; a failure records `finished=false`. Log: `$LOG_DIR/wizard.log`.

Re-running it on a finished install offers **repair** after a yes/no confirmation; to
rebuild from scratch, run `scripts/install/uninstall.sh` first, then the installer again.

### What the script does not do

- **Tailscale split DNS** — add `$DOMAIN` → this node's `100.x` in the admin console; the
  host's dnsmasq already answers the tailnet-only names. Printed as a follow-up.
- **Mailboxes** — create them with `make mail-gen [MAIL=…]` / `make mail-gen-alias TO=…`.
- **Provider-side PTR** — only the machine provider can set reverse DNS. Printed as
  follow-up 1 when the mail module is on.
- **Cloudflare WAF rule skip for `cloud.$DOMAIN`** — optional; desktop/mobile sync is
  bot-challenged otherwise (the trade-off is in "Design rationale").

### Prerequisites (manual, unavoidable)

- Cloudflare zone `$DOMAIN` exists (checked up front; the installer fails fast if not) and
  an API token with `Zone > DNS > Edit` for it.
- Tailscale auth key.
- The device's public SSH key (ssh hardening is applied in the same run).
- Nothing GitHub-side to type: the repo is public and cloned over HTTPS; the optional
  collaborator step mints `/root/.ssh/github_key` and switches `origin` to SSH only once
  GitHub accepts the key. `gh auth login` afterwards (once, on the new box) is what lets
  `make git-pr` open the pull request instead of printing the compare URL.

### Carrying existing data to a new machine

1. The repository is off this host already: carry `KOPIA_SFTP_*` (from `data/instance.conf`)
   and `modules/kopia/.env` — the repository password and the SFTP key open it from anywhere.
2. Install on the new machine, `make kopia-init` to connect (it refuses if the key is not
   authorized there), then `make kopia-restore SNAPSHOT=<id>` on the new host, after
   `make kopia-snapshots` names the id.
3. Copy `modules/*/.env` (gitignored secrets) from the old checkout, then `make render`
   and recreate the affected units.
4. Mail: the snapshot carries `mailserver/mail`, `mailserver/data`, `mailserver/dkim` and
   `mailserver/roundcube`; re-publish the DKIM TXT from the carried keys (the installer's
   `dkim_setup` reads Mailu's own public key) and keep the domain's MX/SPF/DMARC records.
5. Restore with the unit stopped: a snapshot of a live Postgres datadir is crash-consistent
   at best, so `make dok-stop-<ctn>` before restoring that module's tree, then recreate it.

### Manual fallback

If the script cannot be used, it automates exactly: host packages + `root` login +
sshd hardening + `/etc/docker/daemon.json` + `tailscale up` + ufw + dnsmasq + the repo
clone + `docker network create net --subnet=172.22.0.0/16` + `make install-config`, then
`make render`, `make update`, the CF records, the certificates and `make smoke`.

## Commands

`make help` is the daily surface, `make help-more` the granular one — both rendered by `scripts/info/help.sh`, and they are the source of truth for what exists.

| Need | Recipe |
|---|---|
| Machine at a glance in one screen (read-only) | `make fetch` |
| The same machine with depth (read-only) | `make fetch-more` |
| Is every door serving its app? | `make smoke` (also asserts the git hooks are installed) |
| Pull + recreate every deployed unit, edge last | `make update` |
| Recreate / restart / stop / log one container | `make dok-recreate-<ctn>`, `dok-restart-`, `dok-stop-`, `dok-logs-` (`-all` for every) |
| Stop or recreate the whole stack | `make dok-stop-all CONFIRM=yes`, `make dok-recreate-all CONFIRM=yes` — both refuse without `CONFIRM=yes` |
| Restart / log one host unit | `make systemd-restart-<svc>`, `systemd-log-<svc>` |
| Config in the repo → live | `make render`, `make install-config`, `make deploy` |
| Backup, restore, verify | `make backup`, `make kopia-status`, `make kopia-snapshots`, `make kopia-policy`, `make kopia-verify` |

Every script here acts on the live instance, so a real run is an **operator action**: an agent reads it, lints it (`bash -n`) or runs it in plan mode, and never fabricates a run. Every script that writes state takes a plan run — `DRYRUN=1 <script>` or `<script> --dry-run` — which prints one `dry-run: would …` line per action, derived from the same values a real run uses, and exits before the first mutation; a precondition that would refuse still refuses, and a generated credential is described rather than minted. The convention is defined once in `scripts/lib/dryrun.sh`, and the plan gates live in the readers of the live system (`scripts/ops/dns-sync.sh` sets `DRYRUN` for the wizard's `cf_dns`, so the record table is never copied).

Recipe output is uniform: `info: <done>`, `warn: <non-fatal>`, `error: <failed>` (exit 1); usage mistakes print `error: usage: …`. Raw `git`, `docker compose`, `docker exec`, `systemctl` and `tar` are for cases no recipe covers. `make git-com MSG="…"` takes one sentence — embedded newlines or double quotes break the quoting (wrap the whole `MSG=` in single quotes if a quote mark is needed).

## GitHub workflow — branches, pull requests and issues

Every actor follows one line: the human operator, the `make git-*` recipes, `scripts/install/wizard.sh` and an agent. `main` is **write-once** — `scripts/hooks/pre-push` refuses any push whose destination is `refs/heads/main` (and any non-branch ref at all) before the smoke gate, so the refusal holds even when a recipe is bypassed — and every change is made on a branch named `temp-<N>` (`temp-1`, `temp-2`, … the counter is DERIVED from the branches that exist locally and on `origin`, in `scripts/lib/temp-branch.sh`; never hardcoded, never stored).

1. `make git-issue TITLE="…" LABEL="bug" BODY=<file>` — when no pull request is open and the change fixes a problem, file it in the Issues tab first (labels validated against the labels the tracker actually carries, at least one required, body from `BODY`/stdin; an existing title is left alone and the new-issue URL is printed when `gh` is absent). While a pull request is open, a follow-up goes onto its branch as another commit: `make git-issue` and `make git-start` refuse, so the tracker never gains an issue per change.
2. `make git-branch` — create and switch to the next free `temp-<N>` off a freshly pulled `main` (`make git-start` is the same verb; `NAME=<branch>` creates an explicit name, `BASE=<branch>` bases it on another branch). Refused while a pull request is open; the gate asks the tracker and fails closed when it cannot (no authenticated `gh` and no `GITHUB_TOKEN`/`GH_TOKEN`).
3. Make the change and commit it through the installed hooks (`make git-com MSG="…"`); a change wider than ten files is auto-split into one commit per chunk. `make git-audit` checks rule 26. Never bypass a failing hook — fix it.
4. `make git-pr [ISSUE=<n>] [BASE=<branch>]` — audit the range, push the branch, then open the pull request against `main` (or `BASE`, for a change stacked on another branch) — through an authenticated `gh`, or through the GitHub REST API when only `GITHUB_TOKEN`/`GH_TOKEN` is exported (the path for a host without `gh`) — or print the compare URL `https://github.com/<owner>/<repo>/compare/main...temp-<N>?expand=1` and a filled body. `ISSUE=<n>` writes `Closes #<n>`, linking the issue; without an issue, the body must explain the feature (how it works, benefits, risks). Either way the body ends with a `## Revert` section the recipe appends — one `git reset --hard <base-sha>` for the whole pull request (rule 10).
5. **Stop.** A human reviews and merges the pull request (squash-only: the split commits stay on the branch for review, the PR lands as one commit, and its `## Revert` recipe undoes it in one command). An agent never merges, never approves and never pushes `main`. `make git-land` fast-forwards `main` and deletes the local branch only after the merge — a squash-merged branch needs `FORCE=1` on `make git-del`, since its commits never enter `HEAD`. Between steps, `make git-switch BRANCH=<branch>` moves the checkout, `make git-del BRANCH=<branch>` deletes a local branch (never `main`, never the current one, and only once its commits are in HEAD unless `FORCE=1`), and `make git-branches` lists them with the next free `temp-<N>`.

**A branch's pull-request shape is checked before it is pushed** — `scripts/info/pr-guard.sh` (run by `make git-pr`, the `pre-push` hook and the `validate` workflow) refuses a branch whose tree equals `main`, whose squash merge would change nothing, and one that renames a path `main` changed since the merge base, which GitHub reads as delete/modify and resolves by dropping the base's version. It also lists, as a warning, every path both sides changed, so a rebase picks them up before review; `PR_GUARD_OVERRIDE=1` reports without refusing. `make git-pr` additionally refuses a branch that already landed as a pull request, a second open pull request from another branch (no override — the change belongs on the open branch), and any base other than `main` (`STACK_OK=1`) — one open pull request per branch, per author.

**A stacked pull request's base cannot be retargeted once the stack exists** — GitHub answers `Cannot change the base branch because the pull request is part of a stack`, and closing the parent leaves the stack recorded, so the base stays the closed parent's branch. When the stack's content has already landed through a higher pull request (a squash merge carries the whole stack), close the parent and open a **fresh** pull request from the same branch against `main`: the rebased branch is what merges, and the stale parent tree would revert everything merged after it (lesson 2026-11-04).

**A pull request that renames a file `main` later modified reads CONFLICTING, although no local merge conflicts** — the base still holds the old path, so GitHub sees the rename as a delete of a modified file; a local `git merge` resolves it clean, and a local `git rebase` can resolve it the *wrong* way and drop the base's changes to the renamed file (reproduced in a fresh clone: the rebased tree came out byte-identical to the pull request's head, `main`'s gated-`route` restructure gone from the renamed vhost). After rebasing such a branch, diff the renamed path against `origin/main` and restore the base's shape by hand before pushing (lesson 2026-11-05). `make pr-guard` (also run by `make git-pr`, the `pre-push` hook and CI) reports it as `RENAME` before review.

**A stale `.git/hooks` copy breaks a commit or a rebase replay with `commit_folder: command not found` / `SIGNIFICANT_FILE_THRESHOLD: unbound variable`** — `make install-hooks` copies the hooks once and a hook sources the *worktree's* `scripts/lib/commit-areas.sh`, so the installed copy calls functions a reshaped library no longer has; a rebase replay hits it even after the base carries the new library, because the worktree keeps the old one until a replayed commit touches it. Takeaway: `make install-hooks` after any pull that touches `scripts/hooks/` or `scripts/lib/commit-areas.sh` (lesson 2026-11-05). Both hooks now run `scripts/lib/hooks-fresh.sh` first and refuse with that advice instead of the function name.

Issues live **only** in the repository's Issues tab — created, labelled, linked and closed there, through `make git-issue`, or through the GitHub API, never in a markdown file. A new problem is filed with `make git-issue` or the UI. Labels are the tracker's own live set (GitHub's defaults — `bug`, `enhancement`, `documentation`, … — plus `priority:` / `area:` and `good first issue` / `help wanted`) and the forms from `.github/ISSUE_TEMPLATE/`. The installer's first push is the one documented `--no-verify` exception (its pre-push smoke cannot pass before `wizard.state` records `finished=true`); it still pushes a `temp-<N>` branch, prints the compare URL, and leaves the checkout on that branch.

`.github/workflows/validate.yml` runs the same checks on every branch push and pull request — `bash -n` over every tracked shell script, `scripts/info/config-audit.sh`, `scripts/info/prose-audit.sh`, `scripts/info/git-audit.sh origin/main..HEAD` and `scripts/info/pr-guard.sh` over the head commit — read-only, so a commit made in the web editor or from another clone is caught before review.

**Enforcement on GitHub is the repository's "Base Ruleset"** (Settings → Rulesets; it cannot be stored in the repo). It targets the default branch, is active and has **no bypass actors**: *Require a pull request before merging* with 0 required approvals (the review is the human merge, the gate is the PR), squash merge only, *Require linear history*, *Require conversation resolution*, *Require status checks* naming the `validate` workflow, *Block force pushes*, *Restrict deletions*, and Copilot code review on every push. Auto-merge stays off, because the merge is the human decision.

The ruleset must not carry the *Restrict updates* or *Restrict creations* rules alongside "no bypass actors": a pull-request merge **is** an update of the default branch, so that pair leaves every PR at `mergeStateStatus: BLOCKED` — green checks, zero requested approvals, no stated reason — and nothing can be merged. The `pull_request` rule already refuses direct pushes, so those two add only a lockout (lesson 2026-11-01).

## Boot and recovery

`kefo-stack.service` (`config/systemd/kefo-stack.service`; installed and enabled by `make install-config`) is the boot guarantee: a `oneshot` unit that runs `scripts/stack/stack-up.sh` after `docker.service` and `network-online.target`. It closes the one gap `restart: unless-stopped` cannot — a container stopped *cleanly* by hand (`docker stop`, `make dok-stop-*`) never comes back on its own, while `up -d` starts it again.


A periodic repair pass is deliberately **not installed**: boot ordering is guaranteed by `config/systemd/kefo-stack.service` + `scripts/stack/stack-up.sh`, and a supervisor that restarts containers behind the operator's back is a bigger behavioural change than that guarantee. `stack-up.sh --check` exists if the operator ever wants it (file a feature issue if that changes).

## Backup & restore

`make backup` takes one Kopia snapshot of the module's read-only source mount — `$DATA_DIR`: every module's data dir, the rendered config, `data/instance.conf` and the goose environment — with kopia's own state dir excluded. Container name, mount destinations and config path are read live from the container (`scripts/lib/kopia-env.sh`), so only `SOURCE=` and `IGNORE=` ever name a path by hand; retention comes from `KOPIA_KEEP_*` in `data/instance.conf` (10 latest, 14 daily, 8 weekly, 12 monthly by default). Only one snapshot ever runs at a time: the timer, `make backup` and `make kopia-restore` share `data/kopia/.snapshot.lock`, so a manual run makes a scheduled window step aside (exit 0) and a manual run waits for a running window instead of starting a second one. `kopia-snapshot.timer` does the same work twice a day; `make kopia-init` connects the repository the first time and sets retention (10 latest, 14 daily, 8 weekly, 12 monthly), `make kopia-snapshots` lists what exists, `make kopia-policy` shows which paths a source includes (add/drop with `make kopia-ignore-add IGNORE=/path` / `make kopia-ignore-rm IGNORE=/path`: ignore rules are policy, anchored at the source root, so they need no restart of the container or the timer), space is reclaimed by retention plus maintenance: `make kopia-expire SNAPSHOT=<id> CONFIRM=yes` or `make kopia-delete SNAPSHOT=<id> CONFIRM=yes` drops one snapshot, `make kopia-maint FULL=1` then re-packs and frees the blobs nothing references any more, `make kopia-maint-info` shows the schedule and owner, `make kopia-stats` measures the repository directory on the disk and the content histogram, and `make kopia ARGS="…"` reaches every other subcommand. `make kopia-verify` re-reads a sample of the stored packs, and a restore is `make kopia-restore SNAPSHOT=<id>` (it refuses a non-empty target). The repository lives on the off-box disk at `KOPIA_SFTP_PATH`, not on this host: the disk's machine must be awake and the disk mounted, or the timer fails.

- `modules/*/.env` (per-module secrets) live in the checkout, not under `$DATA_DIR`, so they are not in the snapshot — keep a copy on the tailnet device or in the operator's password manager.
- Host-level files outside `$DATA_DIR` (`/root/.ssh/github_key`, the Cloudflare token) are outside the snapshot for the same reason.
- Kopia gotchas on this transport: `kopia blob stats` and a whole-repository `kopia blob list` never return over SFTP (they hang with no output) — use `make kopia-stats`, which measures the directory on the disk instead. `kopia maintenance run` defaults to `--safety=full`, which only *reports* unreferenced blobs and leaves the deletion to a later quick cycle, so repeating the command reclaims nothing. And the repository identity kopia stores is `user@hostname` from the container's config, not its runtime id: `modules/kopia/docker-compose.yml` pins `hostname: kopia` and `make kopia-init` reconnects with `--override-hostname`, or a recreated container silently stops owning maintenance and starts recording every snapshot under a new source name. If maintenance dies with `can't re-create top-level directory …: top-level directory not found` the disk unmounted mid-run, and if it later fails with `sftp: "Failure" (SSH_FX_FAILURE)` on `GetBlob(kopia.repository)` while `ls` on the mount returns `fts_read: Input/output error`, the USB volume itself has dropped into an error state: eject and re-plug it (or run First Aid) before touching the repository again, then `make kopia-status` and `make kopia-verify`. A long maintenance pass holds the disk busy for hours and is what surfaces a marginal USB link — prefer a target that does not depend on one.

## Service reference

The compose files are the source of truth. This table is the one-line reference for each service.

| Service | Compose | Container | Edit mounted config | After compose / image change |
|---------|---------|-----------|---------------------|------------------------------|
| caddy   | `modules/caddy/docker-compose.yml` | `caddy` | `make dok-restart-caddy` | `make dok-recreate-caddy` (rebuilds `caddy:local` from `modules/caddy/Dockerfile`) |
| chat | `modules/matrix/docker-compose.yml` | `matrix-synapse` + `matrix-element` + `matrix-db` + `matrix-mas` + `matrix-mas-db` + `element-admin` | `make dok-restart-matrix-synapse` | `make dok-recreate-matrix-synapse` (depends_on brings both databases up) |
| kopia | `modules/kopia/docker-compose.yml` | `kopia` | `make dok-restart-kopia` | `make dok-recreate-kopia` |
| ocis    | `modules/ocis/docker-compose.yml` | `ocis` | `make dok-restart-ocis` | `make dok-recreate-ocis` |
| vault   | `modules/vaultwarden/docker-compose.yml` | `vaultwarden` | `make dok-restart-vaultwarden` | `make dok-recreate-vaultwarden` |
| kuma    | `modules/uptimekuma/docker-compose.yml` | `uptimekuma` | `make dok-restart-uptimekuma` | `make dok-recreate-uptimekuma` |
| mail | `modules/mailserver/docker-compose.yml` | `mailu-front` + `mailu-imap` + `mailu-smtp` + `mailu-antispam` + `mailu-admin` + `mailu-redis` + `roundcube` | `make dok-restart TARGET=mailu-front` | `make dok-recreate TARGET=mailu-front` |
| home | `modules/homarr/docker-compose.yml` | `homarr` | `make dok-restart-homarr` | `make dok-recreate-homarr` |
| blog | `modules/writefreely/docker-compose.yml` | `writefreely` | `make dok-restart-writefreely` | `make dok-recreate-writefreely` (rebuilds `writefreely:local` from the pinned release tarball) |
| photos | `modules/immich/docker-compose.yml` | `immich-server` + `immich-db` + `immich-redis` | `make dok-restart-immich-server` | `make dok-recreate-immich-server` (depends_on brings db + redis up) |
| terminal | n/a (host systemd; see Protected host resources) | n/a | `make systemd-restart-ttyd` | `make install-config` |
| dnsmasq | n/a (host systemd) | n/a | `make systemd-restart-dnsmasq` | n/a |
| goose   | n/a (host systemd; see Protected host resources) | n/a | `make systemd-restart-goose` | n/a |


### Per-service edit pointers

When you need to know "what does X do / where do I edit Y", read the file at the path below — the docs don't re-type the contents.

- **`kuma`** — image, bind mount, healthcheck: `modules/uptimekuma/docker-compose.yml`. Monitor definitions live in Kuma's SQLite (`modules/uptimekuma/seed-monitors.sql` seeds them; applied by the installer). It also mounts the docker socket read-only — **accepted**, because the monitoring module needs it: a socket holder is host root (a compromise of either is the box), and `no-new-privileges` does not neutralise a socket, so treat every socket holder that way when writing policy.
- **`terminal`** — `ttyd.$DOMAIN` is the tailnet entry point and the shell IS the homepage: `/` proxies straight to ttyd (it runs WITHOUT `-b`, so no base path and the request path is already the app's own — there is no `/ttyd` subpath, and `handle_path`/a prefix strip would break it), with Tailscale membership as the ONLY gate and no second credential. The vhost serves no file: `/` is the shell. **One page, one shell**: ttyd runs `tmux new-session -A -s main` with no `-a`, so the URL cannot name a session and every visitor lands in the single `main` session; a second shell is a tmux window inside it (`make tmux-new`/`tmux-open`), not another ttyd session. Its cert is a normal Let's Encrypt one by DNS-01 with the same fallback issuer chain as every vhost — no `tls internal`, no self-signed warning — and a device reaches it by name only once the tailnet split-DNS route for `$DOMAIN` (admin console → DNS → nameservers → `$DOMAIN` → this node's `100.x`) points at this machine's dnsmasq; `make smoke` probes the tailnet-only doors from the host's own Tailscale address. The whole vhost serves `Cache-Control: no-store, no-cache, must-revalidate, max-age=0` + `Pragma: no-cache` + `Expires: 0` with ETag/Last-Modified stripped — nothing on ttyd.$DOMAIN is cacheable. ttyd runs as a host systemd unit (not a container); interactive shells show the `root@$HOSTNAME` banner/prompt from `config/bash/banner.sh`. Binary at `/usr/local/bin/ttyd`, unit at `/etc/systemd/system/ttyd.service` (reference copy in `config/ttyd/ttyd.service`). No systemd sandbox (operator preference: no permission hunts). Runs as `root`, so full host control from the shell. Access control is at the network layer (Tailscale membership + Caddy `@not_tailnet`), not the unit sandbox. `make install-config` installs the binary (static 1.7.7 from upstream) and the unit; the step is idempotent. Caddy proxies to the loopback bind `127.0.0.1:7681` with `transport http { versions 1.1 }` (ttyd only speaks HTTP/1.1); `make install-config` deletes any stale `172.22.0.0/16 → 7681/tcp` INPUT allow, so a container on `net` cannot reach the terminal.

  **Spoof-proofing**: Roundcube's `identities_level = 3` (`modules/mailserver/roundcube-tls.inc.php`) locks the identity address to the login mailbox — the From dropdown only ever shows the user's own address and only name/signature can be edited; Roundcube exposes no admin UI in this version. Roundcube reaches the platform over STARTTLS (`tls://mail.$DOMAIN:143` / `:587`, same file) and the compose `extra_hosts` maps `mail.$DOMAIN` → 172.22.0.9 so SNI and cert verification match. DKIM keys live in `$DATA_DIR/mailserver/dkim` (mounted at `/dkim` in mailu-antispam; selector `dkim`) and the TXT record is published from Mailu's own public key. DNS: `mail.$DOMAIN` is the public mail door and MUST stay DNS-only (grey cloud) — SMTP/IMAP cannot traverse the CF proxy, and the MX/SPF point at it. `admin.mail.$DOMAIN` is TAILNET-ONLY (same model as `vault.$DOMAIN`): `cf_dns` deletes any public A record, dnsmasq answers the name for tailnet clients (`config/dnsmasq/10-tailnet.conf`) and the vhost 403s every source outside `100.64.0.0/10`. Both certs issue by DNS-01, which needs only the TXT record.
- **`www` pages** — `/` and `/welcome` are INSTANCE files in `$DATA_DIR/pages/www` (`index.html`, `welcome.html`), edited in place; the repo ships no pages and `make render` never reads or writes them, so the edge always serves exactly what is in the web root: the poster page's nav bar links the pages and its `Home →` button points at `home.$DOMAIN`, because the dashboard cannot live under a path (Homarr is a Next.js app linking its assets ROOT-absolute `/_next/...`, and Next's `basePath` is baked in at build time — upstream refuses subpath hosting for the published image, homarr-labs/homarr#2617).
- **`home`** — Homarr at `home.$DOMAIN` (`modules/homarr/docker-compose.yml`, container port 7575, bridge IP `172.22.0.7`). Everything it knows lives in `$DATA_DIR/homarr/appdata` (SQLite DB, redis dump, trusted certs) — there is no template to render and no config file to edit; board layout, apps and integrations are operator data managed in the web UI. `SECRET_ENCRYPTION_KEY` (64 hex chars) encrypts the secrets stored in that DB: the installer mints it once into the gitignored `modules/homarr/.env`, the container exits at boot without it, and **rotating it makes every stored integration secret unreadable**. The first account is created in the UI on first visit; Homarr has no user CLI. It cannot be mounted under a path — see the `www` pages bullet. `GET /var/run/docker.sock` is bind-mounted read-only into the container: without it the UI's docker integration scan fails with `connect ENOENT /var/run/docker.sock` (it only lists containers to suggest integrations, it never drives the daemon).
- **`blog`** — WriteFreely on its own vhost. Upstream publishes no current Docker image, so `modules/writefreely/Dockerfile` pins the official release tarball by version **and sha256**; the entrypoint copies the app tree into `$DATA_DIR/blog/data` on first boot, writes `config.ini` once (operator-editable afterwards), generates keys and initialises SQLite. The FIRST account is the instance admin and must be created with `make writefreely-add-user USER=<name> PASS=<password> ADMIN=1` — WriteFreely allows exactly one admin, and the CLI refuses to delete it. `WF_HOST` is the vhost URL (`https://blog.$DOMAIN`); WriteFreely signs ActivityPub objects from it, so it must never be changed to an internal address.
- **`ocis`** — ownCloud Infinite Scale at `cloud.$DOMAIN`: `modules/ocis/docker-compose.yml` (single container, image pinned by digest, `user: 1000:1000`, bridge 172.22.0.27, port 9200). Everything it stores is under `$DATA_DIR/ocis`: `data/` (IDM boltdb, the decomposed-fs user store, service accounts, search index) and `config/` (the generated `ocis.yaml`, which holds the instance's own secrets — instance data, never tracked). Its `.env` is seeded by the installer's `seed_stack` (`OCIS_URL=https://cloud.$DOMAIN`, `PROXY_HTTP_ADDR`, the IDM admin password minted once and kept — oCIS stores only a hash after first boot). The container sends `X-Frame-Options`, `X-Content-Type-Options` and its own CSP itself, so `cloud.caddy` deliberately does NOT import `security_headers` (that duplicated XFO/XCTO); only HSTS and `Referrer-Policy` are added at the edge. An image bump migrates the IDM store on start — change the digest only deliberately. The IDM password has no web-UI reset: `make ocis-admin-pass` runs `ocis idm resetpassword` interactively inside the container (`USER=<name>`, default `admin`), and `make ocis-status` probes the OCS capabilities endpoint, which is the real health signal (`/healthz` answers 200 with the backend down).
- **dnsmasq** — config: `config/dnsmasq/10-tailnet.conf` (live path: `/etc/dnsmasq.d/10-tailnet.conf`). systemd drop-in: `config/dnsmasq/dnsmasq.service.conf` (live path: `/etc/systemd/system/dnsmasq.service.d/override.conf`).
- **goose** — unit: `config/goose/goose.service` (live path: `/etc/systemd/system/goose.service`); its server secret is not in the repo — the unit reads `EnvironmentFile={{DATA_DIR}}/goose/.env` (root:root 0600), created by the installer and rotated by `make goose-secret` (restarts the agent; every paired client must re-pair). The unit used to carry a `sed`-ed real key, so values remain in git history: purging them is an operator-only `filter-repo` rewrite plus force-push, never a script.
- **goose token management** — every request bills input + cached input + output, so the policy is short context, short replies, cheap tier. `config/goose/token-policy.yaml` is the source of truth and `scripts/info/goose-tokens.sh` applies it.
- **goose session store** — `~/.local/share/goose/sessions/sessions.db` keeps every session and every message with no retention of its own, so it is pruned by hand. `goose session remove --regex <re>` is not the way: it lists the matching sessions and then fails with `Error: not connected`, because the CLI removes through the running `goose serve` ACP endpoint and the handshake never completes. Stop the unit (the DB is root-owned and must not be open), delete the child rows and then the session rows older than the cut — the live session is newer than the cut and survives — and `VACUUM` to give the space back. Run it with the retention you want and start the unit again:
  ```bash
  systemctl stop goose
  python3 - <<'PY'
  import sqlite3, os
  db = os.path.expanduser('~/.local/share/goose/sessions/sessions.db')
  old = "select id from sessions where coalesce(updated_at, created_at) < datetime('now','-30 days')"
  con = sqlite3.connect(db)
  con.execute(f"delete from messages where session_id in ({old})")
  con.execute(f"delete from usage_ledger where session_id in ({old})")
  n = con.execute(f"delete from sessions where id in ({old})").rowcount
  con.commit(); con.execute("vacuum"); con.close()
  print(f"pruned {n} sessions")
  PY
  systemctl start goose
  ```
  The `messages` foreign key carries no cascade (`usage_ledger`'s does), so the explicit delete order matters: children first, sessions last.
- **`chat`** — ESS CE (Element Server Suite Community Edition, assembled from its components): `modules/matrix/docker-compose.yml` — Synapse at 172.22.0.28:8008, Element at 172.22.0.29:80, the Synapse store at 172.22.0.30:5432, Matrix Authentication Service at 172.22.0.34:8080 with its own store at 172.22.0.33:5432. Secrets and all four configs are generated once by `scripts/modules/matrix-gen.sh` and then owned by the operator; a version change goes through `make matrix-update CONFIRM=yes` (dump → recreate MAS → recreate Synapse), accounts are managed by `scripts/modules/matrix-admin.sh` (MAS's CLI under the hood). The Element Admin panel is part of the same unit: `element-admin` (172.22.0.32:8080, `oci.element.io/element-admin`, read-only rootfs) is a static SPA that calls `matrix.$DOMAIN` (Synapse admin API) and `auth.matrix.$DOMAIN` (MAS admin API) from the browser, with `SERVER_NAME` set to the homeserver name (`matrix.$DOMAIN`). Vhosts: `chat.caddy` (Element), `matrix.caddy` (Synapse + client discovery), `auth.matrix.caddy` (MAS), `admin.matrix.caddy` (the panel, TAILNET-ONLY — it reads every account, room and session), `call.matrix.caddy` (Element Call), `livekit.matrix.caddy` (SFU signalling) and `livekit-jwt.matrix.caddy` (the token service).
- **`kopia`** — a client container, not a server: `modules/kopia/docker-compose.yml` (172.22.0.31, idle, no port). The repository is an SFTP path on the off-box disk, named by `KOPIA_SFTP_*` in `data/instance.conf`; `scripts/modules/kopia-gen.sh` seeds the repository password and generates the SFTP key, `scripts/modules/kopia-admin.sh` connects the repository (`make kopia-init`), snapshots, verifies and lists. `config/systemd/kopia-snapshot.timer` drives it through `scripts/ops/kopia-snapshot.sh`. There is no vhost and no DNS record.
- **mail** — Mailu 2.0 + Roundcube: `modules/mailserver/docker-compose.yml`. Every `make mail-*` recipe delegates to `scripts/modules/mail-gen.sh`/`mail-alias-gen.sh`.
  **Spoof-proofing**: Roundcube's `identities_level = 3` (`modules/mailserver/roundcube-tls.inc.php`) locks the identity address to the login mailbox, so the From dropdown only ever shows the user's own address.

### Matrix stack

The homeserver's whole configuration is instance state under `$DATA_DIR/matrix/synapse` (`homeserver.yaml`, `log.config`, the signing key, the media store) plus the PostgreSQL data dir `$DATA_DIR/matrix/pgdata`; Element's runtime config is `$DATA_DIR/matrix/element/config.json`; MAS's `config.yaml` and token-signing keys are `$DATA_DIR/matrix/mas`, with its own store at `$DATA_DIR/matrix/mas-pgdata`. `make matrix-gen` writes a file only when it is missing, so a re-run never rotates a secret or rewrites a working config.

The homeserver NAME is `matrix.$DOMAIN`: it is the suffix of every user id (`@you:matrix.$DOMAIN`) and of every room alias, so it is fixed for the life of the deployment — changing it is a wipe (`make matrix-reset CONFIRM=delete-accounts` drops both databases, deletes the signing key and re-creates only the admin account). The name is also the API host, so `matrix.$DOMAIN` carries no `.well-known` delegation for itself; it publishes `/.well-known/matrix/client` (homeserver URL + MAS issuer) and `/.well-known/matrix/server` (`:443`) from the edge. Registration is closed: accounts are created by `make matrix-add`/`make matrix-add-admin`, which register in MAS and set the Synapse admin flag. The account named by `SYNAPSE_ADMIN_USER` (seeded as `mkadmin`) is the one every `make matrix-*` recipe mints its Synapse admin token for, and the only admin the installer creates; do not delete, rename, deactivate or demote it, and do not hand-edit its password or the shared secret in `modules/matrix/.env` — use `make matrix-add-admin`, `make matrix-passwd` and `make matrix-flag-admin` instead. Losing it leaves the stack running but the host terminal without an admin path until it is re-registered and re-flagged (see Operational gotchas). The `make matrix-*` recipes authenticate with `MAS_SYNAPSE_SECRET` from `modules/matrix/.env` — the one shared secret `homeserver.yaml` sets as `matrix_authentication_service.secret`: Synapse accepts it as the bearer token on `/_synapse/admin` (no password login exists to take) and MAS sends the same value when it calls the homeserver. Because delegated auth removes `/login`, `/logout` and `/refresh` from Synapse, the matrix vhost proxies those three to MAS — that is the compatibility layer an older client still logs in through, while a current one reads `/_matrix/client/v1/auth_metadata` and goes to the issuer itself. QR sign-in — "Link new device" in Settings → Sessions and "Sign in with QR code" on the login page — needs three things that are all generated: `experimental_features.msc4108_enabled` in `homeserver.yaml`, the `feature_login_with_qr` labs flag in Element's `config.json`, and MAS advertising the `urn:ietf:params:oauth:grant-type:device_code` grant in `/auth_metadata`; Element only draws the button when `/versions` lists `org.matrix.msc4108` and that grant is offered. The approving device shares the session through the rendezvous, so Synapse's `login_via_existing_session` (the older MSC3882 token path) stays off — delegated auth refuses it outright. Group calls are the same module's other half: Element Call is served at `call.matrix.$DOMAIN` (`element-call`, static, embedded by Element as an iframe), its SFU is LiveKit at `livekit.matrix.$DOMAIN` (`livekit`, signalling on 7880 plus the media ports 7881/tcp and 7882/udp published straight off the host), and the SFU token service is `livekit-jwt.matrix.$DOMAIN` (`livekit-jwt`), which trades a Matrix OpenID token for a LiveKit one so only this homeserver's users reach the SFU. The browser never names the SFU: `homeserver.yaml`'s `matrix_rtc.transports` does (with `experimental_features.msc4143_enabled`), and Element Call reads the homeserver from `$DATA_DIR/call/element-call/config.json`; the SFU's key/secret and port map live in `$DATA_DIR/call/livekit.yaml` (0600, generated once, never re-rendered). Media encryption is end-to-end in the browser (insertable streams), which is why `call.matrix.$DOMAIN` is served with `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp` — strip either and the call connects unencrypted. `chat.$DOMAIN` is only the web app; a client that used it as its homeserver would ask for `@user:chat.$DOMAIN`, an account that cannot exist. MAS's issuer is `auth.matrix.$DOMAIN` and that string is baked into every token it mints, so renaming the host invalidates every live session — every client and the admin simply log in again (no data changes).

## Protected host resources

**Never delete or disable any of these without explicit operator approval.** If a task seems to require removing any of them, stop and ask.

- `$DATA_DIR/kopia` — Kopia's client config, the repository password in `modules/kopia/.env` and the SFTP key in `$DATA_DIR/kopia/ssh`. Without the password and key the off-box repository cannot be opened: the disk alone is not a restorable backup.
- `/etc/systemd/system/goose.service` — goose agent systemd unit (`enabled`, `Restart=always`). Its server secret lives in `$DATA_DIR/goose/.env` (root:root 0600, instance state — the unit reads it via `EnvironmentFile=`).
- Credentials are never left in loose files: the Kuma admin hash lives in its database, service secrets in `modules/*/.env` + `$DATA_DIR/goose/.env`, and generated passwords are printed once at creation (`make kuma-passwd`, `make mail-password`). Never commit or re-print an existing secret.
- `/etc/systemd/system/ttyd.service` — ttyd web-terminal unit (`enabled`, `Restart=always`). Binds `127.0.0.1:7681` only (loopback), reached solely through Caddy's tailnet-gated `ttyd.$DOMAIN` proxy (`/` proxies straight to it) — no bridge bind and no UFW allow. It runs `tmux new-session -A -s main` with no `-a`, so every visitor lands in the ONE `main` session (created by `tmux-main.service` at boot); there are no per-device sessions and no session name can be passed through the URL.
- `/etc/dnsmasq.d/10-tailnet.conf` and `/etc/systemd/system/dnsmasq.service.d/override.conf` — host DNS resolver + systemd drop-in (`Restart=always`). Binds the host's Tailscale IP on port 53 only.
- `/etc/resolv.conf` — points at Tailscale's resolver `100.100.100.100` (tracked copy `config/resolv/resolv.conf`, applied by `make install-resolv` with a `*.pre-tailscale.bak` backup). This is what makes the split-DNS route for `$DOMAIN` apply to THIS host: without it `ttyd.$DOMAIN`/`vault.$DOMAIN`/`mail.$DOMAIN` answer NXDOMAIN on the machine that serves them. Deliberately NOT part of `install-config` — it must be applied only once tailscaled is up.
- `/etc/default/tailscaled` — tailscaled unit flags (`FLAGS=`, read via `EnvironmentFile=`). The installer sets `FLAGS="--encrypt-state"` **only when a TPM is present** (`/dev/tpmrm0`): on Linux the flag needs TPM, so forcing it on a TPM-less machine makes tailscaled fail to start and takes the node offline (there the console's `tsStateEncrypted` stays false — no TPM, no state encryption).
- The `caddy` container — NEVER alter, stop, or restart it without explicit operator approval; it is the ingress edge for all `$DOMAIN` routes (`make backup` reads it read-only).
- `$DATA_DIR/caddy_data/` — Caddy runtime data dir (LE certs under `caddy/acme/`, ACME account keys, OCSP staples) and the `CF_API_TOKEN` file used for per-vhost ACME DNS-01. The Caddy container bind-mounts this dir at `/data` so certs persist across container recreates; `$DATA_DIR/logs/caddy/` is bind-mounted at `/var/log/caddy` for the per-app access logs the fail2ban jails read. The installer writes `CF_API_TOKEN` (owner uid 201, mode 0600 — never world-readable); do not commit it.
- `$DATA_DIR/download/` — file-browser drop folder, served read-only at `www.$DOMAIN/download` (Caddy bind mount `/download:ro`). Owned by `root`; anything dropped here is publicly readable.
- `$DATA_DIR/pages/` — the web roots (Caddy bind mount `pages:/srv/pages:ro`, so no repo path and no instance path share a name): `pages/www/` for `www.$DOMAIN` (operator-owned pages, edited in place; the repo ships none and `make render` never writes or deletes one). `ttyd.$DOMAIN` has no web root at all — its homepage is the shell.
- `$DATA_DIR/goose/.env` — the goose server secret + the token-policy environment, root:root 0600, read by the unit's `EnvironmentFile=`. Untracked instance state, never a repo file.
- `$DATA_DIR/mailserver/` — mail platform data: `mail/` (Maildirs), `data/` (Mailu SQLite config), `dkim/` (RSA keys, mounted at `/dkim`), `filter/` (Rspamd), `certs/` (the mail.$DOMAIN pair copied from caddy_data), `redis/`, and `roundcube/` (webmail sqlite). `prep_dirs` enforces the ownership each container needs — `data/` is `100:1000` (mailu-admin's uid after `/start.py` drops privileges), `redis/` is `999:1000`, `roundcube/` is `33:33`, the rest `root`.
- `net` Docker network — user-defined bridge, `external: true`, subnet `172.22.0.0/16`. Reused by all inter-container services.

## Goose recipes

`recipes/` holds reusable Goose agent tasks — each one a `version/title/description/instructions/extensions/parameters/prompt` YAML file that tells the agent what to inspect, which tools it may use, what inputs it accepts, and what report to produce. Every recipe is **read-only**: it inspects and reports, never mutates the host, and the operator applies changes after review (the same "read-only first" discipline as "Deep scan and debugging"). The agent's own rules stay in `docs/AGENTS.md`; these recipes point at it and at `docs/MANUAL.md` rather than restating them.

The `make goose-*` front doors wrap `goose run --recipe <name>` with the repo-local `GOOSE_RECIPE_PATH` (`recipes/`), so the recipes stay versioned with the scripts and docs they operate on:

- `make goose-recipes` — list them (`goose recipe list`).
- `make goose-audit [FOCUS=…]` — full read-only audit (security/reliability/ops/docs drift).
- `make goose-review MODULE=…` — review one module (any name in `config/modules.conf`, or `edge`).
- `make goose-troubleshoot SERVICE=…` — triage a failure via "Deep scan and debugging".
- `make goose-check-backups [FOCUS=…]`, `make goose-check-network [FOCUS=…]` — backup and ingress/mail reviews.
- `make goose-validate-installer [TARGET=…]` — lint/review script changes (`bash -n`, no apply).
- `make goose-audit-docs [SCOPE=…]` — find doc drift/stale/duplicate.
- `make goose-deploy-plan CHANGE=…` — produce a deployment/upgrade plan.


## Git remotes and identity

- `origin` is `git@github.com:$GITHUB_USER/$REPO_NAME.git` (pushes use `/root/.ssh/github_key`) or the HTTPS URL (anonymous clone — a push there waits for credentials). Read `git remote -v`, never assume.
- `gh` is installed by the wizard so `make git-pr` opens the pull request and `make git-issue` files the issue. It needs one `gh auth login` (operator action; an agent never runs it). Without it the recipes fall back to `GITHUB_TOKEN`/`GH_TOKEN`, then to printing the compare URL and a ready body.
- `$GITHUB_USER` is the operator's GitHub identity and lives only in `data/instance.conf`: every tracked file references it as `$GITHUB_USER`, never the literal value (the `README.md` clone URL, `LICENSE`, the `.github/` metadata and git history are the only places the literal appears).
- Every commit is authored `<id>+$GITHUB_USER@users.noreply.github.com` (repo-local `git config` written by the installer at deploy time, `user.useConfigOnly true` so git errors instead of inventing `root@<host>`); the hooks refuse any other identity. `--no-verify` is forbidden — a failing hook is fixed, never bypassed; the installer's first push to its one-shot `temppush` remote is the single designed exception.
- Comments and user-facing strings are held to the same line as the docs — current configuration only, no `docs/` path, size, timing, foreign host or plan: `make prose-audit` reports over the tracked tree, and the `pre-push` hook plus `make git-pr` refuse on a finding (`PROSE_AUDIT_OVERRIDE=1` overrides). Markdown is checked for open tasks only — a pending-marker, a task label or an unchecked box outside the issue/PR templates; those belong to the Issues tab, where a human closes them. `recipes/*.yaml` and `make migrate` are exempt.
- The per-commit file limit (ten files) is defined once in `scripts/lib/commit-areas.sh`; nothing else bounds a commit — no folder, subfolder or change-type rule: `make git-audit` reports (read-only, over the range a push would publish), `make git-split` fixes (splits into consecutive chunks, refuses published commits). The `prepare-commit-msg` hook splits an oversized staged change and aborts the outer commit; the `pre-push` hook splits the commits the push publishes — those reachable from the pushed tip and from no remote ref, so `main`'s squash-merge commits (one commit per pull request, wider than the limit) never block a legitimate push — the only place a web-editor commit can be caught. Overrides: `GIT_SPLIT_DISABLE=1`, `HISTORY_AUDIT_OVERRIDE=1`, `REWRITE_PUBLISHED=1` (operator-approved rewrite).
- History rewrites use the plumbing `commit-tree` loop (`scripts/ops/identity-rebuild.sh`, `drop-path.sh`, `replace-string.sh`): `filter-branch` and `filter-repo` rewrite the graph instead of replaying it, and only a parent-first replay keeps trees, dates and messages byte-exact. Each takes `--dry-run` and prints the commit count it would replay. Verify after a rewrite: uniform identities, unchanged tip tree, byte-identical messages and dates, no new root, no merge, `git fsck` clean. Never tag a pre-rewrite or superseded history (GitHub counts tags, and the old commits become reachable again) and never re-rewrite to chase the contribution graph. After a full-history force-push, run `make gh-web-health` — GitHub's web git-data can 500 until a real (never empty) commit nudges a rebuild.

## State, logs, ownership

- `data/` holds everything the install produced: `instance.conf`, `rendered/`, `wizard.state`, `caddy_data/` (certs, ACME account keys, `CF_API_TOKEN`), `logs/` (the installer/uninstall logs, and `logs/caddy/` for the per-app access logs), `download/` (public drop folder), `pages/` (web roots), `goose/.env` (root:root 0600), `mailserver/{mail,data,dkim,filter,certs,redis,roundcube}`, `vaultwarden/`, `uptimekuma/` and the other module dirs. `prep_dirs` enforces the per-container ownership each one needs.
- Docker logging is capped in `config/docker/daemon.json` (json-file, 10m × 3); the installed systemd units are `kefo-stack.service` and `tmux-main.service`.
- `$DATA_DIR/wizard.state` (mode 0600) is the run state: `enabled_modules` (what exists), the `finished` checkpoint (the precondition for `make smoke` and therefore for a push) and the prompted secrets. The installer is its **sole writer** and records `finished=true` only when a run reaches the end; `uninstall.sh` clearing `enabled_modules`/`finished` on a full teardown is the one documented exception. Every consumer reads it through `scripts/lib/modules.sh`, never its bytes directly; `installed-modules.detected.conf` + `installed-modules.report.txt` are its independent-probe confirmation. A missing state file means nothing is recorded — never "assume everything is present".
- The repo is owned by `root:root`; edit as root, do not `chown` it elsewhere. Agent changes are confined to tracked paths — every `data/` change is an operator action, and `git diff -- data/` must be empty before a commit.

## Deep scan and debugging

The procedure for an occasional deep scan or for triaging an incident: read-only until a
finding is confirmed, one logical change at a time, and every claim proven with a probe.
The facts this procedure uses are in the service reference, the state and ownership
section, and the operational gotchas above and below.

### Operating discipline
- **Read-only first.** Inspect before changing; understand dependencies before touching a service.
- **One logical change at a time.** Baseline → hypothesis → smallest change → retest. Never stack unrelated changes.
- **Validate before applying, verify after.** Syntax-check (`caddy validate`, `docker compose -f <file> config -q`, `bash -n <script>`) *and* prove the outcome with a probe.
- **Rollback first.** Every risky change ships with a one-line revert recipe in the pull request body.
- If a change makes things worse: stop, restore the last known-good state, verify, report — never compound it.
- No fabrication: never report a result you did not actually observe; say so when a test could not run.

### Layer ladder (resolve in order, stop at the first failure)
1. **DNS** — `dig +short <host>`; tailnet name not resolving → `make systemd-restart-dnsmasq`.
2. **TCP** — `curl -sS -o /dev/null -w '%{http_code}\n' --connect-timeout 5 https://<host>/`.
3. **TLS** — issuer/dates on a fresh handshake *from the host* (`openssl s_client … -servername <host>`), not through Cloudflare.
4. **Edge / proxy** — `make dok-logs-caddy`; config valid (`docker exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile`); `make smoke`.
5. **Upstream / app** — `docker ps` health, `docker logs --since 10m <ctn>`, `journalctl -u <unit>`.
6. **Access control** — the code tells the layer: 403 = matcher/ACL, 401 = auth, 404 = route, 502 = upstream down.

### Standard scan (read-only)
```
make fetch                   # one screen: os, uptime, disk, memory, swap, ip, install checkpoint, git, tailnet, host units, tmux, docker, module count
make smoke                    # every vhost must serve its real app; runs ONLY on a finished install (wizard.state finished=true); not-installed modules' failures are listed once at the end and don't fail the run
docker ps --format '{{.Names}}	{{.Status}}'
ss -tlnp                      # listeners — compare with "Access model" above
sudo ufw status verbose
free -m; df -h /              # memory / disk headroom
sudo journalctl -p err --since "-3 days" | tail -30
```

### Repo-consistency probes (does the running system match the repo?)
```
git status
bash scripts/ops/optimize.sh --verify                  # host tuning converged
bash scripts/info/gh-web-health.sh                      # after any history rewrite
```

### Where the answers already are
- Symptom → cause map: "Operational gotchas" below (e.g. the `respond "ok"` edge stub, force-recreate name collisions, the tailscaled boot-race, `fs.protected_regular` root-writes in /tmp).
- Open problems and their status: the repository's Issues tab.
- Migration/rebuild path: "Migration (new machine, new domain)" above.
- JS/static-client triage: diff the *served* page against the pristine upstream copy before assuming the server is broken; a single SyntaxError in the only inline script black-screens with no server-side error.

### Report template
What changed · what was tested · did the tests pass · remaining issues · security/operational notes. Cite the probe output, not an assumption. A closed issue gets its own `Closes #<n>` line — one per line, never several numbers on one. Labels belong to the tracker's fields: a PR, commit message or issue body describes the problem and the fix, never the labels it carries.

## Operational gotchas
- A deliberate `systemctl stop dnsmasq` takes all tailnet-side `*.$DOMAIN` resolution down. Restart with `make systemd-restart-dnsmasq`.
- **A removed tailnet node keeps its cached IP, so `tailscale ip -4` still succeeds and the installer skipped the rejoin (2026-10-16)** — after the node is deleted in the admin console the control server answers `404: node not found`, the box is offline, yet `tailscale ip -4` prints the stale address; the old `if ! tailscale ip -4` join guard therefore never fired. The guard now gates on `tailscale status --json` `.Self.Online`. A rejoin can hand the node a NEW `100.x` address; the installer's tailnet step now re-renders the split-DNS conf (`make install-dnsmasq-conf`) whenever either the `listen-address` bind or the `address=/ttyd.$DOMAIN/` answer no longer matches the live IP — a live bind with a stale answer resolves the door to a departed address. Tailnet `*.$DOMAIN` self-heals on the next run.
- **`systemctl restart ttyd` kills every shell it serves — including the agent that ran it (2026-09-11 19:58)** — ttyd spawns its shells (tmux sessions included) inside its own cgroup, so the restart SIGTERMs the whole group: the in-flight agent died mid-run and its tmux session vanished with it. `make install-ttyd` now refuses when the calling shell's `/proc/self/cgroup` sits inside `ttyd.service`; deploy ttyd config from SSH, or restart manually from a non-ttyd terminal.
- **`mailu-imap`/`mailu-smtp` reject plaintext auth** — Roundcube must use STARTTLS (`tls://mail.$DOMAIN:143` / `:587`). The env-derived `ROUNDCUBEMAIL_*` settings in the compose file cannot express the TLS prefix; the override lives in `modules/mailserver/roundcube-tls.inc.php` (included by the image entrypoint) and the compose `extra_hosts` maps the FQDN to the bridge IP.
- **`mailu-admin` 500s on every DB route while the container reports healthy (2026-10-29, recurrence of 2026-10-19)** — `docker logs mailu-admin` shows `sqlite3.OperationalError: unable to open database file` and `/sso/login` answers 500: `/data` was `root:root 0700` while gunicorn runs as uid 100. Root cause was `prep_dirs` chowning `mailserver/data` back to root (its comment assumed the admin runs as root); it now enforces `100:1000`. `make mail-doctor` reproduces it as uid 100, `make mail-fix-perms` repairs it.
- **`mailu-imap` login succeeds but every folder LIST fails — Roundcube shows an empty mailbox / internal server error (2026-11-05)** — `docker logs mailu-imap` shows `Error: mkdir(/mail/<user>): Permission denied (euid=8(mail) egid=12(mail) missing +x perm: /mail, dir owned by 0:0 mode=0700)`: `dovecot.conf` sets `mail_uid`/`mail_gid = mail`, so the imap/lmtp children run as 8:12, but `prep_dirs` kept `mailserver/mail` root-owned by grouping it with front/postfix/rspamd. Auth reads `/data`, not the mail store, so the login redirect (302) looks healthy while the mailbox never loads. `prep_dirs` now enforces `8:12` and `prep_dirs_verify` checks it; `make mail-doctor` probes `/mail` as 8:12 and `make mail-fix-perms` re-owns both stores.
- **mailu-front's `HOSTNAMES` is `mail.$DOMAIN` — the same name its cert covers** — `TLS_FLAVOR=mail` makes the front load `$DATA_DIR/mailserver/certs/{cert,key}.pem`, i.e. the mail.$DOMAIN pair copied from caddy_data, so `HOSTNAMES` must stay the name that cert covers — pointing it at a second name presents clients a CN that does not match the host they connected to. The roundcube container's `extra_hosts: mail.$DOMAIN → 172.22.0.9` plus `tls://mail.$DOMAIN` in `modules/mailserver/roundcube-tls.inc.php` rely on the same identity.
- **Mail DNS records must stay DNS-only at Cloudflare** — MX and the `mail.$DOMAIN` A record are grey-clouded; a proxied record breaks SMTP/IMAP (CF only proxies HTTP(S)).
- **A two-label subdomain cannot be proxied at Cloudflare on the free plan (2026-11-04)** — a proxied A record for `auth.matrix.$DOMAIN` hands every client `error:0A000410: SSL alert handshake failure`: universal SSL covers `$DOMAIN` and one label under it, so the edge holds no certificate for a two-label name. The tells are `curl --resolve <host>:443:$HOST_IP` answering 200 and `openssl s_client -servername <host>` presenting the origin's LE cert while the plain URL fails. Fix: grey-cloud it (`cf_record auth.matrix false`) and serve the origin's own certificate; `admin.matrix`/`admin.mail` are tailnet-only for the same reason.
- **`caddy reload` does not exist here — the global block sets `admin off`** — `docker exec caddy caddy reload --config /etc/caddy/Caddyfile` answers `dial tcp [::1]:2019: connect: connection refused`; the rendered tree is bind-mounted, so `make dok-restart-caddy` (a container restart) is how a vhost change is applied.
- **PTR is provider-side** — only the machine provider can set reverse DNS; the installer now automates MX + SPF + DMARC + the DKIM placeholder, and prints the provider PTR value (`$HOST_IP` → `mail.$DOMAIN`) as numbered follow-up **1** in the success block's follow-up list (shown only when the mail module is on). The live PTR still points at the provider's own hostname, so outbound reputation with Gmail/Outlook stays degraded until it is set (tracked in the Issues tab).
- New `*.$DOMAIN` CF records can appear "down" on tailnet devices: dnsmasq negative-caches the NXDOMAIN if the hostname was queried before the record existed. After creating a CF record, restart dnsmasq (`make systemd-restart-dnsmasq`).
- **Element X says "server not supported — .well-known problem: expected value at line 1 column 1" (2026-11-02)** — the client was given `$DOMAIN`, but nothing serves discovery there: the apex redirects to `www.$DOMAIN` and answers its `ok` stub, so the JSON parser rejects it. The homeserver name is `matrix.$DOMAIN` and nothing serves discovery on `$DOMAIN` (apex included), so install the app with `matrix.$DOMAIN` as the server; the account's ID ends in the same name (`@user:matrix.$DOMAIN`). `matrix.$DOMAIN/.well-known/matrix/client` now carries the homeserver URL and the MAS issuer, so a client that is given the name reads both from one place.
- **Element Admin's login page says "Failed to load the server's well-known document. The server name may be invalid." (2026-11-04)** — the panel is served on `admin.matrix.$DOMAIN` and reads `https://matrix.$DOMAIN/.well-known/matrix/client` from the browser, but that document is answered by the edge (`modules/caddy/vhosts/matrix.caddy`), not by Synapse, and it carried no `Access-Control-Allow-Origin` — Synapse's own routes all do. A cross-origin body without it is discarded by the browser, so the panel calls a perfectly valid server name invalid while `curl` on the same URL returns 200. The edge now sends `Access-Control-Allow-Origin: *` on that file and `make smoke` asserts it (`check_cors`); grep-able tell: `curl -D- -H 'Origin: https://admin.matrix.$DOMAIN' https://matrix.$DOMAIN/.well-known/matrix/client | grep -i access-control` prints nothing.
- **Element says "There was a problem communicating with the homeserver" and the register page "Unable to query for supported registration methods" (2026-11-04)** — Synapse was pinned below the delegated-auth integration: MAS supports Synapse 1.136.0 or later, and `/_matrix/client/v1/auth_metadata` — the document a client and the Element Admin panel read to find the issuer — only exists from 1.123.0, so `/login`, `/register` and `/auth_metadata` all answered `404 M_UNRECOGNIZED`. A client with no auth metadata has nothing to switch to OIDC with, so it falls back to the endpoints delegated auth took away. The bump alone is not enough: Synapse refuses to start while `experimental_features.msc3861` is still in `homeserver.yaml` (`was removed. Use the matrix_authentication_service configuration instead`), so the two blocks are never written together. Tells: `curl -s https://matrix.$DOMAIN/_matrix/client/v1/auth_metadata` answering `M_UNRECOGNIZED`, and `docker logs matrix-synapse` naming the removed `msc3861` section.
- **Element login/signup answers `M_UNRECOGNIZED` and every MAS-minted token answers 503 (2026-11-05)** — two independent layouts. Element's `config.json` carried no `m.authentication`, so it never read the issuer and fell back to `/login/sso/redirect` and `/register`, which Synapse no longer serves; and MAS was pinned at 0.14.1, which predates the shared-secret Bearer introspection Synapse 1.164 sends (0.20.0 is the floor), so `account/whoami` and Element Admin's `viewer.matrix` query failed. Tells: `docker logs matrix-synapse` says `Unable to introspect the access token`, and MAS answers `POST /oauth2/introspect` with `400 Invalid Authorization header`. `matrix-gen` now writes the issuer into Element's config and adds it to an existing one, the matrix vhost forwards MAS's whole compat surface, and the compose file pins MAS 1.28.0. A third symptom of the same stale container: `POST /oauth2/registration` answers `400 invalid_redirect_uri` for Element's `https://chat.$DOMAIN/?no_universal_links=true` (0.14.1's policy rejects a redirect URI carrying a query string; 1.28.0 registers it with `201`), so the sign-in button dies before the authorize request — tell: `docker inspect matrix-mas --format '{{.Config.Image}}'` naming a version older than the pin, since `make render` and `make matrix-gen` never touch a running container. `$DATA_DIR/matrix/mas/config.yaml` is written once and then operator-owned, so a generator change (e.g. the `trusted_proxies` `/32` tightening) does not reach an existing install without editing that file and restarting `matrix-mas`; `make matrix-update CONFIRM=yes` is the version-change path (it dumps the MAS database first).
- **A compose service that moved to another module dir blocks every recreate of its new file (2026-11-05)** — `element-admin` was still owned by the retired `modules/element-admin/docker-compose.yml` project while `modules/matrix/docker-compose.yml` declared it, so `make dok-recreate-matrix-mas` answered `container name "/element-admin" is already in use` and left `matrix-db`/`matrix-element` stopped mid-recreate. Tell: `docker inspect <ctn> --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}'` naming a path that no longer exists. Fix: `docker rm -f <ctn>` (the new project recreates it in the same breath), then `docker compose -f modules/matrix/docker-compose.yml up -d --remove-orphans`; the `--remove-orphans` flag never helps here because the leftover belongs to a different project.
- **A call answers "The server is not configured to work with Element Call … MISSING_MATRIX_RTC_TRANSPORT" (2026-11-05)** — the client never received an SFU. Element Call asks the homeserver for `/_matrix/client/unstable/org.matrix.msc4143/rtc/transports` before it does anything else; Synapse only serves that route with `experimental_features.msc4143_enabled`, and answers `{}` (not a transport list) when `matrix_rtc.transports` is empty or absent. The widget URL is the other half: with no `element_call.url` in Element's `config.json`, the call opens the PUBLIC `call.element.io`, which then asks this homeserver for an SFU and gets nothing — the same error text for a completely different reason. Tells: `curl -s -H "Authorization: Bearer <token>" https://matrix.$DOMAIN/_matrix/client/unstable/org.matrix.msc4143/rtc/transports` answering `{}`, and `docker logs livekit-jwt` staying silent while the error is shown. Once the transport exists, audio/video still needs UDP 7882 (+ TCP 7881) open at the firewall — a call that connects and then carries nothing is those ports, not the signalling.
- **A call answers `[500] Unable to create room on SFU (https://livekit-jwt.matrix.$DOMAIN/sfu/get)` (2026-11-06)** — `livekit-jwt` could not reach the SFU. `lk-jwt-service` builds its `https://…/twirp/livekit.RoomService/CreateRoom` endpoint from `LIVEKIT_URL`, so when that variable still names the pre-rename host (`wss://livekit.$DOMAIN`, while only `livekit.matrix.$DOMAIN` has DNS and a vhost) room creation dies at DNS and the handler returns 500 — the browser leg is fine because `homeserver.yaml`'s `matrix_rtc.transports` was renamed. Tells: `docker logs livekit-jwt` shows `dns error: failed to lookup address information: Name has no usable address`, and `docker inspect livekit-jwt --format '{{range .Config.Env}}{{println .}}{{end}}' | grep LIVEKIT_URL` still prints the old name. The variable is read at container start only: rename it in the compose file and recreate the container.
- **A rewritten `$DATA_DIR/matrix/element/config.json` never reaches the container (2026-11-05)** — the element service bind-mounts that single file, so `mv`-ing a new copy into place swaps the inode while the container keeps the deleted one: the host file looks right, `curl https://chat.$DOMAIN/config.json` still serves the old body, and a feature flag (e.g. `feature_login_with_qr`) appears to do nothing. Write through the existing inode (`cat new > config.json`, as `matrix-gen` now does) or restart `matrix-element`. Tell: the host file and the served body disagree — `jq .features <host path>` versus `curl -s https://chat.$DOMAIN/config.json | jq .features`.
- **`make matrix-*` dies with "admin login failed (403)" though the containers are healthy (2026-11-02)** — the admin bot in `modules/matrix/.env` was never created: the installer's registration step reported `already exists` for ANY non-zero exit (a refused create and a successful one are the same code), so a run where the create failed looked green and every recipe afterwards failed to authenticate. `matrix_setup` now checks the account exists in the MAS database and fails the module's row when it does not. Repair without a reinstall: `docker exec matrix-mas mas-cli manage -c /data/config.yaml register-user --yes -a -p "$SYNAPSE_ADMIN_PASSWORD" "$SYNAPSE_ADMIN_USER"` with the credentials from `modules/matrix/.env`, then `make matrix-flag-admin USER=<name> ADMIN=true`.
- A module's containers can disappear without the module being uninstalled (image prune, `compose down`, a wiped docker store). `scripts/stack/stack-up.sh` used to gate recovery on container existence alone, so boot logged `skip (not deployed)` and the stack reported healthy while the module stayed gone; the gate now also reads `wizard.state`'s `enabled_modules` and recreates what the installer deployed.
- **The module prompt rejected every module except the first and last (2026-11-04)** — `_state_modules` prints the roster one name per line, but `ask_modules` matched the answer against `" $mods "`; with newlines as separators only the first and last entries could match, so a valid middle selection looped on `unknown module: <name>` (or, on a repair, the saved `MOD_*` set skipped the prompt entirely). The roster is now normalized to one space-separated line (`paste -sd' '`) and the prompt is asked on every run.
- Rate limiting is a plugin, not a Caddy feature: `modules/caddy/Dockerfile` bakes in `caddy-ratelimit`, the `(ratelimit)` snippet in `modules/caddy/Caddyfile` limits each client to 240 requests/min per vhost (zone per site, 429 when exceeded), and removing the `--with` line makes Caddy refuse to start on `unrecognized directive: rate_limit`. Each site imports the snippet once. Directive order matters: the apex `www.caddy` site wraps `import ratelimit` and `redir` in one `route` so the limiter counts the redirect, and every tailnet-only site (`vault`, `admin.mail`, `ttyd`) wraps the gate + limiter in `route` with `respond @not_tailnet 403` FIRST — otherwise a refused flood spends the zone window and turns a 403 door into 429. Validate a rendered config with `docker run --rm -v $DATA_DIR/rendered/caddy:/etc/caddy:ro <built image> caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile` (a stock `caddy:2.11.4` image always fails there — the plugin is missing).
- Web logins are jailed from Caddy's own access log, not from the apps: the vhosts for vault, kuma, mail(roundcube), cloud(ocis), blog(writefreely), photos(immich) and chat(element) write `/var/log/caddy/<app>.log`, which is the host's `$DATA_DIR/logs/caddy/` bind-mounted into the edge, so the files survive a container recreate. `config/fail2ban/filter.d/caddy-auth.conf` matches 401/403/429 on a login URI, and one `jail.d/web-<app>.conf` per app points at that app's file — so a ban is scoped to the endpoint that was hammered. `make install-config` copies the filter and a jail only when its `logpath` exists: a jail with a missing log file makes fail2ban exit 255 and takes the sshd jail down with it.
- Tailscale is installed from its signed apt repository (`pkgs.tailscale.com/stable/debian`, keyring + sources list), never `curl … | sh`: a script piped into a shell runs unseen with root. `scripts/install/wizard.d/tasks/04-tailscale.sh` is the only place it is installed; the vendor's goose installer remains the one exception, recorded here because goose ships no apt repository.
- The A records the doors depend on are written by the installer's DNS task, so a module enabled afterwards (or a run that stopped before it) leaves a healthy container with NO name — `curl` by IP works, every client sees a resolution failure. `make dns-sync` (`scripts/ops/dns-sync.sh`) re-runs the installer's own convergence (`cf_dns`) against `wizard.state`, so there is one rule set for the zone; it reads the token from `wizard.state` or `$DATA_DIR/caddy_data/CF_API_TOKEN` and never prints it.
- The Makefile sets `SHELL := /bin/bash` explicitly. Without it, recipes run under `/bin/sh` (dash on Debian) and `set -eu` semantics differ — `dash` aborts on any unset variable reference, while `bash` only aborts on expansion failures. If you see `parameter not set` from a recipe, the Makefile shell setting is the first place to look.
- **`USER` arrives from the environment in every login shell, so make must not trust it** — `USER=root` is exported by the shell and make imports the whole environment, which would make `make kuma-del-user` (no `USER=`) delete `root` instead of printing its usage line. The Makefile blanks the inherited `USER` once at the top, so every account-targeting recipe (`kuma-*`, `matrix-*`, `mail-manager`) takes the name from the command line only; a command-line `USER=` still wins.
- Cloudflare's free tier rate-limits rate-limit rules to a 10s min window. Plan ahead if a public endpoint ends up attracting more traffic than expected.
- **Every Caddy vhost has its own TLS block** — don't reintroduce a shared wildcard cert. The wildcard CF Origin cert at `$(REPO)/certs/` covered `*.$DOMAIN`, so a vhost without its own `tls` directive would pick up the wildcard as a SNI fallback and the per-vhost ACME automation policy would never fire. Lesson: a vhost with no `tls` directive appears to "use ACME by default" but actually picks up any loaded cert that matches the SNI.
- **A stale Tailscale split-DNS `$DOMAIN` route pointed at a departed node takes the whole edge down (lesson 2026-10-14)** — symptom: `make smoke` fails every vhost with HTTP `000`, `tls:<host>` shows an empty issuer, `data/caddy_data/caddy/certificates/` is absent, yet `caddy` is up, listening on `*:80`/`*:443` with resolved vhosts. Root cause: the tailnet split-DNS route for `$DOMAIN` still pointed at an old node IP no longer in `tailscale status`, so the host (resolver `100.100.100.100`) could not resolve the domain and ACME's DNS-01 self-check for `_acme-challenge.$DOMAIN` timed out. Diagnose: `tailscale dns status` (Split DNS Routes block) + `getent hosts cloud.$DOMAIN` (times out) vs `dig @100.100.100.100 example.com` (answers). Fix: repoint the route at this node's tailnet IP (or delete it) in the Tailscale admin console, then `make dok-restart-caddy` — issuance retries per handshake. The `modules/caddy/Caddyfile` default logger now writes to `stderr` (bounded by the compose log cap) instead of `/dev/null`, so `docker logs caddy` shows the ACME lines.
- **Caddy stock `caddy:2.x` doesn't include `caddy-dns/cloudflare`** — needs a custom `xcaddy` build (see `modules/caddy/Dockerfile`). Also: `caddy-dns/cloudflare` v0.2.3 rejects the new 53-char CF token format with a generic "API token appears invalid" error during plugin provisioning — pull from `caddy-dns/cloudflare@a8737d0` (master) until a tagged release ships the regex fix.
- **`caddy:2.11.4` requires Go ≥ 1.25.1** to build — the `golang:1.25-bookworm` image satisfies this. Older builder images (e.g. `golang:1.24-bookworm`) fail with `go: github.com/caddyserver/caddy/v2@v2.11.4 requires go >= 1.25.1`. If you bump Caddy, check the new `go.mod` `go` directive and bump the builder image too.
- **`network_mode: host` is required for `@not_tailnet` to work.** Docker DNAT rewrites every packet to `172.22.0.1` (the bridge gateway) before Caddy sees it. Without `network_mode: host`, the `100.64.0.0/10` matcher matches nothing and every tailnet request gets 403. This is set in `modules/caddy/docker-compose.yml` — do not "fix" it.
- **`docker compose env_file:` reads the file as the UID running `make`, NOT as the UID inside the container** — compose parses `env_file:` at the host side. The `CF_API_TOKEN` file must be readable by the user running the compose command (`root`), mode 0644; chowning it to the container's uid (201) breaks the read and Caddy ends up with no token. The **directory** needs `+x` for `root` too: `caddy_data` is chowned `201:201` for the container, so the installer sets it to `0711` — under the root umask's `0700` the compose read dies with `open …/caddy_data/CF_API_TOKEN: permission denied` *even though the file itself is `root`-owned 0644*, and Caddy never starts (which then cascades: no LE certs → mailserver restart-loops on its missing `mail.$DOMAIN` cert → DKIM keygen fails).
- **`scripts/ops/optimize.sh` bugs found live on the external machine (lesson 2026-09-10)** — (1) `append_lines()` re-appended the **whole** file before the new lines, so every call doubled the target: it duplicated `/etc/fstab` and `/etc/security/limits.conf`; the doubled fstab then made the noatime `sed` (a pattern built from file content) match nothing, so the remount "failed" and reverted — now only the missing lines are appended and the mount line is rewritten with `awk`. (2) re-checks assumed a full stack: `recheck limits` tested the current shell's `ulimit` (can't change until a new login → permanent false failure) and `recheck docker` ran `docker info` on a box without docker — now limits are checked via the config a new login reads, and absent software is skipped. `bash scripts/ops/optimize.sh --verify` is the way to prove a host is converged.
- **`fs.protected_regular=2` silently blocks root writes in /tmp (lesson 2026-09-12)** — when a root-run script does `: > /tmp/file-owned-by-root` (O_CREAT on an existing file owned by another uid in a sticky world-writable dir), the kernel returns `Permission denied` **even for root**, with no log anywhere. It looks like an immutable file or a broken script; it's the kernel's symlink/hardlink-attack mitigation. Repro: `sudo : > /tmp/x` where x is root-owned. When testing scripts with temp files, either write to a non-sticky dir (`mkdir -p /tmp/subdir && chmod`), pre-chown the file, or expect EACCES on cross-uid creates in /tmp and /var/tmp.
- **A lingering test container can poison every later probe (lesson 2026-09-12)** — while iterating on a port-bound service, an earlier `timeout 150 docker run … --name <svc>-test` was still alive and holding the port; three "fix attempts" appeared to change nothing — because every probe hit the OLD broken container, and the new container's log showed `FAILED TO BIND: Address already in use` (easy to miss under a wall of startup output). Rule: before debugging a port-bound service, `docker ps -a` + `ss -tlnp | grep <port>` and remove every stale test container; treat "FAILED TO BIND" in the log as the primary signal, not the connect errors.
- **Bash array pitfalls that produced real uninstall.sh bugs (lesson 2026-09-12)** — (1) `arr=("${EMPTY[@]:-}")` with an empty array creates a **one-element array containing the empty string**, not an empty array — the loop body runs once with a bogus empty item (`bad array subscript` on an associative lookup). Use `arr=(); [ ${#SRC[@]} -gt 0 ] && arr=("${SRC[@]}")`. (2) Nested name construction `${RM_MOD_${k^^}:-false}` is a **bad substitution** in this bash — build the name first and use indirection: `v="RM_MOD_${k^^}"; [ "${!v}" = true ]`. Both compile fine under `bash -n`; they only explode at runtime — test with real data, not just syntax checks.
- **`scripts/ops/optimize.sh` — the host tuner** — fully automatic, **zero prompts** (every choice auto-detected or env-overridable). sysctl (BBR, buffers, dirty ratios, swappiness, `kernel.nmi_watchdog=0`, `sched_autogroup_enabled=0`, `vm.min_free_kbytes` = 1% of RAM computed live, `kernel.core_pattern=/dev/null`, THP=madvise incl. `defrag` via `/etc/tmpfiles.d/99-optimize.conf`), limits (nofile 65535 + `DefaultTasksMax=infinity`), journald caps, apt speed, **swap auto = RAM/3 rounded up, recreated only when the live size differs**, `noatime,nodiratime` auto on `/`, apt autoremove/clean + docker prune (make-cleanup style, no backup pruning), and **`tuned` (profile via `tuned-adm recommend`) + `irqbalance` + `earlyoom`** (the only packages the script installs — performance helpers; service software is never installed). **SSD/HDD auto-detect** (nvme name → ssd; `rotational=0` → ssd; discard support → ssd; else hdd): SSD gets fstrim, HDD gets SETRA readahead (256 kB via `/etc/udev/rules.d/99-readahead.rules`), fstrim off. **tuned/sysctl cooperation**: tuned applies first, then `/etc/sysctl.d` overrides conflicting keys — that's tuned's own behavior (its sysctl plugin re-applies `sysctl --system` and defers to it, verified in `/var/log/tuned/tuned.log`); `tuned-adm verify` reports diffs on those keys **by design**. Opt out: `WITH_TUNED=0` / `WITH_IRQBALANCE=0` / `WITH_EARLYOOM=0` / `NOATIME=0` / `SWAP_GB=0` / `SETRA=0`. Backups under `/root/optimize-backup-*`; re-running is a no-op; `--verify` proves the convergence. Left by design: fstrim (disk detected hdd — `FORCE_FSTRIM=1` if SSD-backed VirtIO), service pruning (targets not installed). Requires root only — pure bash.
- **Two `$DOMAIN` containers (one named `<id>_$DOMAIN`) = a force-recreate that died mid-swap** — compose v5.5.0 creates the replacement under `<old-container-short-id>_$DOMAIN` and only frees the canonical name afterwards; if the run is interrupted between "create new" and "remove old" (e.g. Ctrl-C during the slow xcaddy rebuild), the next `up` starts both → two host-network Caddys on :80/:443 via SO_REUSEPORT sharing one cert store. Fix: `docker rm -f` the stale one, `docker rename` the survivor to `$DOMAIN`, then `make dok-recreate-caddy` + `make smoke`.
- **`make dok-recreate-caddy` (or `make dok-recreate-all`) takes ~3 minutes on a fresh machine and prints zero progress** — `docker compose up --build` runs `docker build` in a streaming-tty mode that buffers until the step finishes. The build chain is `golang:1.25-bookworm` → `go install xcaddy` → `xcaddy build --with caddy-dns/cloudflare@a8737d0 v2.11.4` → `FROM caddy:2.11.4` + `COPY --from=builder`. `docker build --progress=plain` shows the steps.
- **The cert's issuer is the only reliable indicator of which path it took** — `curl -sk` returning 200 means "the listener responded", not "the right cert was served". Check `openssl x509 -noout -issuer` on a fresh `-no-keepalive` handshake. On CF-proxied hosts (every public vhost) the handshake sees Cloudflare's edge cert (issuer `Google Trust Services WE1`), not the origin's — check the origin cert with `openssl s_client -connect 127.0.0.1:443 -servername <host>` from the host instead (issuer should be `Let's Encrypt`).
- **One vhost's ACME order can stall behind Caddy's retry backoff (2026-09-22)** — on a fresh deploy every cert issued except `kuma.$DOMAIN`; `caddy validate` was fine and `/data/caddy/locks/issue_cert_kuma.{{DOMAIN}}.lock` kept getting touched while no cert dir appeared. Nothing surfaces because the global block sets `log { output file /dev/null }`; one `docker restart $DOMAIN` re-attempted the identifier and it issued in ~13 s. The installer's `issue_certs` now restarts Caddy once when any host is still pending after the poll. To read the ACME errors, temporarily set the global `log` output to `stderr` in `modules/caddy/Caddyfile` (bind-mounted, so a container restart picks it up), then restore it.
- **`flask mailu domain` creates no DKIM key, and `config-export` hides it (2026-10-19)** — the CLI only inserts the domain row; the private key is written to `/dkim/<domain>.<selector>.key` and `config-export -j` omits `dkim_key`, so parsing the export finds nothing. Generate through the ORM in `mailu-admin` (`Domain.generate_dkim_key()`, then read `dkim_publickey`) and publish `v=DKIM1; k=rsa; p=<publickey>` as `dkim._domainkey` — that is what `dkim_setup` does. `flask mailu --help` additionally trips a Flask 2.2 context-pop assertion, so probe the CLI with `config-export -j`, never `--help`.
- **`INITIAL_ADMIN_MODE=update` silently reverts the Mailu admin password (2026-10-19)** — `mailu-admin`'s `/start.py` runs `flask mailu admin … --mode $INITIAL_ADMIN_MODE` on **every** container start; `update` re-hashes `INITIAL_ADMIN_PW` from `modules/mailserver/.env`, so a password changed at `mail.$DOMAIN/admin` or via `make mail-admin-password` comes back as the `.env` value after the next restart/recreate. The mode now seeded (and force-corrected on repair) is `ifmissing`: the admin is created once, then the DB hash is the only source of truth — no `.env` sync, no reset. Only the modes `create`/`ifmissing`/`update` exist (`/app/mailu/manage.py`).
- **mailu-front answered 404 on every path (debug hell 2026-10-19)** — mailu-front's own nginx had no `/admin` route: the image's template (`/conf/nginx.conf`) emits `location {{ WEB_ADMIN }}` only inside `{% if ADMIN %}` and reads `WEB_ADMIN`/`WEBROOT_REDIRECT` straight from the environment (`/config.py` defaults none of them), so `/` fell through to `try_files $uri =404`. `ADMIN_ADDRESS` is not enough — it only feeds `set $admin …:8080;`. The keys live in `modules/mailserver/docker-compose.yml`; the front reads env at start, so a change needs `up -d front`. Check the edge too: `admin.mail.$DOMAIN` proxies 172.22.0.9 (mailu-front), `mail.$DOMAIN` proxies 172.22.0.10 (roundcube) — pointing a door at the other IP serves Roundcube under both names.
- **mailu-front's healthcheck cannot use `ss`, `nc` or `grep` (2026-10-19)** — `ghcr.io/mailu/nginx` ships shell builtins only, so `ss -tln | grep …` prints `/bin/sh: ss: not found` and the container stays `unhealthy` forever. The probe in `modules/mailserver/docker-compose.yml` reads `/proc/net/tcp` instead (state `0A` = LISTEN; hex 0019/01D1/024B/03E1 = 25/465/587/993), and its `$` must be written `$$` or compose interpolates it to blank with a WARN.
- **Host `ps` lists container processes** — `node server/server.js` (`docker-<id>.scope` = uptimekuma) and the Mailu daemons (`postfix`, `dovecot`, `rspamd`, `python3`) are container processes visible in the host `/proc`, not stray host daemons. Check `/proc/<pid>/cgroup` (or `docker ps --no-trunc`) before calling a process unknown.
- **Host performance tuning** — network stack (`config/sysctl/99-kefo.conf`): BBR + `fq` qdisc, `tcp_fastopen=3`, `tcp_slow_start_after_idle=0`; Docker (`config/docker/daemon.json`): pull concurrency 10/10, `userland-proxy: false` (no compose publishes ports, so no behavior change); dnsmasq (`config/dnsmasq/10-tailnet.conf`): `cache-size=10000`. Kernel exposure in the same file: `kernel.yama.ptrace_scope=1` (ptrace limited to descendants — the agent holds provider keys in memory), `kernel.kptr_restrict=2`, `kernel.dmesg_restrict=1`; `net.ipv4.conf.all.rp_filter` is deliberately left at 0 because the exit-node routing needs it.
- **"Skipping updater backup clean-up" is benign** — it means `/data/updater-<instanceid>/backups` (the web updater's rollback copy of the old codebase) does not exist yet, i.e. no update has run through the updater; the installer pre-creates the directory so the job stays quiet.

- **`make smoke` can fail a check whose curl works by hand (debug hell 2026-10-19)** — `scripts/stack/smoke-vhosts.sh` runs `set -o pipefail`, and `curl … | grep -q …` makes `grep` exit at the first match, so curl dies with SIGPIPE (23) and the pipeline status becomes curl's — the `if` takes the FAIL branch even though the pattern matched. Grep-able tell: `bash -x` shows the curl, the manually run identical curl prints the match, the check still FAILs. Fix: capture the body in a variable and `grep -q` on a here-string, never pipe curl into `grep -q` in that script.
- **A rendered single-file bind mount keeps the OLD inode (lesson 2026-10-19)** — `make render` used `rsync` (temp file + rename), so `roundcube` kept reading the previous `roundcube-tls.inc.php` (host file 1434 bytes/new, container 942 bytes/old — `stat` shows different inodes) until the container was restarted. `render-all.sh` now rsyncs the mail platform tree with `--inplace`; the same trap applies to any compose file that mounts a single rendered file rather than a directory.
- **Recreating `mailu-imap`, `mailu-front` or `roundcube` breaks every active webmail session** — roundcube sessions are DB-backed (the UI keeps rendering "logged in") but the IMAP connection dies with the container, so users hit "Connection to IMAP server failed" until they log in again. Warn the operator before recreating them; the fix is a re-login, never a config change.
- **The edge guardrail** — app vhosts (cloud/vault/kuma/mail) must serve their real app: the pre-commit hook (installed by the installer on every run; `make install-hooks` to re-run it manually) refuses any commit whose identity is not the logged-in GitHub account, blocks a bare `respond "ok"` in them (www and tail are exempt by design — www serves the operator's static pages, tail serves the tailnet home; a vhost another project installs is guarded by the pre-push smoke instead), runs `caddy validate` on staged `modules/caddy/` changes; the prepare-commit-msg hook auto-splits a staged change wider than the per-commit file limit; the pre-push hook refuses a pushed range with a non-GitHub identity, auto-splits over the pushed range, refuses a branch that would land as an empty merge or arrive CONFLICTING at a renamed path (`pr-guard.sh`), and runs `make smoke`. `EDGE_OVERRIDE=1` (pre-commit only) is the sole operator-approved override; the pre-push smoke has NO bypass — it runs only on a finished install (`wizard.state` `finished=true`). After any `docker restart caddy` / `make dok-recreate-caddy`, run `make smoke`.

- **Repo paths and instance paths never share a name** — `config/` is a skeleton that must be rendered before it is used; `data/` is instance state that is never edited as config. Web pages live only as instance data in `$DATA_DIR/pages/<vhost>/` (never in the repo), the goose env is `$DATA_DIR/goose/.env`, and the uninstall log is `$LOG_DIR/uninstall.log`.
- **`config/dnsmasq/10-tailnet.conf` carries a PLACEHOLDER address, never the live one (lesson 2026-09-22)** — the tracked file says `listen-address=100.64.0.1` (a CGNAT address that is nobody's node); `make install-config` / `make install-dnsmasq-conf` rewrite that literal to the live Tailscale IPv4 at deploy time. Never copy the tracked file verbatim to `/etc/dnsmasq.d/`: dnsmasq then fail-loops with `failed to create listening socket for 100.64.0.1: Cannot assign requested address` and takes tailnet DNS — and with it `ttyd.$DOMAIN`/`vault.$DOMAIN`/`mail.$DOMAIN` — down. The placeholder is a fixed literal on purpose (it used to come from a `TAILNET_SUBNET` instance value, which meant the tracked file contained a real address).
- **A module that is not installed has no route — never report it as "tailnet-only" (lesson 2026-09-22)** — `vault.$DOMAIN` answered 502 and the closing report called the vhost "tailnet-only"; the truth was that the `vault` module simply was not in `enabled_modules` in `wizard.state`. Grep-able symptom: a 502 with no container. Fix the report, not the system: `make fetch` (`modules 8 / 9 enabled`), `make fetch-more` (`routes` + `!dead` rows) and `make smoke` (buffered into the end "Not installed / ignored" section) all carry the right words now. See "Module state vs route exposure".
- **The web roots are INSTANCE DATA and must NOT be mounted inside the rendered config mount** — `modules/caddy/docker-compose.yml` mounts `${DATA_DIR}/pages:/srv/pages:ro` (a plain sibling path) alongside `${DATA_DIR}/rendered/caddy:/etc/caddy:ro`. Nesting it under `/etc/caddy` is a hard failure on current Docker/runc: mounting the parent read-only first makes runc `mkdir` the nested mountpoint *inside* that read-only filesystem and the container dies at create time —
  `error mounting ".../data/pages" to rootfs at "/etc/caddy/pages": ... mkdirat .../merged/etc/caddy/pages: read-only file system`
  so Caddy stays `Created`, never listens, and every ACME cert stays unissued (one bug, seven error tags on the 2026-09-25 fresh install). Pre-creating the dir in the image does not help — only de-nesting does. Symptom if the mount is missing entirely: every static page falls through to the `respond "ok"` stub.
- **An uninstalled module's own state is invisible to the edge (2026-09-22)** — `stack-up.sh` derives its unit list from the live containers, and the tail catalogue only lists routes that exist, so a module removed from `enabled_modules` neither starts nor appears anywhere. That is the designed behaviour; the only visible trace is the dead vhost line `make fetch-more` prints.
- **The module writer used a bad substitution → empty module record → muted smoke (2026-10-04)** — the installer tested `[ "${MOD_${m^^}:-true}" = "true" ]`; nested `${m^^}` inside a variable name is not valid bash, so the test errored and no module was ever recorded — a fresh install then ran with an empty record, `make fetch` reported every module "not installed", and `make smoke` muted every module section and kept real failures OUT of its exit code. Grep-able tell: `make fetch` shows `modules 0 / 9 enabled` while all containers are up. Fix: `local _mod="MOD_${m^^}"; [ "${!_mod:-true}" = "true" ]` (build the name first, indirect it — same pit as the documented bash-array `${RM_MOD_${k^^}}` bug).
- **Mailbox gaps are silent, so `mailbox_add` verifies against Mailu's own export (2026-10-15, Mailu-era 2026-10-19)** — `flask mailu user` and `config-update` write to the admin container's SQLite with no useful exit signal, so a check based on a CLI row format (the old docker-mailserver `setup email list` regex) can report a mailbox missing while it exists. `mailbox_exists` now matches `localpart@domain` against `flask mailu config-export -j` with `jq`, `mailbox_add` logs the CLI output and re-verifies for 90 s, and `mail_wait_ready` probes a real command (`config-export -j`) — never `flask mailu --help`, which trips a Flask 2.2 assertion in Mailu 2.0. Grep-able tells: a reported-missing mailbox that `make mail-card` finds, or an admin container that answers `docker exec true` while every write fails (recreate it; the config store is not writable).
- **A push is blocked until the install is `finished` (2026-10-15)** — `make smoke` refuses to run unless `data/wizard.state` records `finished=true`, and the pre-push hook (installed by the installer, or `make install-hooks` on any other clone) runs `make smoke` with NO bypass. Grep-able symptom: `pre-push: vhost smoke test FAILED` while the edge is actually serving, or `smoke: wizard.state is not finished ('absent')`. Cause: a host that never completed an install (or a fresh clone) has no `finished` checkpoint, and nothing but the installer may write it. Takeaway: finish an install before pushing from a host that has the hook installed; installing the hook on a dev host that is not a finished install makes every push fail by design. The pre-commit side keeps its operator override `EDGE_OVERRIDE=1`; the pre-push side has none.
- **A hook must read its stdin before it runs anything else (2026-10-28)** — the pre-push hook ran the vhost smoke first, and the smoke's `openssl s_client -connect 127.0.0.1:993 -quiet` drains stdin (it forwards it to the connection). Git feeds a hook a PIPE, so the ref list was gone: `read` hit EOF, the per-ref loop never ran, and every pre-push guard (identity scan, history audit, rewrite warning) was skipped while the hook still exited 0 — a push could publish a bundle and print no pre-push line at all. Testing it with `< refs.txt` hid the bug, because reopening `/dev/stdin` on a regular file restarts at offset 0 while a pipe stays drained. Takeaway: `refs=$(cat)` first, then `done <<< "$refs"`, and run the smoke with `</dev/null`.
- **The edge must mount the RENDERED tree, not the tracked one (lesson 2026-09-22)** — `modules/caddy/docker-compose.yml` mounts `${DATA_DIR}/rendered/caddy`. Point it at `./` (the tracked dir) and Caddy does not error: the skeleton's site blocks literally say `https://www.{{DOMAIN}}`, so Caddy starts, binds 80/443, passes its `caddy version` healthcheck and serves **nothing** — every probe returns `000`, `curl -sk` gives no reply and `docker logs caddy` is empty. Symptom to grep for: edge healthy + every vhost `000`. Fix: `make render` then `make dok-recreate-caddy`; `scripts/stack/stack-up.sh` renders first in every mode and `--validate` catches a config that will not load.
- **Every log the project writes lives in `$LOG_DIR` (`$DATA_DIR/logs`, repo-relative — no `$GITHUB_USER` namespace), one logrotate file, nothing chronicle-style (2026-09-22)** — `wizard.log`, `uninstall.log` and any module log share the directory; the edge's per-app access logs live in `$LOG_DIR/caddy/` and rotate with `copytruncate` because Caddy keeps them open. Because a full teardown deletes `data/` mid-run, `wipe_data()` copies `uninstall.log` to `/var/tmp/uninstall-<stamp>.log` and continues logging there — the record survives the teardown it describes; the installer relocates any legacy log path into `$LOG_DIR` on first run and never deletes it.
- **A crashed installer reports stale error tags, and a missing `$LOG_DIR` fakes a `render` failure (2026-09-25)** — a run died in `prep_dirs` with `ROOT: unbound variable` (the installer named the checkout root `$REPO` while its own `$ROOT/data/...` paths kept the repo-wide `$ROOT`; `set -u` then exits, and the `trap summary EXIT` re-prints the persisted `ERR_TAGS` from `$DATA_DIR/wizard.state` — so tags from earlier in the run appear as if current). The `render` tag next to it was false: `write_instance_conf` logs and renders into `$LOG` **before** `phase_host` created `$LOG_DIR`, so the `>>"$LOG"` redirection failed, the renderer never ran, `|| fail render` fired and two log lines vanished. Tell: when a tagged error looks unrelated, grep `wizard.log` for the output the step should have produced (and for its first lines) — the step's output being *absent* is the evidence, not its presence. `ensure_runtime_dirs()` now creates `$LOG_DIR` and tightens `$DATA` (0600 state) before anything redirects into them.
- **`ssh … | grep -q` is always false under `set -o pipefail` when ssh exits non-zero (2026-09-25)** — `ssh -T git@github.com` prints "successfully authenticated" but exits **1** (no shell access), so the installer's GitHub key test reported "not authorized" on a key that worked; the fix is to capture the output first and grep the variable. Any `cmd | grep -q` line in these scripts inherits the trap: pipefail makes the pipeline's status the *left* command's.
- **`make fetch-more` stopped mid-screen for a minute with no error (debug hell 2026-11-11)** — the run printed the disk header and then nothing: one serial `du -sh data/*/` walked `data/photos` + `data/ocis` (the bulk of the instance's files) while every later row sat behind it, and a wedged daemon socket (`docker stats`, `tailscale status`, `journalctl`) could block a row forever. Locate the stall with `BASH_ENV` (a file holding `PS4='+${EPOCHREALTIME} '`) plus `bash -x`: `PS4` is NOT imported from the environment, `BASH_ENV` is. Fix: the per-directory `du` runs in parallel under a budget (`bigdirs` in `scripts/info/fetch-more.sh`), and every daemon/tree probe goes through `tmo <seconds>`, printing `?` when it misses its budget. Grep for `tmo` / `bigdirs`.
- **`make fetch-more` reported two permanently-failed host units (2026-10-16)** — `openipmi.service` (`LSB: OpenIPMI Driver init script`, fails with `Starting ipmi drivers ipmi failed!` — the box has no IPMI hardware) and `systemd-networkd-wait-online.service` (`Timeout occurred while waiting for network connectivity` after 2 min — networkd is active but `networkctl` shows every link `unmanaged`, so no interface can ever satisfy it). Both are distro units, not repo services: the installer's `disable_benign_failed_units()` (called from the Host Services task) disables exactly these two and clears their failed state, so `systemctl --failed` (`make fetch-more`) stays clean and boot skips the dead 2-min wait — re-enable manually with `systemctl enable …`. It touches only these two known units (never a blanket `reset-failed`, which would hide a real one); distro- or hardware-dependent units like these are the only ones it manages.
- **A checklist write that does not return the cursor to column 0 concatenates rows (debug hell 2026-10-16)** — symptom: late in the install two rows mash into one line, e.g. `Repository Managementent[   $    ] [EXEC] Repository Management[…][DONE] DNS Records`, only after the block has scrolled. Root cause: `_task_update`/`_note` end each row with a bare `\n`, which returns to column 0 **only while the tty does NL→CRNL (ONLCR)**; anything that runs the terminal without ONLCR leaves the cursor mid-line and every later row is appended after the previous (a *wrapped* note miscounts `_TAIL` the same way — one logical line counted as one row while it occupies two). Fix: every block/note write now opens with an explicit CR, `_note` counts **physical** rows (width from `stty size`, ANSI stripped), and `_tasks_draw` re-asserts `stty onlcr icrnl` before drawing. Recognise it by a `[EXEC]`/`[DONE]` row that begins mid-line rather than at column 0. Uncounted output does the same one row at a time — a command whose error escapes to the console instead of `$LOG` (e.g. a `chown` on a non-existent path) shifts every later animator frame, so a row that ended `[FAIL]` is painted over by an `[EXEC]` frame; check every command inside a task body redirects to `$LOG`. Repro without a real install: `sed -n` the block out of the installer, source it under `script -qec` with `stty -onlcr`.

- **Declaration-detection probes must not count repo files (2026-10-18)** — `write_state()` counted the module's compose file existing in the checkout as "detected", which is always true for every declared module, so `declared != detected` warned on every run; leftover data dirs/rendered vhosts from an uninstall confirmed it too. Confirmation is now only "the module's container is running"; data/vhost are still printed as leftovers.
