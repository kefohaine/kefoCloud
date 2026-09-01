#!/usr/bin/env bash
# scripts/optimize.sh — universal Debian-family VPS performance optimizer.
#
# One self-contained, idempotent script that squeezes a high-performance VPS
# for the best experience possible — kernel/memory/network tuning, process
# limits, swap, journald caps, docker + dnsmasq tuning, noatime, fstrim, THP,
# apt/docker cleanup — regardless of what the VPS is later used for.
#
# Everything is auto-detected from the live system: no repo paths, hostnames,
# containers or service names are assumed. Files are only touched when the
# state actually differs; every edit is backed up to /root/optimize-backup-*.
#
# Style mirrors install.sh / storage.sh: welcome banner + description, a few
# input prompts at the beginning (with defaults, skipped when env vars or
# --yes are set), then fully unattended work. At the end any failures and
# manual steps are reported with a problem + hint each; every time you press
# Enter the script re-checks them, clears the solved ones, and only prints
# SUCCESS when no issues remain.
#
# Sources merged: OPTIMIZE.md (Debian 13 setup), the repo's tuned values
# (config/sysctl, docker daemon, dnsmasq cache, storage-box swap), `make
# cleanup` (apt autoremove/clean + docker prune — minus backup pruning), and
# standard high-performance-VPS tuning (journald caps, inotify, noatime,
# fstrim, THP=madvise, IRQ balance, earlyoom).
#
# Usage (as root):
#   bash scripts/optimize.sh                # interactive: prompts then unattended
#   bash scripts/optimize.sh --yes          # no prompts, allow package installs
#   bash scripts/optimize.sh --dry-run      # print the plan, change nothing
#   bash scripts/optimize.sh --verify       # re-check applied state only
#
# Env overrides: SWAP_GB= NOATIME=0/1 FORCE_SWAP=0/1 FORCE_FSTRIM=0/1
# WITH_IRQBALANCE=0/1 WITH_EARLYOOM=0/1 (both auto-install; 0 = opt out)
# YES=1 BACKUP_DIR=...

set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# ------------------------------------------------------------------ flags
DRY=0; VERIFY=0; YES=0
SWAP_GB=""; NOATIME=""
BACKUP_DIR=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;; --verify) VERIFY=1 ;; --yes) YES=1 ;;
    --help|-h) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $a (see --help)" >&2; exit 1 ;;
  esac
done

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_DIR:-/root/optimize-backup-$TS}"

# ------------------------------------------------------------------ state
ERR_TAGS=()
declare -A ERR_DETAIL=()
CHANGED=0   # any config actually written this run -> reboot shows as a manual step
NPROC=1; MEM_GB=1; HAS_DOCKER=0; HAS_DNSMASQ=0; ROT=""; ACTIVE_SWAP=""; SSD=0

log()  { echo "[$(date +%H:%M:%S)] $*"; }
fail() {
  local t
  for t in "${ERR_TAGS[@]}"; do [ "$t" = "$1" ] && return 0; done  # no dupes
  ERR_TAGS+=("$1"); ERR_DETAIL[$1]="${2:-}"
  echo "  ERROR: $(problem "$1")${2:+ ($2)}" >&2
}

