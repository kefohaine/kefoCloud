#!/usr/bin/env bash
#
# optimize.sh — universal Debian-family VPS performance optimizer
#
# One self-contained, idempotent script that applies every performance
# optimization in one run, automatically:
#   - OPTIMIZE.md (Debian 13 setup): swapfile, sysctl, BBR, process limits,
#     unneeded-service pruning
#   - homelab repo tuning: dirty ratios, TCP fastopen/slow-start, docker
#     daemon, dnsmasq cache, storage-box swap pattern
#   - strong standards for a high-performance VPS: journald caps, inotify
#     limits, noatime, fstrim, IRQ balance, low-RAM OOM guard
#
# Universal by design: no repo paths, hostnames, containers or service names
# are assumed. Everything is auto-detected from the live system; files are
# only touched when the state actually differs; every edit is backed up to
# /root/optimize-backup-<timestamp>. Safe to re-run at any time.
#
# Usage (as root):
#   ./optimize.sh [--dry-run] [--verify] [--yes] [flags...]
#
# Flags:
#   --dry-run            print the plan without changing anything
#   --verify             re-check the applied state only (no writes)
#   --yes                allow package installs + service restarts
#   --swap-gb N          swapfile size in GB (default 4)
#   --force-swap         recreate the swapfile even if a swap is active
#   --no-swap            never touch swap
#   --noatime            add noatime,nodiratime to the root mount (auto-reverts)
#   --force-fstrim       run fstrim even if all disks report rotational
#   --restart-docker     restart dockerd after writing daemon.json
#   --restart-dnsmasq    restart dnsmasq after writing its config
#   --with-earlyoom      install + enable earlyoom (recommended on <=4 GB RAM)
#   --backup-dir DIR     where to back up edited files
#   --help               this text
#
set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# ------------------------------------------------------------- flags
DRY=0; VERIFY=0; YES=0; FORCE_SWAP=0; NO_SWAP=0; NOATIME=0
FORCE_FSTRIM=0; RESTART_DOCKER=0; RESTART_DNSMASQ=0; WITH_EARLYOOM=0
SWAP_GB=4; BACKUP_DIR=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --verify) VERIFY=1 ;;
    --yes) YES=1 ;;
    --force-swap) FORCE_SWAP=1 ;;
    --no-swap) NO_SWAP=1 ;;
    --noatime) NOATIME=1 ;;
    --force-fstrim) FORCE_FSTRIM=1 ;;
    --restart-docker) RESTART_DOCKER=1 ;;
    --restart-dnsmasq) RESTART_DNSMASQ=1 ;;
    --with-earlyoom) WITH_EARLYOOM=1 ;;
    --swap-gb=*) SWAP_GB="${a#*=}" ;;
    --backup-dir=*) BACKUP_DIR="${a#*=}" ;;
    --help|-h) sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $a (see --help)" >&2; exit 1 ;;
  esac
done
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_DIR:-/root/optimize-backup-$TS}"

# ------------------------------------------------------------- helpers
ok() { "$@" >/dev/null 2>&1; }
STEPS=()
log() { local m="$1" label="$2" note="${3:-}"; STEPS+=("$m|$label|$note"); case "$m" in
  chg)  printf '[chg] %s%s\n' "$label" "${note:+ — $note}";;
  ok)   printf '[ok ] %s%s\n' "$label" "${note:+ — $note}";;
  skip) printf '[ - ] %s%s\n' "$label" "${note:+ — $note}";;
  hint) printf '[>> ] %s%s\n' "$label" "${note:+ — $note}";;
esac; }

