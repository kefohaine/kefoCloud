# wizard.d/lib/ui.sh — the live task checklist: row rendering, animation, notes/sections, task_start/end.

declare -a TASK_STATE=() TASK_TS=()
TASK_CUR=-1 TASK_ACTIVE= TASK_DRAWN= ANIM_PID= ANIM_POS=0 TASK_ERR= TASK_SKIP= SMOKE_FAILS=
_TAIL=0 _ANIM_PAUSE= _COLS=80 ANIM_SYM='$'

# The RUNNING row's time column, drawn as a fake `HH:MM:SS` clock whose six
# digit cells are the operator's currency sign (ANIM_SYM, set by ask_locale from
# the locale country; `$` when that country has no single-column sign) and whose
# two colons are purple. The six signs carry a sliding rainbow: cell i takes
# rainbow[(ANIM_POS + i) % 8], so consecutive frames shift the whole gradient by
# one hue and the colours appear to march across the line. The field is ALWAYS
# exactly 8 visible cells (`$$:$$:$$`), so the row's width never changes and the
# animator can overwrite in place without flicker.
_anim_field() {
  # Rainbow colors: red, orange, yellow, green, cyan, blue, indigo, violet
  local -a rainbow=(196 208 226 46 51 21 54 93)
  local n=${#rainbow[@]}
  local off=$(( ANIM_POS % n ))
  local sym=${ANIM_SYM:-\$}
  local i c
  for i in 0 1 2 3 4 5; do
    c=${rainbow[$(( (off - i + n) % n ))]}
    printf '\033[38;5;%sm%s\033[39m' "$c" "$sym"
    (( i == 1 || i == 3 )) && printf '%s:%s' "$C_PURPLE" "$C_RST"
  done
}
# One newline-terminated row for task $1.
_task_row() {
  local i="$1"
  local st="${TASK_STATE[$i]:-wait}" ts="${TASK_TS[$i]:-}" name="${TASK_NAMES[$i]:-}"
  # Only a task that ENDED has a clock: everything else (pending, and a row
  # skipped before it could run) shows the timestamp placeholder.
  [ -n "$ts" ] || ts="XX:XX:XX"
  case "$st" in
    done)  printf '%s[DONE]%s %s[%s]%s %s\n'  "$C_GREEN"  "$C_RST" "$C_PURPLE" "$ts" "$C_RST" "$name" ;;
    # A skipped task is marked [SKIP] in the status column, so the row can never
    # be mistaken for a task that ran.
    skip)  printf '%s[SKIP]%s %s[%s]%s %s\n'  "$C_ORANGE" "$C_RST" "$C_PURPLE" "$ts" "$C_RST" "$name" ;;
    error) printf '%s[FAIL]%s %s[%s]%s %s\n'  "$C_RED"    "$C_RST" "$C_PURPLE" "$ts" "$C_RST" "$name" ;;
    # The running row shows the animated field (orange sign, purple bracket);
    # the field paints its own colours, so no colour is passed here.
    run)   printf '%s[EXEC]%s %s[%s%s]%s %s%s%s\n'  "$C_ORANGE" "$C_RST"  "$C_PURPLE" "$(_anim_field)" "$C_PURPLE" "$C_RST"  "$C_ORANGE" "$name" "$C_RST";;
    # A pending row has no time yet: the placeholder stands until the task
    # starts (then it is the [EXEC] marker) and finishes (a real HH:MM:SS).
    *)     printf '%s[WAIT] [%s] %s\n'  "$C_GREY" "$ts" "$name" ;;
  esac
}
# Everything printed below the checklist block is "tail": lines an interactive
# prompt or an error printed while a task ran. _TAIL counts them so the animator
# can find its way back to the block with relative moves only. There is
# deliberately NO DECSC/DECRC (`\033[s`/`\033[u`): some terminals honour it and
# some ignore it, and where it is ignored the old relative-move version walked
# down the screen (2026-10-16, "repository management goes wild").
# Physical screen rows a string occupies at the current terminal width (ANSI
# escapes are zero-width). _TAIL counts SCREEN rows, so every console write must
# be counted through this — a ~90-col Enter prompt wraps to 2 rows and counting
# it as 1 drifted every later relative move one row down, tearing the checklist
# ("[DONE] Nextcloud Setupp", 2026-10-19).
_wrapped_rows() { # _wrapped_rows <string> -> prints physical row count
  local plain len cols="${_COLS:-80}"
  plain=$(printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g')
  len=${#plain}; [ "$len" -lt 1 ] && len=1
  echo $(( (len + cols - 1) / cols ))
}
# Print one console line below the block, counting it whenever the block is
# drawn (so a prompt/error printed between tasks is still counted and can be
# cleared before the checklist resumes).
# A leading `\r` is NOT decoration: every console write here assumes it starts
# in column 0, and that assumption only holds if the tty does NL→CRNL (ONLCR).
# A single subcommand that runs the terminal without ONLCR (or an operator who
# turned it off) otherwise leaves the cursor mid-line, so each following row is
# appended after the previous one and rows concatenate — `Repository
# Management[   [...] [EXEC] Repository Management[...]` (2026-10-16, "repo
# management goes wild"). Emitting CR explicitly makes every write
# column-independent of the tty's NL policy.
_note() {
  # A background animator redraws the running row 10x/s with the _TAIL it
  # inherited at fork time — it cannot see a note growing the tail, so its next
  # frame lands ON the note line and tears the checklist apart (2026-10-19,
  # "[EXEC] Nextcloud Setup / [WAIT] Vaultwarden Setup" interleaved garbage
  # after a WARN). Stop the animator, print, then restart it with the new tail.
  if [ -n "$ANIM_PID" ]; then
    kill "$ANIM_PID" 2>/dev/null; wait "$ANIM_PID" 2>/dev/null; ANIM_PID=
  fi
  printf '\r%s\n' "$*"
  if [ -n "$TASK_DRAWN" ]; then
    # Count PHYSICAL rows, not logical lines: _TAIL is the number of screen rows
    # between the cursor and the block's bottom row, so a note wider than the
    # terminal (wrapped to 2+ rows) must count as 2+ or the relative move lands
    # one row too high and every later row shifts (the wrap half of the same
    # 2026-10-16 drift). ANSI escapes have zero width, so strip them first.
    _TAIL=$(( ${_TAIL:-0} + $(_wrapped_rows "$*") ))
  fi
  # Restart the animator now that _TAIL reflects the note (running row only).
  if [ -z "$ANIM_PID" ] && [ -n "$TASK_DRAWN" ] && [ -n "$TASK_ACTIVE" ] \
     && [ "${TASK_STATE[$TASK_CUR]:-}" = run ] && [ "${_ANIM_PAUSE:-0}" -eq 0 ]; then
    _task_anim "$TASK_CUR" & ANIM_PID=$!
  fi
  return 0
}
# Count lines printed by something other than _note (a read prompt's own line).
_task_count() { [ -n "$TASK_DRAWN" ] && _TAIL=$(( ${_TAIL:-0} + ${1:-1} )); return 0; }
# Wipe everything printed below the checklist (the counted tail) whether or not
# a task is running, leaving the block in place. Used after an error/prompt so
# the transient block disappears and the to-do list is what remains on screen.
_tail_clear() {
  [ -t 1 ] || return 0
  [ "${_TAIL:-0}" -gt 0 ] && printf '\r\033[%dA\033[J' "${_TAIL}" >/dev/tty
  _TAIL=0
}
# Fancy status lines below the checklist.
_warn_note() { _note "$(printf '  %s[WARN]%s  %s' "$C_ORANGE" "$C_RST" "$*")"; }
_err_note()  { _note "$(printf '  %s[FAIL]%s %s' "$C_RED" "$C_RST" "$*")"; }
# A colored titled section rule (used to frame the post-install error/warn blocks).
_section() { _note ""; _note "$(printf '%s── %s ──────────────────────────────────%s' "$2" "$1" "$C_RST")"; }
# Redraw row $1 in place: stand on the last block row (stepping over the tail),
# step up to the row, rewrite, step back to the tail bottom.
#
# Emitted as ONE printf (one write to the tty): the whole move-up + row +
# move-back travels as a single frame, so the terminal never paints an
# intermediate state (2026-10-16: separate writes flushed the erase before the
# rewrite, flickering the row ~10x/s). There is deliberately no `\033[K`: every
# state of a row is exactly the same width (the status field is always 8 wide —
# an HH:MM:SS ts or the 8-cell anim field), so the new row overwrites the old
# in place and clearing the line — the other half of the flicker — is
# unnecessary. Zero-count moves (`\033[0A`, treated as 1 by some terminals) are
# never emitted.
_task_update() {
  { [ -n "$TASK_DRAWN" ] && [ -t 1 ]; } || return 0
  local i="$1" t="${_TAIL:-0}"
  local d=$(( TASK_TOTAL - i ))
  local up=$(( t + d )) back=$(( d - 1 + t ))
  local mup="" mback="" row
  [ "$up"   -gt 0 ] && mup=$'\033['"$up"$'A'
  [ "$back" -gt 0 ] && mback=$'\033['"$back"$'B'
  row=$(_task_row "$i")
  # Leading `\r`: start the frame in column 0 whatever the tty's NL policy is
  # (see _note); without it a row is appended after the previous one.
  printf '\r%s%s\n%s' "$mup" "$row" "$mback" >/dev/tty
}
# Background animator for the running row (TTY only).
_task_anim() {
  local i="$1" pos=0
  while :; do pos=$(( (pos + 1) % 8 )); ANIM_POS=$pos; _task_update "$i"; sleep 0.1; done
}
# Stop the animator while an interactive prompt owns the tty, so it cannot redraw
# over the prompt. Ref-counted so nested prompts work.
_task_pause() {
  _ANIM_PAUSE=$(( ${_ANIM_PAUSE:-0} + 1 ))
  [ "$_ANIM_PAUSE" -gt 1 ] && return 0
  [ -n "$ANIM_PID" ] && { kill "$ANIM_PID" 2>/dev/null; wait "$ANIM_PID" 2>/dev/null; ANIM_PID=; }
}
# Wipe the tail (the prompt/output printed below the block), redraw the running
# row, and restart the animator — so a prompt's app list/prompt vanishes and the
# checklist resumes on its own row instead of a duplicate being appended after it.
_task_resume() {
  _ANIM_PAUSE=$(( ${_ANIM_PAUSE:-1} - 1 )); [ "$_ANIM_PAUSE" -lt 0 ] && _ANIM_PAUSE=0
  [ "$_ANIM_PAUSE" -gt 0 ] && return 0
  if [ -n "$TASK_DRAWN" ] && [ -n "$TASK_ACTIVE" ] && [ -t 1 ]; then
    [ "${_TAIL:-0}" -gt 0 ] && printf '\r\033[%dA\033[J' "${_TAIL}" >/dev/tty
    _TAIL=0
    _task_update "$TASK_CUR"
  fi
  # Only a row that is genuinely RUNNING animates: never a finished or skipped
  # one, so an animator can never repaint a row's status into something it is not.
  if [ -n "$TASK_DRAWN" ] && [ -n "$TASK_ACTIVE" ] && [ -z "$ANIM_PID" ] \
     && [ "${TASK_STATE[$TASK_CUR]:-}" = run ]; then
    _task_anim "$TASK_CUR" & ANIM_PID=$!
  fi
}
_tasks_draw() {
  local i
  # A row's time is set when it ends (task_end); a [WAIT] row shows the
  # placeholder instead, so nothing is pre-filled here.
  for i in $(seq 0 $((TASK_TOTAL - 1))); do
    TASK_STATE[$i]=wait
    TASK_TS[$i]=
  done
  [ -t 1 ] || return 0
  # Learn the terminal width (for _note's physical-row counting) and re-assert
  # the tty's NL policy before the block exists: any earlier subcommand that ran
  # the terminal without ONLCR/ICRNL would otherwise leave \n mid-column. Done
  # once here; _note/_task_update also emit CR explicitly so even a later
  # toggler can't concatenate rows.
  _COLS=$(stty size </dev/tty 2>/dev/null | awk '{print $2}')
  [ "${_COLS:-0}" -gt 0 ] 2>/dev/null || _COLS=80
  stty onlcr icrnl </dev/tty 2>/dev/null || true
  for i in $(seq 0 $((TASK_TOTAL - 1))); do printf '\r'; _task_row "$i"; done
  _TAIL=0
  TASK_DRAWN=1
}
task_start() {
  TASK_CUR=$(( TASK_CUR + 1 )); TASK_ACTIVE=1 TASK_ERR= TASK_SKIP=
  TASK_STATE[$TASK_CUR]=run
  if [ -n "$TASK_DRAWN" ]; then
    _task_update "$TASK_CUR"
    _task_anim "$TASK_CUR" & ANIM_PID=$!
  fi
}
# A task that does not run marks its row [SKIP] instead of [DONE] — the
# checklist then says exactly which work was installed and which was
# deliberately not (called from inside a task, before task_end) — a module the
# operator turned off. The row reads [SKIP] in the status column.
task_skip() { [ -n "$TASK_ACTIVE" ] && TASK_SKIP=1; return 0; }
task_end() {
  [ -n "$TASK_ACTIVE" ] || return 0
  [ -n "$ANIM_PID" ] && { kill "$ANIM_PID" 2>/dev/null; wait "$ANIM_PID" 2>/dev/null; ANIM_PID=; }
  # The row's time is stamped whenever the pipeline REACHED it — including a
  # [SKIP] row (the run did walk past it and decided not to run it). Only rows
  # the run never reached keep the timestamp placeholder.
  TASK_TS[$TASK_CUR]=$(date +%H:%M:%S)
  if   [ -n "${TASK_ERR:-}" ];  then TASK_STATE[$TASK_CUR]=error
  elif [ -n "${TASK_SKIP:-}" ]; then TASK_STATE[$TASK_CUR]=skip
  else                               TASK_STATE[$TASK_CUR]=done; fi
  # The row is repainted with what it turned out to be: [DONE], [FAIL] or
  # [SKIP] — a [SKIP] row is painted here, not at task_skip, so a skipped task
  # only ever ends on [SKIP] (the [EXEC] it showed while its body ran is
  # replaced), and a task the run never reached keeps its [WAIT] row.
  if [ -n "$TASK_DRAWN" ]; then _task_update "$TASK_CUR"
  else _task_row "$TASK_CUR"; fi
  # TASK_ERR is deliberately NOT cleared here: run_install reads it right after
  # task_end to decide whether to pause on the failed row (task_start resets it).
  TASK_ACTIVE= TASK_SKIP=
}


banner() {
cat <<'EOF'
           __                      __           __    
.--.--.--.|__|.-----.---.-.----.--|  |  .-----.|  |--.
|  |  |  ||  ||-- __|  _  |   _|  _  |__|__ --||     |
|________||__||_____|___._|__| |_____|__|_____||__|__|

EOF
  printf '%s[WELCOME]%s Installation wizard for https://github.com/%s/%s\n\n' \
    "$C_GREEN" "$C_RST" "${GITHUB_USER:-?}" "${REPO_NAME:-?}"
  printf '%s[WARN]%s Operating kefoCloud before completing installation is highly discouraged\n' \
    "$C_ORANGE" "$C_RST"
  printf '%s[WARN]%s SSH will be exclusive to the connected tailnet — current session stays alive\n' \
    "$C_ORANGE" "$C_RST"
  printf '%s[WARN]%s Full logs at '\''%s'\'' - overridden at each run\n\n' \
    "$C_ORANGE" "$C_RST" "$LOG"
}
