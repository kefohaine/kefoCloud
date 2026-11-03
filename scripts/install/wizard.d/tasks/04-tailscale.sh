# wizard.d/tasks/04-tailscale.sh — `Tailscale Connectivity`: join the tailnet, wait for the node.

# Tailscale Connectivity: install, encrypt state at rest, join, read the IP.
task_tailscale() {
  task_start
  if ! command -v tailscale >/dev/null 2>&1; then
    # The vendor's apt repository, not `curl … | sh`: the script is fetched and
    # executed unseen, which is supply-chain exposure with root on this host,
    # while the repo gives a signed keyring, a sources file and a normal apt
    # install. Output goes to the LOG, never the console (apt chatter would
    # scatter the live checklist — 2026-10-16).
    local codename
    codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-stable}")"
    install -d -m 0755 /usr/share/keyrings
    curl -fsSL -o /usr/share/keyrings/tailscale-archive-keyring.gpg \
      "https://pkgs.tailscale.com/stable/debian/${codename}.noarmor.gpg" >>"$LOG" 2>&1 \
      || fail tailscale
    curl -fsSL -o /etc/apt/sources.list.d/tailscale.list \
      "https://pkgs.tailscale.com/stable/debian/${codename}.tailscale-keyring.list" >>"$LOG" 2>&1 \
      || fail tailscale
    DEBIAN_FRONTEND=noninteractive apt-get update >>"$LOG" 2>&1 || fail tailscale
    DEBIAN_FRONTEND=noninteractive apt-get install -y tailscale >>"$LOG" 2>&1 || fail tailscale
  fi
  # Encrypt the tailscaled state file at rest. On Linux the flag NEEDS a TPM
  # (/dev/tpmrm0): on a box without one, forcing `--encrypt-state` makes
  # tailscaled fail to start and takes the node offline, so enable it only when
  # the device exists — and start tailscaled fresh with it before joining.
  if [ -e /dev/tpmrm0 ] && [ -f /etc/default/tailscaled ]; then
    if ! grep -q -- '--encrypt-state' /etc/default/tailscaled; then
      sed -i -E 's|^FLAGS=.*|FLAGS="--encrypt-state"|' /etc/default/tailscaled
      systemctl restart tailscaled >>"$LOG" 2>&1 || log "tailscaled restart failed after enabling --encrypt-state"
      detail "  tailscale state encryption enabled (FLAGS=--encrypt-state, TPM present)"
    fi
  elif [ ! -e /dev/tpmrm0 ]; then
    detail "  no TPM (/dev/tpmrm0): tailscale state encryption unsupported here — left off"
  fi
  # A cached IP is NOT proof the node is on the tailnet: once the node is removed
  # from the tailnet the control server answers "404: node not found" yet
  # `tailscale ip -4` still prints the stale address, so the old `if ! tailscale
  # ip -4` guard skipped the join and left the box permanently off-tailnet. Gate
  # on the live control-plane state (Self.Online) instead.
  if cred_changed tailscale "$TS_AUTHKEY"; then
    # wizard.state holds a DIFFERENT authkey than the one the node joined with:
    # re-authenticate even though the node is online (true->new-value applies).
    log "  TS_AUTHKEY changed in wizard.state — re-authenticating the node"
    tailscale up --authkey="$TS_AUTHKEY" --force-reauth >>"$LOG" 2>&1 || fail tailscale_up
  elif [ "$(tailscale status --json 2>/dev/null | jq -r '.Self.Online // false')" != "true" ]; then
    # No --hostname: the tailnet node adopts the OS hostname ($NODE_NAME) so the
    # sole entry point is root@$NODE_NAME (MagicDNS).
    tailscale up --authkey="$TS_AUTHKEY" >>"$LOG" 2>&1 || fail tailscale_up
  else
    detail "  node online, TS_AUTHKEY unchanged — join skipped"
  fi
  cred_note tailscale "$TS_AUTHKEY"
  TS_IP=$(tailscale ip -4 2>/dev/null | head -1)
  [ -n "$TS_IP" ] && log "tailscale IP: $TS_IP" || fail ts_ip
  # A rejoin can hand the node a NEW tailnet IP, and dnsmasq binds its split-DNS
  # resolver to that address — a stale bind makes tailnet *.$DOMAIN refuse. The
  # `address=`
  # answers for ttyd.$DOMAIN (and the other tailnet-only doors) must move with
  # it: a bind on the live IP plus an answer on the old one resolves the door to
  # a departed address. Refresh the render whenever either line no longer
  # matches the live IP, so the machine never sits on a dead bind or a stale
  # answer after a rejoin. The render + sed pair is exactly what
  # `make install-config` uses, so one source of truth; non-fatal because
  # install-config re-renders unconditionally later anyway.
  if [ -f /etc/dnsmasq.d/10-tailnet.conf ] \
     && { ! grep -q "listen-address=$TS_IP\$" /etc/dnsmasq.d/10-tailnet.conf \
          || ! grep -q "address=/ttyd\.$DOMAIN/$TS_IP\$" /etc/dnsmasq.d/10-tailnet.conf; }; then
    bash "$REPO/scripts/render/render-all.sh" >>"$LOG" 2>&1 || true
    make -C "$REPO" install-dnsmasq-conf >>"$LOG" 2>&1 \
      || log "dnsmasq split-DNS refresh failed (install-config will render it later in the run)"
  fi
  task_end
}
