#!/usr/bin/env bash
# scripts/lib/dryrun.sh — the ONE definition of the plan mode. SOURCED.
#
# Every script that mutates the live instance accepts a plan run: nothing is
# written, the caller sees exactly what a real run would do, and a precondition
# that would refuse still refuses. That matters because a script with no plan
# mode can only be exercised for real, so a change to it cannot be verified at
# all before it reaches the host.
#
#   DRYRUN=1 bash scripts/…       or       bash scripts/… --dry-run
#
# The flag never changes what a real run does. A script prints its plan where
# its FIRST mutation would be and exits 0 there.
#
# SOURCED, never executed. Defines:
#   dryrun_wanted "$@"      true when DRYRUN=1|yes|true, or an argument is --dry-run
#   dryrun_args "$@"        sets DRYRUN_ARGS to the arguments minus --dry-run
#   dryrun_plan <line>      "dry-run: would <line>"
#   dryrun_note <line>      "dry-run: <line>"
#   dryrun_end [<line>]     close the plan and exit 0 (default: nothing changed)
#
# A script with positional arguments calls dryrun_args and re-assigns, so
# `script.sh --dry-run <arg>` and `DRYRUN=1 script.sh <arg>` behave the same.
# Plan output never carries a value a real run would print: a generated secret
# is described in the plan ("random, printed once on a real run"), never minted.

dryrun_wanted() {
  case "${DRYRUN:-}" in 1|yes|true) return 0 ;; esac
  local _a
  for _a in "$@"; do
    case "$_a" in --dry-run) return 0 ;; esac
  done
  return 1
}

dryrun_args() {
  DRYRUN_ARGS=()
  local _a
  for _a in "$@"; do
    case "$_a" in --dry-run) continue ;; esac
    DRYRUN_ARGS+=("$_a")
  done
}

dryrun_plan() { printf 'dry-run: would %s\n' "$*"; }
dryrun_note() { printf 'dry-run: %s\n' "$*"; }
dryrun_end()  { printf 'dry-run: %s\n' "${1:-nothing changed}"; exit 0; }
