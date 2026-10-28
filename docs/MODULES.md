# Sandbox modules

Try an app on the live stack without touching the repo. `scripts/sandbox/editor.sh` builds a parallel, isolated module stack in `data/sandbox/` (gitignored, so nothing it creates can ever be pushed), reusing the running stack's network, edge and rendered config. Use it to **backtest a module before contributing it** to `modules/`, or to **run custom apps for personal use** without risking a broken repo or a broken stack.

## Why it is safe

- Everything the helper creates lives in `data/sandbox/` — repo files are never written, so `git status` stays clean and an upstream push can never carry sandbox content.
- The stack is not reinstalled: sandbox containers join the existing external `net` bridge and are reached through the running Caddy edge, which is the only host-network container.
- The compose contract is enforced before a single container starts (see below), so a sandbox module cannot publish ports, escape its namespace, or hog memory.
- `restart: unless-stopped` is mandatory, but only the repo's `modules/*/` are globbed at boot — so sandbox modules survive a reboot and rejoin `net` on their own, without ever being registered in the stack.

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

## Exposure

Asked for every module, because it decides both the vhost and the DNS record:

1. **tailnet-only** — real ACME cert via DNS-01, `100.64.0.0/10` is the only network allowed in (everything else gets `403`), no public DNS record. The helper prints the `/etc/hosts` line to use from a tailnet device.
2. **dns-only** — public `A` record, grey cloud, reachable from anywhere.
3. **cloudflare-proxied** — public `A` record behind Cloudflare, orange cloud.

Modes 2 and 3 reuse the Cloudflare token the installer already stored, and take the host's public address from the apex `A` record — no lookup service, no hardcoded address.

## Removing a module

`remove` is a full purge, not just a stop: project containers, its volumes and its own networks (the shared `net` is never touched), both copies of the vhost, the certificate the edge stored for its host, its DNS record when the helper created it, its state record — then, on confirmation, its directory and its local backups. It finishes with a leftover audit and names anything it could not clear (docker image layers stay in the cache by design).

## Promoting a sandbox module into the repo

Once it works, the changes are the ones you would have made by hand: move the rendered compose file to `modules/<name>/`, add its vhost under `modules/<name>/vhosts/` (copy the sandbox-rendered file and replace the pinned address with the container name), add its row to `config/modules.conf`, and drive it through the installer. Then remove the sandbox copy so only one of the two exists.