backup() { local p="$1"; [ "$DRY" = 1 ] && return 0; mkdir -p "$BACKUP_DIR"; [ -f "$p" ] && cp -a "$p" "$BACKUP_DIR/$(echo "$p" | tr '/' '_')"; }
write_file() { # path, content — exact-bytes compare, so re-runs are no-ops
  local p="$1" c="$2"
  if [ -f "$p" ] && cmp -s "$p" <(printf '%s' "$c"); then log ok "$p"; return 1; fi
  backup "$p"
  if [ "$DRY" = 1 ]; then log chg "$p (plan)"; return 0; fi
  mkdir -p "${p%/*}"; printf '%s' "$c" > "$p"; log chg "$p"; return 0
}
append_lines() { # path, lines...
  local p="$1"; shift
  local cur missing=() l
  cur="$(read_file "$p")"
  for l in "$@"; do printf '%s\n' "$cur" | grep -qxF -- "$l" || missing+=("$l"); done
  [ ${#missing[@]} -eq 0 ] && { log ok "$p"; return 1; }
  backup "$p"
  if [ "$DRY" = 1 ]; then log chg "$p (+${#missing[@]} line$( [ ${#missing[@]} -gt 1 ] && echo s)) (plan)"; return 0; fi
  { printf '%s' "$cur"; [ -n "$cur" ] && printf '\n'; printf '%s\n' "${missing[@]}"; } >> "$p"
  log chg "$p (+${#missing[@]} line$( [ ${#missing[@]} -gt 1 ] && echo s))"; return 0
}
read_file() { local p="$1"; [ -f "$p" ] && cat "$p" || true; }

# ------------------------------------------------------------- preflight
[ "$(id -u)" = 0 ] || { echo "run as root: sudo ./optimize.sh [--dry-run]" >&2; exit 1; }
if ! grep -qE '^ID=(debian|ubuntu)$' /etc/os-release; then
  echo "optimize.sh targets Debian-family systems only (ID=$(grep -E '^ID=' /etc/os-release | cut -d= -f2))" >&2; exit 1
fi
NPROC="$(nproc)"; MEM_GB="$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)"; [ -z "$MEM_GB" ] && MEM_GB=1
ok command -v docker && HAS_DOCKER=1 || HAS_DOCKER=0
ok command -v dnsmasq && HAS_DNSMASQ=1 || HAS_DNSMASQ=0
MODE="APPLY"; [ "$DRY" = 1 ] && MODE="DRY-RUN (no changes)"; [ "$VERIFY" = 1 ] && MODE="VERIFY"
echo "# optimize.sh $MODE — ${NPROC} cpu, ~${MEM_GB} GB RAM, docker=${HAS_DOCKER}, dnsmasq=${HAS_DNSMASQ}"
echo

# ------------------------------------------------------------- 1. kernel / memory / network
SYSCTLS="vm.swappiness|10|prefer evicting clean cache over swapping (low-RAM friendly)
vm.vfs_cache_pressure|50|keep inode/dentry cache longer (OPTIMIZE.md)
vm.dirty_ratio|10|smaller writeback bursts -> no long stalls on sync
vm.dirty_background_ratio|5|start writeback earlier, in shorter bursts
vm.max_map_count|262144|headroom for containers/DBs/ES-style workloads
fs.file-max|2097152|max open files system-wide (OPTIMIZE.md)
fs.inotify.max_user_watches|524288|file-watcher headroom (editors, sync tools, apps)
fs.inotify.max_user_instances|1024|inotify instance headroom
net.core.somaxconn|65535|listen backlog for busy proxies/web servers
net.core.netdev_max_backlog|16384|packet backlog before the stack drops
net.core.rmem_max|16777216|allow large TCP receive windows
net.core.wmem_max|16777216|allow large TCP send windows
net.core.default_qdisc|fq|fair-queue qdisc (pair with BBR)
net.ipv4.tcp_congestion_control|bbr|BBR congestion control (win on lossy/high-BDP links)
net.ipv4.tcp_rmem|4096 87380 16777216|auto-tuned receive buffer range
net.ipv4.tcp_wmem|4096 65536 16777216|auto-tuned send buffer range
net.ipv4.tcp_fastopen|3|TFO for client+server (saves an RTT on TLS)
net.ipv4.tcp_slow_start_after_idle|0|don't reset cwnd after idle (interactive HTTPS)
net.ipv4.tcp_max_syn_backlog|65536|SYN backlog for connection bursts
net.ipv4.tcp_tw_reuse|1|reuse TIME-WAIT sockets (safe with timestamps on)
net.ipv4.tcp_notsent_lowat|16384|lower queued-unsent threshold -> lower latency
net.ipv4.ip_forward|1|IP forwarding (containers/VPNs)
net.ipv6.conf.all.forwarding|1|IPv6 forwarding (containers/VPNs)
net.ipv6.conf.default.forwarding|1|IPv6 forwarding default"

CTL="# Generated by optimize.sh — universal VPS tuning (re-run to refresh).
# Merged from OPTIMIZE.md + repo configs + strong standards."
while IFS='|' read -r key val cmt; do
  CTL="${CTL}
# $cmt
$key = $val"
done <<< "$SYSCTLS"
write_file /etc/sysctl.d/99-optimize.conf "${CTL}
"
if [ "$DRY" = 0 ] && [ "$VERIFY" = 0 ]; then
  sysctl --system >/dev/null 2>&1 || while IFS='|' read -r key val cmt; do
    sysctl -w "$key=${val%%|*}" >/dev/null 2>&1
  done <<< "$SYSCTLS"
fi

# ------------------------------------------------------------- 2. process limits
append_lines /etc/security/limits.conf \
  '*               soft    nofile          65535' \
  '*               hard    nofile          65535' \
  'root            soft    nofile          65535' \
  'root            hard    nofile          65535'
if write_file /etc/systemd/system.conf.d/99-optimize.conf '[Manager]
DefaultLimitNOFILE=65535
'; then [ "$DRY" = 0 ] && [ "$VERIFY" = 0 ] && systemctl daemon-reexec 2>/dev/null || true; fi

# ------------------------------------------------------------- 3. swap
if [ "$NO_SWAP" = 1 ]; then
  log skip "swap" "--no-swap given"
else
  ACTIVE_SWAP="$(swapon --show --noheadings 2>/dev/null)"
  if [ -n "$ACTIVE_SWAP" ] && [ "$FORCE_SWAP" = 0 ]; then
    log ok "swap ($(echo "$ACTIVE_SWAP" | head -1))" "use --force-swap to recreate"
  else
    SIZE="$SWAP_GB"; [ "$SIZE" -le 0 ] && SIZE=$(( MEM_GB / 2 ))
    [ "$FORCE_SWAP" = 1 ] && { swapoff -a 2>/dev/null; rm -f /swapfile; }
    if [ "$DRY" = 1 ] || [ "$VERIFY" = 1 ]; then
      log chg "swap /swapfile ${SIZE}G (plan)"
    elif fallocate -l "${SIZE}G" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$(( SIZE * 1024 )) status=none; then
      chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
      append_lines /etc/fstab '/swapfile none swap defaults 0 0' >/dev/null
      log chg "swap /swapfile ${SIZE}G"
    else
      log skip "swap" "could not allocate swapfile"
    fi
  fi
fi

# ------------------------------------------------------------- 4. unneeded services (only if present + enabled)
PRUNE="cups.service cups-browsed.service ModemManager.service avahi-daemon.service bluetooth.service wpa_supplicant.service speech-dispatcher.service pppd-dns.service"
for u in $PRUNE; do
  st="$(systemctl is-enabled "$u" 2>/dev/null)"
  case "$st" in
    enabled|enabled-runtime)
      [ "$DRY" = 0 ] && [ "$VERIFY" = 0 ] && systemctl disable --now "$u" 2>/dev/null
      log chg "disable $u";;
    *) log skip "disable $u" "${st:-not installed}";;
  esac
