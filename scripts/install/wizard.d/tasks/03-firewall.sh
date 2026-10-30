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
  # Self-hosted mail (Mailu): SMTP + submission + IMAPS.
  if [ "${MOD_MAIL:-false}" = "true" ]; then
    ufw allow 25/tcp >/dev/null 2>&1
    ufw allow 465/tcp >/dev/null 2>&1
    ufw allow 587/tcp >/dev/null 2>&1
    ufw allow 993/tcp >/dev/null 2>&1
  fi
  # Nextcloud Talk (only when video calling is on): TURN/STUN + relay range
  # (talk.$DOMAIN must stay DNS-only).
  if [ "${MOD_CLOUD:-false}" = "true" ] && [ "${VIDEO_CALLING:-true}" != "false" ]; then
    ufw allow 3478/udp >/dev/null 2>&1
    ufw allow 3478/tcp >/dev/null 2>&1
    ufw allow 5349/tcp >/dev/null 2>&1
    ufw allow 49160:49200/udp >/dev/null 2>&1
    ufw allow 49160:49200/tcp >/dev/null 2>&1
  fi
  # Snikket (module: xmpp) is HOST-NETWORKED: its XMPP, TURN and proxy65
  # listeners never touch the Caddy edge, so ufw is the only gate on them.
  # TURN relays on 49201-65535 (talk-relay owns 49160-49200 above), which is a
  # wide but deliberate range — a narrow one leaves calls failing for the
  # clients that land outside it.
  if [ "${MOD_XMPP:-false}" = "true" ]; then
    ufw allow 5222/tcp >/dev/null 2>&1   # XMPP c2s
    ufw allow 5269/tcp >/dev/null 2>&1   # XMPP s2s
    ufw allow 3478/udp >/dev/null 2>&1   # TURN/STUN (no-op when talk has it)
    ufw allow 3478/tcp >/dev/null 2>&1
    ufw allow 5349/tcp >/dev/null 2>&1   # TURN over TLS
    ufw allow 5349/udp >/dev/null 2>&1
    ufw allow 5000/tcp >/dev/null 2>&1   # proxy65 (file transfer)
    ufw allow 3479/udp >/dev/null 2>&1   # STUN alternate
    ufw allow 3479/tcp >/dev/null 2>&1
    ufw allow 5350/udp >/dev/null 2>&1   # TURN over TLS alternate
    ufw allow 5350/tcp >/dev/null 2>&1
    ufw allow 49201:65535/udp >/dev/null 2>&1
    ufw allow 49201:65535/tcp >/dev/null 2>&1
  fi
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
