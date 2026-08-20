#!/bin/bash
set -euo pipefail

LOG=/var/log/jehpok-daily.log
echo "=== $(date) ===" >> "$LOG"

cd /var/www/custom/projects/jehpok/repo

# Refresh: apt + image pull + up-all. Backup-all: all five backup recipes
# (now includes backup-minecraft, which tars the world folder — needs the
# game container stopped first so region files are quiescent). Clean-all:
# docker prune + apt autoremove + prune old backups.
make refresh       >> "$LOG" 2>&1

# Stop the game container so the world tar is consistent. Restart on exit
# (trap covers any failure between stop and restart) and again at the end
# so the server comes back up if backup-all ran cleanly.
docker stop minecraft >> "$LOG" 2>&1 || echo "minecraft already stopped" >> "$LOG"
trap 'docker start minecraft >> "$LOG" 2>&1 || echo "minecraft restart failed" >> "$LOG"' EXIT
make backup-all    >> "$LOG" 2>&1 || echo "backup-all failed" >> "$LOG"
trap - EXIT
docker start minecraft >> "$LOG" 2>&1 || echo "minecraft restart failed" >> "$LOG"

make clean-all     >> "$LOG" 2>&1 || echo "clean-all failed" >> "$LOG"

echo "--- done ---" >> "$LOG"
