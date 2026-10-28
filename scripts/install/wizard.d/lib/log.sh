# wizard.d/lib/log.sh — colours, the two output channels ($LOG vs console) and fail()/warn().

# ────────────────────────── output + logging ───────────────────────────────
# TWO channels, one rule: $LOG gets EVERYTHING, the console gets only what a
# human watching the run needs.
#
#   log()    — the full record: timestamped, appended to $LOG ONLY. Every step
#              (even ones the console never shows) goes through this, so the log
#              is a complete debug history of the run.
#   detail() — same channel as log(): verbose detail that belongs in the log
#              and never on the console (secrets, per-record DNS chatter,
#              long decision trails).
#   msg()    — the CONSOLE: timestamped line on stdout AND appended to $LOG.
#              Reserved for things an operator must see live — phase titles,
#              warnings, state changes, and the final summary. Everything else
#              is log()-only (a fresh run shows phases + prompts, not a
#              debugging history).
#
# The log is truncated at the START of every run (main() calls init_log), so one
# file always describes exactly one run. Timestamps are purple on a TTY; the
# persistent status bar's seconds/phase are orange. Both are plain when the
# output is not a terminal or NO_COLOR is set (pipes, cron, CI).
C_PURPLE=$'\033[35m' C_ORANGE=$'\033[33m' C_GREEN=$'\033[32m' C_RED=$'\033[31m' C_GREY=$'\033[90m' C_WHITE=$'\033[37m' C_RST=$'\033[0m'
# The checklist's scope tag is coloured per part: HOST blue, STACK yellow,
# BOTH (smoke) green — brackets included, so the colour is the tag's background
# marker. Plain like every other colour when not a TTY / NO_COLOR is set.
C_BLUE=$'\033[34m' C_YELLOW=$'\033[33m'
if [ ! -t 1 ] || [ -n "${NO_COLOR:-}" ]; then C_PURPLE= C_ORANGE= C_GREEN= C_RED= C_GREY= C_WHITE= C_BLUE= C_YELLOW= C_RST=; fi
_tstamp() { printf '%s[%s]%s' "$C_PURPLE" "$(date +%H:%M:%S)" "$C_RST"; }
log()    { printf '%s %s\n' "$(_tstamp)" "$*" >>"$LOG"; }
detail() { log "$@"; }
# msg never uses `tee`: the purple escapes must land on the console but NOT in
# the log file (a log full of escape codes is unreadable and un-greppable).
# While the live task checklist owns the screen, msg is log-only — nothing may
# print between the task rows.
msg() {
  printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >>"$LOG"
  [ -n "${TASK_ACTIVE:-}" ] && return 0
  printf '%s %s\n' "$(_tstamp)" "$*"
}
fail() {
  local t
  for t in "${ERR_TAGS[@]:-}"; do [ "$t" = "$1" ] && return 0; done  # no duplicates across runs
  ERR_TAGS+=("$1"); ERR_DETAIL[$1]="${2:-}"
  TASK_ERR=1
  log "  ERROR: $(problem "$1")${2:+ ($2)}"
}

# A logged note surfaced in the post-install summary but NOT a success blocker
# (used for non-fatal GitHub-push failures and similar soft warnings).
warn() {
  local t
  for t in "${ERR_WARN_TAGS[@]:-}"; do [ "$t" = "$1" ] && return 0; done  # once per run
  log "  WARN: $(problem "$1")${2:+ ($2)}"
  ERR_WARN_TAGS+=("$1")
  ERR_DETAIL["$1"]="${2:-}"
}

ERR_WARN_TAGS=()


# ───────────────────── fresh log for this run ──────────────────────────────
# wizard.log describes ONE run: truncate it the moment the run starts, then
# announce what the run is. Called from main() before any prompt, so even an
# aborted run leaves a log that says so.
init_log() {
  install -d -m 0755 "$LOG_DIR"
  : >"$LOG"
  chmod 600 "$LOG"
  log "=== the installer run $(date -Is) — node ${NODE_NAME:-?} repo $REPO"
  log "=== args: $*"
}
