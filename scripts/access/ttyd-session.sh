#!/usr/bin/env bash
# scripts/access/ttyd-session.sh — what the web terminal (ttyd) actually runs.
#
# ttyd is started with `-a`, so a URL argument reaches this script:
#
#   https://tail.$DOMAIN/ttyd            → the default session
#   https://tail.$DOMAIN/ttyd?arg=<name> → the named per-device session
#
# One ttyd listener serves every session (ttyd hands the name to tmux), so
# adding a shell for a tailnet device never opens a port and never edits the
# edge. The tail page gains a card per session (see scripts/access/ttyd-devices.sh).
#
# The name is sanitised: it becomes a tmux session name, and a hostile name
# must not be able to do anything but create an oddly-named session.
set -uo pipefail
RAW="${1:-main}"
NAME="$(printf '%s' "$RAW" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-32)"
[ -n "$NAME" ] || NAME=main
exec tmux new-session -A -s "$NAME" -n "$NAME"