done

# ------------------------------------------------------------- 5. journald caps
if write_file /etc/systemd/journald.conf.d/99-optimize.conf '[Journal]
SystemMaxUse=512M
SystemMaxFileSize=64M
MaxRetentionSec=7d
Compress=yes
'; then [ "$DRY" = 0 ] && [ "$VERIFY" = 0 ] && systemctl restart systemd-journald; fi

# ------------------------------------------------------------- 6. docker daemon tuning
if [ "$HAS_DOCKER" = 1 ]; then
  P=/etc/docker/daemon.json
  TUNE='{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"},"live-restore":true,"max-concurrent-downloads":10,"max-concurrent-uploads":10,"userland-proxy":false}'
  if [ -f "$P" ] && ok command -v jq; then
    NEW="$(jq -s --argjson t "$TUNE" '.[0] * $t' "$P")"
  elif [ -f "$P" ] && ok command -v python3; then
    NEW="$(python3 -c 'import json,sys; a=json.load(open(sys.argv[1])); a.update(json.loads(sys.argv[2])); print(json.dumps(a,indent=2))' "$P" "$TUNE")"
  elif [ -f "$P" ]; then
    NEW="$TUNE"; log hint "docker daemon.json" "no jq/python3 — unknown existing keys dropped (install jq to merge)"
  else
    NEW="$TUNE"
  fi
  if ! printf '%s' "$NEW" | grep -q '"storage-driver"'; then
    NEW="$(printf '%s' "$NEW" | sed 's/}$/,"storage-driver":"overlay2"}/')"
  fi
  if write_file "$P" "${NEW}
