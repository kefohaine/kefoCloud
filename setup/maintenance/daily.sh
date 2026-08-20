#!/bin/bash
set -euo pipefail

LOG=/var/log/jehpok-daily.log
echo "=== $(date) ===" >> "$LOG"

cd /var/www/custom/projects/jehpok/repo

# Refresh: apt + image pull + up-all. Backup-all: all four backup recipes.
# Clean-all: docker prune + apt autoremove + prune old backups.
make refresh       >> "$LOG" 2>&1
make backup-all    >> "$LOG" 2>&1 || echo "backup-all failed" >> "$LOG"
make clean-all     >> "$LOG" 2>&1 || echo "clean-all failed" >> "$LOG"

echo "--- done ---" >> "$LOG"
