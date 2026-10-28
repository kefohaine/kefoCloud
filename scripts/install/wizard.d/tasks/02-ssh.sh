# wizard.d/tasks/02-ssh.sh — `SSH Hardening`: authorized key, sshd config, the temporary installer-session rule.

# SSH Hardening: single operator account + key-only root sshd.
task_ssh() {
  task_start
  # Single operator account: root. The provider image may ship a login-capable
  # account (e.g. the cloud-init 'debian' user) — remove every non-root account
  # with a real UID so root@$NODE_NAME is genuinely the only way in.
  local u uid home sh
  while IFS=: read -r u _ uid _ _ home sh; do
    [ "$u" = root ] && continue
    [ "$uid" -ge 1000 ] 2>/dev/null || continue
    [ "$uid" -lt 65534 ] || continue
    # systemd dynamic users live in 61184-65519 and cannot be deleted with
    # userdel ("user does not exist" — they are not in /etc/passwd). They also
    # never log in: skip them, and skip any account whose shell is nologin.
    [ "$uid" -ge 61184 ] && continue
    case "$sh" in */nologin|*/false|'') continue ;; esac
    detail "  removing non-root login account '$u' ($home)"
    pkill -u "$u" 2>/dev/null || true
    sleep 1
    userdel -r "$u" >>"$LOG" 2>&1 || userdel "$u" >>"$LOG" 2>&1 || true
  done < <(getent passwd)

  # SSH: root key-only. The operator's pubkey is collected by ask_ssh_key BEFORE
  # this phase (strict), so a missing key here means the step failed — the
  # `ssh_keys` guard stays as the safety net, and hardening (password auth off,
  # root key-only) is applied ONLY once a usable key exists, so the box is never
  # locked out. The installer never mints a server-side login keypair.
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  if [ -s /root/.ssh/authorized_keys ]; then
    chmod 600 /root/.ssh/authorized_keys
    # Restart sshd ONLY when the config actually changed: a restart drops every
    # in-flight session, and a re-run that rewrites byte-identical files must not
    # disconnect the operator mid-install.
    local ssh_before ssh_after
    ssh_before=$(cat /etc/ssh/sshd_config.d/50-cloud-init.conf /etc/ssh/sshd_config 2>/dev/null | sha256sum)
    printf 'PasswordAuthentication no\nPermitRootLogin prohibit-password\nAllowUsers root\n' \
      > /etc/ssh/sshd_config.d/50-cloud-init.conf
    chmod 600 /etc/ssh/sshd_config.d/50-cloud-init.conf
    sed -i -e 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' \
           -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' \
           -e 's/^#\?X11Forwarding.*/X11Forwarding no/' /etc/ssh/sshd_config
    grep -q '^PubkeyAuthentication' /etc/ssh/sshd_config || echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config
    grep -q '^AllowUsers' /etc/ssh/sshd_config || echo 'AllowUsers root' >> /etc/ssh/sshd_config
    ssh_after=$(cat /etc/ssh/sshd_config.d/50-cloud-init.conf /etc/ssh/sshd_config 2>/dev/null | sha256sum)
    if [ "$ssh_before" != "$ssh_after" ]; then
      systemctl restart sshd >>"$LOG" 2>&1 || true
      detail "  sshd hardened: key-only root login (AllowUsers root)"
    else
      detail "  sshd already hardened (unchanged) — not restarted"
    fi
  else
    fail ssh_keys
    log "no SSH key in /root/.ssh/authorized_keys (ask_ssh_key should have installed one) — add a pubkey, then re-check; sshd stays password-capable until then"
  fi
  task_end
}
