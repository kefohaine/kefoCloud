# REF.md — the fxmq.net demo's public terms

Everything docs and scripts reference that belongs to *this* demo deployment
(domain, hosts, naming). If you are adapting the repo to your own setup, change
your values here once instead of hunting hardcoded occurrences.

**Purpose split**: `REF.md` documents the demo's public *terms*; scripts get
their *prompt defaults* from `scripts/defaults/<script>.conf`. Secrets never
belong in either — credentials stay in env / untracked files (rule 9 in
`docs/AGENTS.md`). Live values (VPS public IP, container names, tailnet peers)
are auto-detected by scripts, not read from this file.

| term | value |
|---|---|
| demo domain | `fxmq.net` (Cloudflare zone, CF nameservers) |
| repo (remote) | `github.com/kefohaine/server` |
| repo (local) | `/var/www/custom/projects/homelab/repo` |
| project dir (make REPO) | `/var/www/custom/projects/homelab` |
| host user | `op` |
| host hostname | `server` (Debian 13, x86_64) |
| website | `https://www.fxmq.net/welcome` |
| proxied vhosts (orange cloud) | `cloud`, `vault`, `kuma`, `www` |
| DNS-only vhosts (grey cloud) | `mail`, `mc`, `talk` |
| no public record | `tail` (tailnet split-DNS only) |
| tailnet | Tailscale, subnet `100.117.144.0/24`; devices: `server` (exit node), `macoslaptop`, an iPhone, one offline Linux node — refresh with `tailscale status` |
| storage box | second Debian system; SSH `root@` via `sshpass`; hosts the Nextcloud datadirectory mount (see `scripts/storage.sh`) |
| mail identity | mailbox user `vaultwarden@fxmq.net` (SMTP sender for Vaultwarden) |
