#!/usr/bin/env bash
# scripts/ops/optimize.sh — universal Debian-family machine performance optimizer.
#
# One self-contained, idempotent script that squeezes a high-performance machine
# for the best experience possible — kernel/memory/network tuning, process
# limits, swap, journald caps, docker + dnsmasq tuning, noatime, fstrim, THP,
# apt/docker cleanup — regardless of what the machine is later used for.
#
# Everything is auto-detected from the live system: no repo paths, hostnames,
# containers or service names are assumed. Files are only touched when the
# state actually differs; every edit is backed up to /root/optimize-backup-*.
#
# The git pass is the repo-wide half: when the script sits inside a checkout it
# turns on that checkout's fast-path settings (commit-graph, untracked cache,
# index v4) and runs git's own cheap pack maintenance, so `git status`/`diff`/
# `log` stay quick on a big tree. No path is assumed — the checkout is found
# with `git rev-parse` from the script's own directory, and "not a checkout" is
# a skip, not an error.
#
# Style mirrors the installer / nc-datadir-nfs.sh: welcome banner + description, no
# interactive prompts (every choice is auto-detected or env-overridable),
# fully unattended work. At the end any failures and manual steps are
# reported with a problem + hint each; every time you press Enter the script
# re-checks them, clears the solved ones, and only prints SUCCESS when no
# issues remain.
#
# Sources merged: the repo's own host tuning (config/sysctl/99-kefo.conf,
# config/docker/daemon.json, the dnsmasq cache-size), apt autoremove/clean +
# docker prune, and generic high-performance-machine tuning (journald caps,
# inotify, noatime, fstrim, THP=madvise, IRQ balance, earlyoom).
#
# Usage (as root):
#   bash scripts/ops/optimize.sh                # fully automatic (no prompts)
#   bash scripts/ops/optimize.sh --yes          # same, non-interactive
#   bash scripts/ops/optimize.sh --dry-run      # print the plan, change nothing
#   bash scripts/ops/optimize.sh --verify       # re-check applied state only
#
# No interactive prompts. Auto choices: swap = RAM/3 rounded up (recreated only
# when the live size differs), noatime/nodiratime on, SSD/HDD auto-detected
# (nvme name, rotational flag, discard support) -> SSD gets fstrim, HDD gets
# SETRA. Env overrides: SWAP_GB= (0 = skip swap) NOATIME=0/1 FORCE_FSTRIM=0/1
# WITH_IRQBALANCE=0/1 WITH_EARLYOOM=0/1 (auto-installed performance helpers; 0 = skip)
# SETRA=<sectors> (HDD readahead via blockdev --setra; auto 512 on HDD; 0 = skip)
# WITH_TUNED=0/1 (tuned auto profile via 'tuned-adm recommend'; tuned keeps its
# unique values, our sysctl values override it on conflicting keys — tuned's
# sysctl plugin re-applies /etc/sysctl.d and defers to it by design)
# WITH_GIT=0/1 (repo git maintenance when the script sits in a checkout; 0 = skip)
# YES=1 BACKUP_DIR=...
#
# The ONLY packages it installs are the performance helpers (tuned, irqbalance,
# earlyoom). Service/application software (docker, dnsmasq, …) is never installed,
# and steps for software that is absent are skipped instead of failing.
#
# Documented options (real benefit with trade-offs, deliberately NOT default):
#   - /tmp on tmpfs: systemctl enable tmp.mount — RAM-backed temp I/O, but costs RAM
#   - zram: compressed RAM swap for <=4 GB hosts — faster than disk swap, added complexity
#   - net.ipv4.tcp_mtu_probing=1 / net.ipv4.tcp_max_tw_buckets=524288: only for
#     specific network issues (MTU paths / time-wait bucket overflow in dmesg)

set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# ------------------------------------------------------------------ flags
DRY=0; VERIFY=0; YES=0
SWAP_GB=""; NOATIME=""
BACKUP_DIR=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;; --verify) VERIFY=1 ;; --yes) YES=1 ;;
    --help|-h) awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    *) echo "unknown flag: $a (see --help)" >&2; exit 1 ;;
  esac