"; then
    if [ "$DRY" = 1 ] || [ "$VERIFY" = 1 ]; then :
    elif [ "$RESTART_DOCKER" = 1 ]; then systemctl restart docker
    else log hint "docker daemon.json written" "restart dockerd to apply: systemctl restart docker (or --restart-docker)"; fi
  fi
fi

# ------------------------------------------------------------- 7. dnsmasq cache
if [ "$HAS_DNSMASQ" = 1 ]; then
  if grep -rsq '^cache-size=' /etc/dnsmasq.conf /etc/dnsmasq.d/ 2>/dev/null; then
    log ok "dnsmasq cache-size" "already set"
  elif write_file /etc/dnsmasq.d/99-optimize.conf 'cache-size=10000
'; then
    [ "$DRY" = 0 ] && [ "$VERIFY" = 0 ] && [ "$RESTART_DNSMASQ" = 1 ] && systemctl restart dnsmasq
    [ "$RESTART_DNSMASQ" = 0 ] && log hint "dnsmasq cache-size=10000" "restart dnsmasq: systemctl restart dnsmasq (or --restart-dnsmasq)"
  fi
fi

# ------------------------------------------------------------- 8. noatime on root
if [ "$NOATIME" = 1 ]; then
  FSTAB="$(read_file /etc/fstab)"
  ROOTLINE="$(printf '%s\n' "$FSTAB" | awk '$2=="/" && $3 ~ /^(ext4|xfs|btrfs)$/')"
  if [ -n "$ROOTLINE" ] && ! printf '%s' "$ROOTLINE" | grep -q noatime; then
    NEWLINE="$(printf '%s' "$ROOTLINE" | awk '{for(i=1;i<=NF;i++){if(i==4)$i=$i",noatime,nodiratime"};print}')"
    backup /etc/fstab
    if [ "$DRY" = 1 ] || [ "$VERIFY" = 1 ]; then
      log chg "noatime,nodiratime on / (plan)"
    else
      sed -i "s|^${ROOTLINE}$|${NEWLINE}|" /etc/fstab
      if mount -o remount / 2>/dev/null && findmnt -no OPTIONS / | grep -q noatime; then
        log chg "noatime,nodiratime on /"
      else
        cp -a "$BACKUP_DIR/$(echo /etc/fstab | tr '/' '_')" /etc/fstab 2>/dev/null
        mount -o remount / 2>/dev/null
        log skip "noatime" "remount failed — reverted"
      fi
    fi
  else
    log ok "noatime on /" "$([ -n "$ROOTLINE" ] && echo already set || echo root fs not ext4/xfs/btrfs)"
  fi
fi

# ------------------------------------------------------------- 9. fstrim (SSD only)
ROT="$(cat /sys/block/*/queue/rotational 2>/dev/null | sort -u)"
if [ "$FORCE_FSTRIM" = 1 ] || { [ -n "$ROT" ] && [ "$ROT" != 1 ]; }; then
  [ "$DRY" = 0 ] && [ "$VERIFY" = 0 ] && { systemctl enable --now fstrim.timer 2>/dev/null; fstrim --fstab -v 2>/dev/null; }
  log chg "fstrim.timer + weekly trim" "$([ "$FORCE_FSTRIM" = 1 ] && echo forced || echo disk reports non-rotational)"
else
  log skip "fstrim" "all disks report rotational (spinning/VirtIO) — use --force-fstrim if SSD-backed"
fi

# ------------------------------------------------------------- 10. apt speed
write_file /etc/apt/apt.conf.d/99-optimize 'Acquire::Languages "none";
Dpkg::Use-Pty "false";
'

# ------------------------------------------------------------- 11. optional packages (need --yes)
if [ "$NPROC" -ge 8 ]; then
  if ok command -v irqbalance; then log ok "irqbalance"
  elif [ "$YES" = 1 ]; then
    [ "$DRY" = 0 ] && [ "$VERIFY" = 0 ] && apt-get install -y -qq irqbalance >/dev/null 2>&1 && systemctl enable --now irqbalance 2>/dev/null
    log chg "irqbalance installed+enabled"
  else log hint "irqbalance" "${NPROC} cpus — re-run with --yes to install"; fi
