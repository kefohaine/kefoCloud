#!/bin/bash
set -euo pipefail

LOG=/var/log/homelab-daily.log
echo "=== $(date) ===" >> "$LOG"

cd /var/www/custom/projects/homelab/repo

make update        >> "$LOG" 2>&1
make bkp-all       >> "$LOG" 2>&1 || echo "bkp-all failed" >> "$LOG"
make clean-all     >> "$LOG" 2>&1 || echo "clean-all failed" >> "$LOG"

echo "--- done ---" >> "$LOG"
