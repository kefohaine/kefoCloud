# Agent operating guide

This file tells agents how to act in this repo. Read it before making changes. For project-specific layout, deployment commands, protected resources, and per-service edit-safe facts, see `docs/GUIDE.md`. For system architecture, design rationale, and request flows, see `README.md`. For open problems and improvements, see `docs/ISSUES.md`.

## Safety rules

These are non-negotiable. Follow them on every task.

1. **Never delete or disable any critical service or file without explicit operator approval.** Each project defines its own list — see `docs/GUIDE.md` for the project-specific protected resources. Do not `systemctl stop/disable`, remove unit files, `daemon-reload` after editing, or replace host services with containers unless the operator has explicitly told you to.
2. **Stay silent while doing tasks.** Do not narrate progress, do not print status updates, do not summarize what you just did. Run commands, edit files, and only emit text when you need a decision from the user or are reporting a blocker. Output should be minimal — the work product speaks for itself.
3. **Push at milestones, before destructive ops, and when the prompt is done.** Before any hard-to-reverse operation (deleting files, force-recreating containers, `systemctl` changes, DB/schema changes, firewall edits), first commit and push. After reaching a milestone (feature, resolved issue, doc sync) or completing the prompt, also commit and push. Don't wait for the operator to ask. If a push fails, fix it before proceeding. When completing a big sequence of tasks, first update every `.md` file to reflect the current system state, then commit and push. The canonical sequence is `make git-add` → `make git-commit MSG="…"` → `make git-push`, or `make git-all MSG="…"` for the all-in-one shortcut. Raw `git` / `docker compose` commands are reserved for the `make` recipes — never run them directly.
4. **Doc maintenance is first-class work, not a cleanup step.** Updating documentation is as important as working on the repo. Every system change, refactor, or operational decision MUST be followed by a doc audit — see the doc-audit workflow in "Before finishing a task" for the concrete procedure (walk every `.md`, diff against source, apply the three prongs). A push that leaves stale `.md` content is the same failure mode as a push that breaks the build — both mean the agent didn't finish the job. Never treat doc updates as optional "if I have time" work; treat them as the definition of done.
5. **Minimize token usage.** Be extremely efficient: short, accurate, and understanding. No filler, no preamble, no restating the question, no recaps of what you just did. Batch tool calls that can run in parallel. Read only the file regions you need. Prefer one precise edit over rewriting whole sections. Answer in as few words as the task allows without sacrificing correctness.
6. **When an issue is explicitly intended by the operator or documented as a deliberate feature/design choice, document the rationale rather than treating it as a bug.** If a behaviour is "by design", record it so future agents don't "correct" it.
7. **Minimize web searches.** Only fetch a URL when the answer is not already in the repo or the agent's own knowledge. Prefer reading local files and reasoning over network fetches.
8. **Never use user-facing data services for agent purposes.** Any service that hosts files or stores data for a user (a shortener, file upload, file browser, password manager, file sync, database, etc.) is user-only. Do not create records, upload files, write to databases, or store any data through these services for testing, debugging, development, or any agent-side reason. Verify changes with read-only checks (`curl`, logs, status commands) and roll back any test artifacts immediately if created by mistake.
9. **Never read secrets, credentials, or sensitive user data.** Do not read, print, or inspect database files, password-manager data, user files, uploaded files, `.env` files, SSH private keys, TLS cert/key files, identity state, or any file containing credentials, tokens, passwords, or personal data. Reading these is a privacy violation — treat them as untouchable. If a task requires knowing a value from a secret file, ask the operator to provide it instead.
11. **After a debug hell, write a "Lessons learned" entry.** A debug hell is anything that took multiple non-obvious hops to root-cause — a symptom that doesn't match the obvious cause, a tool's failure mode that isn't documented, a config interaction that only surfaces under specific combinations. The facts that took you 30 minutes to discover by grepping the repo are facts the next agent will burn 30 minutes rediscovering unless you write them down. After you finish such a task, append a bullet to the `Lessons learned` section in `docs/ISSUES.md` capturing: (a) the symptom, (b) the root cause, (c) the one-line takeaway (so a future agent can grep for it), and (d) any URLs / commands / file paths that took you to the answer. Don't write general engineering advice — write the *specific* facts that were non-obvious in this repo. Emphasize **findings**: the things you found out by reading the repo or by hitting an error, that weren't documented anywhere you'd think to look. Keep entries short and grep-able. If a future agent ends up with the same debug hell, the entry should save them the search. **Don't write a novel in commit messages either** — the operator's words: *"Don't write a novel, bro, nobody's going to read it anyway ;)"* The diff speaks for itself; one sentence per change is enough.
10. **Route / TLS / listener changes must end with a working state, never a half-applied one.** A Caddyfile edit that fails to parse, a new listener port, a per-host cert mode, or a `docker-compose.yml` port-mapping change can take every dependent service offline on the next reload. Rules:
    - **Diff before reload.** Run `git show HEAD:services/domain/Caddyfile | diff - services/domain/Caddyfile` (or the equivalent for compose / systemd units) and confirm the change is exactly what you intended. If the diff surprises you, stop.
    - **Smoke before commit.** Every route change must end with: (a) the four tailnet routes return 200 (`/`, `/share`, `/mc`, `/shell`), (b) the same routes from a non-tailnet source return 403, (c) every public vhost (`www`, `share`, `vault`, `cloud`, `kuma`, `api`, `mc`) returns 200/302 with a valid LE cert (issuer `Let's Encrypt`, not `CloudFlare Origin CA`). If any of these fail, the change is not done — fix it before committing, or revert.
    - **Reload is part of the change.** "I edited the file but haven't reloaded yet" is a half-applied change. A `make up-domain` (or equivalent) and the post-reload smoke test are mandatory; without them the next agent finds a Caddy that doesn't match the repo.
    - **No new listeners without an explicit operator request.** Don't bind to a new port (`8443`, etc.), don't add a `servers { srv0 { listen :X } }` global block, don't split `:443` per-host — these are easy to invent and hard to roll back cleanly. If the existing setup doesn't accommodate the change, ask before inventing.
    - **Cert changes are per-vhost, not global.** Every vhost in `services/domain/vhosts/*.caddy` declares its own `tls { dns cloudflare { env.CF_API_TOKEN } }` block. Don't replace a vhost's `tls` block with `tls internal`, `tls off`, `tls self_signed`, or a non-ACME cert path — browser clients will drop the connection. If a vhost genuinely needs a different cert mode, get explicit operator approval and update `docs/ISSUES.md` with the rationale.
    - **Revert plan in the commit message.** For every Caddyfile / compose / cert change, the commit message must include a one-line revert recipe (e.g. `revert: git revert <sha>` or "restore the previous Caddyfile block X"). A change you can't easily revert isn't safe to commit.

