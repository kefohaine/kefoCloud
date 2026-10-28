# wizard.d/tasks/16-vault.sh — `Vaultwarden Setup`: the vault module’s step (see wizard.d/modules/vaultwarden/).

task_vault() {
  task_start
  if mod_on vault; then vaultwarden_setup; vaultwarden_admin; else detail "  vault module off — skipped"; task_skip; fi
  task_end
}
