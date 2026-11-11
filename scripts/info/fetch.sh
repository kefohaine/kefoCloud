#!/usr/bin/env bash
# scripts/info/fetch.sh — the `make fetch` one-screen dashboard.
#
# The banner, then two fixed blocks, each row one live fact and nothing else:
#   host     — ssh target, os, uptime, disk /, memory, swap, ip (one interface,
#              the default-route one, with its prefix)
#   kefocloud — the install checkpoint (wizard.state `finished`), then git,
#              tailnet, host systemd units, tmux sessions, docker containers, modules
# Anything deeper (load, top processes, containers by name, failed units,
# backups, routes) is `make fetch-more`'s job, not this screen's.
#
# Module-aware: the record comes from data/wizard.state via
# scripts/lib/modules.sh — the ONE accessor (the installer is the sole writer).
# `installation` is the install checkpoint printed FIRST (the honest caveat for
# every row below it); `modules` counts the installed modules against every
# module config/modules.conf declares.
#
# No arguments. Colors auto-disable when stdout is not a tty or NO_COLOR is set.

. "$(dirname "$(readlink -f "$0")")/../lib/instance.sh" 2>/dev/null || true
set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/scripts/lib/modules.sh"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m' D=$'\033[2m' R=$'\033[31m' G=$'\033[32m' Y=$'\033[33m' N=$'\033[0m'
else
  B='' D='' R='' G='' Y='' N=''
fi

# label field 11 + "| ", or 13 and no pipe: both put the value at the same column
row()  { printf "  %-11s| %s\n" "$1" "$2"; }
row0() { printf "  %-13s%s\n" "$1" "$2"; }
rule() { printf "  %s%s%s\n" "$D" "$(printf '%*s' 72 '' | tr ' ' '-')" "$N"; }

# bytes -> binary unit, one decimal under 10 (2.9 TiB), integer above (156 GiB)
hum() {
  awk -v b="${1:-0}" 'BEGIN{split("B KiB MiB GiB TiB PiB",u," ");i=0;v=b;
    while(v>=1024&&i<5){v/=1024;i++}
    if(i==0)printf "%d B",v; else if(v<10)printf "%.1f %s",v,u[i+1]; else printf "%.0f %s",v,u[i+1]}'
}

cat <<'BANNER'

   ██ ▄█▀▓█████   █████▒▒█████   ▄████▄   ██▓     ▒█████   █    ██ ▓█████▄ 
   ██▄█▒ ▓█   ▀ ▓██   ▒▒██▒  ██▒▒██▀ ▀█  ▓██▒    ▒██▒  ██▒ ██  ▓██▒▒██  ██▌
  ▓███▄░ ▒███   ▒████ ░▒██░  ██▒▒▓█    ▄ ▒██░    ▒██░  ██▒▓██  ▒██░░██   █▌
  ▓██ █▄ ▒▓█  ▄ ░▓█▒  ░▒██   ██░▒▓▓▄ ▄██▒▒██░    ▒██   ██░▓▓█  ░██░░▓█    ▌
  ▒██▒ █▄░▒████▒░▒█░   ░ ████▓▒░▒ ▓███▀ ░░██████▒░ ████▓▒░▒▒█████▓ ░▒████▓ 
  ▒ ▒▒ ▓▒░░ ▒░ ░ ▒ ░   ░ ▒░▒░▒░ ░ ░▒ ▒  ░░ ▒░▓  ░░ ▒░▒░▒░ ░▒▓▒ ▒ ▒  ▒▒▓  ▒ 
  ░ ░▒ ▒░ ░ ░  ░ ░       ░ ▒ ▒░   ░  ▒   ░ ░ ▒  ░  ░ ▒ ▒░ ░░▒░ ░ ░  ░ ▒  ▒ 
  ░ ░░ ░    ░    ░ ░   ░ ░ ░ ▒  ░          ░ ░   ░ ░ ░ ▒   ░░░ ░ ░  ░ ░  ░ 
  ░  ░      ░  ░           ░ ░  ░ ░          ░  ░    ░ ░     ░        ░    
                                ░                                   ░      

BANNER

rule
printf "  %s[WARN]%s %s%s make fetch%s\n" "$Y" "$N" "$D" "$(date '+[%H:%M:%S]')" "$N"
rule
echo ""

# ssh — the login this dashboard was read over
row0 ssh "$(id -un)@$(hostname -s)"

rule

# os
. /etc/os-release 2>/dev/null || true
row os "${PRETTY_NAME:-Debian} $(uname -m) $(dpkg --print-architecture 2>/dev/null || uname -m)"

# uptime — since the boot date
up=$(cut -d. -f1 /proc/uptime)
boot=$(date -d "@$(( $(date +%s) - up ))" '+%F' 2>/dev/null || echo '?')
row uptime "$((up / 86400))d $(((up % 86400) / 3600))h $(((up % 3600) / 60))m since ${boot}"

# disk / — used / size (pct)
read -r dk_u dk_s dk_p < <(df -B1 / | awk 'NR==2{print $3, $2, $5+0}')
dcol="$N"
[ "${dk_p:-0}" -ge 90 ] 2>/dev/null && dcol="$R"
[ "${dk_p:-0}" -ge 75 ] 2>/dev/null && dcol="$Y"
row "disk /" "${dcol}$(hum "$dk_u") / $(hum "$dk_s") (${dk_p}%)${N}"