## Boundaries between docs

Each `.md` file in the repo has a single purpose. Don't blur them.

- **`README.md`** — visitor-facing. "What is real, and why." The system as it exists today: architecture, request flow, domain/access model, design choices. No planned features, no uncertainty, no operational details.
- **`docs/AGENTS.md`** (this file) — agent-facing rules. Portable to any look-alike system. The "how an agent must behave" — not "how this project works".
- **`docs/GUIDE.md`** — project-facing operator guide. "How to do x, where is y, what's z" for this specific repo. Layout, deployment commands, protected resources, per-service edit-safe facts, operational gotchas.
- **`docs/ISSUES.md`** — task tracker. Open problems (bugs, security gaps, efficiency losses, robustness risks) that are not yet fixed; resolved problems for history; intended behaviours that look like bugs but are deliberate design choices.

When a fact fits two files, it belongs in the lower one in this list. A future agent reading only `README.md` should understand the system; a future agent reading only `docs/AGENTS.md` should understand the rules; a future agent reading only `docs/GUIDE.md` should be able to deploy and operate the system.

## Doc-audit directives

These directives govern how agents detect and correct drift, stale content, and duplicates when updating docs. Apply them every time a `.md` file is edited — not only at the end of a task.

**Drift** = a documented fact that disagrees with the executable source (compose files, Makefile, systemd units, Caddyfile, Dockerfile, app source). Examples: a wrong port, an old container name, a recipe name that no longer matches the Makefile, a Caddyfile matcher that has moved, a claimed "X is renamed to Y" in a `Solved` entry where the rename was never applied on disk.

**Stale** = content that has lost its anchor in reality — paths that no longer exist, port numbers that changed, container names that were renamed, units that were retired, hardening claims that were weakened, "currently" / "right now" snapshots that drifted from the steady state.

**Duplicate** = the same fact (sentence, command, port, path, claim) living in two or more `.md` files, or two paragraphs in the same file restating each other.

### How to detect each one

- **Drift** — diff-driven. For every concrete fact in the doc (port, path, command, container name, unit name, env var, image tag, log cap, route matcher, schema column, file reference), `grep` the executable source for the same fact and confirm they agree. If a doc says "Caddy matches `@not_tailnet`" but the Caddyfile no longer has that matcher, the doc is wrong. Don't paraphrase what's in the repo — point at the file (writing rule 11) and verify the file still says what you think it says.
- **Stale** — path-of-existence check. For every path, port, hostname, container name, unit name, and file reference in the doc, confirm it still exists on disk (`ls`, `docker ps`, `systemctl list-units`). If the doc references `services/terminal/` but the directory is gone, the doc is stale. Treat `Solved` entries as historical but still anchored — they must accurately describe what changed and what replaced it.
- **Duplicate** — same fact in two places. If a sentence appears verbatim or near-verbatim in two files, one of them is wrong; delete the higher-file instance per the boundaries list. If two `Solved` entries describe the same change from different angles, collapse them.

