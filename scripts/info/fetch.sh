#!/usr/bin/env bash
# scripts/info/fetch.sh — the `make fetch` AIO dashboard.
#
# One aligned, colored, one-screen read of the live system: the install
# checkpoint, every available module (installed green, not-installed red), every
# repo container (running green, stopped red), host perf (uptime, load, cpu,
# memory, swap, disk, top memory processes), git, host units, failed units
# (+ each failed unit's target in () marks), tmux, backups, mailboxes and the
# tailnet — one row per fact, no duplicate listings.
#
# Module-aware: the record comes from data/install.state via
# scripts/lib/modules.sh — the ONE accessor (install.sh is the sole writer).
# TWO INDEPENDENT FACTS, never conflated:
#   * `installation` — the install checkpoint printed FIRST: complete (green) /
#                  pending (red) / no state, from install.state `finished`.
#   * `modules`  — installed (green) vs not installed (red), from install.state,
#                  regardless of `finished`. A not-installed module is ABSENT —
#                  no route — and is printed in WORDS, never colour alone: it is
#                  NOT 'tailnet-only'.
#   * `containers` — the repo-wide roster (config/modules.conf + the edge),
#                  green=running / red=stopped, from live docker — independent
#                  of which modules are enabled.
#
# No arguments. Colors auto-disable when stdout is not a tty or NO_COLOR is set.

