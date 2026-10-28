# wizard.d/flow/hardening.sh — the host-hardening tail: called by resolve_errors
# once every error is resolved, before finalize_install (sshd hardening when a key
# exists by then, and the sweep of the temporary/stale installer SSH rules).

finalize_hardening() {
  # Runs once every error is resolved: if a key exists now, harden sshd
  # (phase 1 skipped it when no key was present at install time). Same
  # change-detection as task_ssh — a re-run that writes identical config does
  # not restart sshd, so an operator's session is never dropped for nothing.
  if [ -s /root/.ssh/authorized_keys ]; then
    local before after
    before=$(cat /etc/ssh/sshd_config.d/50-cloud-init.conf 2>/dev/null | sha256sum)
    printf 'PasswordAuthentication no\nPermitRootLogin prohibit-password\nAllowUsers root\n' \
      > /etc/ssh/sshd_config.d/50-cloud-init.conf
    chmod 600 /etc/ssh/sshd_config.d/50-cloud-init.conf
    after=$(cat /etc/ssh/sshd_config.d/50-cloud-init.conf 2>/dev/null | sha256sum)
    [ "$before" = "$after" ] || systemctl restart sshd >/dev/null 2>&1 || true
  fi
  # Close the temporary installer-session SSH rule (tailnet access stays).
  local ip="${INSTALLER_SSH_IP:-}"
  if [ -n "$ip" ] && [ "$ip" != "$(tailscale ip -4 2>/dev/null | head -1)" ]; then
    ufw --force delete allow from "$ip" to any port 22 proto tcp >/dev/null 2>&1 || true
    ufw delete allow from "$ip" to any port 22 proto tcp >/dev/null 2>&1 || true
    detail "  removed the temporary installer SSH allow for $ip (root@$NODE_NAME over the tailnet remains the entry point)"
  fi
  # Also remove any remaining stale SSH rules from prior installs.
  while IFS= read -r _ip; do
    [ "$_ip" = "100.64.0.0/10" ] && continue
    ufw --force delete allow from "$_ip" to any port 22 proto tcp >/dev/null 2>&1 || true
  done < <(ufw status numbered 2>/dev/null | grep '22/tcp' | awk '{print $NF}')
}
