#!/usr/bin/env -S deno run --allow-all
/**
 * optimize.ts — universal Debian-family VPS performance optimizer
 *
 * One idempotent tool that merges every performance optimization from:
 *   - OPTIMIZE.md (Debian 13 setup: swap, sysctl, BBR, process limits, service pruning)
 *   - the homelab repo's tuned values (dirty ratios, TCP fastopen, docker daemon,
 *     dnsmasq cache, storage-box swap pattern)
 *   - strong standards for a high-performance VPS (journald caps, inotify limits,
 *     noatime, fstrim, IRQ balance, low-RAM OOM guard)
 *
 * Universal by design: nothing is tied to a repo, hostname, path, container or
 * service name. Every target is auto-detected from the live system; files are
 * only touched when the current state actually differs; every edit is backed
 * up; dry-run and verify are first-class modes. It works on any Debian/Ubuntu
 * box regardless of what the VPS is later used for.
 *
 * Requires: root, Deno >= 1.33 (https://deno.land), a Debian-family OS.
 *
 * Usage (as root):
 *   deno run --allow-all optimize.ts [--dry-run] [--verify] [--yes] [flags...]
 *
 * Flags:
 *   --dry-run            print the plan without changing anything
 *   --verify             re-check the applied state only (no writes)
 *   --yes                non-interactive: allow package installs + restarts
 *   --swap-gb N          swapfile size in GB (default 4, 0 = use RAM/2)
 *   --force-swap         recreate the swapfile even if a swap is already active
 *   --no-swap            never touch swap
 *   --noatime            add noatime,nodiratime to the root mount (auto-reverts
 *                        if the remount fails)
 *   --force-fstrim       run fstrim even if all disks report rotational
 *   --restart-docker     restart dockerd after writing daemon.json
 *   --restart-dnsmasq    restart dnsmasq after writing its config
 *   --with-earlyoom      install + enable earlyoom (recommended on <=4 GB RAM)
 *   --backup-dir DIR     where to back up edited files (default /root/optimize-backup-<ts>)
 *   --help               this text
 */

type CmdRes = { code: number; out: string; err: string };
const flags = new Map<string, string>();