. "$(dirname "$(readlink -f "$0")")/../lib/instance.sh" 2>/dev/null || true
set -uo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_DIR="$ROOT/data"
. "$ROOT/scripts/lib/modules.sh"
mod_in() { mod_installed "$1"; }

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\033[1m' D=$'\033[2m' R=$'\033[31m' G=$'\033[32m' Y=$'\033[33m' C=$'\033[36m' N=$'\033[0m'
else
  B='' D='' R='' G='' Y='' C='' N=''
fi

row()  { printf "  %s%-9s%s %s\n" "${C}${B}" "$1" "$N" "$2"; }
rule() { printf "  %s%s%s\n" "$D" "$(printf '%*s' 62 '' | tr ' ' '-')" "$N"; }

echo ""
printf "  %s%s%s — kefoCloud fetch  %s· %s%s\n" "$B" "$(hostname)" "$N" "$D" "$(date '+%F %T %Z')" "$N"
rule

# installation — the install checkpoint (install.state `finished`), first: the
# honest caveat for every row below. complete=green, pending/no state=red.
case "$(mod_finished)" in
  true)    row installation "${G}complete${N} — install.state finished=true" ;;
  false)   row installation "${R}pending${N} — install.state finished=false (install did not complete)" ;;
  absent)  row installation "${R}pending${N} — data/install.state absent (never installed)" ;;
  *)       row installation "${R}pending${N} — finished=$(mod_finished)" ;;
esac

# host
up=$(cut -d. -f1 /proc/uptime)
up_d=$((up / 86400)); up_h=$(((up % 86400) / 3600))
. /etc/os-release 2>/dev/null || true
row host "${PRETTY_NAME:-Debian} · up ${up_d}d ${up_h}h"

# load + cpu
read -r l1 l5 l15 _ < /proc/loadavg
ncpu="$(nproc)"
lcol="$N"
awk -v v="$l15" -v n="$ncpu" 'BEGIN{exit !(v > n*2)}' && lcol="$R"
cpup=$(top -bn1 2>/dev/null | awk '/^%Cpu/{printf "%.0f", 100-$8; exit}')
row load "${lcol}${l1} ${l5} ${l15}${N} · cpu ${cpup:-?}% · ${ncpu} cores"

# memory + swap (one `free` read, not three)
freeb=$(free -b)
m=$(awk '/^Mem:/{printf "%.1f/%.1f GiB", $3/1073741824, $2/1073741824}' <<<"$freeb")
mp=$(awk '/^Mem:/{printf "%d", $3*100/$2}' <<<"$freeb")
s=$(awk '/^Swap:/{if($2==0){print "none"; exit} printf "%.1f/%.1f GiB", $3/1073741824, $2/1073741824}' <<<"$freeb")
mcol="$N"; [ "${mp:-0}" -ge 85 ] 2>/dev/null && mcol="$R"
row memory "${mcol}${m} (${mp:-?}%)${N} · swap ${s}"

# disk (one `df` read)
read -r dk_used dk_size dp < <(df -h / | awk 'NR==2{print $3, $2, $5+0}')
dk="${dk_used}/${dk_size} (${dp}%)"
dcol="$N"
[ "${dp:-0}" -ge 90 ] 2>/dev/null && dcol="$R"
[ "${dp:-0}" -ge 75 ] 2>/dev/null && dcol="$Y"
row "disk /" "${dcol}${dk}${N}"

# top memory processes
topmem=$(ps -eo comm,pmem --sort=-pmem --no-headers 2>/dev/null | head -3 \
  | awk '{printf "%s%s %.0f%%", (NR>1?" · ":""), $1, $2}')
row "top mem" "$topmem"

# modules — ALWAYS every module the repo declares (config/modules.conf), from
# install.state: recorded in green, the rest in red with the words spelled out
# (never colour alone — a not-installed module must not be inferred from colour).
mods=""
while read -r m; do
  [ -n "$m" ] || continue
  if mod_installed "$m"; then mods+="${G}${m}${N}  "
  else mods+="${R}${m}${N} ${D}(not installed)${N}  "; fi
done < <(mod_all)
mods+="${D}(install.state enabled_modules)${N}"
row modules "$mods"

# containers — mod_roster: the edge + EVERY declared module's containers, state
# from live docker, INDEPENDENT of which modules are enabled. running=green,
# stopped=red.
roster="$(mod_roster)"
runnow="$(docker ps --format '{{.Names}}' 2>/dev/null)"
ctns=""
for c in $roster; do
  case "$c" in "") continue ;; esac
  if grep -qx "$c" <<<"$runnow"; then ctns+="${G}${c}${N}  "
  else ctns+="${R}${c} (stopped)${N}  "; fi
done
row containers "$ctns"

# git
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  gb=$(git -C "$ROOT" status -sb 2>/dev/null | head -1 | sed 's/^## //')
  gd=$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l)
  if [ "$gd" -gt 0 ]; then gs="${Y}${gd} uncommitted${N}"; else gs="${G}clean${N}"; fi
  row git "$gb · $gs"
  # The repo's git guards (identity/edge pre-commit + smoke pre-push) — installed
  # by `make install-hooks` and at deploy time by install.sh.
  if [ -x "$ROOT/.git/hooks/pre-commit" ] && [ -x "$ROOT/.git/hooks/pre-push" ]; then
    row hooks "${G}installed${N} — pre-commit (identity + edge), pre-push (smoke)"
  else
    row hooks "${R}missing${N} — run: make install-hooks"
  fi
fi

# host units
us=""
for u in ttyd dnsmasq goose; do
  if [ "$(systemctl is-active "$u" 2>/dev/null)" = active ]; then
    us+="${G}✓${N} $u  "
  else
    us+="${R}✗${N} $u  "
  fi
done
row units "$us"

# failed units (+ each unit's target in () marks)
nfl=$(systemctl --failed --no-legend --plain 2>/dev/null)
nf=$(echo "$nfl" | grep -c . || true)
if [ "${nf:-0}" = 0 ]; then
  row failed "${G}none${N}"
else
  # unit name -> where it points (mount Where / device What / unit Desc)
  ftoks=""
  while read -r un _; do
    [ -n "$un" ] || continue
    tgt=$(systemctl show "$un" -p Where --value 2>/dev/null)
    [ -n "$tgt" ] || tgt=$(systemctl show "$un" -p What --value 2>/dev/null)
    [ -n "$tgt" ] || tgt=$(systemctl show "$un" -p Description --value 2>/dev/null)
    ftoks+="${R}${un}${N}${D}(${tgt})${N}  "
  done < <(echo "$nfl" | head -3)
  row failed "${R}${nf} failed${N} ${ftoks}"
fi

# docker
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  toks=()
  nunh=0
  while IFS=$'\t' read -r nm st; do
    [ -n "$nm" ] || continue
    case "$st" in
      *unhealthy*)  nunh=$((nunh+1)); toks+=("${R}${nm} ✗${N}");;
      *restarting*) nunh=$((nunh+1)); toks+=("${Y}${nm} ↻${N}");;
      *)            toks+=("${G}${nm}${N}");;
    esac
  done < <(docker ps --format '{{.Names}}\t{{.Status}}' 2>/dev/null)
  dhead="${#toks[@]} up"
  [ "$nunh" -gt 0 ] && dhead="${dhead} · ${R}${nunh} unhealthy${N}"
  row docker "$dhead"
  buf=""; i=0
  for t in "${toks[@]}"; do
    buf+="$t   "; i=$((i+1))
    if [ $((i % 5)) = 0 ]; then printf "            %s\n" "$buf"; buf=""; fi
  done
  [ -n "$buf" ] && printf "            %s\n" "$buf"
