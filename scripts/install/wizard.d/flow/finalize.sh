# wizard.d/flow/finalize.sh — the finished checkpoint, the smoke row, the success block and the EXIT trap.

finalize_install() {
  # 1-2: the push happens BEFORE the checkpoint. If GitHub was opted in the push
  # is MANDATORY — any failure to push (no key, rejected (non-collaborator),
  # diverged history) means the install is not finished, so no finished=true is
  # recorded and the success block is never reached.
  local ok=1
  github_push || ok=0
  if [ "$ok" != 1 ]; then
    FINISHED=false
    write_state
    echo ""
    msg " NOT FINISHED — the GitHub push failed (see above / $LOG)."
    echo " Fix it, then re-run the installer to finish."
    return 0
  fi
  # 3: the checkpoint opens; smoke's exit code below decides whether it stands.
  FINISHED=true
  CHECKPOINT_OPEN=1
  write_state
  # 4-5: smoke's exit code is the verdict. Pass → the checkpoint we just wrote
  # stands (finished=true). Fail → this script writes finished=false and stops.
  # "Smoke Pass" is the last checklist row, started here because smoke only runs
  # after the push and the finished checkpoint — the row and its body (task_smoke)
  # live in finalize_install rather than in run_install.
  task_smoke
  if [ -n "${TASK_ERR:-}" ]; then
    TASK_ERR=
    FINISHED=false
    write_state
    CHECKPOINT_OPEN=
    echo ""
    # Name the checks that failed (smoke printed one FAIL line per failing
    # check), then tell the operator the exact recovery: fix it and re-run in
    # REPAIR mode. Then ABORT (non-zero) — a failed smoke is not a clean exit.
    _section "SMOKE FAILURES — the edge is not fully serving" "$C_RED"
    if [ -n "${SMOKE_FAILS:-}" ]; then
      while IFS= read -r _l; do
        _note "$(printf '  %s%s%s' "$C_RED" "$_l" "$C_RST")"
      done <<< "$SMOKE_FAILS"
    else
      _note "  (make smoke printed no per-check FAIL lines — see the full output: $LOG)"
    fi
    _note ""
    msg " NOT FINISHED — wizard.state is recorded pending (finished=false)."
    echo " Fix the failing check(s) above, then re-run this installer and choose REPAIR"
    echo " at the prompt to finish (every step is idempotent)."
    return 1
  fi
  CHECKPOINT_OPEN=
  success_block
  ask_optimize
}




