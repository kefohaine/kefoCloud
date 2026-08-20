#!/bin/bash
set -euo pipefail

LOG=/var/log/jehpok-daily.log
echo "=== $(date) ===" >> "$LOG"

cd /var/www/custom/projects/jehpok/repo

# Refresh: apt + image pull + up-all. Backup-all: all five backup recipes
# (now includes backup-mc, which tars the world folder — needs the
# game container stopped first so region files are quiescent). Clean-all:
# docker prune + apt autoremove + prune old backups.
make refresh       >> "$LOG" 2>&1

# Stop the game container so the world tar is consistent — but only if it
# was running. If the operator had intentionally stopped the server
# (e.g. before a maintenance window), don't restart it on them. Capture
# the pre-backup state, then restart only if it was running.
MC_WAS_RUNNING="false"
if docker inspect --format='{{.State.Running}}' mc 2>/dev/null | grep -q true; then
  MC_WAS_RUNNING="true"
  docker stop mc >> "$LOG" 2>&1 || echo "mc stop failed" >> "$LOG"
fi
trap '
  if [ "$MC_WAS_RUNNING" = "true" ]; then
    docker start mc >> "$LOG" 2>&1 || echo "mc restart failed" >> "$LOG"
  fi
' EXIT
make backup-all    >> "$LOG" 2>&1 || echo "backup-all failed" >> "$LOG"
trap - EXIT
# backup-all ran cleanly. Restore the pre-backup state. If the operator
# had it running, restart it now.
if [ "$MC_WAS_RUNNING" = "true" ]; then
  docker start mc >> "$LOG" 2>&1 || echo "mc restart failed" >> "$LOG"
fi

make clean-all     >> "$LOG" 2>&1 || echo "clean-all failed" >> "$LOG"

echo "--- done ---" >> "$LOG"
