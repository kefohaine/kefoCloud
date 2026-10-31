# What kefoCloud is

A single Debian machine serving the apps declared in `config/modules.conf`, each as one Docker Compose unit under `modules/`, behind one Caddy edge. This file describes the system — its parts, its traffic paths and why each choice was made. For commands and procedures see `docs/MANUAL.md`; for a one-screen pitch see `README.md`.

## Parts

| App | Module | Containers | Door |
|---|---|---|---|
| Nextcloud + Talk | `cloud` | `nextcloud` `postgresql` `redis` `talk-hpb` `talk-relay` `notify-push` | `nextcloud.` (tailnet), `talk.` |
| ownCloud Infinite Scale | `ocis` | `ocis` | `cloud.` |
| Snikket (XMPP) | `xmpp` | `snikket-server` `snikket-proxy` `snikket-portal` `snikket-certs` | `chat.` |
| Vaultwarden | `vault` | `vaultwarden` | `vault.` (tailnet) |
| Mailu + Roundcube | `mail` | `mailu-front` `mailu-imap` `mailu-smtp` `mailu-antispam` `mailu-admin` `mailu-redis` `roundcube` | `mail.`, `mailu.` (tailnet) |
| Uptime Kuma | `monitor` | `uptimekuma` | `kuma.` |
| Homarr | `home` | `homarr` | `home.` |
| WriteFreely | `blog` | `writefreely` | `blog.` |
| Immich | `photos` | `immich-server` `immich-db` `immich-redis` | `photos.` |

Beside the containers run host services: `ttyd` (web terminal on a single `tmux` session), `dnsmasq` (tailnet DNS), `fail2ban`, `sshd` (key-only, tailnet only), `ufw`, `cron`, and the Goose agent (`goose.service`). `kefo-stack.service` brings the deployed compose units back on boot.

**Module state is runtime, never documentation.** The installer is the sole writer of `$DATA_DIR/wizard.state`, whose `enabled_modules` is the list that exists; `scripts/lib/modules.sh` is the only reader. A module that is off has no container, no data and no route — its vhost answers 502 if one is deployed. That is *not* "tailnet-only": see "Module state vs route exposure".

## Request flow

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
           reverse_proxy    reverse_proxy      php_fastcgi
           oCIS (cloud)     uptime-kuma        nextcloud:9000
           (172.22.0.27:9200) (172.22.0.6:3001) (Nextcloud FPM)
           (also: roundcube 172.22.0.10:80 for mail.$DOMAIN; the mail platform
            Postfix/Dovecot at 172.22.0.9 owns ports 25/465/587/993)

    ttyd.$DOMAIN is tailnet-only (not in public DNS) — "/" IS the host shell:
    the single `main` tmux session, no second credential (Tailscale membership
    only); anything off the tailnet gets 403 first. vault.$DOMAIN,
    nextcloud.$DOMAIN and mailu.$DOMAIN are tailnet-only the same way.

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

## Access model

| Hostname | Cloudflare | Reachable by | Serves |
|---|---|---|---|
| `cloud.` | proxied | anyone | oCIS |
| `nextcloud.` | not in public DNS | tailnet only | Nextcloud (FPM + PostgreSQL + Redis + Talk) |
| `vault.` | not in public DNS | tailnet only | Vaultwarden |
| `kuma.` | proxied | anyone | Uptime Kuma |
| `www.` | proxied | anyone | instance pages in `$DATA_DIR/pages/www` (`/welcome`, …), `/download` drop folder |
| `home.` | proxied | anyone | Homarr |
| `blog.` | proxied | anyone | WriteFreely |
| `photos.` | DNS-only | anyone | Immich |
| `mail.` | DNS-only | anyone | Roundcube webmail + the SMTP/IMAP name (MX/SPF point here) |
| `mailu.` | not in public DNS | tailnet only | Mailu admin (`/admin`) |
| `talk.` | DNS-only | anyone | Talk signaling `/signaling/spreed` + TURN/STUN |
| `chat.` (+ `groups.`, `share.`) | DNS-only | anyone | Snikket XMPP, calls, TURN (host networking) |
| `ttyd.` | not in public DNS | tailnet only | the host shell at `/` |

Two rules generate that table: traffic that is not HTTP(S) (mail, talk, XMPP) stays grey-cloud at Cloudflare, and a tailnet hostname never enters public DNS — `dnsmasq` answers it for tailnet clients and Caddy's `@not_tailnet` matcher 403s every other source, so a forged Host header against the public IP gets nothing.

### Module state vs route exposure

| Axis | Values | Truth |
|---|---|---|
| module state | `installed` / `not installed` | `enabled_modules` in `wizard.state` |
| route exposure | `public` / `tailnet-only` | the vhost; `exposure()` in `scripts/lib/modules.sh` classifies |

