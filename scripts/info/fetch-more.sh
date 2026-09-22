#!/usr/bin/env bash
# scripts/info/fetch-more.sh — the `make fetch-more` deep dive.
#
# `make fetch` answers "is everything okay" in one screen. This answers "why
# isn't it", without ssh-ing around: kernel/uptime, memory breakdown, per-core
# busy, the heaviest cpu/mem/rss processes, zombie+thread counts, every
# listening socket, all units (active/failed/enabled-but-dead), timers and
# cron, the docker engine's EFFECTIVE logging caps plus per-container
# cpu/mem/net/pids and per-container log sizes, image/volume/network
# inventory, disk+inodes+reboot-required, data/ growth, journal+our own log
# sizes, the tailnet (peers, prefs, SSH), dnsmasq + a live DNS probe, ufw,
# git state, module/vhost truth and TLS expiry.
#
# Read-only. No arguments. Colors auto-disable when stdout is not a tty or
# NO_COLOR is set. Every probe is best-effort: a missing tool prints
# 'unavailable' rather than failing the run.

. "$(dirname "$(readlink -f "$0")")/../lib/instance.sh" 2>/dev/null || true
set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DATA="$ROOT/data"
LOG_DIR="${LOG_DIR:-$LOG_DIR}"
CONF="$DATA/installed-modules.conf"
MODULES="cloud vault mail monitor"
[ -f "$CONF" ] && MODULES="$(grep -vE '^[[:space:]]*(#|$)' "$CONF" | tr '\n' ' ')"
mod_in() { [[ " $MODULES " == *" $1 "* ]]; }

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m' D=$'\033[2m' R=$'\033[31m' G=$'\033[32m' Y=$'\033[33m' C=$'\033[36m' N=$'\033[0m'
else
  B='' D='' R='' G='' Y='' C='' N=''
fi
W=74
row()  { printf "  %s%-16s%s %s\n" "${C}${B}" "$1" "$N" "$2"; }
rule() { printf "  %s%s%s\n" "$D" "$(printf '%*s' $W '' | tr ' ' '-')" "$N"; }
sec()  { local pad=$((W - ${#1} - 6)); [ "$pad" -lt 2 ] && pad=2
         printf "\n  %s── %s %s%s\n" "$D" "${B}$1${N}${D}" "$(printf '%*s' $pad '' | tr ' ' '-')" "$N"; }
have() { command -v "$1" >/dev/null 2>&1; }
dot()  { local s="$1" n="$2" t="${3:-}"; [ -n "$t" ] && printf "%s%d %s · " "$s" "$n" "$t" || printf "%s%d %s" "$s" "$n"; }

echo ""
printf "  %s%s%s — homelab fetch-more  %s· %s%s\n" "$B" "$(hostname)" "$N" "$D" "$(date '+%F %T %Z')" "$N"
printf "  %srepo %s · data %s%s\n" "$D" "$ROOT" "$DATA" "$N"
rule

# ───────────────────────── identity / kernel ────────────────────────────────
sec "host"
. /etc/os-release 2>/dev/null || true
up="$(cut -d. -f1 /proc/uptime)"
row os "${PRETTY_NAME:-Debian} · $(uname -r) · $(dpkg --print-architecture 2>/dev/null || uname -m)"
row uptime "$(printf '%dd %dh %dm' $((up/86400)) $(((up%86400)/3600)) $(((up%3600)/60))) · boot $(uptime -s 2>/dev/null || echo '?') · $(nproc) cores"
virt="$(systemd-detect-virt 2>/dev/null || echo unknown)"
row platform "virt ${virt} · $(awk -F: '/^model name/{gsub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo)"
reboot="no"; [ -f /var/run/reboot-required ] && reboot="${Y}REQUIRED${N}"
row kernel "reboot ${reboot} · $(cat /proc/sys/kernel/random/boot_id 2>/dev/null | cut -c1-8) · tcp_fin=$(cat /proc/sys/net/ipv4/tcp_fin_timeout 2>/dev/null)"

# ───────────────────────────── load / cpu ───────────────────────────────────
sec "cpu"
read -r l1 l5 l15 _ < /proc/loadavg
lcol="$N"; awk -v v="$l15" -v n="$(nproc)" 'BEGIN{exit !(v > n*2)}' && lcol="$R"
row load "${lcol}${l1} ${l5} ${l15}${N} (1/5/15) · $(nproc) cores"
read_cpu() { awk '/^cpu[0-9]/{print $1, $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat; }
a="$(read_cpu)"; sleep 0.4; b="$(read_cpu)"
paste <(echo "$a") <(echo "$b") | awk -v B="$B" -v N="$N" -v D="$D" -v R="$R" -v Y="$Y" -v G="$G" '
  { t=$5-$2; i=$6-$3; if (t<=0) next; p=int(100*(t-i)/t);
    if (p>=85) c=R; else if (p>=60) c=Y; else c=G;
    printf "%s%s %d%%%s  ", c, $1, p, N; if (++k % 6 == 0) printf "\n            " }
  END { printf "\n" }' | sed 's/^/            /'
row stealing "$(awk '/^cpu /{printf "user %.0f%% sys %.0f%% idle %.0f%% iowait %.0f%% steal %.0f%%", $2*100/($2+$3+$4+$5+$6+$7+$8), $4*100/($2+$3+$4+$5+$6+$7+$8), $5*100/($2+$3+$4+$5+$6+$7+$8), $6*100/($2+$3+$4+$5+$6+$7+$8), $9*100/($2+$3+$4+$5+$6+$7+$8)}' /proc/stat)"
ps -eo stat --no-headers 2>/dev/null | awk '{ if ($1 ~ /^Z/) z++ } END { printf "%d", z+0 }' >/tmp/fm_z.$$ || echo 0 >/tmp/fm_z.$$
ntask="$(ps -eLf --no-headers 2>/dev/null | wc -l)"
row procs "$(ps -e --no-headers | wc -l) processes · ${ntask} threads · ${R}$(cat /tmp/fm_z.$$) zombies${N}"; rm -f /tmp/fm_z.$$

# ─────────────────────────────── memory ─────────────────────────────────────
sec "memory"
free -b | awk '/^Mem:/{printf "            total %.1f GiB · used %.1f GiB · free %.1f GiB · avail %.1f GiB\n", $2/1073741824, $3/1073741824, $4/1073741824, $7/1073741824}'
row cache "$(awk '/^Cached:/{c+=$2} /^Buffers:/{c+=$2} /^SReclaimable:/{c+=$2} /^Slab:/{s=$2} /^Dirty:/{d=$2} /^Shmem:/{sh=$2} END{printf "buff/cache %.1f GiB · slab %.2f GiB · dirty %.0f MiB · shmem %.0f MiB", c/1073741824, s/1073741824, d/1048576, sh/1048576}' /proc/meminfo)"
swapdev="$(swapon --show=NAME,SIZE,USED --noheadings 2>/dev/null | awk '{printf "%s %s used %s", $1, $2, $3}')"
row swap "${swapdev:-none} · swappiness $(cat /proc/sys/vm/swappiness 2>/dev/null) · overcommit $(cat /proc/sys/vm/overcommit_memory 2>/dev/null)"
if [ "$(swapon --show=NAME --noheadings 2>/dev/null | wc -l)" -eq 0 ] && [ -f /swapfile ]; then row swap-file "/swapfile present but NOT active"; fi
row oom "$(dmesg 2>/dev/null | grep -ci 'out of memory\|oom-kill' 2>/dev/null || true) events in dmesg · score_adj root=$(cat /proc/self/oom_score_adj 2>/dev/null)"
row top-mem "$(ps -eo comm,pmem --sort=-pmem --no-headers 2>/dev/null | grep -vE '^(ps|awk|grep|sed|head|cut|tr|sort|wc|bash|sh)$' | head -4 | awk '{printf "%s%s %.1f%%", (NR>1?" · ":""), $1, $2}')"
row top-cpu "$(ps -eo comm,pcpu --sort=-pcpu --no-headers 2>/dev/null | grep -vE '^(ps|awk|grep|sed|head|cut|tr|sort|wc|bash|sh)$' | head -4 | awk '{printf "%s%s %.1f%%", (NR>1?" · ":""), $1, $2}')"

# ─────────────────────────────── disk ───────────────────────────────────────
sec "disk"
printf "            %-28s %8s %8s %5s %6s\n" "mount" "used" "size" "use%" "inodes%"
df -hT -x tmpfs -x devtmpfs -x overlay 2>/dev/null | awk 'NR>1{printf "            %-28s %8s %8s %5s\n", $7, $4, $3, $6}'
df -i 2>/dev/null | awk '$5 ~ /%/ {p=$5+0; if (p>50) printf "            inodes %-20s %s\n", $6, $5}'
row biggest "$(du -sh "$DATA"/*/ 2>/dev/null | sort -rh | head -6 | awk '{printf "%s %s  ", $1, $2}' | sed "s#$DATA/##g")"
row logs "$GITHUB_USER $(du -sh "$LOG_DIR" 2>/dev/null | cut -f1 || echo -) · journal $(journalctl --disk-usage 2>/dev/null | sed 's/.*take up //; s/ in the file system.*//') · logrotate $(test -f /etc/logrotate.d/$GITHUB_USER && echo installed || echo MISSING)"
row docker-disk "$(docker system df --format '{{.Type}}: {{.Size}}' 2>/dev/null | tr '\n' ' ')"
row backups "$(ls -1 "$DATA/backups" 2>/dev/null | wc -l) files · $(du -sh "$DATA/backups" 2>/dev/null | cut -f1 || echo 0) · newest: $(ls -1t "$DATA/backups" 2>/dev/null | head -2 | tr '\n' ' ')"

# ───────────────────────────── processes ────────────────────────────────────
sec "processes (top)"
printf "            %-7s %-9s %5s %5s %8s %-8s %s\n" PID USER "CPU%" "MEM%" RSS ELAPSED CMD
ps -eo pid,user,pcpu,pmem,rss,etime,args --sort=-pcpu --no-headers 2>/dev/null | head -6 \
  | awk '{printf "            %-7s %-9s %5s %5s %8s %-8s %s\n", $1, $2, $3, $4, $5, $6, substr($0, index($0,$7), 44)}'
row "high rss" "$(ps -eo pid,rss,comm --sort=-rss --no-headers 2>/dev/null | head -4 | awk '{printf "%s%s %.0fM", (NR>1?" · ":""), $3, $2/1024}')"
row selinux-apparmor "apparmor $(aa-status --enabled >/dev/null 2>&1 && echo enabled || echo 'unavailable') · $(cat /sys/kernel/security/lsm 2>/dev/null || echo '-')"

# ─────────────────────────── listening sockets ──────────────────────────────
sec "sockets"
if have ss; then
  row tcp-listen "$(ss -tlpn 2>/dev/null | awk 'NR>1{n=split($4,a,":"); printf "%s ", a[n]}' | tr ' ' '\n' | sort -n -u | tr '\n' ' ')"
  row udp-listen "$(ss -ulpn 2>/dev/null | awk 'NR>1{n=split($4,a,":"); printf "%s ", a[n]}' | tr ' ' '\n' | sort -n -u | tr '\n' ' ')"
  row established "$(ss -tn state established 2>/dev/null | wc -l) tcp established · $(ss -s 2>/dev/null | awk '/^TCP:/{print $1, $2}' | tr '\n' ' ')"
  row listeners "$(ss -tlpn 2>/dev/null | awk 'NR>1{print $6}' | sed 's/users:((//;s/))//' | cut -d, -f1 | sort -u | head -6 | tr '\n' ' ')"
else
  row sockets "${D}ss unavailable${N}"
fi
if have ufw; then
  rn="$(ufw status 2>/dev/null | grep -c 'ALLOW\|DENY')"
  row ufw "$(ufw status 2>/dev/null | head -1) · ${rn} rules · $(ufw status verbose 2>/dev/null | awk -F': ' '/^Default:/{print $2}')"
  row ufw-fail2ban "$(fail2ban-client status 2>/dev/null | awk -F'\t' '/Jail list/{print $2, $3}' | tr '\n' ' ' || echo 'no jails')"
fi

# ──────────────────────────── services / units ──────────────────────────────
sec "systemd"
row units "$(systemctl list-units --type=service --state=active --no-legend --plain 2>/dev/null | grep -c .) active services of $(systemctl list-unit-files --type=service --state=enabled --no-legend --plain 2>/dev/null | grep -c .) enabled"
nfl="$(systemctl --failed --no-legend --plain 2>/dev/null)"
nf="$(echo "$nfl" | grep -c . || true)"
if [ "${nf:-0}" = 0 ]; then
  row failed "${G}none${N}"
else
  ftok=""
  while read -r un _; do
    [ -n "$un" ] || continue
    tgt="$(systemctl show "$un" -p Where --value 2>/dev/null)"
    [ -n "$tgt" ] || tgt="$(systemctl show "$un" -p What --value 2>/dev/null)"
    [ -n "$tgt" ] || tgt="$(systemctl show "$un" -p Description --value 2>/dev/null)"
    ftok+="${R}${un}${N}${D}(${tgt})${N}  "
  done < <(echo "$nfl" | head -5)
  row failed "${R}${nf} failed${N} ${ftok}"
fi
# enabled but not running — ignore the distro's timer/getty-driven ones
dead="$(comm -23 \
  <(systemctl list-unit-files --state=enabled --no-legend --plain 2>/dev/null | awk '{print $1}' | grep '\.service$' | sort) \
  <(systemctl list-units --state=active --no-legend --plain 2>/dev/null | awk '{print $1}' | sort) \
  | grep -vE 'apt-daily|fstrim|man-db|logrotate|dpkg-db|e2scrub|getty|systemd-|remote-fs|motd|dmesg|user@|ufw' || true)"
if [ -n "$dead" ]; then row "enabled-dead" "${Y}$(echo "$dead" | tr '\n' ' ')${N}"; else row "enabled-dead" "${G}none${N}"; fi
row timers "$(systemctl list-timers --no-pager --no-legend 2>/dev/null | awk 'NF>6{printf "%s(%s) ", $7, $1}' | head -6)"
row cron "$(ls /etc/cron.d/ 2>/dev/null | tr '\n' ' ') · root crontab $(crontab -l 2>/dev/null | grep -vc '^#\|^$' 2>/dev/null || true) lines"
row journald "$(systemctl is-active systemd-journald) · $(journalctl --disk-usage 2>/dev/null | sed 's/.*take up //; s/ in the file system.*//') · capped $(grep -h SystemMaxUse /etc/systemd/journald.conf.d/*.conf 2>/dev/null | cut -d= -f2 | tr '\n' ' ')"

# ──────────────────────────────── docker ────────────────────────────────────
sec "docker"
if have docker && docker info >/dev/null 2>&1; then
  row engine "$(docker version --format '{{.Server.Version}}' 2>/dev/null) · $(docker info --format '{{.Driver}} · {{.CgroupVersion}} · {{.NCPU}}cpu {{.MemTotal}}B mem' 2>/dev/null)"
  row log-caps "driver $(jq -r '."log-driver" // "default"' /etc/docker/daemon.json 2>/dev/null) · max-size $(jq -r '."log-opts"."max-size" // "-"' /etc/docker/daemon.json 2>/dev/null) · max-file $(jq -r '."log-opts"."max-file" // "-"' /etc/docker/daemon.json 2>/dev/null) · live-restore $(jq -r '."live-restore" // false' /etc/docker/daemon.json 2>/dev/null)"
  row inventory "$(docker images -q 2>/dev/null | wc -l) images ($(docker system df --format '{{.Type}} {{.TotalCount}}' 2>/dev/null | awk '/Images/{print $2}')) · $(docker volume ls -q 2>/dev/null | wc -l) volumes · $(docker network ls -q 2>/dev/null | wc -l) networks"
  echo ""
  printf "            %-16s %6s %-20s %-18s %-6s %s\n" CONTAINER "CPU%" MEMORY NET "PIDS" RESTARTS
  while IFS=$'\t' read -r nm cpu mem net pids; do
    [ -n "$nm" ] || continue
    rc="$(docker inspect -f '{{.RestartCount}}' "$nm" 2>/dev/null)"
    hs="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$nm" 2>/dev/null)"
    col="$G"; [ "$hs" = unhealthy ] && col="$R"; [ "$hs" = restarting ] && col="$Y"
    [ "${rc:-0}" -gt 5 ] 2>/dev/null && col="$Y"
    printf "            %s%-16s%s %6s %-20s %-18s %-6s %s%s\n" "$col" "$nm" "$N" "$cpu" "$mem" "$net" "$pids" "$rc" ""
  done < <(docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.PIDs}}' 2>/dev/null)
  row published "$(docker ps --format '{{.Ports}}' 2>/dev/null | grep -oE '0\.0\.0\.0:[0-9]+(-[0-9]+)?' | sort -u -t: -k2 -n | tr '\n' ' ')"
  row ctn-logs "$(du -ch $(docker inspect -f '{{.LogPath}}' $(docker ps -aq) 2>/dev/null | grep . ) 2>/dev/null | tail -1 | cut -f1)"
  row outside-mounts "$(for c in $(docker ps --format '{{.Names}}' 2>/dev/null); do docker inspect -f '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "$c" 2>/dev/null; done | sort -u | grep -v "^$ROOT" | grep -v '^$' | head -3 | tr '\n' ' ' | cut -c1-70)"
else
  row docker "${R}engine unavailable${N}"
fi

# ─────────────────────────────── tailnet ────────────────────────────────────
sec "tailnet"
if have tailscale && ts="$(tailscale status 2>/dev/null)"; then
  row ip "$(tailscale ip -4 2>/dev/null | head -1) · $(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // "-"' | sed 's/\.$//')"
  row prefs "$(tailscale debug prefs 2>/dev/null | jq -r '"ssh:" + (."RunSSH"|tostring) + " exit:" + (."ExitNodeID" // "-") + " routes:" + ((."AdvertiseRoutes" // []) | length | tostring) + " serve:" + ((."FileServer" // {}) | tostring)' 2>/dev/null | cut -c1-60)"
  peers="$(echo "$ts" | tail -n +2)"
  row peers "${G}$(echo "$peers" | grep -cw 'active\|idle' || true) up${N} · ${D}$(echo "$peers" | grep -cw offline || true) offline${N} · $(echo "$peers" | awk '{print $2}' | head -5 | tr '\n' ' ')"
  row offline "$(echo "$peers" | awk '/offline/{print $2}' | head -6 | tr '\n' ' ')"
else
  row tailnet "${R}tailscale unavailable${N}"
fi
if have dig; then
  TSIP="$(tailscale ip -4 2>/dev/null | head -1)"
  lans="$(dig +short +time=2 +tries=1 "cloud.${DOMAIN:-example.com}" @"${TSIP:-127.0.0.1}" 2>/dev/null | grep -v '^;' | head -1)"
  pun="$(dig +short +time=2 +tries=1 "cloud.${DOMAIN:-example.com}" @1.1.1.1 2>/dev/null | grep -v '^;' | head -1)"
  row dns "dnsmasq $(systemctl is-active dnsmasq 2>/dev/null) · listen $(grep -h '^listen-address' /etc/dnsmasq.d/*.conf 2>/dev/null | cut -d= -f2 | tr '\n' ' ') → cloud.${DOMAIN:-?}: ${lans:-NO ANSWER}"
  row dns-public "via 1.1.1.1 → ${pun:-NO ANSWER} (must be the public VPS A record)"
fi

# ───────────────────────────── project / git ────────────────────────────────
sec "project"
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  b="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  u="$(git -C "$ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
  [ -n "$u" ] || u="origin/$b"
  row branch "${b} → ${u} · $(git -C "$ROOT" rev-list --count "$u"..HEAD 2>/dev/null || echo '?') ahead · $(git -C "$ROOT" rev-list --count "HEAD..$u" 2>/dev/null || echo '?') behind"
  row last "$(git -C "$ROOT" log -1 --format='%h %cd %an — %s' --date=short 2>/dev/null | cut -c1-64)"
  gd="$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l)"
  if [ "$gd" -gt 0 ]; then
    row dirty "${Y}${gd} change(s)${N} · $(git -C "$ROOT" status --porcelain 2>/dev/null | head -6 | awk '{printf "%s ", $2}' | sed "s#$ROOT/##g" | cut -c1-60)"
  else
    row dirty "${G}clean${N}"
  fi
  row remote "$(git -C "$ROOT" remote get-url origin 2>/dev/null)"
fi
mstr=""
for m in cloud vault mail monitor; do
  if mod_in "$m"; then mstr+="${G}${m}${N}  "; else mstr+="${R}${m}${N}  "; fi
done
row modules "$mstr"
for m in cloud vault mail monitor; do
  d="$(case "$m" in cloud) echo nextcloud;; vault) echo vaultwarden;; mail) echo mailserver;; monitor) echo uptimekuma;; esac)"
  [ -d "$ROOT/modules/$d" ] || continue
  [ -z "$(ls -A "$ROOT/modules/$d" 2>/dev/null)" ] && continue
  vh="$(ls "$ROOT/modules/$d/vhosts" 2>/dev/null | wc -l)"
  ctns="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -cE "^(nextcloud|redis|postgresql|mailserver|roundcube|uptimekuma|vaultwarden)$" || true)"
  printf "  %s%-16s%s %-9s %s %s\n" "${C}${B}" "module $m" "$N" "$d" \
    "$([ "$vh" -gt 0 ] && echo "${vh} vhost(s)")" "$(mod_in "$m" && echo '' || echo "${D}(not installed)${N}")"
done
if [ -d "$DATA/caddy_data" ]; then
  certs="$(find "$DATA/caddy_data" -name '*.crt' 2>/dev/null | wc -l)"
  soonest="$(for f in $(find "$DATA/caddy_data" -name '*.crt' 2>/dev/null); do openssl x509 -enddate -noout -in "$f" 2>/dev/null | sed 's/notAfter=//'; done | sort | head -1)"
  days=""; [ -n "$soonest" ] && days="$(( ($(date -d "$soonest" +%s) - $(date +%s)) / 86400 ))d"
  row tls "${certs} certs · earliest expiry ${days:-?} (${soonest:-none})"
fi
row images-local "$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -vE '^(ghcr|louislam|postgres|redis|roundcube|alpine|debian)' | head -8 | tr '\n' ' ')"
rule
echo ""