success_block() {
  local R="──────────────────────────────────────────────────────────────────"
  local n=0
  log "  SUCCESS — the stack is up (success block shown)"
  echo ""
  printf ' %s%s%s\n' "$C_GREEN" "$R" "$C_RST"
  printf '  %s[SUCCESS]%s the stack is up\n' "$C_GREEN" "$C_RST"
  printf ' %s%s%s\n' "$C_GREEN" "$R" "$C_RST"
  # Only the enabled modules' sites are listed — a site the operator chose not
  # to install (and so will not answer) must not appear. Shell (the tailnet
  # door) and the machine's own addresses are always part of the stack.
  mod_on cloud && printf '  %sNextcloud%s    https://cloud.%s    %sadmin / %s%s\n' \
    "$C_PURPLE" "$C_RST" "$DOMAIN" "$C_GREY" "${NEXTCLOUD_ADMIN_PASSWORD:-<see modules/nextcloud/.env>}" "$C_RST"
  mod_on vault && printf '  %sVaultwarden%s  https://vault.%s    %s%s / %s%s\n' \
    "$C_PURPLE" "$C_RST" "$DOMAIN" "$C_GREY" "${VAULTWARDEN_ADMIN_USER:-admin@$DOMAIN}" "${VAULTWARDEN_ADMIN_PASSWORD:-<see modules/vaultwarden/.env>}" "$C_RST"
  mod_on monitor && printf '  %sUptime Kuma%s  https://kuma.%s    %sadmin / %s%s\n' \
    "$C_PURPLE" "$C_RST" "$DOMAIN" "$C_GREY" "${KUMA_PASS:-(already set — rotate with: make kuma-passwd USER=admin PASS=…)}" "$C_RST"
  # Mailu owns mail.$DOMAIN (platform door, admin UI at /admin, SMTP/IMAP cert);
  # Roundcube has its own door on cube.$DOMAIN.
  mod_on mail && printf '  %sMailu admin%s  https://mail.%s/admin   %s(mailboxes via make mail-gen)%s\n' \
    "$C_PURPLE" "$C_RST" "$DOMAIN" "$C_GREY" "$C_RST"
  mod_on mail && printf '  %sWebmail%s      https://cube.%s   %s(roundcube)%s\n' \
    "$C_PURPLE" "$C_RST" "$DOMAIN" "$C_GREY" "$C_RST"
  if [ "${TAIL_TLS_FALLBACK:-false}" = true ]; then
    printf '  %sShell%s        %s(tailnet-only — run scripts/ops/tailscale-https.sh to serve it via tailscale)%s\n' \
      "$C_PURPLE" "$C_RST" "$C_GREY" "$C_RST"
  else
    printf '  %sShell%s        https://tail.%s   %s(tailnet-only)%s\n' \
      "$C_PURPLE" "$C_RST" "$DOMAIN" "$C_GREY" "$C_RST"
  fi
  printf '  %smachine IP%s %s    %sTailscale IP%s %s\n' \
    "$C_GREY" "$C_RST" "${HOST_IP:-?}" "$C_GREY" "$C_RST" "${TS_IP:-?}"
  echo ""
  printf '  %sSSH%s root@%s is the only entry point (key-only, tailnet-only, port 22)\n' "$C_GREY" "$C_RST" "$NODE_NAME"
  printf '  %snew ssh command is ssh root@%s%s\n' "$C_GREEN" "$NODE_NAME" "$C_RST"
  echo ""
  printf ' %s── SSH ACCESS %s%s\n' "$C_PURPLE" "${R:0:$(( ${#R} - 4 ))}" "$C_RST"
  if [ -s /root/.ssh/authorized_keys ]; then
    printf '  %sHardening IS applied:%s %s key(s) authorized, password auth off, root key-only.\n' \
      "$C_GREEN" "$C_RST" "$(grep -c . /root/.ssh/authorized_keys)"
    printf '  %sRe-run the installer to add another.%s\n' "$C_GREY" "$C_RST"
  else
    printf '  %sWARNING:%s no key in /root/.ssh/authorized_keys, so hardening is NOT applied\n' "$C_RED" "$C_RST"
    printf '  %s(password auth stays on). Re-run the installer and paste your device pubkey.%s\n' "$C_GREY" "$C_RST"
  fi
  printf ' %s%s%s\n' "$C_PURPLE" "$R" "$C_RST"
  echo ""
  printf '  %sFollow-ups (none block the install):%s\n' "$C_GREY" "$C_RST"
  if mod_on mail; then
    n=$((n+1))
    printf '   %s%d. PTR (rDNS) record%s — set it at your VPS provider for %s -> mail.%s\n' \
      "$C_ORANGE" "$n" "$C_RST" "${HOST_IP:-<machine IP>}" "$DOMAIN"
    printf '      %s(only your provider can create it; SPF/DKIM/DMARC alone won'"'"'t stop rejects)%s\n' "$C_GREY" "$C_RST"
  fi
  n=$((n+1)); printf '   %d. Tailscale split-DNS: admin console -> DNS -> add %s -> %s\n' "$n" "$DOMAIN" "${TS_IP:-<tailscale IP>}"
  printf '      %sso tail.%s resolves for tailnet devices (dnsmasq on the machine already answers it)%s\n' "$C_GREY" "$DOMAIN" "$C_RST"
  if [ "${TAIL_TLS_FALLBACK:-false}" = true ]; then
    n=$((n+1)); printf '   %d. Run scripts/ops/tailscale-https.sh — the tail.%s LE order failed (often the LE rate limit), so the door is served over Tailscale HTTPS instead\n' "$n" "$DOMAIN"
  fi
  if mod_on cloud; then
    n=$((n+1)); printf '   %d. %s(optional)%s Cloudflare WAF rule skip for cloud.%s (desktop sync)\n' "$n" "$C_GREY" "$C_RST" "$DOMAIN"
  fi
  n=$((n+1)); if [ "${GH_REMOTE:-false}" = "true" ]; then
    printf '   %d. GitHub remote access: origin is git@github.com:%s/%s.git, key /root/.ssh/github_key\n' "$n" "$GITHUB_USER" "$REPO_NAME"
  else
    printf '   %d. %sNo GitHub remote access%s (declined at the last prompt) — re-run and answer true to mint the push key\n' "$n" "$C_GREY" "$C_RST"
  fi
  if mod_on mail; then
    n=$((n+1)); printf '   %d. Mailboxes: make mail-gen MAIL=name@%s (or bare make mail-gen for a disposable)\n' "$n" "$DOMAIN"
    local senders=""
    mod_on cloud && senders+=" nextcloud@$DOMAIN"
    mod_on vault && senders+=" vaultwarden@$DOMAIN"
    [ -n "$senders" ] && printf '      %sthe app SMTP sender mailboxes are created automatically:%s%s\n' "$C_GREY" "$senders" "$C_RST"
  fi
  printf ' %s%s%s\n\n' "$C_GREEN" "$R" "$C_RST"
}

