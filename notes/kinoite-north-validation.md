# kinoite-north — hardware notes

AMD 9900X, dual Radeon AI PRO R9700 (RDNA4 / gfx1201), ASUS ProArt B850-Creator
WiFi Neo. Validated on the real box 2026-08-08/09 on kernel 7.1.7-200.fc44 with
mesa 26.1.6. **Settled** records constraints and non-obvious causes worth keeping;
**Open** is what's left to verify. Code that depends on an open item carries a
`TODO(hardware):` comment pointing here.

## Settled

**GPU node map** (`ls -l /dev/dri/by-path/` + `lspci -nn`). Numbering is not stable
across kernel or slot changes — re-derive rather than trusting it.

Only the PCI column is stable. Observed twice, with different numbering each time —
2026-08-08 gave card1/card2/card3, 2026-08-10 gave card0/card1/card2 with 06:00.0
sorting first. Never bake a card, renderD or device index.

| PCI     | GPU                  | KFD node | `gfx_target_version` |
|---------|----------------------|----------|----------------------|
| 03:00.0 | R9700 (Navi 48)      | 1 or 2   | 120001               |
| 06:00.0 | R9700 (Navi 48)      | 1 or 2   | 120001               |
| 10:00.0 | iGPU (Granite Ridge) | 3        | 100306               |

Re-derive with `ls -l /dev/dri/by-path/`, `lspci -nn`, and
`grep -H gfx_target_version /sys/class/kfd/kfd/topology/nodes/*/properties`. Per-GPU
VRAM in use (i.e. which cards actually hold model weights) reads from
`/sys/class/drm/card*/device/mem_info_vram_used`.

**The display cable decides which GPU does everything.** With the dummy plug in the
motherboard HDMI port, Sunshine encoded on the iGPU (`vaapi vendor: ...
raphael_mendocino`) — the output owns the compositor, and the VAAPI device follows
the compositor. Moving the plug to an R9700 port fixed it and brought AV1 encode
with it. `adapter_name` is the wrong fix: it repoints only the encoder, leaving the
compositor on the iGPU and the cross-GPU copy in place. Keep the plug on a dGPU.

The cost, noted 2026-08-10: the R9700 now owns compositing, and it produces audible
coil whine the iGPU never did (its power delivery is the board VRM, a fraction of the
current). **Confirmed trigger:** UI animations — tab switches, menu/window effects;
disabling desktop animations stops those. **Untested:** whether a connected stream on
a static desktop, or LLM inference, whine on their own. Both are plausible — whine
tracks *periodic* transients, not average load, and all three are periodic: encode at
60/120 Hz, inference at the token rate (~31 Hz), animations at refresh rate. Isolate
with the 2×2 before blaming any one of them: stream on/off × model loaded/generating,
touching nothing during the stream tests. Harmless either way — not a GPU fault.

**A dummy plug is still required, but only for Sunshine's startup probe.** With no
output, KWin keeps running (`wayland-0` present) with zero outputs; what dies is
Sunshine's encoder probe at launch — `[kwingrab] no wl_output found` → `Fatal:
Unable to find display or encoder during startup`. The per-stream virtual monitor
can't help, since the prep command runs long after the probe. Ways to drop the
plug, cheapest first, all untested:
- Persistent `krfb-virtualmonitor` user unit on `graphical-session.target`, ordered
  before Sunshine, so an output exists at probe time. Would need to coexist with
  the per-stream monitor — likely resize it rather than create a second.
- `video=<connector>:1920x1080@60e` ('e' overrides connect detection) in `kargs.d`.
- `drm.edid_firmware=<connector>:edid/<file>.bin` with a blob in
  `/usr/lib/firmware/edid/`, dumped from the plug itself. May need it in initramfs.

**Why the Sunshine config is seeded.** Default `kms` capture enumerates DRM
connectors only, so it discarded the virtual monitor (`Unknown Monitor connector
type`) and silently streamed the physical panel instead. Hence `capture = kwin`,
`output_name`, and `global_prep_cmd` seeded from `ExecStartPre`. Don't "simplify"
that away. The Arch-only `CAP_SYS_NICE` bug affecting kwin capture doesn't apply —
Fedora's kwin sets `%caps(cap_sys_nice=ep)` on `kwin_wayland`. KWin grants the
screencast protocol unaided (`Found matching system KWin desktop permission file`),
so `KWIN_WAYLAND_NO_PERMISSION_CHECKS=1` is not needed.

**`--exclusive` is needed in practice.** Making the virtual output primary only
governs *new* windows, so an already-running Steam stays on the desk. Disabling the
physical outputs is what makes KWin migrate existing windows.

**R9700 fan control — WAS broken, FIXED by a vBIOS flash (2026-08-17).** Until
then hwmon exposed `fan1_enable/target/input/min/max` but no `pwm1_enable` and no
`gpu_od/fan_ctrl/`, and reading `fan1_enable` returned EINVAL — an amdgpu SMU
interface version mismatch specific to the R9700 that broke fan control across
LACT, rocm-smi and amd-smi alike (undervolt/clock/power tuning kept working).
**Flashing updated GPU vBIOS fixed it** — confirmed by setting idle fans to 60% via
LACT (the write took effect). This is exactly the "recheck on firmware bumps" TODO
paying off — a vBIOS flash is a firmware change.

**Correction (2026-08-17): the flash did NOT close the SMU interface mismatch, and
that was never the cause.** An earlier version of this note said it did. dmesg after
the flash still reads `smu driver if version = 0x0000002e, smu fw if version =
0x00000033` — driver 46 vs firmware 51, so the gap actually *widened* (was 46 vs 50),
and both cards still init fine. Fan control works with the mismatch present. So AMD's
#6078 position is correct on the facts: **the mismatch message is harmless and is not
what gates anything.** What the flash actually changed was the vBIOS OverDrive tables.
Practical consequence: on a future kernel or firmware bump, do not use the mismatch
message as the health signal — it will always be there. Check whether
`gpu_od/fan_ctrl/` exists and whether writes take.

**Firmware baseline, post-flash (2026-08-17)** — diff against this after any bump:
| | R9700 ×2 (03:00.0, 06:00.0) | iGPU (10:00.0) |
|---|---|---|
| vBIOS | `115-G287BP00-100`, build 00180814, 2026/03/17 | `102-RAPHAEL-008` |
| SMC fw | `0x00684f00` (104.79.0) | `0x00625400` (98.84.0) |
| SMU if | driver 0x2e (46) vs fw 0x33 (51) — mismatched, harmless | — |

Both R9700s report identical strings, so the flash took on both. Read it with
`sudo sh -c 'cat /sys/kernel/debug/dri/*/amdgpu_firmware_info'` — the glob must be
expanded by root (`/sys/kernel/debug` is 0700, so `sudo cat` with a shell glob fails
with ENOENT). Each card appears twice; debugfs exposes numeric and PCI-addressed dirs.
Note `<smu_v14_0_0>` in dmesg is the generic SMC IP block version, NOT which
`smu_v14_0_*_ppt.c` drives the card — don't read it as evidence about SMU-14.0.2
patches.

**Suspend/resume works, and its `MODE1 reset` lines are not a hang (2026-08-17).**
Two clean deep-sleep cycles (30 min and 3.5 h), all three GPUs resumed. amdgpu issues
a mode1 reset on the resume path, so `GPU smu mode1 reset` on both R9700s at once is
expected noise. Real trouble would look like ring timeouts or a reset with no
surrounding `PM: suspend entry`/`exit`.

**SOLVED (2026-08-18) — there was never a firmware fan floor. Two userspace daemons
were holding the GPUs awake.**

1950–2050 RPM is simply what an *awake* R9700 does. The cards never reached idle
because `coolercontrold` and `lactd` each poll GPU hwmon about once a second. Every
amdgpu hwmon read calls `pm_runtime_get_sync()` on entry and
`pm_runtime_mark_last_busy()` on exit, so a 1 s poll against the 5 s autosuspend delay
resets the timer forever. Stop them and both cards suspend within 30 s:

```
0000:03:00.0 suspended     0000:06:00.0 suspended
sensors -> fan1: N/A, "Can't get value of subfeature fan1_min: Can't read"
```

`N/A` + `Can't read` is the correct result, not an error: hwmon registers are
unreadable on a card that is powered down. Confirmed against a Bazzite live boot and a
Fedora Kinoite live boot, both of which suspend these same cards — neither ships
CoolerControl.

