#!/bin/bash
# $NODE_NAME installation wizard — root-only, plug-and-play new-machine installer.
#
# ALL inputs are collected up front, in one fixed order, before any install
# work, and each is persisted immediately (so an abort mid-run leaves the
# answers for a resume). Order: continue-gate, repair-or-fresh (only when state
# exists: repair reuses every saved answer, fresh moves them to <state>.prev and
# asks again), locale country, GitHub collaborator opt-in (+ commit identity +
# automatic key verification), device SSH key, Tailscale auth key, Cloudflare API
# token, domain, one module question per module in config/modules.conf, and one
# exposure question per door those modules open. Every affirmation takes only the
# literal words `yes`/`no` (no shortcut, no default); the answer is recorded as
# the boolean true/false, and each question and its answer share one line. A
# value this machine can read for itself is never asked (the host timezone, the
# checkout's git identity, an already-joined tailnet, a domain the token names
# alone). The kopia backup target is NOT collected: the disk belongs to another
# machine, so the install leaves it as an operator follow-up. Then it runs
# unattended as a fixed 19-row checklist
# (grey [WAIT] -> animated orange [EXEC] -> green [DONE] / red [FAIL]; a failed
# task pauses the run on its row and hands the error to the operator, and the
# errors are reported after): host services, docker, tailscale, every module
# config/modules.conf declares — Matrix (Synapse + Element + PostgreSQL), oCIS,
# Vaultwarden, Mailu + Roundcube, Uptime Kuma, Kopia, Homarr, WriteFreely,
# Immich — behind the Caddy edge, the Cloudflare DNS records, LE cert issuance
# for every enabled door, and the module setup/verification steps. The repo
# already carries the canonical <domain> naming (modules/<domain>/,
# vhosts/<host>.caddy); no legacy renames are applied.
#
# Fully autonomous: the Kuma admin account is created
# automatically (the admin passwords are printed once in the final summary —
# nothing is written to disk), and no manual confirmation steps block success —
# the only follow-ups are printed in the summary (Tailscale split-DNS, mailboxes).
# The only step that waits is the opt-in GitHub remote access: the installer
# holds until the key it minted is authorized, verified AUTOMATICALLY (it polls
# ssh until GitHub accepts the key — no manual "press Enter to re-check").
# Prerequisites checked up front: the Cloudflare zone must exist. The repo is
# PUBLIC and is cloned over HTTPS — the clone needs no GitHub key; the key the
# opt-in step mints is for PUSHING to the operator's own repos.
#
# Errors are collected with tags, each shown as a "problem" plus a separate
# "hint". Manual dashboard steps are grouped as expected; real failures as
# unexpected. No success message is printed until every error is resolved:
# after the setup you get a numbered list of what's still failing, and each
# time you press Enter the script re-checks them, prints the solved ones
# once, and the remaining ones — until all are green.
#
# Entry point: root@$NODE_NAME is the ONLY way in (key-only SSH over the
# tailnet). The installer runs entirely as root — no sudo user, no hand-off.
#
# Layout: this file is only the ENTRY POINT and the run order — the paths, the
# channels, the checklist UI, the prompts, the tasks and each module's own step
# live in wizard.d/. ONE process: every file is
# SOURCED, never executed, so the checklist arrays, the error tags and the EXIT
# trap stay shared globals. Add a task = one file in wizard.d/tasks/ plus one
# row in wizard.d/tasks/index.sh (the ONLY place the order exists).
#
# Usage (a checkout, never a lone file — the paths are derived from it):
#   git clone https://github.com/$GITHUB_USER/kefoCloud.git
#   cd kefoCloud && bash scripts/install/wizard.sh
#
# Paths: the repo lives at $REPO ($ROOT); every external,
# untracked artefact (data, modules, databases, uploads) lives under $DATA
# ($ROOT/data), which .gitignore excludes.

set -uo pipefail

