# wizard.d/modules/vaultwarden/setup.sh — the vault module: account/org setup and the default admin.

# Vaultwarden SMTP sender mailbox (vaultwarden@$DOMAIN) — created after the
# mailserver container is up (called after containers_up). The SMTP vars the
# vaultwarden container uses come from modules/vaultwarden/.env (written by
# seed_stack); this step only makes the mailbox exist so auth succeeds.
vaultwarden_setup() {
  cd "$REPO" || exit 1
  # The vaultwarden SMTP sender mailbox depends on the mail module: with mail
  # disabled there is no mailserver to authenticate against, so skip it.
  if ! mod_on mail; then
    log "  mail module disabled — skipping mailbox vaultwarden@$DOMAIN"
    return 0
  fi
  . modules/vaultwarden/.env
  # ${SMTP_PASSWORD:-}: an unbound expansion here used to kill this function's
  # pipeline subshell, so the only visible symptom was "mailbox not created"
  # instead of the real fault (seed_stack had skipped writing the key). Name
  # it explicitly now (2026-09-25).
  if [ -z "${SMTP_PASSWORD:-}" ]; then
    fail vaultwarden_setup "SMTP_PASSWORD missing from modules/vaultwarden/.env"
    return
  fi
  mailbox_add "vaultwarden@$DOMAIN" "$SMTP_PASSWORD" \
    || fail vaultwarden_setup "mailbox vaultwarden@$DOMAIN not created"
}

# Create the default Vaultwarden account (the one the success block prints).
# Vaultwarden has no user CLI, so — like Uptime Kuma — the account is written
# into its SQLite DB by scripts/modules/vaultwarden-user.sh (Bitwarden's client
# crypto: master-key hash, the encrypted user key and an RSA key pair). This
# step only runs once the container has made the DB + schema; a re-run leaves an
# existing account untouched (never resets it), so an operator's vault survives.
vaultwarden_admin() {
  cd "$REPO" || exit 1
  . modules/vaultwarden/.env
  if [ -z "${VAULTWARDEN_ADMIN_USER:-}" ] || [ -z "${VAULTWARDEN_ADMIN_PASSWORD:-}" ]; then
    fail vaultwarden_admin "VAULTWARDEN_ADMIN_* missing from modules/vaultwarden/.env"
    return
  fi
  # The container creates db.sqlite3 (and the users table) on first boot — poll
  # for both, not just the file (an empty file is not a usable schema).
  local i=0
  while [ $i -lt 150 ]; do
    bash scripts/modules/vaultwarden-user.sh list >/dev/null 2>&1 && break
    sleep 2; i=$((i+2))
  done
  if ! bash scripts/modules/vaultwarden-user.sh list >/dev/null 2>&1; then
    fail vaultwarden_admin "vault db has no users schema after 5 min"
    return
  fi
  bash scripts/modules/vaultwarden-user.sh ensure "$VAULTWARDEN_ADMIN_USER" "$VAULTWARDEN_ADMIN_PASSWORD" \
    >>"$LOG" 2>&1 || fail vaultwarden_admin
}
