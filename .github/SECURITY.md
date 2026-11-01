# Security Policy

kefoCloud is an installer and a Makefile you run on a machine you own. There is no hosted service here, and no user data lives in this repository.

## Supported versions

Only the current `main` is supported: fixes land there and reach you in the next release tag. An older checkout, a fork or a modified installer is not maintained.

## Reporting a vulnerability

Use GitHub's private reporting — **[Report a vulnerability](https://github.com/kefohaine/kefoCloud/security/advisories/new)** — never a public issue. The report stays private until a fix is published.

Include the file or script, what an attacker gains and the smallest reproduction (a command, an input, a rendered config). Redact every credential: the values rendered into an instance tree never belong in a report.

## In scope

- The installer, its wizard and phases (`scripts/install/`), including anything that renders operator values into a config file.
- The hooks (`scripts/hooks/`), the `Makefile` recipes and the scripts under `scripts/ops/`, `scripts/stack/` and `scripts/modules/`.
- The Compose files, Caddy templates and container defaults under `modules/`.
- A hardening claim in the documentation that the code does not actually enforce.

## Out of scope

- Vulnerabilities in the upstream applications themselves — report those to the upstream project.
- A deployment's own choices: a weak operator password, an admin door the operator exposed, a firewall rule the operator opened.
- Anything that requires an already-compromised root shell on the host.