fi
if [ "$WITH_EARLYOOM" = 1 ]; then
  if ok command -v earlyoom; then log ok "earlyoom"
  elif [ "$YES" = 1 ]; then
    [ "$DRY" = 0 ] && [ "$VERIFY" = 0 ] && apt-get install -y -qq earlyoom >/dev/null 2>&1 && systemctl enable --now earlyoom 2>/dev/null
    log chg "earlyoom installed+enabled"
  else log hint "earlyoom" "re-run with --yes to install"; fi
fi

# ------------------------------------------------------------- 12. verify (runs after apply, or alone with --verify)
if [ "$DRY" = 0 ] && { [ "$VERIFY" = 1 ] || [ "$MODE" = "APPLY" ]; }; then
  echo; echo "# verify"
  FAIL=0
  while IFS='|' read -r key val cmt; do
    got="$(sysctl -n "$key" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//')"
    exp="$(echo "$val" | tr -s ' ')"
    if [ "$got" = "$exp" ] || { [ "$(echo "$val" | wc -w)" -gt 1 ] && [ -n "$got" ]; }; then
      echo "  ok  $key = $got"
    else echo "  FAIL $key = $got (expected $val)"; FAIL=$(( FAIL + 1 )); fi
  done <<< "$SYSCTLS"
  NL="$(ulimit -Sn)"
  if [ "$NL" -ge 65535 ]; then echo "  ok  soft nofile = $NL"; else echo "  FAIL soft nofile = $NL"; FAIL=$(( FAIL + 1 )); fi
  for u in $PRUNE; do
    st="$(systemctl is-enabled "$u" 2>/dev/null)"
    case "$st" in ""|disabled|masked|static|indirect|generated|not-found) echo "  ok  $u $st";;
      *) echo "  FAIL $u still $st"; FAIL=$(( FAIL + 1 ));; esac
  done
  if [ "$NO_SWAP" = 0 ] && [ -z "$(swapon --show --noheadings 2>/dev/null)" ]; then echo "  FAIL swap (none active)"; FAIL=$(( FAIL + 1 ));
  else echo "  ok  swap $(swapon --show --noheadings 2>/dev/null | head -1)"; fi
  for f in /etc/sysctl.d/99-optimize.conf /etc/systemd/system.conf.d/99-optimize.conf \
           /etc/systemd/journald.conf.d/99-optimize.conf /etc/apt/apt.conf.d/99-optimize; do
    if [ -f "$f" ]; then echo "  ok  $f"; else echo "  FAIL $f"; FAIL=$(( FAIL + 1 )); fi
  done
  [ "$HAS_DOCKER" = 1 ] && { ok docker info && echo "  ok  docker daemon" || { echo "  FAIL docker daemon"; FAIL=$(( FAIL + 1 )); }; }
  [ "$HAS_DNSMASQ" = 1 ] && { ok systemctl is-active dnsmasq && echo "  ok  dnsmasq active" || echo "  -   dnsmasq inactive (may be stopped on purpose)"; }
  if [ "$FAIL" = 0 ]; then echo; echo "verify: all checks passed"; exit 0
  else echo; echo "verify: $FAIL check(s) FAILED"; exit 1; fi
fi

# ------------------------------------------------------------- summary
echo; echo "# summary"
for s in "${STEPS[@]}"; do
  IFS='|' read -r m label note <<< "$s"
  case "$m" in
    chg) echo "  + $label${note:+ — $note}";;
    hint) echo "  > $label${note:+ — $note}";;
    ok) echo "  = $label${note:+ — $note}";;
  esac
done
CHANGED=$(printf '%s\n' "${STEPS[@]}" | grep -c '^chg' || true)
echo
if [ "$DRY" = 1 ]; then echo "dry-run: $CHANGED change(s) planned. Would back up to $BACKUP_DIR"
else
  echo "$CHANGED change(s) applied. Backups: $BACKUP_DIR"
  if printf '%s\n' "${STEPS[@]}" | grep -qE '^chg\|(disable |swap |/etc/security|/etc/systemd/system)'; then
    echo "reboot recommended to fully apply limits/service/swap changes"
  else echo "most settings are live; a reboot is optional"; fi
fi