# memory + swap — one `free` read
freeb=$(free -b)
read -r mt mu < <(awk '/^Mem:/{print $2, $3}' <<<"$freeb")
read -r st su < <(awk '/^Swap:/{print $2, $3}' <<<"$freeb")
mp=$(( mu * 100 / (mt > 0 ? mt : 1) ))
mcol="$N"; [ "$mp" -ge 85 ] 2>/dev/null && mcol="$R"
row memory "${mcol}$(hum "$mu") / $(hum "$mt") (${mp}%)${N}"
if [ "${st:-0}" -eq 0 ]; then
  row swap "${D}none${N}"
else
  sp=$(( su * 100 / st ))
  row swap "$(hum "$su") / $(hum "$st") (${sp}%)"
fi

# ip — the default-route interface's address and prefix (one interface, not every
# bridge: docker0 / br-* are global too and would otherwise be listed)
ifc=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
if [ -n "$ifc" ]; then
  cidr=$(ip -4 -o addr show dev "$ifc" scope global 2>/dev/null | awk 'NR==1{print $4}')
else
  cidr=$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1{print $4}')
fi
row ip "${cidr:-${D}no global ipv4${N}}"

rule
echo ""

# kefocloud — the install checkpoint (wizard.state `finished`)
case "$(mod_finished)" in
  true)    row0 kefocloud "${G}installed${N}" ;;
  *)       row0 kefocloud "${R}pending${N}" ;;
esac

rule

# git — working tree state · branch line (upstream + [gone] included)
gb=$(git -C "$ROOT" status -sb 2>/dev/null | head -1 | sed 's/^## //')
gd=$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l)
if [ "${gd:-0}" -gt 0 ]; then gs="${Y}${gd} uncommitted${N}"; else gs="${G}clean${N}"; fi
row git "${gs} · ${gb:-no git}"

# tailnet — JSON, not the columnar `tailscale status`: its human output marks an
# ONLINE node with "-" (not "idle"/"active"), which once read a healthy net as
# "0 up". up:down counts self + peers, then this host's tailnet address.
if command -v tailscale >/dev/null 2>&1 && ts_json=$(tailscale status --json 2>/dev/null) && [ -n "$ts_json" ]; then
  tsip=$(printf '%s' "$ts_json" | jq -r '.Self.TailscaleIPs[0] // empty' 2>/dev/null)
  upn=$(printf '%s' "$ts_json" | jq -r '[.Self, (.Peer[]?)] | map(select(.Online == true)) | length' 2>/dev/null)
  down=$(printf '%s' "$ts_json" | jq -r '[.Peer[]?] | map(select(.Online != true)) | length' 2>/dev/null)
  row tailnet "${G}${upn:-0}${N}:${R}${down:-0}${N} up:down · ${tsip:-?}"
else
  row tailnet "${D}tailscale unavailable${N}"
fi

# systemctl — the host units this stack depends on, active:inactive
sup=0; sdown=0
for u in ttyd dnsmasq goose; do
  if [ "$(systemctl is-active "$u" 2>/dev/null)" = active ]; then sup=$((sup + 1)); else sdown=$((sdown + 1)); fi
done
scol="$N"; [ "$sdown" -gt 0 ] && scol="$R"
row systemctl "${G}${sup}${N}:${scol}${sdown}${N} up:down"

# tmux — sessions
if command -v tmux >/dev/null 2>&1; then
  tsess=$(tmux ls -F '#{session_name}' 2>/dev/null | grep -c . || true)
  row tmux "${tsess} alive"
else
  row tmux "${D}tmux unavailable${N}"
fi

# docker — running / recorded containers. `recorded` is the caddy edge plus
# every container of every module wizard.state has enabled: what the install
# actually put on this host. Green ONLY when all of them run — one stopped
# container is exactly what this row exists to surface, so a partial stack goes
# red like an empty one.
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  drunning=$(docker ps --format '{{.Names}}' 2>/dev/null)
  drec=0; drun=0
  # mod_containers prints no trailing newline: one `echo` per module keeps the
  # command substitution's word splitting from gluing two modules' lists.
  for c in caddy $(while read -r m; do
      [ -n "$m" ] || continue; mod_installed "$m" || continue; mod_containers "$m"; echo
    done < <(mod_all)); do
    drec=$((drec + 1))
    grep -qx "$c" <<<"$drunning" && drun=$((drun + 1))
  done
  dcol="$G"; [ "$drun" -lt "$drec" ] && dcol="$R"
  row docker "${dcol}${drun}/${drec} running${N}"
else
  row docker "${R}docker unavailable${N}"
fi

# modules — installed count / every module config/modules.conf declares
mtot=0; minst=0
while read -r m; do
  [ -n "$m" ] || continue
  mtot=$((mtot + 1))
  mod_installed "$m" && minst=$((minst + 1))
done < <(mod_all)
mcol="$G"; [ "$minst" -lt "$mtot" ] && mcol="$Y"
row modules "${mcol}${minst} / ${mtot} enabled${N}"

rule