done

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_DIR:-/root/optimize-backup-$TS}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------------ state
ERR_TAGS=()
declare -A ERR_DETAIL=()
CHANGED=0   # any config actually written this run -> reboot shows as a manual step
NPROC=1; MEM_GB=1; MEM_KB=0; MIN_FREE_KB=0; SWAP_DEF=4; HAS_DOCKER=0; HAS_DNSMASQ=0; ROOT_DEV=""; KIND="unknown"; ACTIVE_SWAP=""; SSD=0; SETRA=""
SYSCTL_KEYS=(); SYSCTL_VALS=(); SYSCTL_CMTS=(); SYSCTL_BAD=""  # parsed once, not per check
declare -A HAVE=()          # command -> 1/0, so a tool is looked up once
declare -A SYS_NOW=()       # one `sysctl -a` snapshot shared by every check
SYS_SNAP_OK=0; BACKUP_MADE=0

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

 One-shot performance optimizer for a Debian-family machine: kernel/memory/
 network tuning (BBR, buffers, dirty ratios, swappiness), process limits,
 swapfile, journald caps, docker daemon + prune, dnsmasq cache, noatime,
 fstrim, THP=madvise, apt cleanup (update / autoremove / clean) and — when
 the script sits in a checkout — git's fast paths + pack maintenance. All
 idempotent, auto-detected, and backed up to /root/optimize-backup-*.
 Prompt: none — every choice is auto-detected or env-overridable, then it
 runs unattended; failures and manual steps are re-checked on every Enter
 until all are green, and SUCCESS prints only then.

WARNING: edits kernel parameters, swap, service limits and apt state.
Rebooting is recommended (but not required) after the first run.
EOF
}

# ------------------------------------------------------------------ helpers
ok() { "$@" >/dev/null 2>&1; }
has() { # cached `command -v` — each tool is looked up at most once per run
  local c="$1" v="${HAVE[$1]-}"
  if [ -z "$v" ]; then
    if command -v "$c" >/dev/null 2>&1; then HAVE[$c]=1; else HAVE[$c]=0; fi
    v="${HAVE[$c]}"
  fi
  [ "$v" = 1 ]
}
read_file() { local p="$1"; [ -f "$p" ] && echo "$(<"$p")" || true; }  # $(<file): no cat fork
backup() {
  local p="$1"
  [ "$DRY" = 1 ] && return 0
  [ "$BACKUP_MADE" = 1 ] || { mkdir -p "$BACKUP_DIR"; BACKUP_MADE=1; }  # one mkdir per run
  [ -f "$p" ] && cp -a "$p" "$BACKUP_DIR/$(echo "$p" | tr '/' '_')"
}
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
  for l in "$@"; do
    [[ $'\n'"$cur"$'\n' == *$'\n'"$l"$'\n'* ]] || missing+=("$l")   # bash match, no grep fork
  done
  [ ${#missing[@]} -eq 0 ] && { log "  ok: $p (unchanged)"; return 1; }
  backup "$p"
  [ "$DRY" = 1 ] && { log "  would append ${#missing[@]} line(s) to $p"; return 0; }
  printf '%s\n' "${missing[@]}" >> "$p"
  CHANGED=1; log "  appended ${#missing[@]} line(s) to $p"; return 0
}

# enabled systemd units as one newline-wrapped string: one systemctl call for
# every unit the script cares about, instead of one call per unit
enabled_units() {
  local u list=""
  list="$(systemctl list-unit-files --state=enabled,enabled-runtime --no-legend --no-pager 2>/dev/null | awk '{print $1}')"
  printf '\n%s\n' "$list"
}

# one `sysctl -a` snapshot instead of one `sysctl -n` per key per check: the
# sysctl verify path runs on every Enter of the re-check loop, so this is the
# difference between 1 fork and ~30 forks each round
sysctl_snap() {
  [ "${1:-}" = force ] && SYS_SNAP_OK=0
  [ "$SYS_SNAP_OK" = 1 ] && return 0
  SYS_NOW=()
  local line k v
  while IFS= read -r line; do
    case "$line" in *' = '*) ;; *) continue ;; esac
    k="${line%% = *}"; v="${line#* = }"
    while [[ "$v" == *'  '* ]]; do v="${v//  / }"; done   # squeeze runs of spaces
    SYS_NOW["$k"]="$v"
  done < <(sysctl -a 2>/dev/null)
  SYS_SNAP_OK=1
}

get_sysctl() { sysctl_snap; printf '%s' "${SYS_NOW[$1]-}"; }

