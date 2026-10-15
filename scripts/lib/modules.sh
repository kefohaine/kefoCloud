#!/usr/bin/env bash
# scripts/lib/modules.sh — module facts for the OTHER scripts. SOURCED.
#
# One source of truth: config/modules.conf declares each module (name, dir,
# public host label, containers). This file turns that declaration plus the
# live/generated state into answers, so no script hardcodes the module roster
# or invents its own wording for "not installed".
#
# THE VOCABULARY (kept deliberately literal, see docs/SKELETON.md):
#   mod_state   -> `installed` | `not installed`   (from install.state)
#   exposure    -> `public` | `tailnet-only`       (a *route* property)
# A `not installed` module has NO route at all: it is absent, not tailnet-only.
#
# The installed set is the `enabled_modules` field of data/install.state — the
# file install.sh is the SOLE writer of. This module is the ONE accessor for
# it: every reader (smoke, fetch, fetch-more) goes through here. A MISSING
# state file means NOTHING is installed (never "all assumed") — a fresh clone
# has no install until install.sh records one.
#
# Requires instance.sh to have been sourced first (REPO_DIR, DATA_DIR, INSTALL_STATE).
# Functions:
#   mod_all                 every declared module, one per line (declaration order)
#   mod_dir <m>             module directory under modules/
#   mod_host <m>            public host label ('' when the module has no vhost)
#   mod_containers <m>      container names, space-separated
#   mod_installed <m>       exit 0/1 (from install.state `enabled_modules`)
#   mod_state <m>           `installed` | `not installed`  (always printed)
#   mod_note <m>            '' when installed, else `(not installed)` — for rows
#   mod_finished            `true` | `false` | `absent`  (install.state checkpoint)
#   exposure <host>         `tailnet-only` for tail.$DOMAIN, else `public`

MODULES_CONF="${MODULES_CONF:-${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/config/modules.conf}"
INSTALL_STATE="${INSTALL_STATE:-${DATA_DIR:-${REPO_DIR:-.}/data}/install.state}"

_mod_decl() {   # _mod_decl <m> -> "<dir> <host> <containers...>"
  awk -v m="$1" '$1 !~ /^#/ && $1 == m { $1=""; sub(/^ +/,""); print; exit }' "$MODULES_CONF" 2>/dev/null
}

mod_all()      { awk '$1 !~ /^#/ && NF { print $1 }' "$MODULES_CONF" 2>/dev/null; }
mod_dir()      { _mod_decl "$1" | awk '{print $1}'; }
mod_host()     { local h; h="$(_mod_decl "$1" | awk '{print $2}')"; [ "$h" = "-" ] && h=""; printf '%s' "$h"; }
mod_containers() { _mod_decl "$1" | awk '{for(i=3;i<=NF;i++) printf "%s%s", $i, (i<NF?" ":"")}'; }

# Read one field from install.state in a subshell: the file is printf-%q'd and
# contains secrets, so it is sourced (never interpolated) and only the requested
# value escapes. Absent file or key -> empty (exit 1).
_mod_read() {
  [ -f "$INSTALL_STATE" ] || return 1
  ( . "$INSTALL_STATE" 2>/dev/null; printf '%s' "${!1:-}" ) 2>/dev/null
}

# A missing state file means NOTHING is installed (not "all assumed").
mod_installed() {
  local em; em="$(_mod_read enabled_modules)" || return 1
  [ -n "$em" ] || return 1
  case " $em " in *" $1 "*) return 0 ;; esac
  return 1
}
mod_state()    { mod_installed "$1" && printf 'installed' || printf 'not installed'; }
mod_note()     { mod_installed "$1" || printf '(not installed)'; }
mod_finished() {
  [ -f "$INSTALL_STATE" ] || { printf 'absent'; return 0; }
  local f; f="$(_mod_read finished)"
  printf '%s' "${f:-absent}"
}
exposure()     { case "$1" in tail|tail.*) printf 'tailnet-only' ;; *) printf 'public' ;; esac; }
