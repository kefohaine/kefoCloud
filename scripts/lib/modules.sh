#!/usr/bin/env bash
# scripts/lib/modules.sh — module facts for the OTHER scripts. SOURCED.
#
# One source of truth: config/modules.conf declares each module (name, dir,
# public host label, containers). This file turns that declaration plus the
# live/generated state into answers, so no script hardcodes the module roster
# or invents its own wording for "not installed".
#
# THE VOCABULARY (kept deliberately literal, see docs/REF.md):
#   mod_state   -> `installed` | `not installed`   (from installed-modules.conf)
#   exposure    -> `public` | `tailnet-only`       (a *route* property)
# A `not installed` module has NO route at all: it is absent, not tailnet-only.
#
# Requires instance.sh to have been sourced first (REPO_DIR, DATA_DIR).
# Functions:
#   mod_all                 every declared module, one per line (declaration order)
#   mod_dir <m>             module directory under modules/
#   mod_host <m>            public host label ('' when the module has no vhost)
#   mod_containers <m>      container names, space-separated
#   mod_installed <m>       exit 0/1
#   mod_state <m>           `installed` | `not installed`  (always printed)
#   mod_note <m>            '' when installed, else `(not installed)` — for rows
#   exposure <host>         `tailnet-only` for tail.$DOMAIN, else `public`

MODULES_CONF="${MODULES_CONF:-${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/config/modules.conf}"
INSTALLED_CONF="${INSTALLED_CONF:-${DATA_DIR:-${REPO_DIR:-.}/data}/installed-modules.conf}"

_mod_decl() {   # _mod_decl <m> -> "<dir> <host> <containers...>"
  awk -v m="$1" '$1 !~ /^#/ && $1 == m { $1=""; sub(/^ +/,""); print; exit }' "$MODULES_CONF" 2>/dev/null
}

mod_all()      { awk '$1 !~ /^#/ && NF { print $1 }' "$MODULES_CONF" 2>/dev/null; }
mod_dir()      { _mod_decl "$1" | awk '{print $1}'; }
mod_host()     { local h; h="$(_mod_decl "$1" | awk '{print $2}')"; [ "$h" = "-" ] && h=""; printf '%s' "$h"; }
mod_containers() { _mod_decl "$1" | awk '{for(i=3;i<=NF;i++) printf "%s%s", $i, (i<NF?" ":"")}'; }

# A missing installed-modules.conf means "every module is expected" (a fresh
# clone that has never run the installer) — the same rule `make smoke` uses.
mod_installed() {
  [ -f "$INSTALLED_CONF" ] || return 0
  grep -qxE "$1" <(grep -vE '^[[:space:]]*(#|$)' "$INSTALLED_CONF")
}
mod_state()    { mod_installed "$1" && printf 'installed' || printf 'not installed'; }
mod_note()     { mod_installed "$1" || printf '(not installed)'; }
exposure()     { case "$1" in tail|tail.*) printf 'tailnet-only' ;; *) printf 'public' ;; esac; }