sysctl_check() { # sets SYSCTL_BAD to the first mismatch; 1 when any key is off
  sysctl_snap
  local i got exp; local -a words
  SYSCTL_BAD=""
  for i in "${!SYSCTL_KEYS[@]}"; do
    got="${SYS_NOW[${SYSCTL_KEYS[$i]}]-}"; exp="${SYSCTL_VALS[$i]}"
    [ "$got" = "$exp" ] && continue
    read -ra words <<< "$exp"                 # multi-value keys (buffer ranges) only need a value
    [ ${#words[@]} -gt 1 ] && [ -n "$got" ] && continue
    SYSCTL_BAD="${SYSCTL_KEYS[$i]}=$got (expected $exp)"
    return 1
  done
  return 0
}

# ------------------------------------------------------------------ detection
disk_kind() { # root-disk SSD/HDD: nvme name => ssd; rotational=0 => ssd;
  # discard-capable => ssd; otherwise hdd (VirtIO without discard reports hdd)
  local dev="$1" rot disc
  case "$dev" in nvme*) echo ssd; return;; esac
  rot="$(cat "/sys/block/$dev/queue/rotational" 2>/dev/null)"
  [ "$rot" = 0 ] && { echo ssd; return; }
  disc="$(cat "/sys/block/$dev/queue/discard_max_bytes" 2>/dev/null)"
  { [ -n "$disc" ] && [ "$disc" -gt 0 ]; } 2>/dev/null && { echo ssd; return; }
  echo hdd
}

detect() {
  NPROC="$(nproc)"
  local k v _rest
  while read -r k v _rest; do            # one read of /proc/meminfo, no awk forks
    case "$k" in MemTotal:) MEM_KB="$v"; break ;; esac
  done < /proc/meminfo
  [ -n "${MEM_KB:-}" ] || MEM_KB=1048576
  MEM_GB=$(( MEM_KB / 1048576 )); [ "$MEM_GB" -ge 1 ] || MEM_GB=1
  MIN_FREE_KB=$(( MEM_KB / 100 ))   # 1% of total RAM
  SWAP_DEF=$(( (MEM_KB / 3 + 1048575) / 1048576 ))   # RAM/3 rounded up to whole GB
  has docker && HAS_DOCKER=1 || HAS_DOCKER=0
  has dnsmasq && HAS_DNSMASQ=1 || HAS_DNSMASQ=0
  ACTIVE_SWAP="$(swapon --show --noheadings 2>/dev/null)"
  local SRC="$(findmnt -no SOURCE /)"
  ROOT_DEV="$(lsblk -no PKNAME "$SRC" 2>/dev/null | head -1)"
  [ -n "$ROOT_DEV" ] || ROOT_DEV="$(echo "$SRC" | sed 's|/dev/||; s/p[0-9]*$//; s/[0-9]*$//')"
  KIND="$(disk_kind "$ROOT_DEV")"
  sysctl_plan
  log "detected: ${NPROC} cpu, ~${MEM_GB} GB RAM, docker=${HAS_DOCKER}, dnsmasq=${HAS_DNSMASQ}, swap=${ACTIVE_SWAP:+active}, disk=${ROOT_DEV} (${KIND})"
}

# ------------------------------------------------------------------ plan (no prompts)
ask_inputs() { # no prompts — every choice is auto-detected or env-overridable
  SWAP_GB="${SWAP_GB:-$SWAP_DEF}"
  case "$SWAP_GB" in ''|*[!0-9]*) echo "invalid SWAP_GB: $SWAP_GB" >&2; exit 1;; esac
  NOATIME="${NOATIME:-1}"
  [ -n "${FORCE_FSTRIM:-}" ] || FORCE_FSTRIM=0
  SSD=0; [ "$KIND" = ssd ] && SSD=1; [ "$FORCE_FSTRIM" = 1 ] && SSD=1
  [ -n "${SETRA:-}" ] || { [ "$KIND" = hdd ] && SETRA=512 || SETRA=0; }
  # irqbalance + earlyoom + tuned: performance helpers, auto-installed when missing (opt out with =0)
  [ -n "${WITH_IRQBALANCE:-}" ] || WITH_IRQBALANCE=1
  [ -n "${WITH_EARLYOOM:-}" ] || WITH_EARLYOOM=1
  [ -n "${WITH_TUNED:-}" ] || WITH_TUNED=1
  # git: repo-wide fast paths, only when the script sits in a checkout (opt out with =0)
  [ -n "${WITH_GIT:-}" ] || WITH_GIT=1
  local YES_NOTE=""; [ "$YES" = 1 ] && YES_NOTE=" (--yes)"
  log "plan: swap=${SWAP_GB}G (RAM/3 rounded up) noatime=${NOATIME} disk=${ROOT_DEV} (${KIND}) setra=${SETRA} fstrim=${FORCE_FSTRIM} irqbalance=${WITH_IRQBALANCE} earlyoom=${WITH_EARLYOOM} tuned=${WITH_TUNED} git=${WITH_GIT}${YES_NOTE}"
}

