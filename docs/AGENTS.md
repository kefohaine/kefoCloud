# Agent operating guide

This file tells agents how to act in this repo. It is deliberately **portable** — it contains only generic rules that apply to any project using this template. Read it before making changes. For this project's layout, deployment commands, protected resources, per-service facts, rationale, and operational gotchas, see `docs/GUIDE.md` (the only place project-specific facts live). For open problems, see `docs/ISSUES.md`.

## Safety rules

These are non-negotiable. Follow them on every task. Project-specific facts (paths, recipe names, vhost lists) belong in **`docs/GUIDE.md`**, never in these rules.

1. **Never delete or disable any critical service or file without explicit operator approval.** Each project defines its own list — see `docs/GUIDE.md` for the project-specific protected resources. Do not `systemctl stop/disable`, remove unit files, `daemon-reload` after editing, or replace host services with containers unless the operator has explicitly told you to.
2. **Stay silent while doing tasks.** Do not narrate progress, do not print status updates, do not summarize what you just did. Run commands, edit files, and only emit text when you need a decision from the user or are reporting a blocker. Output should be minimal — the work product speaks for itself.
3. **Push at milestones, before destructive ops, and when the prompt is done.** Before any hard-to-reverse operation (deleting files, force-recreating containers, `systemctl` changes, DB/schema changes, firewall edits), first commit and push. After reaching a milestone (feature, resolved issue, doc sync) or completing the prompt, also commit and push. Don't wait for the operator to ask. If a push fails, fix it before proceeding. When completing a big sequence of tasks, first update every `.md` file to reflect the current system state, then commit and push. The project's canonical git commands are listed in `docs/GUIDE.md`. Raw `git` / `docker compose` commands are reserved for the project's `make` recipes — never run them directly.
4. **Doc maintenance is first-class work, not a cleanup step.** Updating documentation is as important as working on the repo. Every system change, refactor, or operational decision MUST be followed by a doc audit — see the doc-audit workflow in "Before finishing a task" for the concrete procedure (walk every `.md`, diff against source, apply the three prongs). A push that leaves stale `.md` content is the same failure mode as a push that breaks the build — both mean the agent didn't finish the job. Never treat doc updates as optional "if I have time" work; treat them as the definition of done.
5. **Minimize token usage.** Be extremely efficient: short, accurate, and understanding. No filler, no preamble, no restating the question, no recaps of what you just did. Batch tool calls that can run in parallel. Read only the file regions you need. Prefer one precise edit over rewriting whole sections. Answer in as few words as the task allows without sacrificing correctness.
6. **When an issue is explicitly intended by the operator or documented as a deliberate feature/design choice, document the rationale rather than treating it as a bug.** If a behaviour is "by design", record it so future agents don't "correct" it.
7. **Minimize web searches.** Only fetch a URL when the answer is not already in the repo or the agent's own knowledge. Prefer reading local files and reasoning over network fetches.
8. **Never use user-facing data services for agent purposes.** Any service that hosts files or stores data for a user (a shortener, file upload, file browser, password manager, file sync, database, etc.) is user-only. Do not create records, upload files, write to databases, or store any data through these services for testing, debugging, development, or any agent-side reason. Verify changes with read-only checks (`curl`, logs, status commands) and roll back any test artifacts immediately if created by mistake.
9. **Never read secrets, credentials, or sensitive user data.** Do not read, print, or inspect database files, password-manager data, user files, uploaded files, `.env` files, SSH private keys, TLS cert/key files, identity state, or any file containing credentials, tokens, passwords, or personal data. Reading these is a privacy violation — treat them as untouchable. If a task requires knowing a value from a secret file, ask the operator to provide it instead.
10. **Network-listener / route changes must end with a working state, never a half-applied one.** Editing a config that controls what reaches a container or a host port can take every dependent caller offline on the next reload. Rules:
    - **Diff before reload.** Compare the live config to the version you're about to commit (`git show HEAD:<path>` vs. the working file). If the diff surprises you, stop.
    - **Smoke before commit.** After the reload, exercise the routes from both the public and the access-controlled source (e.g. tailnet vs. non-tailnet). If any expected response fails, the change is not done — fix it before committing, or revert.
    - **Reload is part of the change.** "I edited the file but haven't reloaded yet" is a half-applied change. The project's reload + smoke sequence (in `docs/GUIDE.md`) is mandatory; without them the next agent finds a system that doesn't match the repo.
    - **No new listeners without an explicit operator request.** Don't bind to a new port, don't split listeners per-host, don't invent a new global block — these are easy to invent and hard to roll back cleanly. If the existing setup doesn't accommodate the change, ask before inventing.
    - **TLS / cert changes must keep the production trust model.** If a vhost currently relies on ACME for its cert, don't replace its block with `tls internal`, `tls off`, `tls self_signed`, or a static cert path — browser clients will drop the connection. If a vhost genuinely needs a different cert mode, get explicit operator approval and update `docs/ISSUES.md` with the rationale.
    - **Revert plan in the commit message.** For every config change that can take callers offline, the commit message must include a one-line revert recipe. A change you can't easily revert isn't safe to commit.