### What to do when you find drift / stale / duplicate

1. **The source wins.** The executable source (compose, Makefile, systemd unit, Caddyfile, app source) is the truth; the doc is wrong. Fix the doc, not the source (unless the source is what's broken — that's a separate bug, log it in `docs/ISSUES.md`).
2. **Be specific in the fix.** Don't rewrite the surrounding paragraph — replace the drifted/stale/duplicated fact with the correct one in place. Preserve verified useful guidance around it (writing rule 9).
3. **For `Solved` entries that claim a change was made but wasn't**, downgrade the claim to match reality (e.g. "claimed rename; never actually applied — see `Open`" or revert the entry until the rename is done for real). A `Solved` entry that lies is worse than no entry — future agents act on it.
4. **For `Intended` rationales that no longer reflect the code**, rewrite the rationale or move the behaviour to `Open` if it's actually unintended now.
5. **For duplicates across files**, delete the higher-file instance per the boundaries list. Each fact lives in exactly one place.

### When to audit

- After every system change, refactor, or operational decision (mandatory per safety rule 4).
- At the end of every task — see "Before finishing a task" for the full checklist.
- When picking up an old issue in `docs/ISSUES.md` whose root cause might no longer apply (the fix landed elsewhere; the entry is stale).
- Before committing any doc-only change (verify the new content doesn't introduce its own drift).
- After any debug hell — append a `Lessons learned` entry to `docs/ISSUES.md` (Safety rule 11). The entries are the most valuable future-agent artifact; don't skip them.

## Workflow

1. Read `README.md` to understand the system.
2. Read `docs/GUIDE.md` to learn the project's layout, commands, and protected resources.
3. Read `docs/AGENTS.md` (this file) for the rules.
4. Check `docs/ISSUES.md` for known problems or in-progress work.
5. Make changes following the rules.
6. Verify the change works (run the project's status / logs / smoke commands listed in `docs/GUIDE.md`).
7. Update `.md` files if the change altered layout, architecture, or design.
8. Commit and push (Safety rule 3).

## Before finishing a task

1. Verify the change works using the project's verification commands (see `docs/GUIDE.md`).
2. **If this task was a debug hell** (symptom didn't match the obvious cause, took multiple non-obvious hops to root-cause, or surfaced a non-documented tool/config interaction), append a `Lessons learned` entry to `docs/ISSUES.md` per Safety rule 11. Do this *before* the doc audit, not after — the lesson is the most valuable future-agent artifact.
3. **Doc audit — mandatory, not optional (Safety rule 4 + doc-audit directives).** Walk every `.md` file in the repo and apply the three prongs from the doc-audit directives:
   - **Delete stale** — anything that no longer matches the running system: outdated paths, ports, container names, unit names, hardened/locked-down claims, decommissioned services, retired rationale, "currently" / "right now" snapshots that have drifted. For every path/port/hostname/unit/container in the doc, confirm it still exists on disk. For `Solved` entries, confirm the change they describe actually happened — a `Solved` entry that lies is worse than no entry.
   - **Correct drift** — every fact in every `.md` (commands, ports, paths, file references, env vars, image tags, log caps, route matchers, behaviour claims) must match the executable source (compose files, Makefile, systemd units, Caddyfile, Dockerfile, app source). Diff docs against the source; if they disagree, the source wins and the doc is wrong. Use `grep` to verify each concrete fact.
   - **Organize duplicates** — each fact lives in exactly one place. If a sentence appears in two files, delete the one in the higher file (per the boundaries list). If a `Solved` entry is multi-line, collapse to one line (writing rule 10). If a section restates another doc, point at the other doc instead.
3. Update `README.md` if the architecture, request flow, or design choices changed.
4. Update `docs/GUIDE.md` if the layout, commands, or per-service facts changed.
5. Update or resolve items in `docs/ISSUES.md` if you fixed something listed there.
6. Add new issues you discovered to `docs/ISSUES.md`.
7. Commit and push (Safety rule 3).

## `.md` writing rules

Follow these on every edit to any `.md` file in this repo.

1. **No duplicated content across files.** State each fact once, in the most appropriate file. See "Boundaries between docs" above.
2. **No pasting repo file contents.** Don't copy config / compose / Makefile blocks into docs. Describe in prose; link to the file path. Command snippets are fine.
3. **No duplicated prose within a file.** If a paragraph repeats what another section already said, delete one.
4. **Prose over code blocks.** Use a code block only for commands the reader will run, or a structure that genuinely needs monospace (a directory tree, an architecture diagram). Everything else is prose.
5. **One source of truth.** If a detail appears in two files, pick one and delete the other. Prefer the executable source (compose file, Makefile, config) as truth; docs summarize it.
6. **No runtime snapshots.** Don't write "all three currently running" or "healthy" — it drifts the moment a service stops. Describe the steady-state config, not the current transient state.
7. **Keep it short.** Every line should answer "would an agent miss this without help?" If not, cut it. No filler, no restating the obvious, no generic advice.
8. **Verify before writing.** Don't describe a path, port, or behaviour you haven't checked in the actual file. Stale docs are worse than missing docs.
9. **Preserve verified useful guidance.** When editing an existing `.md`, keep what's accurate and high-signal; only delete fluff, duplicates, or stale claims. Don't rewrite blindly.
10. **Categorize `Solved` history by month.** In `docs/ISSUES.md`, group resolved items under `### Mon YYYY — short label` headings (e.g. `### Jul 2026 — early system build`). Add a new heading only when the month changes — never create a second heading for the same month; append to the existing one. **One line per resolved issue, aggressively short** — format: `- **Short title** — one-sentence summary.` Aim for ~80 chars after the dash. Never multi-line entries, sub-bullets, or paragraphs. The full root-cause / symptom / fix narrative belongs in an open issue entry while it's being worked; once resolved, collapse it to one short line.
11. **Don't re-type what's in the repo.** If a fact can be confirmed by reading the compose file, config, app source, or Makefile, point at the file — don't paraphrase it. Anything that drifts the moment a file is edited is more harm than help. This applies to image tags, env vars, log caps, healthcheck commands, route tables, schema columns, and `content/` file contents in particular.
12. **README = real and verified, never planned or unsure.** Anything you can't point at in the running system today doesn't belong in `README.md`. If it's planned, drop it; if it's speculative, drop it. `docs/ISSUES.md` is the right home for "we should add X" / "consider switching to Y" — even before approval, as long as it's framed as a candidate.

## docs/ISSUES.md workflow

`docs/ISSUES.md` is the task tracker. When you pick up an issue:

1. Move it under a `## In progress` heading (or just start working).
2. Follow the **Fix** steps in the issue entry.
3. Verify the fix.
4. Remove the entry from `docs/ISSUES.md` when fully resolved, or update it with notes if partially done.
5. Commit with a message referencing what was fixed.

When you discover a new problem, append it under the appropriate severity heading (`High` / `Medium` / `Low`) with the same format:
```
### Short title
- **File**: path/to/file
- **Problem**: what's wrong and why it matters
- **Fix**: concrete steps to resolve
```

When a behaviour looks like a bug but is deliberate, document the rationale in `README.md` (not `docs/ISSUES.md`) so future agents don't "correct" it. Only behaviours that genuinely need fixing belong in `docs/ISSUES.md`.

## Project-specific overrides

This section is project-defined and not part of the portable agent rulebook above. Other projects using this AGENTS.md as a template should replace it with their own project-specific notes (or delete it).

<!-- project-specific content begins here -->

This project (`jehpok.com`) is a self-hosted Debian VPS. The full project guide lives in `docs/GUIDE.md`. The protected host resources and any per-project safety constraints are listed there — never assume what they are without reading `docs/GUIDE.md`.

### `server.jehpok.com` cert is now a per-vhost LE cert, not a wildcard — do not "consolidate"

The historical design used a single wildcard Cloudflare Origin cert at `$(REPO)/certs/cert.pem` shared across every vhost. That was retired because the wildcard SNI (`*.jehpok.com`) covered `mc.jehpok.com` and Caddy served it as a SNI fallback for the `mc.jehpok.com` vhost, blocking the per-vhost ACME automation policy from firing. The current design has every vhost declare its own `tls { dns cloudflare { env.CF_API_TOKEN } }` block in `services/domain/vhosts/*.caddy`; the wildcard cert is no longer referenced. **Do not reintroduce a shared wildcard cert, import `tls_keys`, or mount `/certs` back into the domain container** — each change puts `mc.jehpok.com` back into the cert-fallback loop.

### `caddy_data/` is a runtime data dir, not source

The Caddy container bind-mounts `/var/www/custom/projects/jehpok/caddy_data` at `/data` for persistent cert/account storage. It also contains the `CF_API_TOKEN` file (token for the ACME DNS-01 challenge). The token file is created by the operator outside the repo (see `docs/MIGRATE.md`), lives under `caddy_data/` so container recreates don't lose the cert, and is excluded from the `backup-secrets` recipe (DN-01 ACME doesn't need off-VPS cert copies — the cert is renewed by Caddy from the CF token). Do not commit anything from `caddy_data/`.
