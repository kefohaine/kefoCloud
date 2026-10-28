# wizard.d/tasks/08-host.sh — `Host Services`: host units (dnsmasq, ttyd, goose, fail2ban, …) and benign failed units.

# Two host units the distro ships are permanently 'failed' on this box without
# changing anything: openipmi starts the IPMI driver a machine with no IPMI
# hardware cannot load, and systemd-networkd-wait-online waits on networkd
# (which is not managing the links here). They show up in `make fetch` as
# "2 failed" forever. Disable them and clear the failed state. Idempotent, and
# every other unit is left untouched (never blanket-reset failed units — that
# would hide a real one).
disable_benign_failed_units() {
  local u
  for u in openipmi.service systemd-networkd-wait-online.service; do
    systemctl cat "$u" >/dev/null 2>&1 || continue
    if systemctl is-enabled --quiet "$u" 2>/dev/null; then
      systemctl disable "$u" >>"$LOG" 2>&1 || true
      detail "  disabled $u (fails every boot without the hardware/daemon it expects)"
    fi
    if systemctl is-failed --quiet "$u" 2>/dev/null; then
      systemctl reset-failed "$u" >>"$LOG" 2>&1 || true
      detail "  cleared the failed state of $u"
    fi
  done
}

host_services() {
  [ -n "${TS_IP:-}" ] || fail ts_ip
  # The tracked 10-tailnet.conf keeps a PLACEHOLDER address — install-config
  # renders the live Tailscale IP in at deploy time, so the repo file is never
  # mutated and no instance-specific address is ever committed.
  make install-config >>"$LOG" 2>&1 || fail install_config
  # Clear any `tailscale serve` mapping so nothing shadows the Caddy tail vhost
  # (idempotent; a no-op when serve has no configuration).
  tailscale serve reset >>"$LOG" 2>&1 || true
  # fail2ban: on trixie the default file backend finds no /var/log/auth.log and
  # the unit exits 255. Our jail.d/sshd.conf ships backend=systemd; restart and
  # verify so a silently-dead jail can never pass as hardened.
  systemctl restart fail2ban >>"$LOG" 2>&1 || true
  # `systemctl restart` returns while the unit is still activating, and
  # install-config restarts fail2ban again seconds later — so poll for the
  # server + the sshd jail instead of judging the unit on the first look
  # (2026-09-25: the tag fired ~0.3 s before the jail came up and then sat in
  # the summary as a phantom "not running" error on an active fail2ban).
  local i=0
  while [ $i -lt 30 ]; do
    systemctl is-active --quiet fail2ban && fail2ban-client status sshd >/dev/null 2>&1 && break
    sleep 1; i=$((i+1))
  done
  systemctl is-active --quiet fail2ban || fail fail2ban
  fail2ban-client status sshd >/dev/null 2>&1 || fail fail2ban
}


# Host Services: render+install host config (make install-config) and clear the
# two benign permanently-failed distro units.
task_host() {
  task_start
  host_services
  disable_benign_failed_units
  task_end
}
