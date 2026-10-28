# wizard.d/tasks/index.sh — THE task order, in one place: checklist rows (TASK_NAMES) and the run list (TASKS).

# ─────────────────────── the installation task checklist ───────────────────
# One fixed list, printed once as a live checklist. Each row starts as [WAIT]
# (grey), becomes an animated [EXEC] (orange) while it runs, and ends as [DONE]
# (green), [SKIP] (orange, a module that is off) or [FAIL] (red). A failed task
# HARD-STOPS the run: the checklist pauses on its [FAIL] row and hands the error
# to the operator; once resolved the row flips to [DONE] and the run continues,
# but if it stays unresolved (or there is no terminal) the remaining tasks are
# left [WAIT] and the installer stops — it never runs on past a failure and marks
# the rest [DONE]. Nothing prints between the task rows (msg is muted while
# TASK_ACTIVE is set); each step's own output goes to $LOG. On a non-TTY run the
# animation is skipped and each row is printed once, when it finishes.
TASK_NAMES=(
  "System Packages" "SSH Hardening" "Firewall Rules"
  "Tailscale Connectivity" "Docker Engine" "Goose CLI"
  "Repository Setup" "Host Services" "DNS Records"
  "Repo Hygiene"
  "Stack Config" "Docker Containers" "SSL Certificates"
  "Mail Setup" "Nextcloud Setup" "Vaultwarden Setup"
  "Monitoring Setup"
  "Smoke Pass"
)
# Set in main() when the operator confirms repair — the mode the run's start
# line names (a fresh install sets neither).
REPAIR=
TASK_TOTAL=${#TASK_NAMES[@]}

# The ordered task list, in TASK_NAMES order. A task that fails PAUSES the
# checklist on its [FAIL] row (later rows stay [WAIT]) and hands the error to
# the operator; once resolved, the block clears, the list returns and the run
# continues from the next task. An unresolved failure HARD-STOPS the run
# (returns non-zero) instead of continuing — the wizard can never finish through
# an unresolved failure, and never marks the tasks after it [DONE]. "Smoke Pass"
# is the last task and is marked from finalize_install — it runs only after the
# push and the finished checkpoint.
# The run order, in ONE place: the checklist (TASK_NAMES) and run_install both
# read it, so the two can never drift.
# Same order as TASK_NAMES: every [HOST] step first, then the [STACK] steps,
# then the [BOTH] verdict (smoke). Nothing in the list depends on a later step,
# except that the stack needs the host ready (docker, goose, DNS, certs) — which
# is exactly why the host half comes first.
# One entry per checklist row, in the SAME order as TASK_NAMES — including
# smoke (run_finalize's last row), which run_install does not call because it
# runs from finalize_install after the checkpoint: the list is the checklist's
# row map first, and the run order second.

TASKS=(
  task_packages task_ssh task_firewall task_tailscale task_docker task_goose
  task_repo task_host task_dns task_hygiene
  task_stackcfg task_containers task_certs task_mail task_cloud task_vault
  task_monitor task_smoke
)