**Every OD node we tested was irrelevant.** `minimum_pwm`, `zero_rpm`,
`acoustic_target_rpm_threshold`, `fan_target_temperature` all govern an awake card, and
the card was only awake because something was watching it. The observations about them
are still accurate (below) — they just never mattered.

**Disposition of the daemons.**
- **CoolerControl: removed from the image (2026-08-18).** It could not actually change
  fan settings on this board anyway — the NCT6701D is too new — so it was blocking dGPU
  idle while providing nothing. COPR, packages and `coolercontrold.service` all dropped
  from `motherboard.sh`. The `acpi_enforce_resources=lax` karg and the `nct6775`
  module-load stay: those unlock sensor *reads* for lm_sensors and LACT and are
  independent of CoolerControl.
- **LACT: kept, with a caveat.** It is what applies the power cap and will apply the
  undervolt, so it earns its place. But `lactd` polls the same way, so with it running
  the dGPUs will not idle. Open question: whether LACT can be configured to stop polling
  with no GUI client attached, or poll slower than the 5 s autosuspend delay. Until
  then it is a straight trade — LACT running, or quiet idle. `systemctl stop lactd`
  reclaims the idle at any time; settings it already applied persist.

**Still accurate, for an awake card:**
- Idle is 1950–2050 RPM = exactly 30% of the 6500 max, dies ice-cold.
- `fan_minimum_pwm` OD_RANGE is `30 100`; writes below 30 error out.
- `fan_zero_rpm_enable` is an inert stub; `fan_zero_rpm_stop_temperature` is absent.
- `acoustic_target_rpm_threshold` (range `500 6500`, default 3500) and
  `fan_target_temperature` (default 100, range `25 105`) accept writes, commit without
  error, and do nothing — a silent no-op unlike the two that error loudly. Keep all
  four out of any LACT profile regardless.
- `pp_table` does not exist on gfx1201 — no soft PowerPlay override path.
- Ruled out as causes, each tested directly: the `amdgpu.ppfeaturemask=0xfff7ffff`
  karg, the persistent virtual monitor, processes holding the DRM nodes, the HDMI audio
  function 06:00.1, and the kernel itself.

**Claims previously recorded here as fact that were wrong:**
- "Fans are WONTFIX / a firmware floor with no fix." False. It was a poller.
- "The floor is power-state-independent." Never tested — no suspended card had ever been
  measured, because none had ever suspended.
- "amdgpu never enables runtime PM on these cards." False; it does.
- "The bigmalloy D0/runtime-PM fix is a no-op." Its A/B ran on the display card, which
  was legitimately always D0. It never tested the headless card.
- ROCm#6078's "the ~30% default curve is intended" is still AMD's position, but it was
  never the reason for *this* box's noise.

**Self-inflicted confound, for the record.** A `power/control=on` pin was written to
`/etc/tmpfiles.d/` and `/etc/udev/rules.d/` on 2026-08-17 while testing #6101 D3
insurance, and left there. It forbade runtime suspend on 06:00.0 across every
subsequent reboot, so hours of "06:00.0 never suspends" were measuring the pin. Both
files deleted. Nothing equivalent is baked in the image.

**Separate real bug — the virtual monitor could leave the box with no display. FIXED
2026-08-18.** `services-north.sh` `--global enable`s `sunshine-virtual-monitor.service`,
so every login runs `sunshine-virtual-display up --persistent`, launching
`krfb-virtualmonitor` and making the virtual output primary whether or not anyone
streams. Found in the wild as `HDMI-A-3` **connected but disabled** — this was "the iGPU
doesn't work on north".

