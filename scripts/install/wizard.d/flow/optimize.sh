# wizard.d/flow/optimize.sh — the post-install hardening/optimisation prompt.

# ── Optional follow-up — only ever reached after a FULLY green run ────────
# optimize.sh is a separate tool (the machine performance pass), so it is offered,
# never assumed. It is idempotent — re-running it is a no-op — which is why a
# re-run of the installer may offer it again.
ask_optimize() { ## BROKEN - NEITHER PROMPT ANSWERS FIRE OPTIMIZE.SH - SILENT FAIL - INVESTIGATE AND FIX
  local answer="" rc
  local script="$REPO/scripts/ops/optimize.sh"

  if [ ! -f "$script" ]; then
    detail "  optimize.sh not found: $script"
    return 0
  fi

  if ! ask_boolean "Also run the machine performance pass (kernel, swap, disk tuning) now?" answer; then
    detail "  optimize.sh prompt did not complete"
    return 0
  fi

  if [ "$answer" != "true" ]; then
    log "  optimize.sh skipped — run it later: bash $script"
    return 0
  fi

  detail "  running $script --yes (its output goes to $LOG)"

  bash "$script" --yes 2>&1 | tee -a "$LOG"
  rc=${PIPESTATUS[0]}

  if [ "$rc" -eq 0 ]; then
    detail "  optimize.sh done"
  else
    detail "  optimize.sh exited $rc — it is optional and can be re-run any time: bash $script"
  fi
}