# ------------------------------------------------------------------ 1. apt cleanup (apt autoremove + clean)
apt_clean() {
  log "apt: update / autoremove / clean"
  [ "$DRY" = 1 ] && { log "  would apt-get update + autoremove -y + clean"; return 0; }
  DEBIAN_FRONTEND=noninteractive apt-get update -qq || { fail apt "apt-get update failed"; return; }
  DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq || fail apt "autoremove failed"
  apt-get clean || fail apt "apt-get clean failed"
  log "  ok: apt updated, autoremoved, cleaned"
}

# ------------------------------------------------------------------ 1b. tuned (auto profile via recommend)
# Cooperation model: tuned applies its profile first; our /etc/sysctl.d values
# then override it on conflicting keys. This is tuned's own behavior — its
# sysctl plugin "reapplies system sysctl" (re-reads /etc/sysctl.d) and defers
# to it, so our universal values win the conflicts while tuned keeps its
# unique ones (cpu governor, energy-perf bias, THP, ...). tuned-adm verify may
# report diffs on those keys — expected by design.
tuned_tune() {
  [ "${WITH_TUNED:-1}" = 1 ] || { log "tuned: skipped (WITH_TUNED=0)"; return 0; }
  log "tuned: auto profile (tuned-adm recommend)"
  if ! has tuned-adm; then
    if [ "$DRY" = 1 ] || [ "$VERIFY" = 1 ]; then log "  would install tuned + apply its recommended profile"; return 0; fi
    fail tuned "tuned still missing after the helpers install"; return
  fi
  local prof
  prof="$(tuned-adm recommend 2>/dev/null | head -1)"
  [ -n "$prof" ] || { fail tuned "no profile recommended"; return; }
  if [ "$DRY" = 0 ] && [ "$VERIFY" = 0 ]; then
    systemctl enable --now tuned >/dev/null 2>&1
    tuned-adm profile "$prof" >/dev/null 2>&1 || { fail tuned "profile '$prof' apply failed"; return; }
  fi
  log "  ok: tuned profile '$prof' active (our sysctl values win conflicts; tuned keeps unique ones)"
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
kernel.core_pattern|/dev/null|discard core dumps (no giant core files on crash)
kernel.pid_max|4194304|PID headroom for many containers/threads
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

sysctl_plan() { # parse the table once into parallel arrays (no here-string per check);
  # vm.min_free_kbytes is RAM-derived, so it is appended at runtime
  SYSCTL_KEYS=(); SYSCTL_VALS=(); SYSCTL_CMTS=()
  local key val cmt
  while IFS='|' read -r key val cmt; do
    [ -n "$key" ] || continue
    SYSCTL_KEYS+=("$key"); SYSCTL_VALS+=("$val"); SYSCTL_CMTS+=("$cmt")
  done <<< "$SYSCTLS"
  SYSCTL_KEYS+=("vm.min_free_kbytes"); SYSCTL_VALS+=("$MIN_FREE_KB")
  SYSCTL_CMTS+=("1% of RAM (emergency allocation headroom, computed)")
}

kernel_tune() {
  log "kernel: sysctl tuning"
  local CTL="# Generated by optimize.sh — universal machine tuning (re-run to refresh)."
  local i
  for i in "${!SYSCTL_KEYS[@]}"; do
    CTL="${CTL}
# ${SYSCTL_CMTS[$i]}
${SYSCTL_KEYS[$i]} = ${SYSCTL_VALS[$i]}"
  done
  write_file /etc/sysctl.d/99-optimize.conf "${CTL}
" || true
  if [ "$DRY" = 0 ] && [ "$VERIFY" = 0 ]; then
    # apply only our own file first (this file is last in the sort order, so it
    # wins anyway); `sysctl --system` re-reads every file and is the fallback
    sysctl -p /etc/sysctl.d/99-optimize.conf >/dev/null 2>&1 \
      || sysctl --system >/dev/null 2>&1 \
      || { fail sysctl "sysctl apply failed"; return; }
  fi
  sysctl_snap force   # the snapshot the checks read is now stale
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
  log "swap: auto size = RAM/3 rounded up (${SWAP_DEF}G)"
  local SIZE="${SWAP_GB:-$SWAP_DEF}"
  if [ "$SIZE" -le 0 ]; then log "  skipped: size 0"; return 0; fi
  local target=$(( SIZE * 1073741824 )) cur=""
  [ -f /swapfile ] && cur="$(stat -c %s /swapfile)"
  if [ -n "$cur" ] && [ "$cur" = "$target" ] && [ -n "$ACTIVE_SWAP" ]; then
    log "  ok: /swapfile already ${SIZE}G (matches auto size) — skipping recreate"
    return 0
  fi
  if [ "$DRY" = 1 ] || [ "$VERIFY" = 1 ]; then
    log "  would recreate /swapfile ${SIZE}G (current: ${cur:-none})"
    return 0
  fi
  swapoff -a 2>/dev/null; rm -f /swapfile
  if fallocate -l "${SIZE}G" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$(( SIZE * 1024 )) status=none; then
    chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile || { fail swap "mkswap/swapon failed"; return; }
    append_lines /etc/fstab '/swapfile none swap defaults 0 0'
    log "  ok: /swapfile ${SIZE}G active (recreated — size differed)"
  else
    fail swap "could not allocate /swapfile"
  fi
}

# ------------------------------------------------------------------ 5. unneeded services
SERVICE_PRUNE="cups.service cups-browsed.service ModemManager.service avahi-daemon.service bluetooth.service wpa_supplicant.service speech-dispatcher.service pppd-dns.service openipmi.service systemd-networkd-wait-online.service"
services_prune() {
  log "services: disabling unneeded units (only if present + enabled)"
  local u on
  on="$(enabled_units)"   # one systemctl call, not one per unit
  for u in $SERVICE_PRUNE; do
    [[ $on == *$'\n'"$u"$'\n'* ]] || continue   # absent or already disabled
    if [ "$DRY" = 0 ] && [ "$VERIFY" = 0 ]; then
      systemctl disable --now "$u" 2>/dev/null || { fail services "could not disable $u"; continue; }
    fi
    log "  disabled: $u"
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

# ------------------------------------------------------------------ 7. docker (daemon tuning + prune)
docker_tune() {
  [ "$HAS_DOCKER" = 0 ] && { log "docker: not installed — skipped"; return 0; }
  log "docker: daemon tuning + prune"
  local P=/etc/docker/daemon.json
  local TUNE='{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"},"live-restore":true,"max-concurrent-downloads":10,"max-concurrent-uploads":10,"userland-proxy":false}'
  local NEW
  if [ -f "$P" ] && has jq; then
    NEW="$(jq -s --argjson t "$TUNE" '.[0] * $t' "$P")"
  elif [ -f "$P" ] && has python3; then
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
  local ROOTLINE
  ROOTLINE="$(awk '$2=="/" && $3 ~ /^(ext4|xfs|btrfs)$/ {print; exit}' /etc/fstab)"
  if [ -z "$ROOTLINE" ] || printf '%s' "$ROOTLINE" | grep -q noatime; then
    log "  ok: noatime already set (or root fs not ext4/xfs/btrfs)"
    return 0
  fi
  if [ "$DRY" = 1 ] || [ "$VERIFY" = 1 ]; then log "  would add noatime,nodiratime to /"; return 0; fi
  backup /etc/fstab
  # rewrite field 4 on the first "/" line only (awk — never a sed pattern built from file content)
  awk 'done!=1 && $2=="/" && $3 ~ /^(ext4|xfs|btrfs)$/ && $4 !~ /noatime/ { $4=$4",noatime,nodiratime"; done=1 } {print}' \
    /etc/fstab > /etc/fstab.optimize.new && mv /etc/fstab.optimize.new /etc/fstab
  if mount -o remount / 2>/dev/null && findmnt -no OPTIONS / | grep -q noatime; then
    log "  ok: noatime,nodiratime on /"
  else
    cp -a "$BACKUP_DIR/$(echo /etc/fstab | tr '/' '_')" /etc/fstab 2>/dev/null; mount -o remount / 2>/dev/null
    fail noatime "remount failed — reverted"
  fi
}

# ------------------------------------------------------------------ 10. fstrim
fstrim_tune() {
  if [ "$SSD" = 0 ]; then
    log "fstrim: skipped (disk ${ROOT_DEV} = ${KIND}; fstrim is for SSD — FORCE_FSTRIM=1 to override)"
    return 0
  fi
  log "fstrim: enabling weekly trim (${ROOT_DEV} is SSD)"
  if [ "$DRY" = 0 ] && [ "$VERIFY" = 0 ]; then
    systemctl enable --now fstrim.timer 2>/dev/null || fail fstrim "timer enable failed"
    fstrim --fstab -v 2>/dev/null || true
  fi
  log "  ok: fstrim.timer enabled"
}

# ------------------------------------------------------------------ 10b. HDD readahead (opt-in: SETRA=<sectors>, only for rotational disks)
setra_tune() {
  [ "${SETRA:-0}" != 0 ] || { log "setra: skipped (disk ${ROOT_DEV} = ${KIND}; SETRA is for HDD — SETRA=<n> to force)"; return 0; }
  case "$SETRA" in ''|*[!0-9]*) fail setra "invalid SETRA value"; return;; esac
  [ "$KIND" = hdd ] || log "  note: ${ROOT_DEV} detected as ${KIND} — SETRA applied because SETRA=$SETRA is set"
  local KB=$(( SETRA * 512 / 1024 ))
  if [ "$DRY" = 0 ] && [ "$VERIFY" = 0 ]; then
    blockdev --setra "$SETRA" "/dev/$ROOT_DEV" 2>/dev/null || { fail setra "blockdev --setra failed"; return; }
  fi
  write_file /etc/udev/rules.d/99-readahead.rules "ACTION==\"add\", SUBSYSTEM==\"block\", KERNEL==\"$ROOT_DEV\", ATTR{queue/read_ahead_kb}=\"$KB\"
" >/dev/null
  log "  ok: readahead ${SETRA} sectors (${KB} kB) on /dev/$ROOT_DEV (runtime + udev persistence)"
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

# ------------------------------------------------------------------ 12. performance helpers: tuned + irqbalance + earlyoom
helpers_install() {
  # ONE apt transaction for every missing helper: three separate `apt-get install`
  # runs re-resolve dependencies, re-take the dpkg lock and rewrite the lists each
  # time. Opt-outs are honoured, so a box that has them all is a no-op.
  local want=() p
  [ "${WITH_TUNED:-1}" = 1 ] && ! has tuned-adm && want+=(tuned)
  [ "${WITH_IRQBALANCE:-1}" = 1 ] && ! has irqbalance && want+=(irqbalance)
  [ "${WITH_EARLYOOM:-1}" = 1 ] && ! has earlyoom && want+=(earlyoom)
  if [ ${#want[@]} -eq 0 ]; then
    log "helpers: tuned/irqbalance/earlyoom present or opted out"
    return 0
  fi
  log "helpers: installing ${want[*]} (one apt transaction)"
  if [ "$DRY" = 1 ] || [ "$VERIFY" = 1 ]; then log "  would apt-get install -y ${want[*]}"; return 0; fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${want[@]}" >/dev/null 2>&1 \
    || { fail pkg "apt-get install ${want[*]} failed"; return; }
  for p in "${want[@]}"; do
    systemctl enable --now "$p" >/dev/null 2>&1 || { fail pkg "could not enable $p"; continue; }
    HAVE["$p"]=1; log "  ok: $p installed+enabled"
  done
}

# ------------------------------------------------------------------ 13. apt speed
aptconf_tune() {
  log "apt: non-interactive, no language pulls"
  write_file /etc/apt/apt.conf.d/99-optimize 'Acquire::Languages "none";
Dpkg::Use-Pty "false";
'
}

# ------------------------------------------------------------------ 14. git repo maintenance (auto-detected checkout)
# The repo-wide half of the pass: per-checkout local settings that make git use
# its fast paths, plus git's own cheap pack maintenance. Everything is derived
# from the script's own location (never a hardcoded path) and every setting is
# read back before it is written, so a re-run is a no-op.
GIT_CFG=(
  "core.preloadIndex|true"
  "core.untrackedCache|true"
  "core.commitGraph|true"
  "gc.writeCommitGraph|true"
  "index.version|4"
)
git_tune() {
  [ "${WITH_GIT:-1}" = 1 ] || { log "git: skipped (WITH_GIT=0)"; return 0; }
  local root line key val backed=0
  root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$root" ] || { log "git: $SCRIPT_DIR is not a checkout — skipped"; return 0; }
  log "git: repo maintenance in $root"
  for line in "${GIT_CFG[@]}"; do
    key="${line%%|*}"; val="${line#*|}"
    [ "$(git -C "$root" config --local --get "$key" 2>/dev/null)" = "$val" ] && continue
    if [ "$DRY" = 1 ] || [ "$VERIFY" = 1 ]; then log "  would set $key=$val"; continue; fi
    [ "$backed" = 1 ] || { backup "$root/.git/config"; backed=1; }   # once, before the first edit
    git -C "$root" config --local "$key" "$val" || { fail git "could not set $key=$val"; return; }
    CHANGED=1; log "  set $key=$val"
  done
  if [ "$DRY" = 0 ] && [ "$VERIFY" = 0 ]; then
    git -C "$root" pack-refs --all --prune >/dev/null 2>&1 || true
    git -C "$root" commit-graph write --reachable >/dev/null 2>&1 || true
    git -C "$root" gc --auto --quiet >/dev/null 2>&1 || true   # no-op unless thresholds are hit
    log "  ok: refs packed, commit-graph written, gc --auto"
  fi
}

# ------------------------------------------------------------------ error framework (the installer style)
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
    setra)        echo "HDD readahead not set" ;;
    thp)          echo "transparent huge pages still not madvise" ;;
    pkg)          echo "optional package install failed" ;;
    tuned)        echo "tuned auto profile not active" ;;
    git)          echo "git repo maintenance settings not applied" ;;
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
    setra)        echo "run: blockdev --setra <sectors> /dev/<disk>; udev rule at /etc/udev/rules.d/99-readahead.rules, then re-check" ;;
    thp)          echo "run: echo madvise > /sys/kernel/mm/transparent_hugepage/enabled, then re-check" ;;
    pkg)          echo "run: apt-get install -y <package>, then re-check" ;;
    tuned)        echo "run: apt-get install -y tuned && systemctl enable --now tuned && tuned-adm profile \"\$(tuned-adm recommend)\", then re-check" ;;
    git)          echo "run: git -C <checkout> config --local core.commitGraph true (and core.untrackedCache/index.version), then re-check" ;;
    reboot)       echo "run: sudo reboot (optional but recommended; press Enter to acknowledge for now)" ;;
    *)            echo "" ;;
  esac
}