summary() {
  if [ ${#ERR_TAGS[@]} -gt 0 ]; then
    log "  ERROR(S) — no success until every item below is resolved"
    _section "ERROR(S) — no success until every item below is resolved" "$C_RED"
    local exp=() unexp=()
    for tag in "${ERR_TAGS[@]}"; do
      if is_expected "$tag"; then exp+=("$tag"); else unexp+=("$tag"); fi
    done
    if [ ${#exp[@]} -gt 0 ]; then
      _note "$(printf '  %sManual steps (expected):%s' "$C_ORANGE" "$C_RST")"
      for i in "${!exp[@]}"; do
        _note "$(printf '    %s%d.%s %s%s' "$C_ORANGE" "$((i+1))" "$C_RST" "${exp[$i]}" "$C_RST")"
        _note "$(printf '       %sproblem:%s %s%s' "$C_GREY" "$C_RST" "$(problem "${exp[$i]}")" "${ERR_DETAIL[${exp[$i]}]:+ (${ERR_DETAIL[${exp[$i]}]})}")"
        _note "$(printf '       %shint:%s %s' "$C_GREY" "$C_RST" "$(hint "${exp[$i]}")")"
      done
    fi
    if [ ${#unexp[@]} -gt 0 ]; then
      _note "$(printf '  %sUnexpected errors (%s):%s' "$C_RED" "${#unexp[@]}" "$C_RST")"
      for i in "${!unexp[@]}"; do
        _note "$(printf '    %s%d.%s %s' "$C_RED" "$((i+1))" "$C_RST" "${unexp[$i]}")"
        _note "$(printf '       %sproblem:%s %s%s' "$C_GREY" "$C_RST" "$(problem "${unexp[$i]}")" "${ERR_DETAIL[${unexp[$i]}]:+ (${ERR_DETAIL[${unexp[$i]}]})}")"
        _note "$(printf '       %shint:%s %s' "$C_GREY" "$C_RST" "$(hint "${unexp[$i]}")")"
      done
    fi
  fi
  if [ ${#ERR_WARN_TAGS[@]} -gt 0 ]; then
    _section "WARNINGS (no success block — see $LOG)" "$C_ORANGE"
    local wt
    for i in "${!ERR_WARN_TAGS[@]}"; do
      wt="${ERR_WARN_TAGS[$i]}"
      # Print the problem AND the recorded reason (ERR_DETAIL), like the error
      # blocks: a bare tag with an empty hint told the operator nothing about
      # WHY the push failed (2026-10-15).
      _note "$(printf '    %s%d.%s %s' "$C_ORANGE" "$((i+1))" "$C_RST" "$wt")"
      _note "$(printf '       %sproblem:%s %s%s' "$C_GREY" "$C_RST" "$(problem "$wt")" "${ERR_DETAIL[$wt]:+ (${ERR_DETAIL[$wt]})}")"
      _note "$(printf '       %shint:%s %s' "$C_GREY" "$C_RST" "$(hint "$wt")")"
    done
  fi
}
# EXIT trap: revert the checkpoint if the run died between writing finished=true
# and the final decision (write_state is safe to call any time), then print the
# error summary as before.
_exit_trap() {
  if [ "${CHECKPOINT_OPEN:-}" = 1 ]; then
    FINISHED=false
    CHECKPOINT_OPEN=
    write_state 2>/dev/null || true
  fi
  summary
}
