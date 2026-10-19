# AGENTS.md — hard rules for AI agents and operators

## Git
- `--no-verify` is FORBIDDEN on every commit and every push (whichever command is
  affected). Pre-commit and pre-push hooks always run; if a hook fails, fix the
  problem and re-run the command normally. Never bypass, edit to skip, or
  uninstall the hooks to make a commit or push succeed.
- The ONE designed exception: `scripts/install/wizard.sh`'s own first-run push
  to the `temppush` remote uses `--no-verify`, because the pre-push hook's smoke
  cannot pass before `wizard.state` records `finished=true`. No agent or operator
  command may use it.

## Scripts
- Never run a script on the operator's behalf without explicit approval in the
  current task — not even for debugging or to reproduce a bug. Without it, read
  it, lint it (`bash -n`), or use its dry-run/fixture mode only; the operator
  runs the real thing (docs/AGENTS.md rule 29).

## Installer invariants (see scripts/install/wizard.sh)
- Never commit or push unless the user explicitly asks for it in the current task.
- data/logs/wizard.log is cleared at the start of each run; fix root causes, not symptoms.
- wizard.state is the source of truth for repair mode; apply non-live changes, skip unchanged. Repair mode is fully idempotent and add-only: it never hands off to uninstall.sh, and certs already served by Caddy are never re-issued (no trigger request, no ACME order).