recheck() {
  case "$1" in
    apt)          DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 ;;
    sysctl)       sysctl_snap force; sysctl_check ;;   # one snapshot per re-check round
    # this shell's live ulimit only changes on a new login, so verify the config a
    # new login/service will read (checking the live value gives a false failure)
    limits)       grep -qE 'soft[[:space:]]+nofile[[:space:]]+65535' /etc/security/limits.conf \
                    && grep -qE 'hard[[:space:]]+nofile[[:space:]]+65535' /etc/security/limits.conf \
                    && grep -q '^DefaultLimitNOFILE=65535' /etc/systemd/system.conf.d/99-optimize.conf ;;
    swap)         [ -n "$(swapon --show --noheadings 2>/dev/null)" ] ;;
    services)     local on u; on="$(enabled_units)"
                  for u in $SERVICE_PRUNE; do [[ $on == *$'\n'"$u"$'\n'* ]] && return 1; done; return 0 ;;
    journald)     [ -f /etc/systemd/journald.conf.d/99-optimize.conf ] && systemctl is-active --quiet systemd-journald ;;
    docker)       [ "$HAS_DOCKER" = 0 ] || { ok docker info && [ -f /etc/docker/daemon.json ]; } ;;
    dnsmasq)      [ "$HAS_DNSMASQ" = 0 ] || grep -rsq '^cache-size=' /etc/dnsmasq.conf /etc/dnsmasq.d/ 2>/dev/null ;;
    noatime)      [ "$NOATIME" = 0 ] || findmnt -no OPTIONS / | grep -q noatime ;;
    fstrim)       [ "$SSD" = 0 ] || systemctl is-enabled --quiet fstrim.timer ;;
    setra)        [ "${SETRA:-0}" = 0 ] && return 0
                  [ -n "$ROOT_DEV" ] && [ "$(cat "/sys/block/$ROOT_DEV/queue/read_ahead_kb" 2>/dev/null)" = "$(( SETRA * 512 / 1024 ))" ] ;;
    thp)          grep -q '\[madvise\]' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null \
                    && { [ ! -r /sys/kernel/mm/transparent_hugepage/defrag ] || grep -q '\[madvise\]' /sys/kernel/mm/transparent_hugepage/defrag; } ;;
    pkg)          { [ "${WITH_TUNED:-1}" = 0 ] || has tuned-adm; } \
                    && { [ "${WITH_IRQBALANCE:-1}" = 0 ] || has irqbalance; } \
                    && { [ "${WITH_EARLYOOM:-1}" = 0 ] || has earlyoom; } ;;
    tuned)        [ "${WITH_TUNED:-1}" = 0 ] || { has tuned-adm && systemctl is-active --quiet tuned && [ -n "$(tuned-adm active 2>/dev/null | sed -n 's/^Current active profile: //p' | head -1)" ]; } ;;
    git)          local root line key val
                  [ "${WITH_GIT:-1}" = 1 ] || return 0
                  root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || return 0
                  [ -n "$root" ] || return 0
                  for line in "${GIT_CFG[@]}"; do
                    key="${line%%|*}"; val="${line#*|}"
                    [ "$(git -C "$root" config --local --get "$key" 2>/dev/null)" = "$val" ] || return 1
                  done; return 0 ;;
    reboot)       return 0 ;;   # informational — acknowledged on Enter
    *)            false ;;
  esac
}