Root cause was a storage-location mistake, not the disabling itself: `--exclusive`
recorded which outputs it turned off in `$XDG_RUNTIME_DIR`, which is tmpfs, while the
damage it was undoing (KDE's disabled-output state in
`~/.config/kwinoutputconfig.json`) persists on disk. Any abnormal end to an exclusive
stream — crash, hard reboot, power cut — destroyed the restore list and kept the
disabled outputs. `teardown` at next login already re-enables whatever the list holds;
the list just never survived to be read.

Two changes in `sunshine.sh`:
1. `DISABLEDFILE`/`PRIMARYFILE` moved to `${XDG_STATE_HOME:-~/.local/state}/sunshine-vm/`
   so the restore list outlives a reboot. `PIDFILE` deliberately stays in the runtime
   dir — a PID from a previous boot is worse than none.
2. A login-path safety net: if no non-virtual output is enabled when the persistent
   service starts, re-enable every connected output. Covers a lost or never-written
   list, including KDE-persisted state predating this fix. Gated on `--persistent` so a
   deliberate manual `up --exclusive` is not undone.

Recovery if it ever recurs: `kscreen-doctor output.HDMI-A-3.enable`. Note a
`--global enable` cannot be undone with `systemctl --user disable` — it needs
`systemctl --user mask`.

**Virtual monitor is now on-demand, not at login (2026-08-18).** `krfb-virtualmonitor`
holds a DRM render node the whole time it runs, pinning whichever GPU backs it into D0
— the same class of problem as the CoolerControl polling. Requirement was "fine for a
GPU to spin up while streaming, not when idle", so:
- `sunshine-virtual-monitor.service` is **shipped but no longer `--global enable`d**.
  Still the right answer for a genuinely headless box (no physical output ⇒ losing the
  virtual one puts KWin at zero outputs), so it's kept and documented:
  `systemctl --user enable --now sunshine-virtual-monitor.service`.
- The seeded `global_prep_cmd` `undo` changed from `ensure` to **`down`**, so the
  monitor is destroyed when a stream ends instead of lingering until logout.
- `down` gained a guard: it refuses to run when no physical output is *connected*, so
  it cannot strand a headless box. A merely-disabled physical output is fine — teardown
  re-enables it first.

**Caveat for existing installs:** the seeder only ever adds *missing* keys (the Web UI
owns that file), so a `sunshine.conf` that already has the old `undo … ensure` will keep
it. Change it in Sunshine → Configuration → General → Command Preparation, or delete the
`global_prep_cmd` line and let it re-seed.

**Measurement gotchas — all of these cost hours:**
- **Reading hwmon wakes the GPU.** `sensors` is not a passive instrument. Read
  `power/runtime_status` (PCI core sysfs) FIRST and `sensors` second, or you measure
  your own observation.
- `runtime_usage` / `runtime_enabled` do NOT exist on Fedora (they need
  `CONFIG_PM_ADVANCED_DEBUG`). `runtime_suspended_time` answers "has it ever suspended"
  and works while the GPU is busy, being cumulative.
- `fuser /dev/dri/*` does not see hwmon readers. CoolerControl never appeared there.
- Daemons that block idle may be *system* services — `systemctl stop display-manager`
  does not touch them.
- `udevadm trigger --action=bind` does NOT prove boot behaviour: amdgpu.ko is in the
  initramfs, the card binds before switch-root, and udev never replays `bind`. Use
  tmpfiles.d for sysfs writes that must happen at boot.
- Testing GPU idle from a Sunshine session is self-defeating; the stream holds the GPU.
- kscreen-doctor colours output even when piped — strip with `sed 's/\x1b\[[0-9;]*m//g'`.
- The display manager here is `plasmalogin.service`, not sddm.
- DRM card indices reshuffle between boots; PCI addresses do not.

Nothing fan-related is baked into `tuning.sh`, by choice — and nothing needs to be.

**Escape-hatch analysis — Windows / WSL2 (decision reference, 2026-08-17).** NOTE: MOOT
as a noise argument. This was reasoned from the premise that a quiet Linux idle was
impossible, which turned out to be a polling daemon (see SOLVED above) — Linux idles the
cards fully, fans off. The workload analysis below still stands on its own merits.
Evaluated moving to Windows (quiet Adrenalin
12%/zero-RPM fans + better game compat) while keeping LLM work in WSL2. Under WSL2
the *Windows* driver owns the GPU, so fans stay quiet while WSL borrows it for
compute — appealing, but the workload fit is the catch:
- **FP8 is two-card-only for 27B.** FP8 27B weights ≈ 27 GB — fills a 32 GB card,
  leaving no room for KV. That's *why* we run TP=2. Single-card FP8 27B @ any real
  context does not fit, independent of WSL. (FP8 kernels themselves work on gfx1201;
  vLLM-on-ROCm-WSL is just not AMD-validated.)
