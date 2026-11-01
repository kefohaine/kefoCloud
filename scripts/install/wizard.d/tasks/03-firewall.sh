# wizard.d/tasks/03-firewall.sh — `Firewall Rules`: ufw defaults and the tailnet-only port set.

# Firewall Restriction: ufw (tailnet SSH, public 80/443, mail + Talk ports).
task_firewall() {
  task_start
  ufw allow from 100.64.0.0/10 to any port 22 proto tcp >/dev/null 2>&1
  # Remove stale installer-session SSH rules from prior runs (tailnet rule stays).
  while IFS= read -r _ip; do
    [ "$_ip" = "100.64.0.0/10" ] && continue
    ufw --force delete allow from "$_ip" to any port 22 proto tcp >/dev/null 2>&1 || true
  done < <(ufw status numbered 2>/dev/null | grep '22/tcp' | awk '{print $NF}')
  # Keep the current SSH client reachable even before it joins the tailnet, so
  # enabling ufw never locks the operator out mid-install. TEMPORARY rule for
  # the installer session only: finalize_hardening deletes it once the run
  # succeeds (a permanent rule for a consumer IP would be a standing hole).
  INSTALLER_SSH_IP="${SSH_CLIENT:+$(echo "$SSH_CLIENT" | awk '{print $1}')}"
  if [ -n "$INSTALLER_SSH_IP" ]; then
    ufw allow from "$INSTALLER_SSH_IP" to any port 22 proto tcp >/dev/null 2>&1 || true
  fi
  ufw allow 80/tcp >/dev/null 2>&1
  ufw allow 443/tcp >/dev/null 2>&1
  # Self-hosted mail (Mailu): SMTP + submission + IMAPS. Converges both ways —
  # a module turned OFF in repair loses the ports, so the box does not keep a
  # public mail door open for a stack that no longer exists.
  local p
  for p in 25 465 587 993; do
    if [ "${MOD_MAIL:-false}" = "true" ]; then
      ufw allow "$p/tcp" >/dev/null 2>&1
    else
      ufw --force delete allow "$p/tcp" >/dev/null 2>&1 || true
    fi
  done
  # Default-deny incoming, set explicitly: some base images ship ufw's
  # DEFAULT_INPUT_POLICY as "ACCEPT" (this one did), and with that `ufw enable`
  # plus the allow rules above restrict nothing — every port, 22 included, stays
  # world-open and the rules are cosmetic. The tailnet rule and the temporary
  # installer rule above cover the must-stay-reachable paths, and ts-input
  # accepts the tailscale0 interface before the ufw chains, so tailnet DNS/SSH
  # are unaffected.
  ufw default deny incoming >/dev/null 2>&1 || true
  echo y | ufw enable >/dev/null 2>&1 || true
  task_end
}
