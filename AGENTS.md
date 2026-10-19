# AGENTS.md — hard rules for AI agents and operators

## Git
- `--no-verify` is FORBIDDEN on every commit and every push (whichever command is
  affected). Pre-commit and pre-push hooks always run; if a hook fails, fix the
  problem and re-run the command normally. Never bypass, edit to skip, or
  uninstall the hooks to make a commit or push succeed.

## Installer invariants (see scripts/install/wizard.sh)
- Never commit or push unless the user explicitly asks for it in the current task.
- data/logs/wizard.log is cleared at the start of each run; fix root causes, not symptoms.
- wizard.state is the source of truth for repair mode; apply non-live changes, skip unchanged.