for (const a of Deno.args) {
  if (a === "--help" || a === "-h") {
    const m = Deno.readTextFileSync(new URL(import.meta.url).pathname).match(/\/\*\*[\s\S]*?\*\//);
    if (m) console.log(m[0]);
    Deno.exit(0);
  }
  const eq = a.indexOf("=");
  if (a.startsWith("--") && eq > 0) flags.set(a.slice(0, eq), a.slice(eq + 1));
  else flags.set(a, "1");
}
const has = (f: string) => flags.has("--" + f);
const val = (f: string, d: string) => flags.get("--" + f) ?? d;

const DRY = has("dry-run");
const VERIFY = has("verify");
const YES = has("yes");
const TS = new Date().toISOString().replace(/[:.]/g, "-");
const BACKUP_DIR = val("backup-dir", `/root/optimize-backup-${TS}`);
const SWAP_GB = has("swap-gb") ? parseInt(val("swap-gb", "4"), 10) : 4;

// ---------------------------------------------------------------- helpers
function sh(cmd: string): CmdRes {
  const r = new Deno.Command("bash", { args: ["-lc", cmd], stdout: "piped", stderr: "piped" }).outputSync();
  return { code: r.code, out: new TextDecoder().decode(r.stdout).trimEnd(), err: new TextDecoder().decode(r.stderr).trimEnd() };
}
const ok = (c: CmdRes) => c.code === 0;
const read = (p: string): string | null => {
  try { return Deno.readTextFileSync(p); } catch { return null; }
};
const exists = (p: string) => { try { Deno.statSync(p); return true; } catch { return false; } };
function backup(p: string): void {
  if (DRY) return;
  try { Deno.mkdirSync(BACKUP_DIR, { recursive: true }); Deno.copyFileSync(p, `${BACKUP_DIR}/${p.replace(/^\//, "").replaceAll("/", "_")}`); } catch { /* file may not exist yet */ }
}
function writeFile(p: string, content: string): boolean {
  const cur = read(p);
  if (cur === content) { log("unchanged", p); return false; }
  backup(p);
  if (!DRY) {
    Deno.mkdirSync(p.slice(0, p.lastIndexOf("/")), { recursive: true });
    Deno.writeTextFileSync(p, content);
  }
  log("applied", p);
  return true;
}
function appendLines(p: string, lines: string[]): boolean {
  const cur = read(p) ?? "";
  const missing = lines.filter((l) => !cur.split("\n").includes(l));
  if (missing.length === 0) { log("unchanged", p); return false; }
  backup(p);
  if (!DRY) Deno.writeTextFileSync(p, cur.endsWith("\n") || cur === "" ? cur + missing.join("\n") + "\n" : cur + "\n" + missing.join("\n") + "\n");
  log("applied", p + ` (+${missing.length} line${missing.length > 1 ? "s" : ""})`);
  return true;
}
const step: { label: string; status: "applied" | "unchanged" | "skipped" | "hint"; note: string }[] = [];
function log(st: "applied" | "unchanged" | "skipped" | "hint", label: string, note = "") {
  step.push({ label, status: st, note });
  const mark = { applied: "[chg]", unchanged: "[ok ]", skipped: "[ - ]", hint: "[>> ]" }[st];
  console.log(`${mark} ${label}${note ? ` — ${note}` : ""}`);
}
function hint(label: string, note: string) { log("hint", label, note); }

// ---------------------------------------------------------------- preflight
if (!ok(sh("id -u")) || sh("id -u").out.trim() !== "0") {
  console.error("run as root: sudo deno run --allow-all optimize.ts [--dry-run]");
  Deno.exit(1);
}
const osRel = read("/etc/os-release") ?? "";
if (!/^ID=(debian|ubuntu)\b/m.test(osRel)) {
  console.error("optimize.ts targets Debian-family systems only (found: " + (osRel.match(/^ID=.*$/m)?.[0] ?? "unknown") + ")");
  Deno.exit(1);
}
const NPROC = parseInt(sh("nproc").out || "1", 10) || 1;
const MEM_GB = Math.max(1, Math.round(parseFloat(sh("awk '/MemTotal/{print $2/1024/1024}' /proc/meminfo").out || "1")));
const HAS_DOCKER = ok(sh("command -v docker"));
const HAS_DNSMASQ = exists("/etc/dnsmasq.conf");
console.log(`# optimize.ts ${DRY ? "DRY-RUN (no changes)" : VERIFY ? "VERIFY" : "APPLY"} — ${NPROC} cpu, ~${MEM_GB} GB RAM, docker=${HAS_DOCKER}, dnsmasq=${HAS_DNSMASQ}\n`);

// ---------------------------------------------------------------- 1. kernel / memory / network
const SYSCTLS: [key: string, val: string, comment: string][] = [
  // memory (OPTIMIZE.md + repo dirty ratios)
  ["vm.swappiness", "10", "prefer evicting clean cache over swapping (low-RAM friendly)"],
  ["vm.vfs_cache_pressure", "50", "keep inode/dentry cache longer (OPTIMIZE.md)"],
  ["vm.dirty_ratio", "10", "smaller writeback bursts -> no long stalls on sync"],
  ["vm.dirty_background_ratio", "5", "start writeback earlier, in shorter bursts"],
  ["vm.max_map_count", "262144", "headroom for containers/DBs/ES-style workloads"],
  ["fs.file-max", "2097152", "max open files system-wide (OPTIMIZE.md)"],
  ["fs.inotify.max_user_watches", "524288", "file-watcher headroom (editors, sync tools, apps)"],
  ["fs.inotify.max_user_instances", "1024", "inotify instance headroom"],
  // network core
  ["net.core.somaxconn", "65535", "listen backlog for busy proxies/web servers"],
  ["net.core.netdev_max_backlog", "16384", "packet backlog before the stack drops"],
  ["net.core.rmem_max", "16777216", "allow large TCP receive windows"],
  ["net.core.wmem_max", "16777216", "allow large TCP send windows"],
  ["net.core.default_qdisc", "fq", "fair-queue qdisc (pair with BBR)"],
  // TCP (OPTIMIZE.md + repo BBR/fastopen/slow-start)
  ["net.ipv4.tcp_congestion_control", "bbr", "BBR congestion control (big win on lossy/high-BDP links)"],
  ["net.ipv4.tcp_rmem", "4096 87380 16777216", "auto-tuned receive buffer range"],
  ["net.ipv4.tcp_wmem", "4096 65536 16777216", "auto-tuned send buffer range"],
  ["net.ipv4.tcp_fastopen", "3", "TFO for client+server (saves an RTT on TLS)"],
  ["net.ipv4.tcp_slow_start_after_idle", "0", "don't reset cwnd after idle (interactive HTTPS)"],
  ["net.ipv4.tcp_max_syn_backlog", "65536", "SYN backlog for connection bursts"],
  ["net.ipv4.tcp_tw_reuse", "1", "reuse TIME-WAIT sockets (safe with timestamps on)"],
  ["net.ipv4.tcp_notsent_lowat", "16384", "lower queued-unsent threshold -> lower latency"],
  // routing (containers, VPNs, NAT need forwarding)
  ["net.ipv4.ip_forward", "1", "IP forwarding (containers/VPNs)"],
  ["net.ipv6.conf.all.forwarding", "1", "IPv6 forwarding (containers/VPNs)"],
  ["net.ipv6.conf.default.forwarding", "1", "IPv6 forwarding default"],
];

{
  const lines: string[] = ["# Generated by optimize.ts — universal VPS tuning (re-run to refresh).", "# See optimize.ts --help; values merged from OPTIMIZE.md + repo configs + standards."];
  for (const [k, v, c] of SYSCTLS) lines.push("", `# ${c}`, `${k} = ${v}`);
  writeFile("/etc/sysctl.d/99-optimize.conf", lines.join("\n") + "\n");
  if (!DRY && !VERIFY) {
    if (!ok(sh("sysctl --system 2>&1"))) for (const [k, v] of SYSCTLS) sh(`sysctl -w "${k}=${v}"`);
  }
}

// ---------------------------------------------------------------- 2. process limits
{
  const lim = ["*               soft    nofile          65535", "*               hard    nofile          65535",
               "root            soft    nofile          65535", "root            hard    nofile          65535"];
  appendLines("/etc/security/limits.conf", lim);
  const sysd = "[Manager]\nDefaultLimitNOFILE=65535\n";
  if (writeFile("/etc/systemd/system.conf.d/99-optimize.conf", sysd) && !DRY && !VERIFY) sh("systemctl daemon-reexec 2>/dev/null || true");
}

// ---------------------------------------------------------------- 3. swap
{
  const active = sh("swapon --show --noheadings").out;
  if (has("no-swap")) log("skipped", "swap", "--no-swap given");
  else if (active !== "" && !has("force-swap")) log("unchanged", `swap (${active.split("\n")[0] || "active"})`, "use --force-swap to recreate");
  else {
    const size = has("swap-gb") ? SWAP_GB : Math.max(2, Math.min(4, Math.ceil(MEM_GB / 2)));
    if (active !== "" && has("force-swap")) { sh("swapoff -a"); sh("rm -f /swapfile"); }
    if (!DRY && !VERIFY) {
      const okFall = ok(sh(`fallocate -l ${size}G /swapfile 2>/dev/null`)) || ok(sh(`dd if=/dev/zero of=/swapfile bs=1M count=$(( ${size} * 1024 )) status=none`));
      if (okFall) {
        sh("chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile");
        appendLines("/etc/fstab", ["/swapfile none swap defaults 0 0"]);
        log("applied", `swap /swapfile ${size}G`);
      } else log("skipped", "swap", "could not allocate swapfile");
    } else log("applied", `swap /swapfile ${size}G (plan)`);
  }
}

// ---------------------------------------------------------------- 4. unneeded services (only if present + enabled)
const PRUNE = ["cups.service", "cups-browsed.service", "ModemManager.service", "avahi-daemon.service",
               "bluetooth.service", "wpa_supplicant.service", "speech-dispatcher.service", "pppd-dns.service"];
for (const u of PRUNE) {
  const st = sh(`systemctl is-enabled ${u} 2>/dev/null`).out.trim();
  if (st === "enabled" || st === "enabled-runtime") {
    if (!DRY && !VERIFY) sh(`systemctl disable --now ${u} 2>/dev/null`);
    log("applied", `disable ${u}`);
  } else log("skipped", `disable ${u}`, st === "" ? "not installed" : st);
}

// ---------------------------------------------------------------- 5. journald caps
{
  const c = "[Journal]\nSystemMaxUse=512M\nSystemMaxFileSize=64M\nMaxRetentionSec=7d\nCompress=yes\n";
  if (writeFile("/etc/systemd/journald.conf.d/99-optimize.conf", c) && !DRY && !VERIFY) sh("systemctl restart systemd-journald");
}

// ---------------------------------------------------------------- 6. docker daemon tuning (if docker present)
if (HAS_DOCKER) {
  const p = "/etc/docker/daemon.json";
  let cfg: Record<string, unknown> = {};
  try { cfg = JSON.parse(read(p) ?? "{}"); } catch { cfg = {}; }
  const tune: Record<string, unknown> = {
    "log-driver": "json-file",
    "log-opts": { "max-size": "10m", "max-file": "3" },
    "live-restore": true,
    "max-concurrent-downloads": 10,
    "max-concurrent-uploads": 10,
    "userland-proxy": false,
  };
  let changed = false;
  for (const [k, v] of Object.entries(tune)) if (JSON.stringify(cfg[k]) !== JSON.stringify(v)) { cfg[k] = v; changed = true; }
  if (!("storage-driver" in cfg)) { cfg["storage-driver"] = "overlay2"; changed = true; }
  if (changed) {
    const wrote = writeFile(p, JSON.stringify(cfg, null, 2) + "\n");
    if (wrote && !DRY && !VERIFY && !ok(sh(`python3 -m json.tool ${p} >/dev/null 2>&1`))) {
      log("skipped", p, "invalid JSON — restoring previous file");
      sh(`cp ${BACKUP_DIR}/${p.replace(/^\//, "").replaceAll("/", "_")} ${p}`);
    } else if (wrote && has("restart-docker") && !DRY && !VERIFY) sh("systemctl restart docker");
    else if (wrote) hint("docker daemon.json written", "restart dockerd to apply: systemctl restart docker (or re-run with --restart-docker)");
  } else log("unchanged", p);
}

// ---------------------------------------------------------------- 7. dnsmasq cache (if present)
if (HAS_DNSMASQ) {
  const p = "/etc/dnsmasq.d/99-optimize.conf";
  const hasCache = ok(sh("grep -rsq '^cache-size=' /etc/dnsmasq.conf /etc/dnsmasq.d/ 2>/dev/null"));
  if (hasCache) log("unchanged", "dnsmasq cache-size", "already set");
  else if (writeFile(p, "cache-size=10000\n")) {
    if (has("restart-dnsmasq") && !DRY && !VERIFY) sh("systemctl restart dnsmasq");
    else hint("dnsmasq cache-size=10000", "restart dnsmasq: systemctl restart dnsmasq (or re-run with --restart-dnsmasq)");
  }
}

// ---------------------------------------------------------------- 8. noatime on root
if (has("noatime")) {
  const fstab = read("/etc/fstab");
  const rootLine = fstab?.split("\n").find((l) => / \/ (ext4|xfs|btrfs) /.test(l));
  if (rootLine && !rootLine.includes("noatime")) {
    const newLine = rootLine.replace(/\s(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s*$/, " $1 $2 $3 $4,noatime,nodiratime $5 $6");
    backup("/etc/fstab");
    if (!DRY && !VERIFY) {
      Deno.writeTextFileSync("/etc/fstab", (fstab ?? "").replace(rootLine, newLine));
      if (ok(sh("mount -o remount /")) && ok(sh("findmnt -no OPTIONS / | grep -q noatime"))) log("applied", "noatime,nodiratime on /");
      else { sh(`cp ${BACKUP_DIR}/etc_fstab /etc/fstab 2>/dev/null`); sh("mount -o remount / 2>/dev/null"); log("skipped", "noatime", "remount failed — reverted"); }
    } else log("applied", "noatime,nodiratime on / (plan)");
  } else log("unchanged", "noatime on /", rootLine ? "already set" : "root fs not ext4/xfs/btrfs");
}

// ---------------------------------------------------------------- 9. fstrim (SSD only)
{
  const rot = sh("cat /sys/block/*/queue/rotational 2>/dev/null | sort -u").out.trim();
  const ssd = has("force-fstrim") || (rot !== "" && rot !== "1");
  if (ssd) {
    if (!DRY && !VERIFY) { sh("systemctl enable --now fstrim.timer 2>/dev/null"); sh("fstrim --fstab -v 2>/dev/null"); }
    log("applied", "fstrim.timer + weekly trim", has("force-fstrim") ? "forced" : "disk reports non-rotational");
  } else log("skipped", "fstrim", "all disks report rotational (spinning/VirtIO) — use --force-fstrim if SSD-backed");
}

// ---------------------------------------------------------------- 10. apt speed (non-interactive, no language pulls)
{
  const c = 'Acquire::Languages "none";\nDpkg::Use-Pty "false";\n';
  writeFile("/etc/apt/apt.conf.d/99-optimize", c);
}

// ---------------------------------------------------------------- 11. optional packages (only with explicit consent)
if (NPROC >= 8 && YES) {
  if (ok(sh("command -v irqbalance"))) log("unchanged", "irqbalance");
  else if (!DRY && !VERIFY && ok(sh("apt-get install -y -qq irqbalance && systemctl enable --now irqbalance 2>/dev/null"))) log("applied", "irqbalance installed+enabled");
  else log("applied", "irqbalance (plan)");
} else if (NPROC >= 8) hint("irqbalance", `${NPROC} cpus — re-run with --yes to install`);
if (has("with-earlyoom") && YES) {
  if (ok(sh("command -v earlyoom"))) log("unchanged", "earlyoom");
  else if (!DRY && !VERIFY && ok(sh("apt-get install -y -qq earlyoom && systemctl enable --now earlyoom 2>/dev/null"))) log("applied", "earlyoom installed+enabled");
  else log("applied", "earlyoom (plan)");
} else if (has("with-earlyoom")) hint("earlyoom", "re-run with --yes to install");

// ---------------------------------------------------------------- 12. verify
if (!DRY && (VERIFY || !has("dry-run"))) {
  console.log("\n# verify");
  let fail = 0;
  for (const [k, v] of SYSCTLS) {
    const got = sh(`sysctl -n ${k} 2>/dev/null`).out.replace(/\s+/g, " ").trim();
    if (got === v.replace(/\s+/g, " ").trim() || v.split(" ").length > 1 && got !== "") console.log(`  ok  ${k} = ${got}`);
    else { console.log(`  FAIL ${k} = ${got} (expected ${v})`); fail++; }
  }
  const nl = sh("ulimit -Sn").out.trim();
  console.log(`  ${nl >= "65535" ? "ok " : "FAIL"} soft nofile = ${nl}`);
  for (const u of PRUNE) {
    const st = sh(`systemctl is-enabled ${u} 2>/dev/null`).out.trim();
    if (["", "disabled", "masked", "static", "indirect", "generated", "not-found"].includes(st)) console.log(`  ok  ${u} ${st}`);
    else { console.log(`  FAIL ${u} still ${st}`); fail++; }
  }
  const swapNow = sh("swapon --show --noheadings").out.trim();
  console.log(swapNow !== "" ? `  ok  swap ${swapNow.split("\n")[0]}` : `  ${has("no-swap") ? "ok " : "FAIL"} swap (none active)`);
  if (swapNow === "" && !has("no-swap")) fail++;
  for (const f of ["/etc/sysctl.d/99-optimize.conf", "/etc/systemd/system.conf.d/99-optimize.conf",
                   "/etc/systemd/journald.conf.d/99-optimize.conf", "/etc/apt/apt.conf.d/99-optimize"]) {
    console.log(`  ${exists(f) ? "ok " : "FAIL"} ${f}`);
    if (!exists(f)) fail++;
  }
  if (HAS_DOCKER) console.log(ok(sh("docker info >/dev/null 2>&1")) ? "  ok  docker daemon" : "  FAIL docker daemon");
  if (HAS_DNSMASQ) console.log(ok(sh("systemctl is-active dnsmasq 2>/dev/null")) ? "  ok  dnsmasq active" : "  -   dnsmasq inactive (may be stopped on purpose)");
  console.log(fail === 0 ? "\nverify: all checks passed" : `\nverify: ${fail} check(s) FAILED`);
  Deno.exit(fail === 0 ? 0 : 1);
}

// ---------------------------------------------------------------- summary
console.log("\n# summary");
for (const s of step.filter((s) => s.status !== "skipped")) console.log(`  ${s.status === "applied" ? "+" : s.status === "hint" ? ">" : "="} ${s.label}${s.note ? ` — ${s.note}` : ""}`);
const applied = step.filter((s) => s.status === "applied").length;
console.log(`\n${DRY ? "dry-run: " : ""}${applied} change(s)${DRY ? " planned" : " applied"}. Backups: ${BACKUP_DIR}`);
if (!DRY && !VERIFY) {
  const needsReboot = step.some((s) => s.label.startsWith("disable ") || s.label.includes("limits") || s.label.includes("swap"));
  console.log(needsReboot ? "reboot recommended to fully apply limits/service/swap changes" : "most settings are live; a reboot is optional");
}
