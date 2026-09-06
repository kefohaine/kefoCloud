#!/usr/bin/env bash
# perf — one-shot live system performance + status overview. No arguments.
set -uo pipefail
say() { printf '\n\033[1;36m== %s ==\033[0m\n' "$1"; }
echo "fxmq.net homelab — perf overview  $(date '+%F %T %Z')"
say "host"
hostname; uname -srm
say "load / uptime"
uptime
say "top cpu/mem"
top -bn1 | head -15
say "memory"
free -h
say "swap / zram"
swapon --show 2>/dev/null || echo "(no swap devices)"
say "disk"
df -h / 2>/dev/null
say "containers"
docker ps --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null || echo "(docker unavailable)"
say "failed units"
systemctl --failed --no-legend 2>/dev/null || echo "(none)"
say "tailnet"
tailscale status 2>/dev/null | head -8 || echo "(tailscale unavailable)"