An uninstalled module has no route at all — `kuma.` answering 502 means the monitor is not installed, never that it is tailnet-only. Tailnet-only describes a route that exists and is reachable only from the tailnet. `make fetch` prints `module (not installed)` in words, and `make fetch-more` prints a `routes` row that classifies each deployed vhost.

## Design rationale

**Edge: Caddy over nginx / Traefik.** One vhost per file (`modules/caddy/vhosts/<host>.caddy`), ACME renewal built in, `caddy-dns/cloudflare` for DNS-01 so a cert issues whether or not port 80 reaches the origin, certs persisted in the bind-mounted `/data` so recreates don't restart the 90-day clock, HTTP/3 free. Trade-off: Bot Fight Mode challenges non-JS clients on proxied hostnames; Nextcloud sits behind the tailnet instead, so its clients never meet it.

**Admin doors off public DNS.** `ttyd.` is reachable only from the operator's devices, so public DNS would hand every bot a port that isn't public. Tailscale split-DNS means the name resolves the moment a device joins, with a normal LE cert by DNS-01 (same fallback issuer chain as every vhost: Buypass, then ZeroSSL) — trusted by browsers, no port forward, no firewall hole. The machine also advertises exit-node routes; IPv4/IPv6 forwarding is in `config/sysctl/99-kefo.conf`.

**Mail: Mailu.** Postfix + Dovecot in active release with DKIM/DMARC/Rspamd/fail2ban built in, plus the official Roundcube image — the lightest trusted option (Mailcow costs roughly 6–8 GB RAM).

**dnsmasq on the host, bound to the Tailscale IP.** One small file answers the tailnet names and forwards everything else. On the host it survives `docker stop`, image pulls and `systemctl restart docker` — the failures a container restart policy cannot cover — with `Restart=always` as the only supervisor. It binds port 53 to the Tailscale IP only, never `0.0.0.0`, so the machine is not an open resolver. The split-DNS route only reaches this host if the host's own `/etc/resolv.conf` asks Tailscale (tracked copy applied by `make install-resolv`); otherwise every public name resolves while the tailnet names answer NXDOMAIN on the machine that serves them.

**One `net` bridge.** Inter-container DNS needs a user-defined bridge; Docker's embedded resolver answers container names, so no service registry is needed. One shared `172.22.0.0/16` network (`external: true`) is reused by every compose file so the pinned bridge IPs attach cleanly.

**Nextcloud: PostgreSQL + Redis + self-hosted TURN.** PostgreSQL replaced SQLite, whose file locking caused intermittent 504s under concurrent sync and made consistent backups hard; its data dir is portable. Redis is a cache with no persistence. Talk runs the official Go signaling server plus a self-hosted coturn, so call media never touches a public STUN/TURN service. Every container carries `mem_limit`/`memswap_limit` ceilings (not allocations — idle stays low) so a runaway process cannot reach the host. Mail is reciprocal: Nextcloud (Mail app, notifications) and Vaultwarden (invite mail) send through the same local mailboxes over the bridge.

## Repository layout

```
Makefile      the command surface (recipes call scripts/ or one command)
modules/      one dir per app: docker-compose.yml (+ Dockerfiles, caddy/vhosts/*.caddy)
config/       catalogue (modules.conf, instance.defaults) + tracked host configs
scripts/      install/ (wizard + uninstall), ops/, stack/, render/, modules/,
              lib/, hooks/, info/
recipes/      Goose agent tasks (read-only inspection + reports)
data/         instance state, written at install time — never committed
```

`config/` holds catalogues and reference copies of host-level configs (systemd units, SSH hardening, dnsmasq, ttyd, docker daemon, sysctl, logrotate, tmux); `make render` renders them with instance values and `make install-config` pushes them live. Web pages are not in the repo — they are instance data under `$DATA_DIR/pages/`. The repo itself is owned by `root:root`.

## Instance values

Deployable files carry `{{TOKENS}}`; the values live in `data/instance.conf`; `make render` writes `data/rendered/` and every script reads values through `scripts/lib/instance.sh`. Nothing instance-specific is committed — see `docs/SKELETON.md` for the token list.

## Generalization principle

Scripts derive instance facts from the live system instead of hardcoding them (the installer and `scripts/ops/nc-datadir-nfs.sh` auto-detect container names, the datadirectory and DB credentials; user lists come from `occ`, never a fixed roster), and generated manifests are **generated** (`make nc-capture` writes `cloud/recovery/`, outside the repo). Before writing a user, host, IP, port, path or container name into a script or doc, ask whether it can change — if it can, detect or prompt for it.
