# wizard.d/tasks/19-kopia.sh — `Backup Setup`: the kopia module's step.

task_kopia() {
  task_start
  if mod_on kopia; then kopia_setup; else detail "  kopia module off — skipped"; task_skip; fi
  task_end
}
