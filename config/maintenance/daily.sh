#!/bin/bash
set -euo pipefail

LOG=/var/log/homelab-daily.log
echo "=== $(date) ===" >> "$LOG"

cd /var/www/custom/projects/homelab/repo

# update: apt + image pull + up-all. bkp-all: all four bkp-* recipes
# (now includes bkp-mc, which tars the world folder — needs the
# game container stopped first so region files are quiescent). clean-all:
# docker prune + apt autoremove + prune old backups.
make update        >> "$LOG" 2>&1

# Stop the game container so the world tar is consistent — but only if it
# was running. If the operator had intentionally stopped the server
# (e.g. before a maintenance window), don't restart it on them. Capture
# the pre-backup state, then restart only if it was running.
MC_WAS_RUNNING="false"
if docker inspect --format='{{.State.Running}}' mc-server 2>/dev/null | grep -q true; then
  MC_WAS_RUNNING="true"
  docker stop mc-server >> "$LOG" 2>&1 || echo "mc-server stop failed" >> "$LOG"
fi
trap '
  if [ "$MC_WAS_RUNNING" = "true" ]; then
    docker start mc-server >> "$LOG" 2>&1 || echo "mc-server restart failed" >> "$LOG"
  fi
' EXIT
make bkp-all       >> "$LOG" 2>&1 || echo "bkp-all failed" >> "$LOG"
trap - EXIT
# bkp-all ran cleanly. Restore the pre-backup state. If the operator
# had it running, restart it now.
if [ "$MC_WAS_RUNNING" = "true" ]; then
  docker start mc-server >> "$LOG" 2>&1 || echo "mc-server restart failed" >> "$LOG"
fi

make clean-all     >> "$LOG" 2>&1 || echo "clean-all failed" >> "$LOG"

echo "--- done ---" >> "$LOG"
