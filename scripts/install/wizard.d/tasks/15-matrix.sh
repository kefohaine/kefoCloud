# wizard.d/tasks/15-matrix.sh — `Matrix Setup`: the chat module's step (see wizard.d/modules/matrix/).

task_matrix() {
  task_start
  if mod_on chat; then matrix_setup; else detail "  chat module off — skipped"; task_skip; fi
  task_end
}
