# REF.md — the skeleton's variables

This repo carries **no instance values**. Every deployable file is a template
(`{{TOKEN}}`), a compose file using `${VAR}` substitution, or a script reading
`scripts/instance.sh`. The values live in **one untracked file**,
`data/instance.conf`, written by `scripts/install.sh`.

- **What each token means** → `config/instance.defaults` (tracked, documented).
- **The current values** → `data/instance.conf` (untracked, mode 0600).
- **How rendering works, and how to rename/move an instance** →
  `docs/SKELETON.md`.
- **Inspect the values without reading the file** → `scripts/render.sh --tokens`.

## The tokens

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
| `{{STATE_DIR}}` | installer state (CF token + Tailscale key), mode 0700 |
| `{{TAILNET_SUBNET}}` | tailnet CIDR; its address part is the placeholder in `config/dnsmasq/10-tailnet.conf`, replaced with the live tailnet IP at deploy time |
| `{{SERVER_IP}}` | the host's public IPv4 (DNS + mail PTR checks) |
| `{{EMAIL}}` | operator contact address |
| `{{TIMEZONE}}` | IANA zone for containers and cron |

## Notes

- Docs use the *variables* (`$DOMAIN`, `$DATA_DIR`, …) and templates use the
  tokens; nothing in git names a real host, domain, path or user.
- Live values (public IP, container names, tailnet peers, module list) are still
  **auto-detected** by scripts — never read from a file (AGENTS rule 12).
- `installed-modules.conf` (written by `install.sh`) records which modules this
  deployment *declared*; `installed-modules.detected.conf` +
  `installed-modules.report.txt` are the independent-probe confirmation.
  `make smoke` and `make fetch` read the declared file.
- Secrets never belong in git, `instance.conf` is 0600, and rendered output
  (`data/rendered/`) is where live config actually comes from.
- `scripts/defaults/*.conf` hold *prompt defaults* — a different purpose from the
  token list.
