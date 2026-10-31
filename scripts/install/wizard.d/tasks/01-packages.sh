# wizard.d/tasks/01-packages.sh — `System Packages`: base apt set, machine rename, timezone.

# ───────────────────────────── Phase 1 (root) ─────────────────────────────
# One function per checklist task, in checklist (TASK_NAMES) order. Each opens
# with task_start and closes with task_end, so a `fail` inside marks its row
# [FAIL] and the run continues through the remaining tasks.

# System Packages: log relocation, hostname, base apt packages.
task_packages() {
  task_start
  # Log may contain host/secret-adjacent output — root-readable only, never 666.
  # One-time relocation off the legacy /var/log paths (never drop the old log).
  if [ ! -f "$LOG" ]; then
    for old in /var/log/$NODE_NAME-install.log /var/log/homelab-install.log \
               /var/log/$GITHUB_USER/install.log; do
      [ -f "$old" ] && { mv -f "$old" "$LOG"; break; }
    done
  fi
  touch "$LOG" && chmod 640 "$LOG"

  # Canonical machine name: root@$NODE_NAME must agree with the OS hostname.
  if [ "$(hostname -s 2>/dev/null)" != "$NODE_NAME" ]; then
    hostnamectl set-hostname "$NODE_NAME" >>"$LOG" 2>&1 || true
    detail "  hostname set to $NODE_NAME (tailnet node will be $NODE_NAME)"
  fi

  DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$LOG" 2>&1
  # bzip2 is REQUIRED: goose's official download_cli.sh ships a .tar.bz2 — without
  # bzip2 the extraction fails and goose lands in the error list as a phantom
  # "unexpected error" whose real cause is a missing extractor.
  # dnsutils = dig: the dkim_setup re-check and its hint query the zone's
  # nameserver directly ("dig +short TXT dkim._domainkey.$DOMAIN @<zone NS>").
  # gh = the GitHub CLI: `make git-pr` / `make git-issue` open the pull request
  # and file the issue themselves once `gh auth login` has been run once.
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    git curl make sudo dnsmasq ufw jq apache2-utils fail2ban sqlite3 python3-yaml tmux bzip2 dnsutils gh >>"$LOG" 2>&1 || fail apt
  task_end
}