11. **After a debug hell, record the lesson in `docs/GUIDE.md`.** A debug hell is anything that took multiple non-obvious hops to root-cause — a symptom that doesn't match the obvious cause, a tool's failure mode that isn't documented, a config interaction that only surfaces under specific combinations. The facts that took you 30 minutes to discover by grepping the repo are facts the next agent will burn 30 minutes rediscovering unless you write them down. After you finish such a task, fold a bullet into the *relevant existing section* of `docs/GUIDE.md` (service bullet, gotcha, or script section — never a standalone "lessons" section) capturing: (a) the symptom, (b) the root cause, (c) the one-line takeaway (so a future agent can grep for it), and (d) any URLs / commands / file paths that took you to the answer. Don't write general engineering advice — write the *specific* facts that were non-obvious in this repo. Emphasize **findings**: the things you found out by reading the repo or by hitting an error, that weren't documented anywhere you'd think to look. Keep entries short and grep-able. If a future agent ends up with the same debug hell, the entry should save them the search. **Don't write a novel in commit messages either** — the diff speaks for itself; one sentence per change is enough.
12. **Stay global — derive from the live system, never hardcode instance specifics.** Everything that can change over time (users, groups, quotas, hostnames, IPs, ports, paths, container names, domains) must be detected, queried, or generated from the running system — not written as a fixed list. Patterns that satisfy this: auto-detect (container names, datadirectory, DB credentials from `docker inspect`/env), derive (user/group lists from occ, not from a hardcoded roster), and *generate* any persistent manifest from the live state (mark generated manifests as GENERATED, with a refresh path). A hardcoded value is a promise that the instance will never change; the moment it does, the script silently operates on the wrong target. If you must ship a specific value, mark it clearly and provide the refresh path; prefer prompting with a sensible detected default. This applies to every installer, storage script, optimizer, and future script.
13. **Docs record the setup, never what the operator does with it.** Never write volatile, operator-editable state into any `.md`: statistics, database contents, user lists, mailbox addresses in use, which game server is running, game-server tuning decisions pending, quota values that change from a website, monitor definitions, anything the operator can change from a web UI without touching the host terminal. If a fact can change via a website, it will change, and the doc will be stale the moment it does. Setup facts (how a service is deployed, which routes exist, which config files matter) belong in docs; *usage* of the services does not.
14. **No dead records, fallbacks, or "now removed" commentary.** Anything that isn't real anymore (a retired path, an old name, a superseded config, a fallback file kept "for history") must be deleted from the repo, the host, and the docs — not described. Never write comments like "X worked Y way, now removed" or "kept for audit/history": if X is gone, remove it and its references; the git history keeps the record. A doc or comment that describes something that no longer exists is a trap for the next agent.

## Boundaries between docs

Each `.md` file in the repo has a single purpose. Don't blur them.

- **`README.md`** — visitor-facing. "What is real, and why." The system as it exists today: architecture, request flow, domain/access model, design choices. No planned features, no uncertainty, no operational details, no volatile state.
- **`docs/AGENTS.md`** (this file) — agent-facing rules. Portable to any look-alike system. The "how an agent must behave" — not "how this project works". Project-specific facts (recipe names, paths, vhost lists, port numbers) belong in `docs/GUIDE.md`, not here.
- **`docs/GUIDE.md`** — project-facing operator guide. "How to do x, where is y, what's z" for this specific repo. Layout, deployment commands, protected resources, per-service edit-safe facts, operational gotchas, lessons, intended-behaviour rationales. This is the ONLY file that carries project-specific facts.
- **`docs/ISSUES.md`** — task tracker. Open problems (bugs, security gaps, efficiency losses, robustness risks) that are not yet fixed; resolved problems for history, one sentence each. No rationale prose, no lessons, no intended-behaviour documentation — those live in `docs/GUIDE.md`.