is_expected() { case "$1" in reboot) return 0;; *) return 1;; esac; }

verify_all() { # fail() any tag whose state is not converged, so the loop re-checks it
  sysctl_snap force
  sysctl_check || fail sysctl "$SYSCTL_BAD"
  recheck limits || fail limits
  recheck swap || fail swap
  recheck services || fail services
  recheck journald || fail journald
  recheck docker || fail docker
  recheck dnsmasq || fail dnsmasq
  recheck noatime || fail noatime
  recheck fstrim || fail fstrim
  recheck setra || fail setra
  recheck thp || fail thp
  recheck pkg || fail pkg
  recheck tuned || fail tuned
  recheck git || fail git
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
  echo " SUCCESS — the machine is tuned:"
  sysctl_snap
  echo "   kernel      $(get_sysctl net.ipv4.tcp_congestion_control) congestion control, $(get_sysctl vm.swappiness) swappiness, $(get_sysctl net.core.default_qdisc) qdisc"
  echo "   limits      nofile 65535 (pam + systemd), tasks unlimited"
  echo "   swap        ${SW_NOW:-$(swapon --show --noheadings 2>/dev/null | head -1)}"
  echo "   storage     $(findmnt -no OPTIONS / | tr ',' ' ' | grep -q noatime && echo noatime || echo atime) on /, $(systemctl is-enabled fstrim.timer 2>/dev/null || echo no-fstrim)"
  echo "   logs        journald capped at 512M/7d"
  echo "   docker      daemon tuned + pruned; dnsmasq cache 10000 (if installed)"
  echo "   repo        git commit-graph + untracked cache on, refs packed (when this is a checkout)"
  echo ""
  echo " Every edited file is backed up under: $BACKUP_DIR"
  echo ""
  echo " Follow-ups (none block the service):"
  [ "$CHANGED" = 1 ] && echo "   1. Reboot when convenient: sudo reboot (never done automatically; applies systemd limits to new services)"
  [ "$KIND" = hdd ] && [ "$FORCE_FSTRIM" != 1 ] && \
    echo "   2. If $ROOT_DEV is actually SSD-backed (VirtIO without discard reports hdd): FORCE_FSTRIM=1 bash scripts/ops/optimize.sh"
  [ "$WITH_EARLYOOM" = 1 ] && echo "   earlyoom guards against OOM hangs (low-RAM host)."
  echo "=============================================================="
}

# ------------------------------------------------------------------ main
main() {
  [ "$(id -u)" = 0 ] || { echo "run as root: sudo bash scripts/ops/optimize.sh" >&2; exit 1; }
  grep -qE '^ID=(debian|ubuntu)$' /etc/os-release || { echo "optimize.sh targets Debian-family systems only" >&2; exit 1; }
  [ "$VERIFY" = 0 ] && banner
  detect   # also parses the sysctl table (vm.min_free_kbytes is RAM-derived)
  ask_inputs

  if [ "$VERIFY" = 0 ]; then
    apt_clean
    helpers_install
    tuned_tune
    kernel_tune
    limits_tune
    swap_tune
    services_prune
    journald_tune
    docker_tune
    dnsmasq_tune
    noatime_tune
    fstrim_tune
    setra_tune
    thp_tune
    aptconf_tune
    git_tune
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
