# Sandbox modules

Try an app on the live stack without touching the repo. `scripts/sandbox/editor.sh` builds a parallel, isolated module stack in `data/sandbox/` (gitignored, so nothing it creates can ever be pushed), reusing the running stack's network, edge and rendered config. Use it to **backtest a module before contributing it** to `modules/`, or to **run custom apps for personal use** without risking a broken repo or a broken stack.

## Why it is safe

- Everything the helper creates lives in `data/sandbox/` — repo files are never written, so `git status` stays clean and an upstream push can never carry sandbox content.
- The stack is not reinstalled: sandbox containers join the existing external `net` bridge and are reached through the running Caddy edge, which is the only host-network container.
- The compose contract is enforced before a single container starts (see below), so a sandbox module cannot publish ports, escape its namespace, or hog memory.
- `restart: unless-stopped` is mandatory, but only the repo's `modules/*/` are globbed at boot — so sandbox modules survive a reboot and rejoin `net` on their own, without ever being registered in the stack.

## A sandbox module can own a public name

A trial app usually ends up behind a real hostname. Its vhost must live in `modules/caddy/vhosts/` (`{{DOMAIN}}`-templated) rather than `data/sandbox/caddy/`, because `make render` rsyncs the rendered tree with `--delete` and a sandbox-only vhost is wiped — the running edge keeps serving it only until its next restart. One vhost per name: when a module is promoted into `modules/`, the sandbox copy is deleted in the same change.

A module that a name depends on does not stay a sandbox module for long. oCIS served `cloud.$DOMAIN` this way and Snikket served `chat.$DOMAIN`; both are now repo modules (`ocis`, `xmpp`) because a sandbox module has no installer step and no backup coverage.

## Commands

Run `bash scripts/sandbox/editor.sh` for the list. `create` collects every answer before it acts; `remove` confirms before each destructive step. `list`, `validate` and `sync` are non-interactive; `backup` asks which module.

| Command | What it does |
| --- | --- |
| `create` | asks, renders, starts one module and wires its door |
| `remove` | takes a module down and clears every trace of it |
| `list` | per-module host, exposure, address, running state, data size |
| `validate` | re-checks every recorded module against the compose contract |
| `sync` | re-applies sandbox vhosts after `make render`, revives stopped projects |
| `backup` | tarball + sha256 of one module's data, under `data/sandbox/backups/` |

`make sandbox-sync` is the `sync` command as a recipe — run it after any `make render`, which rsyncs the rendered Caddy tree with `--delete` and so drops the injected vhosts.

The helper bootstraps its own tree on first use: `data/sandbox/{lib,tasks,flow,templates,modules,state,caddy,backups}`, and stamps it with the sha256 of the `editor.sh` that wrote it (`data/sandbox/.stamp`). A tree written by a different `editor.sh` is refreshed in full before anything is sourced, so an older copy can never shadow a fix — that stale copy is what used to fall back to the usage message. Between script changes the files are yours: later runs leave them alone, and `bootstrap --force` restores the shipped version.

## The compose contract

A sandbox module is rendered from `data/sandbox/templates/docker-compose.yml.tmpl` and validated on docker's **normalised** config (`docker compose config`), never on a YAML grep:

- no `ports:` — services are reached through the edge;
- a pinned `ipv4_address` on `net`, allocated from the subnet's first free address;
- `restart: unless-stopped`, plus `mem_limit` and `memswap_limit`;
- no `privileged`, `network_mode`, `pid`, `devices` or `cap_add`;
- every bind mount inside the module's own directory;
- a pinned image tag — `:latest` is refused.

## Host-networked modules

An app whose protocol is not HTTP(S) cannot follow the compose contract above: it needs `network_mode: host` and moves its own web ports into the private range so the edge keeps 80/443 (XMPP 5222/5269, TURN, proxy65 5000). The helper can create and remove such a module but does not template its compose file, and its listeners are host ports, so the firewall is the only gate on them. Snikket was this case and has since been promoted into `modules/snikket/` (module `xmpp`) — its coturn wrapper lives at `modules/snikket/coturn-run`, next to the compose file that mounts it.

## Exposure

Asked for every module, because it decides both the vhost and the DNS record:

1. **tailnet-only** — real ACME cert via DNS-01, `100.64.0.0/10` is the only network allowed in (everything else gets `403`), no public DNS record. The helper prints the `/etc/hosts` line to use from a tailnet device.
2. **dns-only** — public `A` record, grey cloud, reachable from anywhere.
3. **cloudflare-proxied** — public `A` record behind Cloudflare, orange cloud.

Modes 2 and 3 reuse the Cloudflare token the installer already stored, and take the host's public address from the apex `A` record — no lookup service, no hardcoded address.

## Removing a module

`remove` is a full purge, not just a stop: project containers, its volumes and its own networks (the shared `net` is never touched), both copies of the vhost, the certificate the edge stored for its host, its DNS record when the helper created it, its state record — then, on confirmation, its directory and its local backups. It finishes with a leftover audit and names anything it could not clear (docker image layers stay in the cache by design).

## Promoting a sandbox module into the repo

Once it works, the changes are the ones you would have made by hand:

1. Create `modules/<name>/docker-compose.yml` from the sandbox file: container names must match the row you are about to add, bind mounts must point at `${DATA_DIR}/<name>` instead of the module's own directory, and the pinned `ipv4_address` stays — the edge runs `network_mode: host`, so it dials the bridge IP and cannot resolve a container name.
2. Move the vhost into `modules/caddy/vhosts/` (`{{DOMAIN}}`-templated) if it lives in `data/sandbox/caddy/` — a sandbox vhost is wiped by `make render`.
3. Add the row to `config/modules.conf` (`<module> <dir> <host-label> <containers...>`). That row alone gives every container its `dok-*` targets, its compose mapping, the installer's module prompt and its state record.
4. Seed its settings in the installer (`seed_stack` for the module's `.env`, `prep_dirs` for its data dir and ownership, `containers_up` for the recreate, `03-firewall.sh` for host-networked ports, `cloudflare.sh` for the DNS record) and add a smoke section.
5. Stop the sandbox project, move its datadir to `$DATA_DIR/<name>` (verify byte and file counts on both sides), bring it up with `make dok-recreate-<container>`, and only then delete the sandbox copy so exactly one exists.
6. Record `MOD_<NAME>=true` and the module name in `enabled_modules` in `wizard.state` — the installer is that file's only writer, so this one edit is a deliberate exception, and without it smoke, `make fetch` and `make backup` treat the promoted module as not installed.