banner() {
cat <<'EOF'
  ____  _____ _____ _____ ___ ___ _   _ _____ ___ ____
 / __ \|  _  |_   _|_   _|_ _|_ _| \ | | ____|_ _/ ___|
/ / _` | | | | | |   | |  | | | ||  \| |  _|  | | |  _
| |_| | |_| | | |   | |  | | | || |\  | |___ | | |_| |
 \__,_|\___/  |_|   |_| |___|___|_| \_|_____|___\____/

 One-shot performance optimizer for a Debian-family VPS: kernel/memory/
 network tuning (BBR, buffers, dirty ratios, swappiness), process limits,
 swapfile, journald caps, docker daemon + prune, dnsmasq cache, noatime,
 fstrim, THP=madvise, apt cleanup (update / autoremove / clean) — all
 idempotent, auto-detected, and backed up to /root/optimize-backup-*.
 Prompts once (all with defaults), then runs unattended; failures and
 manual steps are re-checked on every Enter until all are green, and
 SUCCESS prints only then.

WARNING: edits kernel parameters, swap, service limits and apt state.
Rebooting is recommended (but not required) after the first run.
EOF
}

# ------------------------------------------------------------------ helpers
ok() { "$@" >/dev/null 2>&1; }
read_file() { local p="$1"; [ -f "$p" ] && cat "$p" || true; }
backup() { local p="$1"; [ "$DRY" = 1 ] && return 0; mkdir -p "$BACKUP_DIR"; [ -f "$p" ] && cp -a "$p" "$BACKUP_DIR/$(echo "$p" | tr '/' '_')"; }
write_file() { # path, content — exact-bytes compare; returns 0 when written/would-write, 1 when unchanged
  local p="$1" c="$2"
  if [ -f "$p" ] && cmp -s "$p" <(printf '%s' "$c"); then log "  ok: $p (unchanged)"; return 1; fi
  backup "$p"
  [ "$DRY" = 1 ] && { log "  would write: $p"; return 0; }
  mkdir -p "${p%/*}"; printf '%s' "$c" > "$p"; CHANGED=1; log "  wrote: $p"; return 0
}
append_lines() { # path, lines... — returns 0 when appended/would-append, 1 when unchanged
  local p="$1"; shift; local cur missing=() l
  cur="$(read_file "$p")"
  for l in "$@"; do printf '%s\n' "$cur" | grep -qxF -- "$l" || missing+=("$l"); done
  [ ${#missing[@]} -eq 0 ] && { log "  ok: $p (unchanged)"; return 1; }
  backup "$p"
  [ "$DRY" = 1 ] && { log "  would append ${#missing[@]} line(s) to $p"; return 0; }
  { printf '%s' "$cur"; [ -n "$cur" ] && printf '\n'; printf '%s\n' "${missing[@]}"; } >> "$p"
  CHANGED=1; log "  appended ${#missing[@]} line(s) to $p"; return 0
}

# ------------------------------------------------------------------ detection
detect() {
  NPROC="$(nproc)"; MEM_GB="$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)"; [ -z "$MEM_GB" ] && MEM_GB=1
  ok command -v docker && HAS_DOCKER=1 || HAS_DOCKER=0
  ok command -v dnsmasq && HAS_DNSMASQ=1 || HAS_DNSMASQ=0
  ROT="$(cat /sys/block/*/queue/rotational 2>/dev/null | sort -u)"
  ACTIVE_SWAP="$(swapon --show --noheadings 2>/dev/null)"
  log "detected: ${NPROC} cpu, ~${MEM_GB} GB RAM, docker=${HAS_DOCKER}, dnsmasq=${HAS_DNSMASQ}, swap=${ACTIVE_SWAP:+active}"
}

# ------------------------------------------------------------------ prompts (beginning only)
ask_inputs() {
  # non-interactive / plan / verify: use defaults, never prompt
  if [ "$DRY" = 1 ] || [ "$VERIFY" = 1 ] || [ "$YES" = 1 ]; then
    SWAP_GB="${SWAP_GB:-4}"; NOATIME="${NOATIME:-1}"
    [ -n "${FORCE_SWAP:-}" ] || FORCE_SWAP=0
    [ -n "${FORCE_FSTRIM:-}" ] || FORCE_FSTRIM=0
    [ -n "${WITH_IRQBALANCE:-}" ] || WITH_IRQBALANCE=1
    [ -n "${WITH_EARLYOOM:-}" ] || WITH_EARLYOOM=1
    local SW_NOTE=""; [ "$FORCE_SWAP" = 1 ] && SW_NOTE=" (recreate)"
    local YES_NOTE=""; [ "$YES" = 1 ] && YES_NOTE=" (--yes)"
    log "plan: swap=${SWAP_GB}G${SW_NOTE} noatime=${NOATIME} fstrim=${FORCE_FSTRIM} irqbalance=${WITH_IRQBALANCE} earlyoom=${WITH_EARLYOOM}${YES_NOTE}"
    return 0
  fi
  if [ -z "$SWAP_GB" ]; then
    read -rp "swapfile size in GB [4 (0 = half of RAM)]: " SWAP_GB
    SWAP_GB="${SWAP_GB:-4}"
  fi
  case "$SWAP_GB" in ''|*[!0-9]*) echo "invalid swap size"; exit 1;; esac
  if [ -z "$NOATIME" ]; then
    read -rp "add noatime,nodiratime to the root mount? [Y/n] " a
    case "${a:-y}" in y|Y|yes) NOATIME=1;; *) NOATIME=0;; esac
  fi
  if [ -n "$ACTIVE_SWAP" ] && [ -z "${FORCE_SWAP:-}" ]; then
    read -rp "swap already active — recreate as /swapfile (${SWAP_GB}G)? [y/N] " a
    case "$a" in y|Y|yes) FORCE_SWAP=1;; *) FORCE_SWAP=0;; esac
  fi
  [ -n "${FORCE_SWAP:-}" ] || FORCE_SWAP=0
  if [ "$ROT" = 1 ] && [ -z "${FORCE_FSTRIM:-}" ]; then
    read -rp "disk reports rotational — force fstrim anyway (SSD-backed VirtIO)? [y/N] " a
    case "$a" in y|Y|yes) FORCE_FSTRIM=1;; *) FORCE_FSTRIM=0;; esac
  fi
  [ -n "${FORCE_FSTRIM:-}" ] || FORCE_FSTRIM=0
  # irqbalance + earlyoom: auto-installed when missing (opt out with =0)
  [ -n "${WITH_IRQBALANCE:-}" ] || WITH_IRQBALANCE=1
  [ -n "${WITH_EARLYOOM:-}" ] || WITH_EARLYOOM=1
  local SW_NOTE=""; [ "$FORCE_SWAP" = 1 ] && SW_NOTE=" (recreate)"
  log "plan: swap=${SWAP_GB}G${SW_NOTE} noatime=${NOATIME} fstrim=${FORCE_FSTRIM} irqbalance=${WITH_IRQBALANCE} earlyoom=${WITH_EARLYOOM}"
}

# ------------------------------------------------------------------ 1. apt cleanup (make cleanup minus backups)
apt_clean() {
  log "apt: update / autoremove / clean"
  [ "$DRY" = 1 ] && { log "  would apt-get update + autoremove -y + clean"; return 0; }
  DEBIAN_FRONTEND=noninteractive apt-get update -qq || { fail apt "apt-get update failed"; return; }
  DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq || fail apt "autoremove failed"
  apt-get clean || fail apt "apt-get clean failed"
  log "  ok: apt updated, autoremoved, cleaned"
}

# ------------------------------------------------------------------ 2. kernel / memory / network
SYSCTLS="vm.swappiness|10|prefer evicting clean cache over swapping (low-RAM friendly)
vm.vfs_cache_pressure|50|keep inode/dentry cache longer
vm.dirty_ratio|10|smaller writeback bursts -> no long stalls on sync
vm.dirty_background_ratio|5|start writeback earlier, in shorter bursts
vm.max_map_count|262144|headroom for containers/DBs/ES-style workloads
fs.file-max|2097152|max open files system-wide
fs.aio-max-nr|1048576|async IO headroom (databases, heavy IO)
fs.inotify.max_user_watches|524288|file-watcher headroom (editors, sync tools, apps)
fs.inotify.max_user_instances|1024|inotify instance headroom
kernel.numa_balancing|0|disable NUMA migrations on a single-socket VM
kernel.nmi_watchdog|0|no NMI watchdog on VMs (false soft-lockups, perf-counter cost)
kernel.sched_autogroup_enabled|0|server: disable per-session CPU groups (predictable scheduling)
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
net.ipv4.ip_local_port_range|1024 65535|wider ephemeral port range (many connections)
net.ipv4.ip_forward|1|IP forwarding (containers/VPNs)
net.ipv6.conf.all.forwarding|1|IPv6 forwarding (containers/VPNs)
net.ipv6.conf.default.forwarding|1|IPv6 forwarding default"

kernel_tune() {
  log "kernel: sysctl tuning"
  local CTL="# Generated by optimize.sh — universal VPS tuning (re-run to refresh)."
  local key val cmt
  while IFS='|' read -r key val cmt; do CTL="${CTL}
# $cmt
$key = $val"; done <<< "$SYSCTLS"
  write_file /etc/sysctl.d/99-optimize.conf "${CTL}
" || true
  if [ "$DRY" = 0 ] && [ "$VERIFY" = 0 ]; then
    sysctl --system >/dev/null 2>&1 || { fail sysctl "sysctl --system failed"; return; }
  fi
  log "  ok: sysctl applied"
}

# ------------------------------------------------------------------ 3. process limits
limits_tune() {
  log "limits: nofile 65535 (pam + systemd)"
  append_lines /etc/security/limits.conf \
    '*               soft    nofile          65535' \
    '*               hard    nofile          65535' \
    'root            soft    nofile          65535' \
    'root            hard    nofile          65535' || true
  local SYS="[Manager]
DefaultLimitNOFILE=65535
DefaultTasksMax=infinity
"
  if write_file /etc/systemd/system.conf.d/99-optimize.conf "$SYS"; then
    [ "$DRY" = 0 ] && [ "$VERIFY" = 0 ] && systemctl daemon-reexec 2>/dev/null
  fi
  log "  ok: limits set"
}

# ------------------------------------------------------------------ 4. swap
swap_tune() {
  log "swap: ensuring a swapfile"
  if [ -n "$ACTIVE_SWAP" ] && [ "$FORCE_SWAP" = 0 ]; then
    log "  ok: swap already active ($(echo "$ACTIVE_SWAP" | head -1))"
    return 0
  fi
  local SIZE="${SWAP_GB:-4}"; [ "$SIZE" -le 0 ] && SIZE=$(( MEM_GB / 2 ))
  [ "$FORCE_SWAP" = 1 ] && { swapoff -a 2>/dev/null; rm -f /swapfile; }
  if [ "$DRY" = 1 ] || [ "$VERIFY" = 1 ]; then
    log "  would create /swapfile ${SIZE}G"
  elif fallocate -l "${SIZE}G" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$(( SIZE * 1024 )) status=none; then
    chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile || { fail swap "mkswap/swapon failed"; return; }
    append_lines /etc/fstab '/swapfile none swap defaults 0 0'
    CHANGED=1
    log "  ok: /swapfile ${SIZE}G active"
  else
    fail swap "could not allocate /swapfile"
  fi
}

# ------------------------------------------------------------------ 5. unneeded services
SERVICE_PRUNE="cups.service cups-browsed.service ModemManager.service avahi-daemon.service bluetooth.service wpa_supplicant.service speech-dispatcher.service pppd-dns.service"
services_prune() {
  log "services: disabling unneeded units (only if present + enabled)"
  local u st
  for u in $SERVICE_PRUNE; do
    st="$(systemctl is-enabled "$u" 2>/dev/null)"
    case "$st" in
      enabled|enabled-runtime)
        if [ "$DRY" = 0 ] && [ "$VERIFY" = 0 ]; then
          systemctl disable --now "$u" 2>/dev/null || { fail services "could not disable $u"; continue; }
        fi
        log "  disabled: $u";;
    esac
  done
  log "  ok: service pruning done"
}

# ------------------------------------------------------------------ 6. journald caps
journald_tune() {
  log "journald: capping log growth"
  if write_file /etc/systemd/journald.conf.d/99-optimize.conf '[Journal]
SystemMaxUse=512M
SystemMaxFileSize=64M
MaxRetentionSec=7d
Compress=yes
'; then
    [ "$DRY" = 0 ] && [ "$VERIFY" = 0 ] && systemctl restart systemd-journald
  fi
  log "  ok: journald capped"
}

# ------------------------------------------------------------------ 7. docker (daemon tuning + prune, like make cleanup)
docker_tune() {
  [ "$HAS_DOCKER" = 0 ] && { log "docker: not installed — skipped"; return 0; }
  log "docker: daemon tuning + prune"
  local P=/etc/docker/daemon.json
  local TUNE='{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"},"live-restore":true,"max-concurrent-downloads":10,"max-concurrent-uploads":10,"userland-proxy":false}'
  local NEW
  if [ -f "$P" ] && ok command -v jq; then
    NEW="$(jq -s --argjson t "$TUNE" '.[0] * $t' "$P")"
  elif [ -f "$P" ] && ok command -v python3; then
    NEW="$(python3 -c 'import json,sys; a=json.load(open(sys.argv[1])); a.update(json.loads(sys.argv[2])); print(json.dumps(a,indent=2))' "$P" "$TUNE")"
  elif [ -f "$P" ]; then
    NEW="$TUNE"; log "  warn: no jq/python3 — unknown existing keys dropped (install jq to merge)"
  else
    NEW="$TUNE"
  fi
  if ! printf '%s' "$NEW" | grep -q '"storage-driver"'; then
    NEW="$(printf '%s' "$NEW" | sed 's/}$/,"storage-driver":"overlay2"}/')"
  fi
  if write_file "$P" "${NEW}
"; then
    if [ "$DRY" = 0 ] && [ "$VERIFY" = 0 ]; then
      python3 -m json.tool "$P" >/dev/null 2>&1 || jq -e . "$P" >/dev/null 2>&1 \
        || { fail docker "invalid daemon.json — restoring previous file"; cp -a "$BACKUP_DIR/$(echo "$P" | tr '/' '_')" "$P" 2>/dev/null; return; }
      systemctl restart docker || fail docker "docker restart failed"
      log "  restarted dockerd (live-restore keeps containers up)"
    fi
  fi
  if [ "$DRY" = 0 ] && [ "$VERIFY" = 0 ]; then
    docker builder prune -af >/dev/null 2>&1 || true
    docker image prune -af >/dev/null 2>&1 || true
    docker container prune -f >/dev/null 2>&1 || true
    log "  ok: docker pruned (builder/images/containers)"
  fi
}

# ------------------------------------------------------------------ 8. dnsmasq cache
dnsmasq_tune() {
  [ "$HAS_DNSMASQ" = 0 ] && { log "dnsmasq: not installed — skipped"; return 0; }
  log "dnsmasq: cache-size"
  if grep -rsq '^cache-size=' /etc/dnsmasq.conf /etc/dnsmasq.d/ 2>/dev/null; then
    log "  ok: cache-size already set"
  elif write_file /etc/dnsmasq.d/99-optimize.conf 'cache-size=10000
'; then
    [ "$DRY" = 0 ] && [ "$VERIFY" = 0 ] && systemctl restart dnsmasq 2>/dev/null || fail dnsmasq "restart failed"
    log "  ok: cache-size=10000"
  fi
}

# ------------------------------------------------------------------ 9. noatime
noatime_tune() {
  [ "$NOATIME" = 1 ] || { log "noatime: skipped (not requested)"; return 0; }
  log "noatime: root mount"
  local FSTAB ROOTLINE NEWLINE
  FSTAB="$(read_file /etc/fstab)"
  ROOTLINE="$(printf '%s\n' "$FSTAB" | awk '$2=="/" && $3 ~ /^(ext4|xfs|btrfs)$/')"
  if [ -n "$ROOTLINE" ] && ! printf '%s' "$ROOTLINE" | grep -q noatime; then
    NEWLINE="$(printf '%s' "$ROOTLINE" | awk '{for(i=1;i<=NF;i++){if(i==4)$i=$i",noatime,nodiratime"};print}')"
    backup /etc/fstab
    if [ "$DRY" = 1 ] || [ "$VERIFY" = 1 ]; then log "  would add noatime,nodiratime to /"; return 0; fi
    sed -i "s|^${ROOTLINE}$|${NEWLINE}|" /etc/fstab
    if mount -o remount / 2>/dev/null && findmnt -no OPTIONS / | grep -q noatime; then
      log "  ok: noatime,nodiratime on /"
    else
      cp -a "$BACKUP_DIR/$(echo /etc/fstab | tr '/' '_')" /etc/fstab 2>/dev/null; mount -o remount / 2>/dev/null
      fail noatime "remount failed — reverted"
    fi
  else
    log "  ok: noatime already set (or root fs not ext4/xfs/btrfs)"
  fi
}

# ------------------------------------------------------------------ 10. fstrim
fstrim_tune() {
  if [ -n "$ROT" ] && [ "$ROT" != 1 ]; then SSD=1; elif [ "$FORCE_FSTRIM" = 1 ]; then SSD=1; else SSD=0; fi
  if [ "$SSD" = 0 ]; then log "fstrim: skipped (disks report rotational — use FORCE_FSTRIM=1 if SSD-backed)"; return 0; fi
  log "fstrim: enabling weekly trim"
  if [ "$DRY" = 0 ] && [ "$VERIFY" = 0 ]; then
    systemctl enable --now fstrim.timer 2>/dev/null || fail fstrim "timer enable failed"
    fstrim --fstab -v 2>/dev/null || true
  fi
  log "  ok: fstrim.timer enabled"
}

# ------------------------------------------------------------------ 11. THP -> madvise
thp_tune() {
  log "thp: transparent huge pages -> madvise (enabled + defrag; fewer latency spikes)"
  local EN=/sys/kernel/mm/transparent_hugepage/enabled
  local DF=/sys/kernel/mm/transparent_hugepage/defrag
  [ -r "$EN" ] || { log "  skipped: THP not exposed"; return 0; }
  local need=0
  grep -q '\[madvise\]' "$EN" || need=1
  [ -r "$DF" ] && ! grep -q '\[madvise\]' "$DF" && need=1
  [ "$need" = 0 ] && { log "  ok: already madvise (enabled + defrag)"; return 0; }
  if write_file /etc/tmpfiles.d/99-optimize.conf "w $EN - - - - madvise
w $DF - - - - madvise
"; then
    if [ "$DRY" = 0 ] && [ "$VERIFY" = 0 ]; then
      echo madvise > "$EN" 2>/dev/null || { fail thp "runtime set failed (enabled)"; return; }
      [ -w "$DF" ] && echo madvise > "$DF" 2>/dev/null
    fi
    log "  ok: THP=madvise (runtime + persists via tmpfiles.d)"
  fi
}

# ------------------------------------------------------------------ 12. packages: irqbalance + earlyoom (auto-install when missing)
pkg_tune() {
  # Both install automatically on every host (opt out: WITH_IRQBALANCE=0 / WITH_EARLYOOM=0).
  if [ "${WITH_IRQBALANCE:-1}" = 1 ] && ! ok command -v irqbalance; then
    if [ "$DRY" = 0 ] && [ "$VERIFY" = 0 ]; then
      apt-get install -y -qq irqbalance >/dev/null 2>&1 && systemctl enable --now irqbalance 2>/dev/null \
        || { fail pkg "irqbalance install failed"; return; }
      log "  ok: irqbalance installed+enabled"
    else
      log "  would install+enable irqbalance"
    fi
  elif [ "${WITH_IRQBALANCE:-1}" = 1 ]; then log "  ok: irqbalance"
  fi
  if [ "${WITH_EARLYOOM:-1}" = 1 ] && ! ok command -v earlyoom; then
    if [ "$DRY" = 0 ] && [ "$VERIFY" = 0 ]; then
      apt-get install -y -qq earlyoom >/dev/null 2>&1 && systemctl enable --now earlyoom 2>/dev/null \
        || { fail pkg "earlyoom install failed"; return; }
      log "  ok: earlyoom installed+enabled"
    else
      log "  would install+enable earlyoom"
    fi
  elif [ "${WITH_EARLYOOM:-1}" = 1 ]; then log "  ok: earlyoom"
  fi
}

# ------------------------------------------------------------------ 13. apt speed
aptconf_tune() {
  log "apt: non-interactive, no language pulls"
  write_file /etc/apt/apt.conf.d/99-optimize 'Acquire::Languages "none";
Dpkg::Use-Pty "false";
'
}

# ------------------------------------------------------------------ error framework (install.sh style)
problem() {
  case "$1" in
    apt)          echo "apt update/autoremove/clean did not complete" ;;
    sysctl)       echo "kernel tuning not applied" ;;
    limits)       echo "process limits not applied" ;;
    swap)         echo "no active swap" ;;
    services)     echo "one or more unneeded services could not be disabled" ;;
    journald)     echo "journald caps not applied" ;;
    docker)       echo "docker daemon config/prune failed" ;;
    dnsmasq)      echo "dnsmasq cache-size not applied" ;;
    noatime)      echo "noatime not active on the root mount" ;;
    fstrim)       echo "fstrim timer not enabled" ;;
    thp)          echo "transparent huge pages still not madvise" ;;
    pkg)          echo "optional package install failed" ;;
    reboot)       echo "reboot pending (recommended after first run)" ;;
    *)            echo "$1" ;;
  esac
}

hint() {
  case "$1" in
    apt)          echo "check 'apt-get update' output; fix mirror/network, then re-check" ;;
    sysctl)       echo "inspect: sysctl --system; check /etc/sysctl.d/99-optimize.conf syntax, then re-check" ;;
    limits)       echo "verify: ulimit -Sn; check /etc/security/limits.conf and /etc/systemd/system.conf.d/99-optimize.conf, then re-check" ;;
    swap)         echo "run: fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile, then re-check" ;;
    services)     echo "run: systemctl disable --now <unit> for each listed unit, then re-check" ;;
    journald)     echo "check: systemctl status systemd-journald; config at /etc/systemd/journald.conf.d/99-optimize.conf, then re-check" ;;
    docker)       echo "run: systemctl restart docker, then re-check" ;;
    dnsmasq)      echo "run: systemctl restart dnsmasq, then re-check" ;;
    noatime)      echo "run: sed -i to add noatime,nodiratime to the / line of /etc/fstab && mount -o remount /, then re-check" ;;
    fstrim)       echo "run: systemctl enable --now fstrim.timer, then re-check" ;;
    thp)          echo "run: echo madvise > /sys/kernel/mm/transparent_hugepage/enabled, then re-check" ;;
    pkg)          echo "run: apt-get install -y <package>, then re-check" ;;
    reboot)       echo "run: sudo reboot (optional but recommended; press Enter to acknowledge for now)" ;;
    *)            echo "" ;;
  esac
}

recheck() {
  case "$1" in
    apt)          DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 ;;
    sysctl)
      local key val got exp all=1
      while IFS='|' read -r key val cmt; do
        got="$(sysctl -n "$key" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//')"
        exp="$(echo "$val" | tr -s ' ')"
        [ "$got" = "$exp" ] || [ "$(echo "$val" | wc -w)" -gt 1 -a -n "$got" ] || all=0
      done <<< "$SYSCTLS"
      [ "$all" = 1 ];;
    limits)       [ "$(ulimit -Sn)" -ge 65535 ] && [ -f /etc/security/limits.conf ] && [ -f /etc/systemd/system.conf.d/99-optimize.conf ] ;;
    swap)         [ -n "$(swapon --show --noheadings 2>/dev/null)" ] ;;
    services)     local u st all=1; for u in $SERVICE_PRUNE; do
                    st="$(systemctl is-enabled "$u" 2>/dev/null)"
                    case "$st" in ""|disabled|masked|static|indirect|generated|not-found) :;; *) all=0;; esac
                  done; [ "$all" = 1 ] ;;
    journald)     [ -f /etc/systemd/journald.conf.d/99-optimize.conf ] && systemctl is-active --quiet systemd-journald ;;
    docker)       ok docker info && [ -f /etc/docker/daemon.json ] ;;
    dnsmasq)      [ "$HAS_DNSMASQ" = 0 ] || grep -rsq '^cache-size=' /etc/dnsmasq.conf /etc/dnsmasq.d/ 2>/dev/null ;;
    noatime)      [ "$NOATIME" = 0 ] || findmnt -no OPTIONS / | grep -q noatime ;;
    fstrim)       [ "$SSD" = 0 ] || systemctl is-enabled --quiet fstrim.timer ;;
    thp)          grep -q '\[madvise\]' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null \
                    && { [ ! -r /sys/kernel/mm/transparent_hugepage/defrag ] || grep -q '\[madvise\]' /sys/kernel/mm/transparent_hugepage/defrag; } ;;
    pkg)          { [ "${WITH_IRQBALANCE:-1}" = 0 ] || ok command -v irqbalance; } && { [ "${WITH_EARLYOOM:-1}" = 0 ] || ok command -v earlyoom; } ;;
    reboot)       return 0 ;;   # informational — acknowledged on Enter
    *)            false ;;
  esac
}

is_expected() { case "$1" in reboot) return 0;; *) return 1;; esac; }

verify_all() { # fail() any tag whose state is not converged, so the loop re-checks it
  local key val cmt
  while IFS='|' read -r key val cmt; do
    local got exp
    got="$(sysctl -n "$key" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//')"
    exp="$(echo "$val" | tr -s ' ')"
    { [ "$got" = "$exp" ] || { [ "$(echo "$val" | wc -w)" -gt 1 ] && [ -n "$got" ]; }; } || fail sysctl "$key=$got != $exp"
  done <<< "$SYSCTLS"
  recheck limits || fail limits
  recheck swap || fail swap
  recheck services || fail services
  recheck journald || fail journald
  recheck docker || fail docker
  recheck dnsmasq || fail dnsmasq
  recheck noatime || fail noatime
  recheck fstrim || fail fstrim
  recheck thp || fail thp
  recheck pkg || fail pkg
  # reboot is never automatic — it is a manual step in the debug report whenever
  # this run changed anything; pressing Enter acknowledges it (an in-process
  # reboot would kill the script, so it can't be re-checked for real).
  [ "$CHANGED" = 1 ] && fail reboot
}

resolve_errors() {
  local remaining=("${ERR_TAGS[@]}")
  while [ ${#remaining[@]} -gt 0 ]; do
    echo ""
    local exp=() unexp=()
    for tag in "${remaining[@]}"; do
      if is_expected "$tag"; then exp+=("$tag"); else unexp+=("$tag"); fi
    done
    if [ ${#exp[@]} -gt 0 ]; then
      echo " Manual steps (expected):"
      for i in "${!exp[@]}"; do
        echo "   $((i+1)). ${exp[$i]}"
        echo "      problem: $(problem "${exp[$i]}")"
        echo "      hint: $(hint "${exp[$i]}")"
      done
    fi
    if [ ${#unexp[@]} -gt 0 ]; then
      echo " Unexpected errors (${#unexp[@]}):"
      for i in "${!unexp[@]}"; do
        echo "   $((i+1)). ${unexp[$i]}"
        echo "      problem: $(problem "${unexp[$i]}")${ERR_DETAIL[${unexp[$i]}]:+ (${ERR_DETAIL[${unexp[$i]}]})}"
        echo "      hint: $(hint "${unexp[$i]}")"
      done
    fi
    read -rp "Fix / complete the items above, then press Enter to re-check (Ctrl-C aborts): " input \
      || { echo "No terminal input — aborting."; exit 1; }
    local still=()
    for tag in "${remaining[@]}"; do
      if recheck "$tag"; then
        echo "   ✓ solved: $tag — $(problem "$tag")"
      else
        still+=("$tag")
      fi
    done
    remaining=("${still[@]}")
  done
  ERR_TAGS=()
  success_block
}

summary() {
  if [ ${#ERR_TAGS[@]} -gt 0 ]; then
    echo ""
    echo " ERROR(S) — no success until every item below is resolved:"
    local i
    for i in "${!ERR_TAGS[@]}"; do
      t="${ERR_TAGS[$i]}"
      echo "   $((i+1)). $t"
      echo "      problem: $(problem "$t")"
      echo "      hint: $(hint "$t")"
    done
  fi
}
trap summary EXIT

success_block() {
  echo ""
  echo "=============================================================="
  echo " SUCCESS — the VPS is tuned:"
  echo "   kernel      $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) congestion control, $(sysctl -n vm.swappiness 2>/dev/null) swappiness, $(sysctl -n net.core.default_qdisc 2>/dev/null) qdisc"
  echo "   limits      nofile 65535 (pam + systemd), tasks unlimited"
  echo "   swap        ${SW_NOW:-$(swapon --show --noheadings 2>/dev/null | head -1)}"
  echo "   storage     $(findmnt -no OPTIONS / | tr ',' ' ' | grep -q noatime && echo noatime || echo atime) on /, $(systemctl is-enabled fstrim.timer 2>/dev/null || echo no-fstrim)"
  echo "   logs        journald capped at 512M/7d"
  echo "   docker      daemon tuned + pruned; dnsmasq cache 10000 (if installed)"
  echo ""
  echo " Every edited file is backed up under: $BACKUP_DIR"
  echo ""
  echo " Follow-ups (none block the service):"
  [ "$CHANGED" = 1 ] && echo "   1. Reboot when convenient: sudo reboot (never done automatically; applies systemd limits to new services)"
  [ -n "$ROT" ] && [ "$ROT" = 1 ] && [ "$FORCE_FSTRIM" != 1 ] && \
    echo "   2. If the disk is actually SSD-backed (VirtIO often reports rotational): FORCE_FSTRIM=1 bash scripts/optimize.sh"
  [ "$WITH_EARLYOOM" = 1 ] && echo "   earlyoom guards against OOM hangs (low-RAM host)."
  echo "=============================================================="
}

# ------------------------------------------------------------------ main
main() {
  [ "$(id -u)" = 0 ] || { echo "run as root: sudo bash scripts/optimize.sh" >&2; exit 1; }
  grep -qE '^ID=(debian|ubuntu)$' /etc/os-release || { echo "optimize.sh targets Debian-family systems only" >&2; exit 1; }
  [ "$VERIFY" = 0 ] && banner
  detect
  ask_inputs

  if [ "$VERIFY" = 0 ]; then
    apt_clean
    kernel_tune
    limits_tune
    swap_tune
    services_prune
    journald_tune
    docker_tune
    dnsmasq_tune
    noatime_tune
    fstrim_tune
    thp_tune
    pkg_tune
    aptconf_tune
  fi
  [ "$DRY" = 1 ] && { echo; echo "dry-run complete — nothing was changed. Would back up to $BACKUP_DIR"; exit 0; }

  verify_all
  if [ ${#ERR_TAGS[@]} -eq 0 ]; then
    success_block
  else
    resolve_errors
  fi
}

main "$@"
