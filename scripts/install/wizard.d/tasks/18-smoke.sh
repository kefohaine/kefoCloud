# wizard.d/tasks/18-smoke.sh — `Smoke Pass`: one `make smoke`, run from finalize_install after the checkpoint.

# The last checklist row. run_smoke is the body; the row is started and ended
# around it so a smoke failure shows as this row's [FAIL].
task_smoke() {
  task_start
  run_smoke || TASK_ERR=1
  task_end
}


# The install checkpoint gate — the LAST thing a green run does, in this order:
#   1. the stack is up (assets installed) — already true when this runs.
#   2. GitHub push (opt-in + an authorized key): a --no-verify push to a
#      TEMPORARY remote. It runs BEFORE the checkpoint on purpose: a rejected
#      push (not a collaborator, diverged history) means the run is NOT done, so
#      no `finished=true` is ever recorded for it. github_push returns 0
#      immediately when NOT opted in.
#   3. record the install: enabled_modules + finished=true, via write_state.
#   4. ONE `make smoke` — the "is everything actually done?" source. The gate it
#      enforces (wizard.state finished=true) is why the checkpoint is written
#      FIRST; its EXIT CODE is the verdict (core + enabled modules decide it, a
#      not-installed module's checks are informational only).
#   5. finished=false + stop, no success block, when smoke fails. Fail LOUD.
# Nothing but this script ever writes wizard.state: `make smoke` only reports,
# and the installer records the verdict of the single call it makes.
# CHECKPOINT_OPEN guards the window between step 3 and the last decision: if the
# run is interrupted there, the EXIT trap reverts finished to false.
run_smoke() {
  detail "  running the live edge smoke test (make smoke) — the last check"
  # ONE call, ONE source of truth: `make smoke`'s exit code. smoke itself never
  # writes wizard.state — this script reads the code and records the verdict
  # (that is what keeps the installer the sole writer, and what lets an operator's
  # own `make smoke`, and the pre-push hook, only report). The output is
  # captured so the per-check FAIL lines can be shown to the operator on a
  # failure (not just hidden in the log).
  local out
  if out="$(make -C "$REPO" smoke 2>&1)"; then
    printf '%s\n' "$out" >>"$LOG"
    detail "  smoke passed — the edge and every enabled module answer"
    return 0
  fi
  printf '%s\n' "$out" >>"$LOG"
  # Keep only the failing check lines — smoke prints one `FAIL …` line per check
  # that did not pass, plus a trailing summary. That is what the operator needs.
  SMOKE_FAILS="$(printf '%s\n' "$out" | grep -E '^FAIL ' || true)"
  detail "  SMOKE FAILED — the edge is not fully serving every enabled module"
  return 1
}
