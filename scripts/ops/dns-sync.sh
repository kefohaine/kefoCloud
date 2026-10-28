#!/bin/bash
# scripts/ops/dns-sync.sh — converge the Cloudflare zone from the module record.
#
# Why this exists: the A records are written by the installer's DNS task, so a
# module enabled AFTER the install (or a name whose record was never created
# because the run failed earlier) leaves a live vhost with NO name — the door
# looks broken to every client while the container is healthy. This re-runs the
# SAME convergence code the installer uses (wizard.d/lib/cloudflare.sh: cf_dns)
# against the SAME record of modules (data/wizard.state), so there is exactly
# one rule set: adding a hostname to cf_dns fixes the installer and this target.
#
# Reads the token the installer persisted: data/wizard.state (CF_API_TOKEN) or,
# when the state was written by an older run, data/caddy_data/CF_API_TOKEN — the
# env_file Caddy already uses. Never prints the token.

set -uo pipefail

WIZ_DIR="$(cd "$(dirname "$(readlink -f "$0")")/../install" && pwd)"

# The wizard's libs are written to be SOURCED (one process, shared globals), so
# load them in the same order and reuse their functions instead of a copy.
for _f in lib/env.sh lib/log.sh lib/state.sh lib/cloudflare.sh lib/errors.sh; do
  # shellcheck disable=SC1090  # the paths are relative to WIZ_DIR on purpose
  . "$WIZ_DIR/wizard.d/$_f" || { echo "dns-sync: cannot source $_f" >&2; exit 1; }
done
unset _f

install -d -m 0755 "$LOG_DIR"
LOG="$LOG_DIR/dns-sync.log"
chmod 600 "$LOG" 2>/dev/null || true

load_state || true
# wizard.state is 0600 root:root; a non-root run reads the copy Caddy uses.
if [ -z "${CF_API_TOKEN:-}" ] && sudo -n test -s "$DATA/caddy_data/CF_API_TOKEN" 2>/dev/null; then
  CF_API_TOKEN="$(sudo -n sed -n 's/^CF_API_TOKEN=//p' "$DATA/caddy_data/CF_API_TOKEN")"
fi
if [ -z "${CF_API_TOKEN:-}" ]; then
  echo "dns-sync: no Cloudflare token in $INSTALL_STATE or $DATA/caddy_data/CF_API_TOKEN" >&2
  exit 1
fi
[ -n "${DOMAIN:-}" ] || { echo "dns-sync: DOMAIN is empty in $INSTALL_STATE" >&2; exit 1; }

cf_dns

if [ "${#ERR_TAGS[@]}" -gt 0 ]; then
  echo "dns-sync: FAILED — $(printf '%s ' "${ERR_TAGS[@]}")" >&2
  echo "dns-sync: details in $LOG" >&2
  exit 1
fi
echo "dns-sync: zone converged for $DOMAIN (modules: $(enabled_modules_list))"
