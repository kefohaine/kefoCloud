# Welcome to kefoCloud

Easy self-hosting for Debian with Docker.

![Banner](.github/images/banner.jpg)

**One Debian server, one plug-and-play installer, dozens of strong apps.** kefoCloud bundles a suite of community-maintained self-hosted apps ready to be deployed in a matter of minutes -- all thanks to my advanced idempotent installation wizard. It configures the server from the ground up with high performance & security standards, for a seamless integration of your selected pre-configured apps.

## Install

```bash
git clone https://github.com/kefohaine/kefoCloud.git
cd kefoCloud && sudo bash scripts/install/wizard.sh
```

The wizard asks for five values up front, then works by itself: DNS records, certificates, databases, mailboxes and admin accounts, ending with a health scan for these services. Its repair mode lets you fix issues or change your stack anytime.

## Why this

- **Private by default.** Your photos, files, mail and passwords live on hardware you own.
- **Secure where it counts.** Key-only tailnet SSH, deny-by-default firewall, LE certificates, fail2ban..
- **Fast & frugal.** My custom host tuner (`scripts/ops/optimize.sh`) cuts most performance losses down.
- **Simple to run.** One bootstrap, one Makefile, no YAML archaeology: `make help` will go a long way.
- **Compatible & stable.** Stock upstream images, standard Docker Compose files, on plain Debian.
- **Reversible.** `scripts/install/uninstall.sh` & `make backup` are all you need for worst-case scenarios.

## Supported Apps

Pick to your needs:
- `chat` ESS CE (+ Synapse, MAS, Element Call/Admin)
- `ocis` ownCloud Infinite Scale
- `mail` Mailu & Roundcube
- `vault` Vaultwarden
- `kuma` Uptime Kuma
- `blog` WriteFreely
- `photos` Immich
- `home` Homarr
- `kopia` Kopia

## Read next

- **[docs/MANUAL.md](docs/MANUAL.md)** — the knowledge base of the whole project.
- **[docs/AGENTS.md](docs/AGENTS.md)** — the rules agentic workflows follow.

## Credits

Thanks to:
- [Sunyy](https://github.com/rrm9mw6g6j-collab) for beta-testing privately with me
- Mister R for providing with powerful personal hardware
- [Cloudflare](https://cloudflare.com), [Porkbun](https://porkbun.com) & [Interserver](https://interserver.net) for their amazing services