- **Dual-GPU is what WSL2 least reliably delivers.** AMD ships ROCm-on-WSL as
  preview/limited-validation, and gfx1201 multi-GPU RCCL is already fragile on NATIVE
  Linux — open TP=2 deadlock issues on dual R9700 (vllm-project/vllm#40980,
  ROCm/rocm-systems#5480; both GPUs 100%, TP=1 fine). Our working TP=2 is on the
  lucky side of a known-rocky feature; moving it onto WSL's weaker multi-GPU layer is
  the opposite of derisking.
- **The container model doesn't port.** WSL2 has no `/dev/kfd`; GPU goes through
  `/dev/dxg` + a WSL-specific ROCm runtime. Existing rootless Quadlets / kfd+dri
  passthrough (lemonade.container, north-llm pod) need rework, not lift-and-shift.
- **Single-card GGUF IS viable, and the hybrid KV savings CARRY to llama.cpp.**
  llama.cpp has `llama_memory_hybrid` (Jamba-derived) extended to the qwen3_5 GDN
  arch: only the full-attention layers keep a KV cache, the linear-attention (Gated
  DeltaNet) layers keep none → the same ~4× saving vLLM sees (~0.0625 vs dense 0.25
  GB/1K). CAVEAT: qwen3_5/GDN operator support is bleeding-edge — needs the
  absolute-latest llama.cpp/lemonade build, and you must confirm the hybrid path
  engages on load (grep the log for linear-attention/GDN) vs a silent dense fallback.
- **Single-card memory (32 GB, hybrid KV):** Q6_K 27B @128K ≈ 23 weights + ~8 KV ≈
  31 GB → fits (tight); Q5_K_M @128K ≈ 29 GB comfortable; 256K needs KV quant or two
  cards. Stack flash-attn + Q4_0 KV (~47% saving, near-zero quality, lemonade b1285)
  to push one card toward 256K. Without the hybrid path it falls back to dense
  (0.25 GB/1K → 128K KV ≈ 33 GB), where single-card 128K needs Q4 weights + Q4 KV.
- Gotcha: llamacpp-rocm#96 — gfx1201 segfaults if the iGPU is also visible to ROCm;
  likely moot under WSL (iGPU not exposed) but verify.

**Verdict:** WSL2 single-card = quiet + gaming + Q6 27B @128K, *if* on a bleeding-edge
build with the hybrid path engaged; it gives up dual-card 256K/FP8. The lower-rework
alternative that keeps everything: this box already has Sunshine + WoL + Tailscale, so
**relocate the loud box out of earshot and keep native Linux dual-card** — solves the
noise without abandoning the stack. Dual-boot is the middle path (Linux for LLM/dev,
Windows for quiet gaming sessions).

**Sensor channels that read wrong, and always will.** `AUXTIN3 -61°C`, `AUXTIN4
+86°C ALARM`, all three `PCH_*` at 0°C, and several `inN` rails flagged ALARM
against a 0V max. Cosmetic NCT6701D quirks — ignore rather than chase. Recheck if
`asus-ec-sensors` gains an entry for this board.

**Clipboard is KDE Connect's job.** Sunshine has no clipboard sync in any build or
channel — upstream closed host→client on security grounds (#1539) and the text-only
proposal as `not_planned` (#5384). Don't debug Sunshine for it.

**Rootless Quadlets must ship in `/etc`, not `/usr`.** `podman-systemd.unit(5)` lists
`/usr/share/containers/systemd/users/` as a rootless search path, and current podman
source does iterate both admin tiers — but podman **5.8.4** (Fedora 44) does not. The
generator on the box reports searching only:

    /run/user/$UID/containers/systemd
    ~/.config/containers/systemd
    /etc/containers/systemd/users
    /etc/containers/systemd/users/$UID

A unit under `/usr/share/...` is silently ignored — no error, the unit simply doesn't
exist. Confirmed by forcing it: `QUADLET_UNIT_DIRS=/usr/share/containers/systemd/users
/usr/lib/systemd/user-generators/podman-user-generator --user --dryrun` parses the
same file fine and emits `lemonade.service`. Hence `lemonade.sh` writes to `/etc`, which
also matches `signing.sh` (`/etc/containers/policy.json`) and the `services.sh`
drop-ins. Don't "fix" it back to `/usr` for tidiness — recheck with the `--dryrun`
above after a podman bump if you want to.

**3DMark: two separate failures, first one solved.** (1) Hangs at startup collecting
system info — disabling hardware monitoring in 3DMark's settings fixes it. SystemInfo
is genuinely Wine-incompatible and UL supports Windows only. (2) With that off, the
benchmark itself then gets stuck — **unresolved, cause unknown**.

Important: 3DMark *does* run on Bazzite on this same hardware (observed directly). So
(2) is a real gap between this image and Bazzite, not an upstream Proton limitation —
do not write it off as "3DMark doesn't work on Linux." Leading suspect is Proton
version: Bazzite ships Proton-GE by default and this image had only stock Proton at the
time; GE is baked as of the gaming.sh change, so retest after a rebuild before
investigating anything else.

Already ruled out: `radeon_icd.i686.json` is present so 32-bit Vulkan is fine, and
Vulkan selects an R9700 rather than the iGPU (03:00.0 at ~9%, iGPU at 0%). Note scores
can't validate on Linux regardless, so this is a "does the stack work" question rather
than a benchmarking one.

**ROCm's real blocker was one missing SELinux permission: `map` on `/dev/kfd`.**
`container-selinux` grants container domains `hsa_device_t:chr_file` all of
`{open getattr read write append ioctl lock}` but **not `map`** — and ROCm mmaps the
node. Out of the box every model load aborted ~25ms in, before any
`llama_model_loader:` output: `Memory critical error by agent node-0 ... Reason:
Memory in use.` → exit 134 (SIGABRT). Node 0 is the **CPU** agent — host-memory
registration — which is why every llama.cpp-level knob missed for a week. The only AVC
in the entire trace:

    denied { map }  tclass=chr_file  tcontext=system_u:object_r:hsa_device_t:s0

Bisected 2026-08-10, each option alone against an otherwise-stock container:

| `container_use_devices=on` | **PASS** | the fix; now baked via `lemonade-selinux.service` |
| `SecurityLabelDisable=true` | PASS | same fix, bigger hammer — drops the container to `spc_t` |
| `--ipc=host` | PASS | *also* the same fix: podman drops label separation when sharing host IPC |
| `SeccompProfile=unconfined` | FAIL | never involved |
| nothing | FAIL | the AVC above |

Two traps this cost time on. `Ulimit=memlock=-1:-1` as a Quadlet key does **not**
equal the `PodmanArgs` form — it left `ulimit -l` at 8192, because rootless can't raise
a hard limit; memlock was inert in every configuration and is not part of the fix. And
any bisect must pin `llamacpp.rocm_args` first: leaving `-sm row` set from an earlier
experiment made six consecutive tests fail for an unrelated reason.

Ruled out — don't re-chase: capping `ctx_size` (auto-tunes to **157140** on a 27B —
worth pinning anyway, but not the cause); `-mg 0 -sm none`; `--load-mode mmap` alone;
`ROCR_VISIBLE_DEVICES`. So this is **not** the documented iGPU warmup segfault
(lemonade#1921 / llamacpp-rocm#96) and the iGPU is not implicated at all. Not the
half-VRAM bug; VRAM reports correctly at 31.9 GB. A GPU power cap cannot cause it —
the fault precedes any compute.

**`-sm row` is unavailable, permanently for this build:** `device ROCm0 does not support
split buffers` (exit 1, same with `-ts 1,1,0`). Split buffers need peer-copy compiled
in, so layer split is the ceiling — decode streams from one card at a time and the
second GPU adds capacity, not bandwidth. Recheck on llamacpp-rocm bumps.

**Layer split does the right thing unaided — no device pinning needed.** With all three
GPUs visible, a loaded 27B put 14186 MiB on 06:00.0 and 13680 MiB on 03:00.0, and 20 MiB
(framebuffer only) on the iGPU. That is also proof the work is on the GPUs rather than
silently on CPU. ~27.2 GiB resident for 19.7 GiB of weights; the rest is KV cache,
compute buffers and MTP draft state.

**Measured, 27B Q5_K_M (21.2 GB), layer split, ctx 32768:** ROCm **31–35 tok/s**,
Vulkan ~29. Treat anything in the low 30s as the same result — observed spread on
identical config was 32→35→31, and generation slows as the KV cache fills, so compare
only from a fresh load at a fixed prompt. A number below ~30 is worth investigating.
Both are near the ~30 tok/s single-card bandwidth ceiling (~640 GB/s ÷ 21.2 GB), which
is why the backend gap is only ~20% — and MTP speculation is what puts ROCm *above* the
naive ceiling. A remembered ~40 on Bazzite was likely **vLLM** (PyTorch/HIP), which
shares nothing with llama.cpp's hand-written HIP backend but the name.

**ROCm never lands on the host, and doesn't have to.** lemonade's `llamacpp-rocm`
builds bundle their own ROCm 7 runtime, so the container needs no host ROCm and no
`/opt/rocm` mount — which is why `amdgpu.sh` installs firmware and monitoring only.
This retires the old "pick a gfx1201-capable ROCm 7.2+ image" item: there is no ROCm
image to pick. The `nightly` channel is the only one shipping per-arch `gfx120X`
builds; `stable` and `preview` have no gfx1201 HIP support and *silently* run on CPU
at ~1/7th the speed (lemonade-sdk/lemonade#1787). That's a correctness trap, not a
tuning knob — hence the seeded `rocm_channel` in `lemonade.sh`.

## Open

### Sunshine — `build_files/profiles/north/sunshine.sh`

- [x] Crash safety, the one that matters most: `systemctl --user kill -s KILL
      app-dev.lizardbyte.app.Sunshine.service` mid-stream, and confirm the
      `ExecStopPost` teardown drops the virtual monitor and re-enables the physical
      output. A failure here in exclusive mode means a black desk.
      → N/A: the display is now persistent via sunshine-virtual-monitor.service;
        there is no ExecStopPost teardown. Crash safety is handled by systemd user
        session cleanup (which kills the virtual monitor with the session). This is
        acceptable because the persistent display is the login-time default; a
        crashed session already needs re-login.
- [x] Clean restore on normal disconnect — physical output back, previous primary
      restored, desk window layout intact after `--exclusive`.
      → `ensure --exclusive` disables physical outputs; undo (seeded as `ensure`)
        re-enables them from `$DISABLEDFILE` when the stream ends, so toggling
        exclusivity per-app works. The Sunshine service drop-in's ExecStopPost runs
        `ensure` on shutdown as a backup if a stream is still active, without tearing
        down the persistent display. `up --exclusive` still works for one-off use.
- [ ] Refresh rate follows the client: a 120Hz client should get `addCustomMode` +
      `mode` applied (krfb only ever creates the monitor at 60Hz). Only 60Hz seen
      so far, where the mode already exists and `addCustomMode` is correctly
      skipped. Check `kscreen-doctor -o` mid-stream for the `*` on `WxH@120.00`.

### GPU — `build_files/profiles/north/amdgpu.sh`, `tuning.sh`

- [ ] Does `70-kfd.rules` help or hurt? Observed on the laptop: `/dev/dri/renderD128`
      is mode **0666**, and Fedora's `70-uaccess.rules` tags DRM render nodes but has
      no `kfd` line — so the script's comment is accurate and its rule is the only
      thing tagging `/dev/kfd`. What's unknown is whether the base rules already ship
      `/dev/kfd` at 0666 too; if so our `MODE="0660"` *tightens* it and then hands
      back via `uaccess`/`render` access that was never restricted. One command
      settles it: `stat -c '%n %a %U %G' /dev/kfd /dev/dri/renderD128`. If `/dev/kfd`
      reads `666 root render` with our rule removed, drop the rule (or set
      `MODE="0666"`) and delete the `usermod -aG render,video` advice from the README.
- [x] Fan control, decisive local check: writes now take effect after the 2026-08-17
      vBIOS flash — set idle fans to 60% via LACT and the fan responded. Was EINVAL
      before the flash (SMU mismatch). See the Settled entry above.
- [x] Fan OD nodes, all four tested (2026-08-17): `minimum_pwm` floors at 30,
      `zero_rpm` is an inert stub, and `acoustic_target_rpm_threshold` /
      `fan_target_temperature` accept writes and silently do nothing. Keep all of them
      OUT of the LACT config. Leave LACT on **Automatic**. This says what an *awake*
      card does; it is not a conclusion about the fan floor overall.
- [x] **Fans SOLVED (2026-08-18): it was `coolercontrold` + `lactd` polling hwmon.**
      Not a firmware floor. Each poll calls `pm_runtime_get_sync()` and resets the 5 s
      autosuspend timer, so the cards never idled; ~1950 RPM is just what an awake
      R9700 does. Stop both and both cards suspend in <30 s with fans off. See the
      SOLVED entry above.
- [x] CoolerControl removed from `motherboard.sh` (2026-08-18) — it couldn't drive this
      board's fans anyway (NCT6701D too new) and was the main blocker. Sensor karg and
      `nct6775` module-load kept; they're independent.
- [ ] LACT vs quiet idle — `lactd` polls the same way, so the dGPUs won't idle while it
      runs. Check whether it can stop polling with no GUI client attached, or poll
      slower than 5 s. Until then it's a straight trade; `systemctl stop lactd` reclaims
      the idle and already-applied settings persist.
- [x] **Bug FIXED (2026-08-18): the virtual monitor could leave the box with no
      display.** An `--exclusive` teardown that never completed left physical outputs
      disabled while its restore list died with `$XDG_RUNTIME_DIR`. Fixed by moving the
      restore state to `$XDG_STATE_HOME` and adding a login-path safety net that
      re-enables all connected outputs when none are on. Unverified on hardware — needs
      a rebuild, then an exclusive stream killed mid-flight, then a reboot.
- [x] Virtual monitor moved to on-demand (2026-08-18): unit shipped but not enabled,
      `undo` seeded as `down`, and `down` guarded against stranding a headless box.
      Goal was "GPU may spin up while streaming, not when idle". Unverified on
      hardware — needs a rebuild, then a stream start/stop cycle checking that krfb
      exits and the backing GPU returns to `suspended`.
- [ ] Undervolt is the actual tuning goal (not a fan curve). The ppfeaturemask karg
      already baked is what unlocks the mV offset — no karg change needed. Tune a
      per-card negative GPU voltage offset in LACT (start −50 mV, step −25 mV under
      sustained load until unstable, back off one step; two dies may differ), pair
      with the existing 210 W PPT cap, confirm stable across a reboot via
      `/etc/lact/config.yaml`, THEN bake the proven offsets into `tuning.sh`. Bake
      only after load-testing — a too-aggressive offset would make a fresh install
      unstable at boot.
- [ ] HDR, if wanted: `mesa-vulkan-drivers-freeworld` supersedes `VK_hdr_layer`,
      but RPM Fusion trails Fedora's mesa (26.0.3 vs 26.1.6), so we don't swap it —
      a Vulkan downgrade on RDNA4 is the worse trade. Revisit if RPM Fusion catches
      up and gamescope HDR turns out to matter.

### Containerized ROCm + lemonade — `build_files/profiles/north/lemonade.sh`

The Quadlet is baked (`/etc/containers/systemd/users/lemonade.container`), deliberately
**not** enabled — no `[Install]`, nothing in `services-north.sh`. On-box runbook is
`/usr/share/kinoite/lemonade.md`. First bring-up 2026-08-10; the container plumbing is
proven, the ROCm backend is not.

**Settled on the box 2026-08-10, from the first bring-up log:**

- Rootless device passthrough works. ROCm initialized in-container and enumerated
  agents, so `/dev/kfd` + `/dev/dri` reach a rootless container with no group or ACL
  changes and no `usermod`.
- The SELinux `map` gap **did** materialize — see the Settled entry above. Enumerating
  agents does not require `map`, which is why ROCm got far enough to look like a
  non-SELinux failure.
- The `nightly` channel seed took: the log reports `Using LlamaCpp Backend:
  rocm-nightly` on a first-run container.
- VRAM is reported correctly — `Largest memory pool: 31.9`. The half-VRAM bug that
  affects some gfx1201 nightly builds is not present here.
- KFD topology on this box: node 0 = CPU, nodes 1–2 = R9700 (`gfx_target_version
  120001`), node 3 = iGPU (`100306`). `ROCR_VISIBLE_DEVICES` indexes GPU agents only,
  so `0,1` is the pair that excludes the iGPU.

- [ ] `TAG+="uaccess"` actually lands on `/dev/kfd` — it's a non-DRM device, so
      whether logind assigns it to a seat is the open question. `getfacl -p /dev/kfd`
      while logged in locally: the login user should appear without being in `render`.
      No active seat (SSH) means no ACL either way. Do the `stat` check under GPU
      above first — it may make this moot. Lower priority now that passthrough is
      proven working for the local-login case.
- [ ] `UserNS=keep-id:uid=10001,gid=10001` gives host-side files owned by the login
      user: `ls -ln ~/.local/share/models/huggingface` after the first model pull. A
      subuid owner means keep-id didn't apply and the bind mounts are pointless. Needs
      `grep "^$USER:" /etc/subuid` non-empty and sized > 10001.
- [ ] `GroupAdd=keep-groups` — confirm effective or delete the key. Known-flaky here:
      containers/podman#27876 (inert in rootless Quadlets; groups come from the
      `systemd --user` manager, so `usermod -aG` needs `loginctl terminate-user`) and
      #28364 (device gids under keep-id). Only matters if `/dev/kfd` isn't 0666 *and*
      the box is driven headless.
- [ ] Is `--load-mode mmap` in the seeded `rocm_args` actually load-bearing? It was
      pinned throughout the SELinux bisect and never isolated afterwards. Drop it and
      retry; if ROCm still loads, remove it from `lemonade-defaults.json`.
- [ ] Narrow `container_use_devices` to a CIL module granting only
      `container_domain hsa_device_t:chr_file map`, installed by the same oneshot. The
      boolean grants `map` on every device node to every container — fine for a
      single-user box, worth tightening if that ever stops being true.
- [ ] Whether it stays hand-started. If it earns its keep the change is `[Install]
      WantedBy=default.target` in the quadlet plus `loginctl enable-linger` — *not* a
      line in `services-north.sh`, since `systemctl --global enable` doesn't apply to
      generator-produced units.

**Baked recipe set (resolved 2026-08-15).** `lemonade.sh` now seeds four Unsloth Qwen custom
models into `~/.local/share/lemonade/config/{user_models,recipe_options}.json` (curated
superset, always in the model list; conditional install so user edits survive). Profile is
**Q6 + big context**, chosen for coding/testing: `Qwen3.8-27B` Q6_K / `Qwen3.6-27B` Q6_K /
`Qwen3.6-35B-A3B` UD-Q6_K at **128K**, `Qwen3-Coder-30B` Q6_K at **256K** (native). Sizing
math (verified against Qwen3.8-27B config: 64 layers, 4 KV heads, head_dim 256): dense KV
≈ 0.25 GB/1K, MoE ≈ 0.10 GB/1K, so 27B Q6 @128K ≈ 22.9 GB weights + ~33 GB KV ≈ 56 GB.
These **exceed one card** and depend on the layer split — which is automatic here (the
Settled "Layer split does the right thing unaided" measurement), so no pinning is baked.

- [ ] Do the seeded contexts actually fit and stay off the iGPU at their full size? The
      "nothing on the iGPU" measurement was at ctx **32768**; the seeds are 128K–256K,
      where KV is ~10–20 GB larger. Load `user.Qwen3-Coder-30B` (256K) and a 128K dense,
      watch `mem_info_vram_used` per card + `podman logs lemonade | grep -iE 'buffer
      size|assigned'`. If it OOMs or spills onto the iGPU, either lower `ctx_size` in
      `recipe_options.json` or pin with `ROCR_VISIBLE_DEVICES=0,1` (GPU-agent indices,
      2 = iGPU). This is the gating check for the baked LLM defaults.
- [ ] Flash-attention on gfx1201 (llamacpp-rocm nightly), the context multiplier: does
      `-fa -ctk q8_0 -ctv q8_0` load and roughly halve KV? If yes, it ~doubles every seed
      (or lets Q8 weights fit) and is worth baking into `recipe_options.json`. Documented
      as a tunable in `lemonade.md`, not baked, until confirmed on the box.
- [ ] Q6 tok/s vs the measured Q5_K_M ~31–35: bigger weights + far bigger KV will be
      slower; confirm it's still usable for agentic loops. Compare from a fresh load at a
      fixed prompt (generation slows as KV fills).

### vLLM + Open WebUI stack — `build_files/profiles/north/vllm.sh`

Second, independent local-LLM stack (added 2026-08-16): kyuz0's gfx1201 vLLM image
(`docker.io/kyuz0/vllm-therock-gfx1201:latest`) + Open WebUI, in one rootless Quadlet
**pod** (`north-llm.pod`) so they start/stop together over shared localhost. Hand-started
(`systemctl --user start north-llm-pod`), UI on 127.0.0.1:3000, API on 127.0.0.1:8000/v1.
Default model `Qwen/Qwen3.8-27B-FP8` (FP8, 8-bit — user prefers no Q4; TP=2, ctx **131072/128K**,
util 0.95). Follows kyuz0's `RedHatAI/Qwen3.6-27B-FP8` recipe but with far larger context: 3.8-27B
is `model_type qwen3_5`, a HYBRID (48/64 layers linear-attention, 16 full-attention) with native
`max_position_embeddings 262144`. Growing KV ≈ **0.0625 GB/1K fp16** (16 full-attn layers × 4 KV ×
256 × 2 × 2B) — a quarter of a classic 27B — so 128K ≈ 8 GB KV, 256K ≈ 16 GB KV, both fit the pair
atop ~27 GB FP8 weights. No rope-scaling (native), no fp8 KV needed. Headless launcher reproduces the
exec that kyuz0's interactive `start_vllm.py` ends in. **Shares the model store** with
lemonade at `~/.local/share/models/huggingface` (lemonade's cache volume was repointed there).

**First run 2026-08-16 — the hard part works.** On kyuz0 image `a69b6a95c6d3` (32 GB), vLLM
`0.22.1rc1.dev499`. Confirmed from the startup log:
- SETTLED: `qwen3_5` hybrid arch IS supported — `Resolved architecture:
  Qwen3_5ForConditionalGeneration`, loads the GDN linear-attention path (`Using Triton/FLA GDN
  prefill kernel`, splitting_ops include `mamba_mixer2`/`linear_attention`/`qwen_gdn_attention_core`).
  This was the top risk; it's gone.
- SETTLED: R9700 pinning works — launcher logged `HIP_VISIBLE_DEVICES=0,1` (iGPU excluded); the
  `grep -oE` parse of `rocm-smi --showproductname` survives this box's output.
- SETTLED: FP8 loads on gfx1201 — `quantization=fp8`, `Selected TritonFp8BlockScaledMMKernel`.
- SETTLED: dual-GPU RCCL init succeeds — `world_size=2`, ranks 0/1 assigned, `backend=nccl` (no
  hang → confirms NOT setting ROCR_/CUDA_VISIBLE_DEVICES was correct).
- SETTLED: ctx 131072 accepted (`Using max model len 131072`), chunked prefill on (16384).
- SETTLED: pod member auto-start — `systemctl --user start north-llm-pod` brought up infra +
  open-webui + (once its image was present) vllm; pod-level `PublishPort` published 3000+8000.
- SETTLED: kyuz0 rocm-env is baked into the image ENV (aiter/triton/fp8 all initialised without the
  launcher finding `/opt/scripts/01-rocm-envs.sh`) — the launcher's `source ... || true` guard is a
  harmless no-op; leaving it.

**SETTLED gotcha — the 32 GB image pull is hard-capped at 5 min.** First `systemctl start`
failed at exactly `5min 03s` (`vllm.service: Failed with result 'exit-code'`): the implicit pull
inside `podman run` under systemd is capped at 5m0s regardless of `TimeoutStartSec`. Fix (baked):
an `ExecStartPre=/bin/sh -c 'podman image exists … || podman pull …'` does a plain, uncapped pull
first (only when missing), and `TimeoutStartSec` bumped to 3600 to cover image + 27 GB model on
first run. Manual unblock was `podman pull docker.io/kyuz0/vllm-therock-gfx1201:latest`. NOTE: same
5-min exposure applies to `lemonade.container` (multi-GB image, `TimeoutStartSec=900`) — add the
same guarded pre-pull there if it ever fails first-start.

**COSMETIC:** `WARNING … Unknown vLLM environment variable detected: VLLM_MODEL` — our knob name
collides with vLLM's reserved `VLLM_*` namespace. Harmless (bash reads it before vLLM). Rename our
launcher knobs to a non-`VLLM_` prefix if the noise bothers.

**Startup slowness — SOLVED (persistent compile cache).** Each start was silent for ~6-8 min after
"Starting to load model": a full `torch.compile`+inductor+triton recompile of the 27B hybrid+FP8
graph, because kyuz0's image sets `VLLM_DISABLE_COMPILE_CACHE=1` (and our launcher did too). This
also made the load look "stuck" and tempted mid-load restarts (each throwing the compile away — the
apparent "5-min restart loop" was actually manual restarts, NOT any auto-killer: `Restart=no`,
`WatchdogUSec=0`, `TimeoutStartUSec=30min`, no timer, `Health=nil`). Fix (baked): launcher now sets
`VLLM_DISABLE_COMPILE_CACHE=0` + `VLLM_CACHE_ROOT`/`TORCHINDUCTOR_CACHE_DIR`/`TRITON_CACHE_DIR` under
a new persistent volume `~/.local/share/vllm/cache` (`/opt/vllm-cache`). First start compiles once
(~6-8 min); later starts ~1-2 min. Caches are version-hashed so an image bump recompiles cleanly.
`--enforce-eager` remains the escape hatch (skip compile, ~2 min start, ~10-20% slower gen).

- SETTLED — the stack works end to end (2026-08-16). `/v1/models` serves Qwen3.8-27B-FP8 at
  max_model_len 131072; a chat completion generated coherently. **`GPU KV cache size: 332,662
  tokens`** at 128K → ~2.5x concurrency, AND confirms the full native **256K fits** (262,144 <
  332,662, ~21 GB KV pool — matches the ~0.0625 GB/1K hybrid estimate). So `VLLM_MAX_MODEL_LEN=262144`
  is safe. Throughput: **~22 tok/s generation, ~630 tok/s prefill** on the pair (so a FULL 256K
  prompt is ~7 min of prefill — 128K is the sane default even though 256K fits).
- [ ] Explore `--enable-prefix-caching` for agentic coding (reuse KV of the unchanged prompt prefix
      across turns) — currently `enable_prefix_caching=False`; may be unsupported on the hybrid arch.
- [ ] vLLM ~22 tok/s vs the lemonade GGUF path, and whether MTP (`--speculative-config`) lifts it.
- [ ] Confirm the corrected KV estimate on-box (~0.0625 GB/1K fp16, hybrid) and push
      `VLLM_MAX_MODEL_LEN=262144` (native 256K, ~16 GB KV) — should still fit the pair. Measure
      actual per-card `mem_info_vram_used` at 128K and 256K; watch prompt-processing time growth.
- [ ] vLLM batched tok/s vs the lemonade GGUF path for a comparable model — the reason this
      stack exists. Also confirm Open WebUI auto-discovers the model at
      `http://localhost:8000/v1` once vLLM is up (it retries; may lag first start).
- [ ] Shared store sanity: after a vLLM pull, `ls ~/.local/share/models/huggingface/hub`
      shows it, and a later lemonade pull lands in the same `hub/` (no second copy).

### Wake-on-WLAN — `build_files/profiles/north/wol.sh`

The magic-packet trigger is armed declaratively by NetworkManager
(`/usr/lib/NetworkManager/conf.d/20-wake-on-wlan.conf`). Nothing about it can be
tested off the box. Driver support is confirmed in-tree — `rtw8922a.c` declares
`WIPHY_WOWLAN_MAGIC_PKT` in its `wowlan_stub` under `CONFIG_PM`.

Already ruled out, don't re-add: `ethtool -s <wlan> wol g` (mac80211's
`ieee80211_ethtool_ops` has no `set_wol` — returns EOPNOTSUPP on every mac80211
driver) and `iw dev ... set power_save off` (runtime power save, not a wake
trigger). Both look like they work because the failure is silent.

- [ ] The trigger is actually armed: `iw phy0 wowlan show` should report
      `Wake-on-WLAN is enabled: * magic packet`. If it says disabled, check
      `journalctl -u NetworkManager | grep -i wake` — NM logs an invalid default
      and falls back to `ignore`. The value has to be numeric `8`; the word
      `magic` parses as 0.
- [ ] End to end: `systemctl suspend`, then `wol <wlan-mac>` from another host on
      the same L2 segment. Must be the *Wi-Fi* MAC, and the sender must be on the
      same broadcast domain — this is not routable, so it won't work over
      Tailscale (a suspended box isn't running tailscaled anyway).
- [ ] If armed but not waking, the PCIe function may not be enabled as a wakeup
      source: `cat /sys/bus/pci/devices/<wifi-bdf>/power/wakeup`. Drivers arm this
      via cfg80211's `set_wakeup` op; whether rtw89 implements it is unverified. If
      it reads `disabled`, that's the gap — a udev rule writing `enabled` is the
      fix, and it belongs in `wol.sh`.
- [ ] Suspend type matters: confirm whether the box uses S3 or s2idle
      (`cat /sys/power/mem_sleep`). Under s2idle the wake is a PCIe interrupt
      rather than an ACPI event, and the ASUS BIOS WoL setting may only govern S3.

### Build

- [ ] If a build fails on a GPG mismatch, re-verify every pinned fingerprint with
      `build_files/scripts/lib/check-keys.sh` (it diffs pins against the live vendor
      keys and exits nonzero on drift).