# ─────────────────────────── wizard.d/ (sourced) ───────────────────────────
# The checkout root, resolved ONCE from this script's own path (every
# wizard.d/lib file reuses $WIZ_DIR instead of re-deriving it).
WIZ_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# Fixed source order: paths/globals first (env), then the channels that write
# to them (log), the checklist they draw (ui), the state they persist (state),
# then the helper libs, then the task ORDER (tasks/index.sh) and the task
# bodies, the per-module steps, and the flows that drive it all.
for _wiz_f in \
  "$WIZ_DIR"/wizard.d/lib/env.sh "$WIZ_DIR"/wizard.d/lib/log.sh \
  "$WIZ_DIR"/wizard.d/lib/ui.sh "$WIZ_DIR"/wizard.d/lib/state.sh \
  "$WIZ_DIR"/wizard.d/lib/svc.sh "$WIZ_DIR"/wizard.d/lib/prompt.sh \
  "$WIZ_DIR"/wizard.d/lib/github.sh "$WIZ_DIR"/wizard.d/lib/cloudflare.sh \
  "$WIZ_DIR"/wizard.d/lib/errors.sh \
  "$WIZ_DIR"/wizard.d/tasks/index.sh "$WIZ_DIR"/wizard.d/tasks/[0-9]*.sh \
  "$WIZ_DIR"/wizard.d/modules/*/*.sh "$WIZ_DIR"/wizard.d/flow/*.sh
do
  # shellcheck disable=SC1090  # the glob list is the point
  . "$_wiz_f" || { echo "wizard.d: failed to source $_wiz_f" >&2; exit 1; }
done
unset _wiz_f

run_install() {
  local _t
  # TASKS has one entry per checklist row, smoke included; the pipeline runs
  # every row but the last (smoke is run by finalize_install, after the
  # checkpoint).
  for _t in "${TASKS[@]:0:${#TASKS[@]}-1}"; do
    "$_t"
    [ -n "${TASK_ERR:-}" ] && { TASK_ERR=; pause_and_resolve || return 1; }
  done
  save_state
}

trap _exit_trap EXIT

# ─────────────────────────────── main ──────────────────────────────────────

# A previous, incomplete run leaves either the saved answers (wizard.state) or
# the instance.conf a run writes once the prompts are answered.
previous_install() { [ -s "${INSTALL_STATE:-}" ] || [ -s "$DATA/instance.conf" ]; }

# The fail-fast zone gate in main() runs BEFORE task_packages installs the base
# packages, yet it needs curl + jq. On a fresh host neither was present, so the
# jq pipe produced nothing and the gate reported a bogus "zone not found" while
# the token and zone were both valid (2026-10-16). Install just those two here,
# up front; task_packages re-installs them harmlessly later. Returns non-zero
# only if the install failed, so the caller can report a real (apt) error rather
# than misblame the zone.
ensure_cli_deps() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v jq   >/dev/null 2>&1 || missing+=(jq)
  [ "${#missing[@]}" -eq 0 ] && return 0
  detail "  installing CLI prerequisites: ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$LOG" 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >>"$LOG" 2>&1 || true
  command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1
}

main() {
  if [ "$(id -u)" -ne 0 ]; then
    msg "Run as root: root@$NODE_NAME is the only entry point (no sudo hand-off)."; exit 1
  fi
  ensure_runtime_dirs       # first: the prompts below log (see the helper)
  init_log "$@"             # FRESH log for this run (wizard.log = one run)
  migrate_state             # one-time legacy setup.state import (before load)
  banner
  load_state

  # Decide fresh-vs-installed BEFORE the save_state below: save_state CREATES
  # wizard.state, so asking previous_install afterwards always said "installed"
  # — even on a first run — and dropped a fresh run into the repair gate, where
  # instance.sh's DOMAIN=example.com fallback was reused and the domain prompt
  # was skipped (the 2026-10-17 "domain isn't asked on fresh runs" bug).
  local _prev=
  previous_install && _prev=1

  # Consent gate: nothing is touched until the operator says yes.
  local _go
  ask_boolean "Do you want to continue?" _go || _go=false
  if [ "$_go" != "true" ]; then
    log "  aborted at the continue prompt — nothing was changed"
    exit 0
  fi

  if [ -n "$_prev" ]; then
    # A previous run is either REPAIRED (saved answers reused) or replaced by a
    # FRESH run (saved answers kept at <state>.prev, not deleted). Neither one
    # removes data/: the installer is add-only, so a re-run can not wipe it.
    printf "%s[WARN]%s 'data/wizard.state' detected - wizard previously ran\n" "$C_ORANGE" "$C_RST"
    local _repair
    ask_boolean "Do you want to repair this installation?" _repair || _repair=false
    if [ "$_repair" != "true" ]; then
      # Not a repair does not have to mean "stop": the operator may want a FRESH
      # run. A fresh run ignores every saved answer but never deletes them — the
      # state file is moved aside to <state>.prev, so a later run can still
      # resume from it. Both options are described on one line each, and the
      # second answer decides; declining it leaves the system untouched.
      printf '%s[INFO]%s repair = reuse every saved value, ask only what is missing\n' "$C_GREY" "$C_RST"
      printf '%s[INFO]%s fresh  = ask every value again, ignore the saved ones (they are kept at %s.prev)\n' "$C_GREY" "$C_RST" "$INSTALL_STATE"
      local _fresh
      ask_boolean "Start a fresh install instead?" _fresh || _fresh=false
      if [ "$_fresh" != "true" ]; then
        log "  repair and fresh both declined — nothing was changed"
        msg "Cancelled — nothing was changed."
        exit 0
      fi
      if [ -f "$INSTALL_STATE" ]; then
        mv -f "$INSTALL_STATE" "$INSTALL_STATE.prev" 2>/dev/null \
          || { msg "Could not set the previous answers aside ($INSTALL_STATE.prev) — nothing was changed."; exit 1; }
        chmod 600 "$INSTALL_STATE.prev" 2>/dev/null || true
        detail "  fresh run — the previous answers are kept at $INSTALL_STATE.prev"
      fi
      # Forget everything load_state put in the environment: with the file moved
      # aside, the prompts below ask each value again and save_state cannot
      # resurrect a stale one.
      unset DOMAIN LOCALE_COUNTRY CF_API_TOKEN TS_AUTHKEY TS_IP KOPIA_SFTP_HOST \
            KOPIA_SFTP_PORT KOPIA_SFTP_USER KOPIA_SFTP_PATH SSH_PUBKEY SSH_PUBKEYS \
            GH_REMOTE GH_AUTH_OK GITHUB_COMMIT_NAME GITHUB_COMMIT_EMAIL \
            NC_APPS_APPLIED VIDEO_CALLING CLIENT_PUSH
      local _mk
      for _mk in $(_state_modules); do unset "MOD_${_mk^^}"; done
    else
      REPAIR=true
      detail "  repairing — every saved value is reused; only missing ones are asked"
      # A repair is a full pipeline re-run, not a skip: every step is idempotent
      # (containers are recreated, DNS records upserted, setup steps re-applied),
      # so a re-run after a green install works but does the work again. Say so,
      # because "repair" reads like "continue from where it stopped" (2026-10-16).
      if [ "${FINISHED:-false}" = "true" ]; then
        msg "  previous run finished successfully — a repair re-runs the pipeline but only re-applies what is missing or changed (enabled-in-state but not detected locally gets installed; running services with unchanged inputs are skipped)."
      fi
    fi
  else
    # No previous run: drop whatever instance.sh's fallbacks put in the
    # environment (notably DOMAIN=example.com) so no prompt is silently skipped.
    unset DOMAIN CF_API_TOKEN TS_AUTHKEY SSH_PUBKEY SSH_PUBKEYS NC_APPS_APPLIED \
          VIDEO_CALLING CLIENT_PUSH
  fi
  ask_inputs
  # The exposure answers are stored ONLY in data/instance.conf, and the row that
  # used to write it (Stack Config) runs AFTER the one that already renders from
  # it (Host Services → make install-config). On a repair of a pre-exposure
  # install.conf the first render therefore met {{IF <VHOST>_EXPOSURE=…}} with no
  # answer, refused the file, and install-config died on the first `cp` of a unit
  # that was never rendered (2026-11-15, "Host Services" FAIL). Persist the file
  # as soon as the prompts are done — same writer, still one store, idempotent.
  write_instance_conf_file
  # The decisions this run is built on — recorded so the log explains itself
  # without re-reading wizard.state (never the token/key VALUES).
  detail "  answers: domain=$DOMAIN modules=$(enabled_modules_list || true)"
  detail "  answers: cloudflare_token=$([ -n "${CF_API_TOKEN:-}" ] && echo present || echo MISSING) tailscale_key=$([ -n "${TS_AUTHKEY:-}" ] && echo present || echo MISSING) github_remote=${GH_REMOTE:-false}"
  # Each installation starts UNFINISHED: whatever a previous run recorded (even
  # finished=true) is cleared here, so an interrupted run can never leave a
  # stale finished=true that a reader (smoke, modules.sh) would trust.
  FINISHED=false
  save_state

  # Fail fast: the Cloudflare zone must already exist (the script cannot create
  # one — that needs nameservers pointing at Cloudflare).
  # This gate runs BEFORE task_packages installs the base packages (curl, jq),
  # so bring them in first — otherwise the `| jq` yields nothing on a fresh host
  # and the gate falsely reports "zone not found" for a valid token+zone
  # (2026-10-16). A failure to install them is a real apt error, not a zone one.
  ensure_cli_deps || { fail apt "install curl and jq (apt-get install -y curl jq), then re-run"; exit 1; }
  if [ -z "$(curl -s -H "Authorization: Bearer $CF_API_TOKEN" \
        "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" | jq -r '.result[0].id // empty')" ]; then
    fail zone "create the zone in the CF dashboard (point your nameservers there), then re-run"
    exit 1
  fi

  # The start-of-run banner line: orange [WARN], purple [HH:MM:SS], white text —
  # printed once, just above the checklist (msg is log-only once a task is live).
  # The verb names what THIS run does: Installing / Repairing / Reinstalling.
  echo ""
  local _verb="Installing"
  [ -n "${REPAIR:-}" ] && _verb="Repairing"
  printf '[WARN] %s %s..\n' "$(date +%H:%M:%S)" "$_verb" >>"$LOG"
  printf '%s[WARN]%s %s %s%s..%s\n' \
    "$C_ORANGE" "$C_RST" "$(_tstamp)" "$C_WHITE" "$_verb" "$C_RST"
  _tasks_draw
  if ! run_install; then
    # A task failed and stayed unresolved: stop here, LOUD. The remaining rows
    # are still [WAIT] — never [DONE] — and the run is not finished.
    log "  HALTED at '${TASK_NAMES[$TASK_CUR]:-?}' — the tasks after it did not run"
    FINISHED=false
    write_state
    echo ""
    msg " HALTED — '${TASK_NAMES[$TASK_CUR]:-?}' failed and was not resolved; the tasks after it did not run."
    msg " Resolve it, then re-run the installer (every step is idempotent)."
    return 1
  fi
  resolve_errors
}

main "$@"
