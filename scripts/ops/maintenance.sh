#!/usr/bin/env bash
# scripts/ops/maintenance.sh — the host's one nightly maintenance window.
#
# Runs by maintenance.timer at midnight (local wall clock, so CET in winter and
# CEST in summer with no DST edit): package index refresh, upgrade, the cleanups
# that follow an upgrade, the distro jobs whose own timers are masked by
# `make install-config` (log rotation, the dpkg database backup, the man-page
# index, tmpfiles aging, and on Sunday the weekly TRIM + ext4 scrub), and one
# fail2ban whitelist pass. Everything that used to be a separate daily unit now
# happens here, in one serialized window, so nothing fights the same apt lock or
# the same disk at midnight.
#
# The merged jobs are CALLED, not reimplemented (`systemctl start <unit>.service`):
# the distro's own unit keeps its configuration and its failure reporting, and a
# timer that is masked cannot drift away from the logic that used to run under it.
# Weekly work stays weekly — it is gated on Sunday, not run every night.
#
# Kopia snapshots and the local-branch prune are NOT here: they belong to
# kefocloud-nightly.sh / kefocloud.timer, because they depend on the kopia
# module and on GitHub credentials and must skip quietly when those are absent.
# This script is the opposite: a maintenance step that fails must be visible, so
# it exits non-zero and systemd records it (`systemctl --failed`).
#
# Two things it deliberately never does: reboot (a required reboot is recorded,
# and the decision is the operator's), and reclamation that could destroy
# something still in use (`docker system prune -a`, volume prune, `--purge` of
# anything beyond orphaned packages).
#
# Plan mode: `DRYRUN=1 bash scripts/ops/maintenance.sh`.
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
. "$ROOT/scripts/lib/instance.sh" 2>/dev/null || true
. "$ROOT/scripts/lib/dryrun.sh"

LOCK="${DATA_DIR:-$ROOT/data}/.nightly.lock"
# A serialized window, not a race: kefocloud.timer holds this while a snapshot
# uploads over the tailnet, and starting an upgrade on the same disk mid-upload
# is exactly what the lock exists to prevent. Twice the longest snapshot budget.
LOCK_WAIT=7200

say() { printf 'maintenance: %s\n' "$*"; }
step() { printf '\n== %s ==\n' "$*"; }
# Weekly, not nightly: the jobs that were weekly before the merge keep that
# cadence, inside the same window (Sunday is ISO day 7).
weekly() { [ "$(date +%u)" = 7 ]; }
# start_unit <unit> — run a distro job that lost its timer to this window.
start_unit() {
  local u="$1"
  if ! systemctl cat "$u" >/dev/null 2>&1; then
    say "$u is absent on this host — skipped"; return 0
  fi
  if [ "${DRY:-0}" = 1 ]; then dryrun_plan "systemctl start $u"; return 0; fi
  run "systemctl start $u" systemctl start "$u"
}
fail=0
run() {   # run <description> <command...>
  local d="$1"; shift
  if [ "${DRY:-0}" = 1 ]; then dryrun_plan "$d"; return 0; fi
  if ! timeout "${STEP_BUDGET:-3600}" "$@"; then
    say "FAILED: $d"
    fail=$((fail + 1))
  fi
}

dryrun_wanted "$@" && DRY=1
dryrun_args "$@"

if [ "${DRY:-0}" != 1 ]; then
  [ -d "${DATA_DIR:-$ROOT/data}" ] || { say "${DATA_DIR:-$ROOT/data} is missing — no instance to maintain"; exit 1; }
  exec 9>"$LOCK" || { say "cannot open $LOCK"; exit 1; }
  if ! flock -w "$LOCK_WAIT" 9; then
    say "still waiting on $LOCK after ${LOCK_WAIT}s (a snapshot is running) — this window is skipped"
    exit 1
  fi
fi

# 1. Package index and upgrade. --force-confold keeps a locally edited config
#    instead of prompting: nothing here may stop on a question.
step "packages: update + full upgrade"
run "apt-get update" env DEBIAN_FRONTEND=noninteractive \
    apt-get -y -o Dpkg::Options::=--force-confold update
run "apt-get full-upgrade" env DEBIAN_FRONTEND=noninteractive \
    apt-get -y -o Dpkg::Options::=--force-confold full-upgrade
if [ -e /var/run/reboot-required ] && [ "${DRY:-0}" != 1 ]; then
  say "$(cat /var/run/reboot-required 2>/dev/null || echo 'a reboot is required') — rebooting is the operator's decision, nothing reboots here"
fi

# 2. What the upgrade left behind.
step "packages: autoremove + clean"
run "apt-get autoremove --purge" env DEBIAN_FRONTEND=noninteractive \
    apt-get -y autoremove --purge
run "apt-get clean" apt-get clean

# 3. The distro jobs whose timers are masked so this window owns them. Order
#    matters only in that these follow the upgrade: log rotation and the dpkg
#    database copy should describe the packages that are now installed.
step "merged: tmpfiles, logrotate, dpkg database backup, man-page index"
run "systemd-tmpfiles --clean" systemd-tmpfiles --clean
start_unit logrotate.service
start_unit dpkg-db-backup.service
start_unit man-db.service

# 4. Container garbage. Dangling images and build cache only: `-a` would drop
#    images the compose files still name, and a re-pull needs the network.
if command -v docker >/dev/null 2>&1; then
  step "docker: dangling images + build cache"
  run "docker image prune" docker image prune -f
  run "docker builder prune (older than 7 days)" docker builder prune -f --filter until=168h
else
  say "docker is absent — no container cleanup"
fi

# 5. Journal size. Project logs under LOG_DIR are rotated by logrotate.timer;
#    this bounds the unit output that has no other cap.
if command -v journalctl >/dev/null 2>&1; then
  step "journal: keep 14 days"
  run "journalctl --vacuum-time=14d" journalctl --vacuum-time=14d --quiet
fi

# 6. Weekly: TRIM and the ext4 scrub, which were weekly timers of their own.
if weekly; then
  step "weekly: TRIM + ext4 scrub"
  start_unit fstrim.service
  start_unit e2scrub_all.service
else
  say "weekly jobs (TRIM, ext4 scrub) are Sunday's — skipped tonight"
fi

# 7. One fail2ban whitelist pass after the upgrade: a restart can leave a ban
#    behind, and the per-minute repair loop is the steady state, not this.
if [ -x "$ROOT/scripts/ops/fail2ban-tailnet-sync.sh" ]; then
  step "fail2ban: tailnet whitelist + unban pass"
  run "fail2ban tailnet sync" "$ROOT/scripts/ops/fail2ban-tailnet-sync.sh"
fi

[ "${DRY:-0}" = 1 ] && dryrun_end "the window above would run"

if [ "$fail" -ne 0 ]; then
  say "$fail step(s) failed — see the lines above and 'journalctl -u maintenance'"
  exit 1
fi
say "window complete"