else
  row docker "${R}docker unavailable${N}"
fi

# tmux
if command -v tmux >/dev/null 2>&1; then
  tsess=$(tmux ls -F '#{session_name}' 2>/dev/null | tr '\n' ' ')
  if [ -n "$tsess" ]; then row tmux "$tsess"; else row tmux "${D}none${N}"; fi
fi

# backups
if [ -d "$PROJECT_DIR/backups" ]; then
  blist=$(ls -1t "$PROJECT_DIR/backups" 2>/dev/null)
  if [ -n "$blist" ]; then
    bn=$(echo "$blist" | wc -l)
    b3=$(echo "$blist" | head -3 | tr '\n' ' ')
    extra=""; [ "$bn" -gt 3 ] && extra=" ${D}(+$((bn-3)) older)${N}"
    row backups "$b3$extra"
  else
    row backups "${D}empty${N}"
  fi
else
  row backups "${D}none yet — make backup${N}"
fi

# mail (module-gated)
if mod_in mail; then
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx mailserver; then
    mb=$(docker exec mailserver setup email list 2>/dev/null | grep -c '@' || true)
    al=$(docker exec mailserver setup alias list 2>/dev/null | grep -c '@' || true)
    row mail "${mb:-0} mailboxes · ${al:-0} aliases"
  else
    row mail "${R}mailserver down${N}"
  fi
else
  row mail "${D}module not installed${N}"
fi

# tailnet — read the JSON, not the columnar `tailscale status`: its human
# output marks an ONLINE node with "-" (not "idle"/"active"), so the old
# grep-for-idle/active count read a healthy net as "0 up", and its first line is
# this host (self), which the old `tail -n +2` dropped — the machine never
# listed itself. Self counts as an up device and is listed first.
if command -v tailscale >/dev/null 2>&1 && ts_json=$(tailscale status --json 2>/dev/null) && [ -n "$ts_json" ]; then
  tsip=$(printf '%s' "$ts_json" | jq -r '.Self.TailscaleIPs[0] // empty' 2>/dev/null)
  up=$(printf '%s' "$ts_json" | jq -r '[.Self, (.Peer[]?)] | map(select(.Online == true)) | length' 2>/dev/null)
  noff=$(printf '%s' "$ts_json" | jq -r '[.Peer[]?] | map(select(.Online != true)) | length' 2>/dev/null)
  pnames=$(printf '%s' "$ts_json" | jq -r '[.Self.HostName, (.Peer[]?.HostName)] | .[:5] | join(" ")' 2>/dev/null)
  row tailnet "${tsip} · ${G}${up:-0} up${N} · ${D}${noff:-0} offline${N} · ${pnames}"
else
  row tailnet "${D}tailscale unavailable${N}"
fi

rule
echo ""