#!/bin/bash
set -euo pipefail

LOG=/var/log/jehpok-daily.log
echo "=== $(date) ===" >> "$LOG"

echo "--- apt update + upgrade ---" >> "$LOG"
sudo apt-get update -y >> "$LOG" 2>&1
sudo apt-get upgrade -y >> "$LOG" 2>&1
sudo apt-get autoremove -y >> "$LOG" 2>&1

echo "--- docker prune ---" >> "$LOG"
docker builder prune -af >> "$LOG" 2>&1
docker image prune -af >> "$LOG" 2>&1
docker container prune -f >> "$LOG" 2>&1

echo "--- pull + recreate containers ---" >> "$LOG"
cd /var/www/github/jehpok.com/repo

for svc in domain cloud share vault kuma homer; do
  compose="services/$svc/docker-compose.yml"
  image=$(grep -m1 'image:' "$compose" | awk '{print $2}')
  if [ -n "$image" ]; then
    docker pull "$image" >> "$LOG" 2>&1 || true
  fi
done

make up-all >> "$LOG" 2>&1

echo "--- done ---" >> "$LOG"