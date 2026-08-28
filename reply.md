## Current state (what you already have)

Your VPS (`fxmq.net`) already runs a full Minecraft stack, and it's **single-server-hardcoded** — that shapes the options:

- **VPS**: 11 GB RAM (~10 GB free), 4 vCPU (Xeon Gold 6140 @ 2.3 GHz), 79 GB free disk, ~2.6 GB used by the existing server dir.
- **Existing server** (`2ecfbe8c`): Paper 26.2, 3.5 GB heap, managed by PufferPanel, wake-on-connect via lazymc, 5-min idle sleep via mc-idle-sleeper, Geyser+Floodgate (Bedrock on `19132/udp`), online-mode, whitelist, plain-text MOTD.
- **The sleep/wake stack is welded to this one server**: lazymc owns public `25565` → proxies `127.0.0.1:25566`; `start-panel.sh` and `mc-idle-sleeper.py` hardcode the server id `2ecfbe8c` and port 25566. A second server means a second lazymc instance (own unit/config/start script), a second UDP port for Geyser, and a second idle-sleeper or an always-on policy.

## Honest reality check before the comparison

- **RAM isn't the whole performance story.** Minecraft's tick loop is single-threaded, and the 6140 is a 2017 server chip — your laptop's single-core speed is likely *higher*, so ticks may not get faster. What the VPS genuinely buys you: RAM capacity (bigger worlds, modpacks, pre-gen, view distance), 24/7 uptime, and **device health** (no fans/heat/battery wear — this goal is fully met).
- **Latency**: you'll play over the internet to the VPS IP (mc.fxmq.net is DNS-only, straight to the origin). Expect +10–40 ms vs. localhost — imperceptible for MC, but not zero.
- **Single-player → server conversion is trivial**: same save format, copy the `world` folder, set `level-name`. Player position/`level.dat` carry over.
- The catch is **modloader compatibility**: the existing server is Paper with plugins. If your local instance is vanilla/Paper at MC 26.2, it can merge in. If it's Fabric/Forge or a different MC version, it cannot — it needs its own server.

## The options, compared

| | **A. Merge into existing server** | **B. Second PufferPanel server** | **C. Standalone container** | **D. Third-party MC host** |
|---|---|---|---|---|
| What it is | Replace `2ecfbe8c`'s worlds with your local world | New server entry in PufferPanel (Fabric/Forge/Paper all supported by the template) | Plain `docker`/compose Java container, world bind-mounted | Upload world to Bisect/Apex-style host |
| Requires local to be | Vanilla/Paper, MC 26.2 | Any modloader/version | Any modloader/version | Any |
| Existing server | **World replaced** (back it up first) | Untouched, runs in parallel | Untouched | Untouched |
| New ports/hostnames | None | New Java port + new UDP for Geyser (or no Bedrock) | New Java port | Their IP/hostname |
| Sleep/wake | lazymc already works | 2nd lazymc unit + 2nd idle-sleeper, or always-on | Same as B | Host's own |
| Management | PufferPanel console, existing plugins (StackMob/Chunky/Geyser) | PufferPanel console | Manual (logs, console via docker) | Host's panel |
| Cost | ~0 | ~0 | ~0 | ~$10–25/mo |
| RAM math | Fits (one 3.5 GB heap; could raise to ~6 GB if you drop other containers' headroom) | Tight: second 4 GB heap → ~9.5/11 GB peak, OK w/ swap | Same as B | n/a |
| Best for | Your local world *is* the one true world; kill the old one | Local is modded/different version, or you want both worlds | Local is modded and you want zero panel dependency | You'd rather not touch the VPS |

**A** is the zero-infra path — same URL, same lazymc, same Bedrock. **B** is the flexible path and is genuinely well-supported here (the PufferPanel template already carries Fabric/Forge/NeoForge install steps); the cost is a second lazymc/idle-sleeper pair and remembering a port or a new subdomain. **C** loses the panel's console/backups but keeps everything in your repo's compose style. **D** only makes sense if the VPS RAM ceiling becomes the limit — 11 GB caps you at roughly one 6 GB or two 3.5–4 GB servers.

One gap to flag: there's no `bkp-mc` recipe (only `clean-backups` mentions `mc-backup-*` patterns). Whatever option you pick, back up the existing `2ecfbe8c` dir (~2.6 GB) before touching it — I'd add a `bkp-mc` Makefile recipe as part of the work.

## What I need from you to recommend one

1. Your local instance: **version + modloader** (vanilla / Paper / Fabric / Forge / NeoForge) and whether it has server-side mods or plugins.
2. **World size** (GB) and roughly what RAM you'd want to give it.
3. Your laptop's RAM (to confirm the headroom gap) and whether the existing VPS world still has content you want kept.
4. Whether Bedrock access matters for the local instance.

Answer those and I'll implement the chosen path — including the second lazymc unit if it's B, a `bkp-mc` recipe either way, and the doc updates (GUIDE/ISSUES) per repo rules, then commit and push.
