# wizard.d/tasks/15-cloud.sh — `Nextcloud Setup`: the cloud module’s step (see wizard.d/modules/nextcloud/).

task_cloud() {
  task_start
  if mod_on cloud; then nextcloud_setup; else detail "  cloud module off — skipped"; task_skip; fi
  task_end
}
