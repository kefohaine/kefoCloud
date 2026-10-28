# wizard.d/tasks/17-monitor.sh — `Monitoring Setup`: the monitor module’s step (see wizard.d/modules/uptimekuma/).

task_monitor() {
  task_start
  if mod_on monitor; then kuma_seed; else detail "  monitor module off — skipped"; task_skip; fi
  task_end
}
