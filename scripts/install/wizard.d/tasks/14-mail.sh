# wizard.d/tasks/14-mail.sh — `Mail Setup`: the mailserver module’s step (see wizard.d/modules/mailserver/).

# Per-module setup, one checklist row each (a module that is off marks its row
# [SKIP], so the checklist says exactly which module ran and which was off).
task_mail() {
  task_start
  if mod_on mail; then mail_wait_ready; dkim_setup; else detail "  mail module off — skipped"; task_skip; fi
  task_end
}
