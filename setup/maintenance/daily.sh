#!/bin/bash
set -euo pipefail

LOG=/var/log/jehpok-daily.log
echo "=== $(date) ===" >> "$LOG"

cd /var/www/custom/projects/jehpok/repo

make maintain >> "$LOG" 2>&1
make clean >> "$LOG" 2>&1
make backup-cloud >> "$LOG" 2>&1 || echo "backup-cloud failed" >> "$LOG"
make backup-share >> "$LOG" 2>&1 || echo "backup-share failed" >> "$LOG"

echo "--- done ---" >> "$LOG"