When a fact fits two files, it belongs in the lower one in this list. A future agent reading only `README.md` should understand the system; a future agent reading only `docs/AGENTS.md` should understand the rules; a future agent reading only `docs/GUIDE.md` should be able to deploy and operate the system.

## Doc-audit directives

These directives govern how agents detect and correct drift, stale content, and duplicates when updating docs. Apply them every time a `.md` file is edited — not only at the end of a task.

**Docs always reflect the repo — never the reverse.** The repo (compose files, Makefile, systemd units, Caddyfile, Dockerfile, app source, the running system) is the ground truth; every `.md` is a derived description. When a doc and the repo disagree, the doc is wrong — fix the doc in place, never the repo.

**Missing repo artifacts are deliberate until the operator says otherwise.** A file, directory, or service absent from the repo was removed on purpose — even if a doc, the Makefile, or a script still references it. Never restore, re-create, copy in, or resurrect anything missing: no `git checkout` of deleted paths, no copying from the host or from git history, no re-adding "reference copies". If the absence breaks tooling (e.g. `make install-config` copies a file that doesn't exist), that is an operator decision point, not an invitation to fix: log the gap in `docs/ISSUES.md` and leave the repo untouched. The only exception is an explicit operator instruction to restore.

**When in doubt, treat the repo as authoritative and the artifact as deliberately removed.** Note the mismatch in `docs/ISSUES.md` for the operator instead of acting on it.

**Drift** = a documented fact that disagrees with the executable source (compose files, Makefile, systemd units, Caddyfile, Dockerfile, app source). Examples: a wrong port, an old container name, a recipe name that no longer matches the Makefile, a Caddyfile matcher that has moved, a claimed "X is renamed to Y" in a Solved entry where the rename was never applied on disk.

**Stale** = content that has lost its anchor in reality — paths that no longer exist, port numbers that changed, container names that were renamed, units that were retired, hardening claims that were weakened, volatile operator-editable state that drifted from the live websites, "currently" / "right now" snapshots that drifted from the steady state.

**Duplicate** = the same fact (sentence, command, port, path, claim) living in two or more `.md` files, or two paragraphs in the same file restating each other.

### How to detect each one

- **Drift** — diff-driven. For every concrete fact in the doc (port, path, command, container name, unit name, env var, image tag, log cap, route matcher, schema column, file reference), `grep` the executable source for the same fact and confirm they agree. If a doc says "Caddy matches `@not_tailnet`" but the Caddyfile no longer has that matcher, the doc is wrong. Don't paraphrase what's in the repo — point at the file (writing rule 11) and verify the file still says what you think it says.
- **Stale** — path-of-existence check. For every path, port, hostname, container name, unit name, and file reference in the doc, confirm it still exists on disk (`ls`, `docker ps`, `systemctl list-units`). If the doc references a vhost that no longer exists, the doc is stale. Treat Solved entries as historical but still anchored — they must accurately describe what changed and what replaced it. Volatile-state checks: if a doc fact can be changed from a website (mailbox lists, game-server state, quotas, users), it is stale by construction — remove it (rule 13).
- **Duplicate** — same fact in two places. If a sentence appears verbatim or near-verbatim in two files, one of them is wrong; delete the higher-file instance per the boundaries list. If two Solved entries describe the same change from different angles, collapse them.

### What to do when you find drift / stale / duplicate

1. **The source wins.** The executable source (compose, Makefile, systemd unit, Caddyfile, app source) is the truth; the doc is wrong. Fix the doc, not the source (unless the source is what's broken — that's a separate bug, log it in `docs/ISSUES.md`).
2. **Be specific in the fix.** Don't rewrite the surrounding paragraph — replace the drifted/stale/duplicated fact with the correct one in place. Preserve verified useful guidance around it (writing rule 9).
3. **For Solved entries that claim a change was made but wasn't**, downgrade the claim to match reality (e.g. "claimed rename; never actually applied — see Open" or revert the entry until the rename is done for real). A Solved entry that lies is worse than no entry — future agents act on it.
4. **For intended-behaviour rationales that no longer reflect the code**, rewrite the rationale or move the behaviour to Open if it's actually unintended now.
5. **For duplicates across files**, delete the higher-file instance per the boundaries list. Each fact lives in exactly one place.

### When to audit

- After every system change, refactor, or operational decision (mandatory per safety rule 4).
- At the end of every task — see "Before finishing a task" for the full checklist.
- When picking up an old issue in `docs/ISSUES.md` whose root cause might no longer apply (the fix landed elsewhere; the entry is stale).
- Before committing any doc-only change (verify the new content doesn't introduce its own drift).
- After any debug hell — fold a lesson into the relevant section of `docs/GUIDE.md` (safety rule 11). The lessons are the most valuable future-agent artifact; don't skip them.

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
2. **If this task was a debug hell** (symptom didn't match the obvious cause, took multiple non-obvious hops to root-cause, or surfaced a non-documented tool/config interaction), fold a lesson into the relevant section of `docs/GUIDE.md` per Safety rule 11. Do this *before* the doc audit, not after — the lesson is the most valuable future-agent artifact.
3. **Doc audit — mandatory, not optional (Safety rule 4 + doc-audit directives).** Walk every `.md` file in the repo and apply the three prongs from the doc-audit directives:
   - **Delete stale** — anything that no longer matches the running system: outdated paths, ports, container names, unit names, hardened/locked-down claims, decommissioned services, retired rationale, volatile operator-editable state, "currently" / "right now" snapshots that have drifted, "now removed" commentary. For every path/port/hostname/unit/container in the doc, confirm it still exists on disk. For Solved entries, confirm the change they describe actually happened — a Solved entry that lies is worse than no entry.
   - **Correct drift** — every fact in every `.md` (commands, ports, paths, file references, env vars, image tags, log caps, route matchers, behaviour claims) must match the executable source (compose files, Makefile, systemd units, Caddyfile, Dockerfile, app source). Diff docs against the source; if they disagree, the source wins and the doc is wrong. Use `grep` to verify each concrete fact.
   - **Organize duplicates** — each fact lives in exactly one place. If a sentence appears in two files, delete the one in the higher file (per the boundaries list). If a Solved entry is multi-line, collapse to one line (writing rule 10). If a section restates another doc, point at the other doc instead.
4. Update `README.md` if the architecture, request flow, or design choices changed.
5. Update `docs/GUIDE.md` if the layout, commands, per-service facts, or lessons changed.
6. Update or resolve items in `docs/ISSUES.md` if you fixed something listed there.
7. Add new issues you discovered to `docs/ISSUES.md`.
8. Commit and push (Safety rule 3).

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
9. **Preserve verified useful guidance.** When editing an existing `.md`, keep what's accurate and high-signal; only delete fluff, duplicates, stale claims, and volatile state. Don't rewrite blindly.
10. **Categorize `Solved` history by month.** In `docs/ISSUES.md`, group resolved items under `### Mon YYYY — short label` headings (e.g. `### Jul 2026 — early system build`). Add a new heading only when the month changes — never create a second heading for the same month; append to the existing one. **One line per resolved issue, one sentence, aggressively short** — format: `- **Short title** — one-sentence summary.` Aim for ~100 chars after the dash. Every resolved item stays recorded, but as a single short sentence — never multi-line entries, sub-bullets, paragraphs, or root-cause narratives (the full story lives in the git history).
11. **Don't re-type what's in the repo.** If a fact can be confirmed by reading the compose file, config, app source, or Makefile, point at the file — don't paraphrase it. Anything that drifts the moment a file is edited is more harm than help. This applies to image tags, env vars, log caps, healthcheck commands, route tables, schema columns, and `content/` file contents in particular.
12. **README = real and verified, never planned or unsure.** Anything you can't point at in the running system today doesn't belong in `README.md`. If it's planned, drop it; if it's speculative, drop it. `docs/ISSUES.md` is the right home for "we should add X" / "consider switching to Y" — even before approval, as long as it's framed as a candidate.
13. **Never write volatile, operator-editable state** (rule 13 above): statistics, users, mailbox contents, game-server state, website-editable config values. Docs describe the setup, not the usage.
14. **No "now removed" / "kept for history" commentary** (rule 14 above): delete dead things and their references instead of describing them.

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

When a behaviour looks like a bug but is deliberate, document the rationale in the relevant section of `docs/GUIDE.md` (not `docs/ISSUES.md`) so future agents don't "correct" it. Only behaviours that genuinely need fixing belong in `docs/ISSUES.md`.

This template's project-specific section is intentionally absent: project-specific overrides live in `docs/GUIDE.md`.
