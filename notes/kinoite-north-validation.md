# kinoite-north — hardware notes

AMD 9900X, dual Radeon AI PRO R9700 (RDNA4 / gfx1201), ASUS ProArt B850-Creator
WiFi Neo. Validated on the real box across 2026-08-08 → 08-18, on kernel
7.1.7-200.fc44 with mesa 26.1.6. **Settled** records constraints and non-obvious causes
worth keeping;
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
can't help, since the prep command runs long after the probe.

**Still true after the 2026-08-18 on-demand change — more so (reconfirmed
2026-08-18).** The failure is a matter of *timing*, not mechanism: `global_prep_cmd`
fires when a client starts a stream, the probe runs at process launch, and Sunshine is
already dead by then. No command-driven display can ever satisfy it. Making the display
on-demand also un-enabled `sunshine-virtual-monitor.service`, which was the one thing
that put an output there at probe time, so on the current image the plug is the only
output present when Sunshine starts.

Ways to drop the plug, all untested. **Reordered 2026-08-18** — the persistent unit is
no longer the cheap option, because it is exactly what the GPU-idle fix removed:
- `video=<connector>:1920x1080@60e` ('e' overrides connect detection) in `kargs.d`.
  Now the preferred route: a kernel-forced connector is a real DRM output with **no
  userspace process holding a render node**, and it keeps KWin off the zero-output
  state the `down` guard exists to prevent. Cost is unchanged from today — the GPU
  driving it can't runtime-suspend, same as with the plug, so put it on a dGPU
  connector for the reason given above. Caveat to check first: `video=` matches by
  connector name (`DP-1`), and with three amdgpu devices those names are not globally
  unique — confirm which card actually takes the override.
- `drm.edid_firmware=<connector>:edid/<file>.bin` with a blob in
  `/usr/lib/firmware/edid/`, dumped from the plug itself. May need it in initramfs.
- Persistent `krfb-virtualmonitor` user unit on `graphical-session.target`, ordered
  before Sunshine, so an output exists at probe time. **Now the last resort:** krfb
  holds a DRM render node for as long as it runs, so this buys back the always-awake
  dGPU that disabling the unit eliminated (see the on-demand entry below). It also
  leaves a headless box one crash away from KWin at zero outputs. Would additionally
  need to coexist with the per-stream monitor — resize it rather than create a second.

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

**R9700 fan control — was broken, fixed by a vBIOS flash (2026-08-17).** Before the
flash, hwmon exposed `fan1_enable/target/input/min/max` but no `pwm1_enable` and no
`gpu_od/fan_ctrl/`, and reading `fan1_enable` returned EINVAL — fan control was dead
across LACT, rocm-smi and amd-smi alike, while undervolt/clock/power tuning kept working.
The flash changed the vBIOS OverDrive tables and fixed it, confirmed by setting idle fans
to 60% via LACT.

**The SMU interface mismatch is not what gated this, and never was.** It survives the
flash — `smu driver if version = 0x0000002e` vs `smu fw if version = 0x00000033`, 46 vs
51, a *wider* gap than the 46 vs 50 before — and both cards init fine either way. AMD's
ROCm#6078 position is correct on this point: the message is harmless. So on a future
kernel or firmware bump, do not use it as the health signal; it will always be there.
Check whether `gpu_od/fan_ctrl/` exists and whether writes take.

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

**Every OD node tested was irrelevant** — `minimum_pwm`, `zero_rpm`,
`acoustic_target_rpm_threshold` and `fan_target_temperature` all govern an *awake* card,
and the card was only awake because something was watching it. Still accurate for an
awake card:
- Idle is 1950–2050 RPM = exactly 30% of the 6500 max, dies ice-cold.
- `fan_minimum_pwm` OD_RANGE is `30 100`; writes below 30 error out.
- `fan_zero_rpm_enable` is an inert stub; `fan_zero_rpm_stop_temperature` is absent.
- `acoustic_target_rpm_threshold` (range `500 6500`, default 3500) and
  `fan_target_temperature` (default 100, range `25 105`) accept writes, commit without
  error, and do nothing — a silent no-op unlike the two that error loudly. Keep all
  four out of any LACT profile regardless.
- `pp_table` does not exist on gfx1201 — no soft PowerPlay override path.
- Ruled out as causes, each tested directly: the `amdgpu.ppfeaturemask=0xfff7ffff`
  karg, processes holding the DRM nodes, the HDMI audio function 06:00.1, and the
  kernel itself.
- **Retracted 2026-08-18:** "the persistent virtual monitor" was on that ruled-out list
  and shouldn't have been — the test ran with the pollers still active, which pin the
  cards regardless, so it proved nothing either way. krfb holds a render node and pins
  its backing GPU into D0 on its own; that's an independent second cause, not a
  competing explanation. Untested with the pollers stopped.

**Wrong claims previously recorded here as fact** — the first one you will meet again in
AMD's own tracker, so it's worth keeping refuted:
- "Fans are WONTFIX / a firmware floor with no fix." False; it was a poller. ROCm#6078's
  "the ~30% default curve is intended" remains AMD's position and remains not the reason
  for this box's noise.
- "amdgpu never enables runtime PM on these cards." False; it does.
- "The bigmalloy D0/runtime-PM fix is a no-op." Unproven — the A/B ran on the display
  card, which was legitimately always D0, so it never tested the headless card.

**The virtual monitor could leave the box with no display — FIXED 2026-08-18.** Found in
the wild as `HDMI-A-3` **connected but disabled**; it presented as "the iGPU doesn't work
on north". Root cause was a storage-location mistake, not the disabling itself:
`--exclusive` recorded which outputs it turned off in `$XDG_RUNTIME_DIR` (tmpfs), while
the damage it was undoing — KDE's disabled-output state in
`~/.config/kwinoutputconfig.json` — persists on disk. Any abnormal end to a stream
destroyed the restore list and kept the outputs off. **The general rule: restore state
must outlive whatever it restores.**

Fixed by moving `DISABLEDFILE`/`PRIMARYFILE` to `$XDG_STATE_HOME/sunshine-vm/` (`PIDFILE`
deliberately stays in the runtime dir — a PID from a previous boot is worse than none),
plus a login-path safety net that re-enables every connected output when none are on.

Recovery if it recurs: `kscreen-doctor output.HDMI-A-3.enable`. Note a `systemctl
--global enable` cannot be undone with `systemctl --user disable` — it needs
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
- **Check for stray `power/control=on` pins before trusting any idle measurement** —
  `/etc/tmpfiles.d/` and `/etc/udev/rules.d/`. One left behind by a #6101 D3 test on
  2026-08-17 forbade runtime suspend on 06:00.0 across every reboot, and hours of
  "06:00.0 never suspends" turned out to be measuring the pin. Nothing equivalent is
  baked in the image.
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

**Windows / WSL2 escape hatch — evaluated and rejected (2026-08-17).** The whole case
rested on noise, which turned out to be a polling daemon (see SOLVED), so the decision is
settled: **stay on native Linux dual-card and move the box out of earshot** — Sunshine +
WoL + Tailscale are already in place for exactly that. Dual-boot is the middle path if
quiet gaming sessions ever matter. The findings that outlived the decision:
- **FP8 27B is two-card-only.** Weights ≈ 27 GB fill a 32 GB card with no room for KV.
  That is *why* TP=2, independent of WSL.
- **Dual-GPU is what WSL2 least reliably delivers.** ROCm-on-WSL is preview/limited-
  validation, and gfx1201 multi-GPU RCCL is already fragile on *native* Linux — open TP=2
  deadlock issues on dual R9700 (vllm-project/vllm#40980, ROCm/rocm-systems#5480; both
  GPUs 100%, TP=1 fine). Our working TP=2 sits on the lucky side of a known-rocky feature.
- **The container model doesn't port.** WSL2 has no `/dev/kfd` — GPU goes via `/dev/dxg`
  and a WSL-specific ROCm runtime, so the rootless Quadlets need rework, not a lift.
- **llama.cpp gets the same hybrid KV saving vLLM does.** `llama_memory_hybrid`
  (Jamba-derived) extended to the qwen3_5 GDN arch: only full-attention layers keep a KV
  cache, so ~0.0625 vs dense 0.25 GB/1K. Bleeding-edge — confirm the hybrid path actually
  engages on load (grep the log for linear-attention/GDN) rather than silently falling
  back to dense. Single-card sizing at 32 GB with it: Q6_K 27B @128K ≈ 31 GB (tight),
  Q5_K_M @128K ≈ 29 GB; 256K needs KV quant.
- Gotcha: llamacpp-rocm#96 — gfx1201 segfaults if the iGPU is also visible to ROCm.

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
is why the backend gap is only ~20%. A remembered ~40 on Bazzite was likely **vLLM**
(PyTorch/HIP), which shares nothing with llama.cpp's hand-written HIP backend but the name.

**CORRECTION 2026-08-20 — the "MTP puts ROCm above the naive ceiling" clause was wrong**
and is struck. No MTP was configured when those numbers were taken: there is no
`--spec-type`, no `-md` and no `draft` checkpoint in `lemonade.sh` or in the seeded
recipes, so the low-30s figures are plain unspeculated decode sitting just under the
bandwidth ceiling, exactly as the rest of the paragraph says. The "MTP draft state"
mentioned in the layer-split note above was a misreading of resident VRAM.

Measured properly, driving `llama-server` directly on the R9700 pair (Qwen3.8-27B-UD-IQ4_XS,
14.0 GB, `-ngl 99 -c 32768`, HIP_VISIBLE_DEVICES=0,1, 512-token runs):

| config | rust | python | prose | MEAN |
| --- | --- | --- | --- | --- |
| baseline, no speculation | 30.45 | 30.43 | 30.33 | **30.40** |
| `--spec-type draft-mtp -md mtp-Qwen3.8-27B-Q4_0.gguf -ngld 99 --spec-draft-n-max 4` | 53.92 | 65.25 | 51.41 | **56.86** |

**+87%.** Draft acceptance 0.45–0.67, mean accepted length 2.8–3.7. The shipped
rocm-nightly build supports the whole feature set already (`--spec-type`, `-md`, `-ngld`,
`--spec-draft-n-max`, `--spec-draft-p-min` are all in `--help`) — it was never switched on.

Note the baseline is dead flat across workloads (30.45/30.43/30.33), the signature of a
purely bandwidth-bound loop; the MTP arm varies a lot (51–65) because acceptance is
workload-dependent. 30.40 tok/s on 14.0 GB works out to ~426 GB/s effective, i.e. ~67% of
the 640 GB/s spec — llama.cpp's HIP backend leaves real bandwidth on the table here, which
is worth remembering before attributing any llama.cpp-vs-vLLM gap to quantisation alone.

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

All three display checks below were closed against the pre-2026-08-18 design and reopened
with it: the display is no longer persistent, `undo` is `down` rather than `ensure`, and a
SIGKILL now skips a teardown that actually matters. Nothing here has run on the box.

- [ ] Crash safety, the one that matters most: `systemctl --user kill -s KILL
      app-dev.lizardbyte.app.Sunshine.service` mid-*exclusive* stream, then confirm
      `ExecStopPost` drops the monitor and re-enables the physical output. Reboot after
      it and confirm the outputs are still on — that second leg is what proves the
      `$XDG_STATE_HOME` restore-list fix. Failure here means a black desk.
- [ ] Clean restore on normal disconnect — physical output back, previous primary
      restored (`down` is what reads `$PRIMARYFILE`; `ensure` never did), desk window
      layout intact after `--exclusive`.
- [ ] `ExecStopPost` is now `down`, was `ensure` (fixed 2026-08-18). `ensure` creates the
      monitor when none exists, so stopping Sunshine without ever streaming spawned krfb
      on the way out and pinned a GPU awake. Check: `systemctl --user stop
      app-dev.lizardbyte.app.Sunshine.service` after a login with no stream, then confirm
      no `krfb-virtualmonitor` survives and both dGPUs reach `runtime_status: suspended`.
- [ ] Refresh rate follows the client: a 120Hz client should get `addCustomMode` +
      `mode` applied (krfb only ever creates the monitor at 60Hz). Only 60Hz seen
      so far, where the mode already exists and `addCustomMode` is correctly
      skipped. Check `kscreen-doctor -o` mid-stream for the `*` on `WxH@120.00`.

### GPU — `build_files/profiles/north/amdgpu.sh`, `tuning.sh`

- [x] **`70-kfd.rules` HURT — REMOVED 2026-08-22.** The base rules do ship kfd:
      `systemd-udev`'s own `/usr/lib/udev/rules.d/50-udev-default.rules:62` has
      `SUBSYSTEM=="kfd", GROUP="render", MODE="0666"`. Our `MODE="0660"` was therefore
      tightening it and handing the access back only via `uaccess`/`render` — which is
      what made `usermod -aG render` look necessary for headless SSH. Rule deleted from
      `amdgpu.sh`, README advice dropped. On-box before removal:
      `/dev/kfd 660 root render`, `/dev/dri/renderD12[89],130 666 root render`.
- [x] Fan control works post-flash; fan OD nodes all tested and all irrelevant; the
      ~1950 RPM floor was `coolercontrold` + `lactd` polling, not firmware; CoolerControl
      dropped from `motherboard.sh`. All four resolved 2026-08-17/18 — see Settled.
      Operationally: keep every OD node out of the LACT config, leave LACT on
      **Automatic**.
- [x] **LACT vs quiet idle — ANSWERED 2026-08-22: the poll interval IS configurable.**
      `/etc/lact/config.yaml` carries `interval_ms: 500` (per profile) — LACT polls twice
      a second, faster than the 1 s assumed, and it is a plain config key. Setting it well
      past the 5 s autosuspend delay should let the dGPUs idle between polls; that trade
      has not been measured, but "can it poll politely" is answered: yes, edit
      `interval_ms`. Confirmed too that polling is the whole story — with `lactd` not
      running, both R9700s sit at `runtime_status=suspended` (~645 s accumulated) while
      the iGPU stays `active` driving the desktop.
      Note the box currently has `lactd` **disabled**, though `tuning.sh:47` enables it
      in the image — so this is a local override, not the shipped default.
- [x] Virtual monitor: no-display bug fixed and the display moved to on-demand
      (2026-08-18) — see Settled. Both are code-complete and neither has run on the box;
      the hardware checks live under Sunshine above.
- [ ] Undervolt is the actual tuning goal (not a fan curve). The ppfeaturemask karg
      already baked is what unlocks the mV offset — no karg change needed. Tune a
      per-card negative GPU voltage offset in LACT (start −50 mV, step −25 mV under
      sustained load until unstable, back off one step; two dies may differ), pair
      with the existing 210 W PPT cap, confirm stable across a reboot via
      `/etc/lact/config.yaml`, THEN bake the proven offsets into `tuning.sh`. Bake
      only after load-testing — a too-aggressive offset would make a fresh install
      unstable at boot.
- [x] **HDR — the blocker is GONE as of 2026-08-22; what's left is a preference.**
      RPM Fusion has caught up: `mesa-vulkan-drivers-freeworld 26.1.7-1.fc44` in
      *RPM Fusion - Free - Updates* matches the installed Fedora `mesa-vulkan-drivers
      26.1.7-1.fc44`, so swapping no longer downgrades the Vulkan driver on RDNA4.
      Still not swapped because nothing here needs `VK_hdr_layer` yet — it is now a
      straight "do you want gamescope HDR" call, not a technical objection. `codecs.sh`
      updated to say so. Re-check the versions still match before swapping; the gap can
      reopen.

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

- [x] **`TAG+="uaccess"` did land on `/dev/kfd` — CONFIRMED 2026-08-22, and now moot.**
      With a seat0 session present, `getfacl -p /dev/kfd` showed `user:north:rw-`, so
      logind does seat-assign this non-DRM device. Moot because the rule that set the tag
      has been removed: at the base 0666 no ACL is needed. Recorded so nobody re-derives
      it if a rule is ever reconsidered.
- [x] **`keep-id` works — CONFIRMED 2026-08-22.** `ls -ln` on the model store shows
      `hub/` and `xet/` owned by `1000:1000`, and the lemonade `config/`, `llama/`,
      `huggingface/` dirs likewise — not subuids. `/etc/subuid` reads
      `north:524288:65536`, comfortably sized past 10001. The bind mounts are yours to
      inspect and prune as intended.
- [ ] `GroupAdd=keep-groups` — **now believed unnecessary; candidate for deletion.** Its
      own precondition was "only matters if `/dev/kfd` isn't 0666 *and* the box is driven
      headless", and `/dev/kfd` is 0666 (see the GPU section). Left in place rather than
      removed blind, since it is also known-flaky in rootless Quadlets
      (containers/podman#27876, #28364). Delete it the next time lemonade is exercised
      headless and proven to work without it.
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
      across turns) — **still open, not settled 2026-08-22.** Confirmed from the startup log that
      it is off (`enable_prefix_caching=False`) and that the hybrid path is active
      (`Setting attention block size to 800 tokens to ensure that attention page size is >= mamba
      page size`), but nothing in the log says *why* it is off. Testing it needs a launcher flag
      that `vllm-serve.sh` does not expose, and the quadlet's `ExecStartPre` reinstalls the
      launcher from `/usr` on every start — so a hand-edited copy is overwritten. To actually try
      it: shadow the quadlet, drop that `ExecStartPre` line, and add `--enable-prefix-caching` to
      the launcher copy in `~/.local/share/vllm/bin/`.
- [x] **vLLM vs the lemonade GGUF path, and whether MTP lifts it — ANSWERED 2026-08-20.** MTP lifts
      it enormously, and the knob that mattered was not "on/off" but `num_speculative_tokens`, which
      had been pinned at 1 on a misreading of `mtp_num_hidden_layers` (that field is the draft
      head's DEPTH, not a cap on speculation width; `vllm/config/speculative.py:765-780` only
      requires k to be divisible by it, and everything divides by 1). Sweep at batch 1, FP8, TP=2,
      512-token runs, decode timed first-token-to-last:

      | k | rust | python | prose | MEAN | accept_len | per_draft_token |
      | --- | --- | --- | --- | --- | --- | --- |
      | 1 | 38.41 | 39.22 | 36.75 | 38.13 | 1.853 | 0.853 |
      | 2 | 49.14 | 50.78 | 46.22 | 48.71 | 2.554 | 0.777 |
      | **3** | 55.17 | 57.99 | 49.51 | **54.22** | 3.038 | 0.679 |
      | 4 | 56.25 | 60.19 | 50.64 | 55.69 | 3.298 | 0.575 |

      Knee at 3 (+42% over k=1); k=4 adds 2.7% for 33% more draft compute at much worse acceptance.
      **Baked as the launcher default.** Head-to-head with llama.cpp on the same pair, same day:
      vLLM FP8 (27.8 GB) k=3 = **54.22**, llama.cpp IQ4_XS (14.0 GB) MTP = **56.86**. llama.cpp
      reads half the bytes per token and wins by ~5%; the quantisation advantage is almost entirely
      cancelled by vLLM being the more efficient engine. Neither is "the fast one".
- [x] **256K works, and the KV estimate holds — MEASURED 2026-08-22.** Ran the shipped stack at
      `VLLM_MAX_MODEL_LEN=262144`: it loads, serves, and generates correctly. Both runs at the
      image's `num_speculative_tokens=1`, so they are comparable:

          128K   GPU KV cache 314,572 tokens   max concurrency 2.40x
          256K   GPU KV cache 332,781 tokens   max concurrency 1.27x   28,447 MiB/card

      KV cost: 11.01 GiB/rank for 332,781 tokens = **0.033 GiB per 1K tokens per rank**, i.e.
      ~0.066 GiB/1K across the TP pair — the ~0.0625 GB/1K estimate was right to within ~6%.

      The important correction: **256K does not cost VRAM, it costs concurrency.** Per-card usage
      barely moves (~28.1 → ~28.4 GiB) because `gpu_memory_utilization=0.95` is a *budget*, not a
      demand — the KV pool is whatever fits in it either way. Raising `max_model_len` only lets one
      request consume more of that fixed pool, so full-context concurrency drops 2.40x → 1.27x.
      Enable it via a shadowed quadlet if you want the long context; there is no memory reason not
      to, only a batching one.
- [x] **vLLM batched tok/s — MEASURED 2026-08-20.** 4 concurrent x 384 tokens, released from a
      barrier so they genuinely overlap, `ignore_eos` so every stream is the same length, median of
      3 reps: aggregate **139.02 tok/s at k=1 → 187.11 at k=3 (+35%)**, per-stream 33.2-37.6 →
      48.0-59.7. So raising k does NOT cost anything at batch >1, which was the real risk in making
      k=3 the default (wrong guesses waste compute, and that waste normally scales with batch).
      Long context, same method: ~9.5k prompt 33.14 → 47.55, ~38k prompt 20.83 → 29.08.
      Caveat on those single-stream controls (40.76 at k=1, 67.58 at k=3): `ignore_eos` pushes the
      model into low-entropy filler past its natural stop, which MTP predicts unrealistically well.
      Fine for an A/B where both arms do it, not a number to quote — use the k-sweep table above.
      **Context is not free once you speculate:** 67.6 short → 47.6 at ~9.5k → 29.1 at ~38k. The
      "dead flat in context" finding holds for the NON-speculative baseline only.
- [x] **Open WebUI → vLLM path confirmed 2026-08-22.** From inside the pod's network namespace
      (`nsenter -t $(podman inspect north-llm-infra --format '{{.State.Pid}}') -n`),
      `http://localhost:8000/v1/models` returns `Qwen/Qwen3.8-27B-FP8` — and that is exactly the
      address open-webui is configured with (`OPENAI_API_BASE_URL=http://localhost:8000/v1`,
      `ENABLE_OLLAMA_API=false`, both verified via `podman inspect`). Open WebUI's own
      `/health` answers `{"status":true}`. Scope: this proves the network + config path; the UI
      actually *listing* the model is unverified because `/openai/models` returns
      `Not authenticated` and confirming it would mean creating an account on the box.
      Note `podman exec` into these containers fails under `runuser` (`OCI permission denied`
      writing the payload cgroup) — no session cgroup delegation. Use `nsenter` on the infra
      container instead, or a real login session.
- [x] **Shared store — CONFIRMED 2026-08-22.** One `hub/` holds both runtimes' models:
      `models--Qwen--Qwen3.8-27B-FP8` (vLLM) next to `models--unsloth--*-GGUF`
      (lemonade), 41 GB total, no second copy.

### Wake-on-WLAN — `build_files/profiles/north/wol.sh`

The magic-packet trigger is armed declaratively by NetworkManager
(`/usr/lib/NetworkManager/conf.d/20-wake-on-wlan.conf`). Nothing about it can be
tested off the box. Driver support is confirmed in-tree — `rtw8922a.c` declares
`WIPHY_WOWLAN_MAGIC_PKT` in its `wowlan_stub` under `CONFIG_PM`.

Already ruled out, don't re-add: `ethtool -s <wlan> wol g` (mac80211's
`ieee80211_ethtool_ops` has no `set_wol` — returns EOPNOTSUPP on every mac80211
driver) and `iw dev ... set power_save off` (runtime power save, not a wake
trigger). Both look like they work because the failure is silent.

- [x] **Trigger is armed — CONFIRMED 2026-08-22.** `iw phy0 wowlan show` reports
      `WoWLAN is enabled: * wake up on magic packet`, so the numeric `8` in the NM
      connection default parsed correctly.
- [x] **End to end — WORKS, confirmed 2026-08-22.** `systemctl suspend` then a magic
      packet to the Wi-Fi MAC from a host on the same L2 segment woke the box, across
      several suspend/resume cycles. Still not routable, so it will not work over
      Tailscale (a suspended box isn't running tailscaled anyway) — the sender has to be
      on the same broadcast domain.

      **WoL recovers a SUSPENDED box, not a HUNG one.** The wedge documented under the LLM
      suspend hook below — suspend with a model loaded and the hook off — leaves the
      machine powered with the network dead, and no magic packet reaches it; only the
      power button does. That asymmetry is the practical reason the hook is
      `RequiredBy=sleep.target`: a hook that cannot do its job refuses the suspend and
      leaves the box awake and reachable, rather than suspending into a state you cannot
      recover remotely.
- [x] **PCIe wakeup source — CONFIRMED 2026-08-22, no udev rule needed.**
      `0000:0d:00.0` (`rtw89_8922ae`, `wlp13s0`) reads `power/wakeup = enabled`, so
      rtw89 does implement cfg80211's `set_wakeup`. The feared gap does not exist.
      For contrast both r8169 NICs (`eno1`, `eno2`) read `disabled` — if wired WoL is
      ever wanted, that is where a udev rule would go.
- [x] **Suspend type — ANSWERED 2026-08-22: `deep` (S3), not s2idle.**
      `cat /sys/power/mem_sleep` → `s2idle [deep]`. So the wake is an ACPI event and the
      ASUS BIOS WoL setting is the relevant one. See the LLM suspend hook section below,
      where the same fact decides the VRAM eviction path.

### LLM suspend hook — `build_files/profiles/north/services-north.sh`

`kinoite-llm-sleep.service` stops the LLM stacks before sleep and restores what was
running on resume. **Verified end to end 2026-08-22**: three real S3 cycles with a model
loaded, plus the negative control below. Nothing here is open.

**Why it is mandatory, not a nicety.** A loaded `Qwen/Qwen3.8-27B-FP8` holds ~28.1 GiB on
each R9700 — ~56 GB against 62.8 GB of RAM — and `/sys/power/mem_sleep` is `deep`, so S3
takes the full amdgpu eviction path. `pre` drains both cards to ~57 MiB in 2-3 s, and
ExecStart completes ~23 ms before `PM: suspend entry`.

**The failure it prevents is a hard hang, not a failed suspend.** Negative control, hook
disabled, model loaded: the kernel log ends and never resumes —

    PM: suspend entry (deep)
    Filesystems sync: 0.009 seconds
    <nothing>

Every *successful* cycle continues `Freezing user space processes` → `PM: suspend devices
took 0.116 seconds` → `PM: suspend exit`. The wedge dies in the device-suspend phase with
no error, no OOM, no eviction warning. At the desk: powered, fans audible, blank monitor,
no network; only a held power button recovers it. Nothing is lost (ostree + persistent
journal). **This is why the unit is `RequiredBy=sleep.target`** — a soft `Wants=` would let
a failed hook suspend into that hang. It also means opting out is `systemctl disable`, not
`mask`; masking leaves sleep.target requiring a masked unit and the box cannot suspend.

Constraints worth not re-discovering:

- **`systemctl --user --machine=<user>@.host` does not work on this image.** sd-bus
  implements it by spawning a transient system unit running `systemd-stdio-bridge`
  (`-pUser=… -pPAMName=login`), and that spawn fails with `Connection reset by peer`.
  `systemd-run -M` fails identically, so it is not systemctl; zero AVCs, so not SELinux.
  Root exporting `XDG_RUNTIME_DIR` and calling `systemctl --user` is refused too, and
  systemd's own hint is to use `--machine`. What works, including from a service context
  (`initrc_t`): `runuser -u <user> -- env XDG_RUNTIME_DIR=/run/user/<uid> systemctl --user`.
  `setpriv` works too and skips the PAM session pairs that runuser logs. runuser inherits
  the caller's cwd, hence the `cd /` in the helper.
- **systemd freezes `user.slice` across sleep** (`Successfully froze/thawed unit
  'user.slice'`). That rules out a `/usr/lib/systemd/system-sleep/` drop-in, which runs
  inside `systemd-suspend.service` — inside the frozen window — and is why the hook is a
  unit ordered `Before=sleep.target` instead.
- **Quadlet dependency directions** (podman 5.8.4): members get
  `BindsTo=north-llm-pod.service`, the pod gets `Wants=` + `Before=` its members, and
  `Upholds=` is empty everywhere. So stopping the pod tears down members, and starting any
  one member starts *both*.
- **`StopWhenUnneeded=yes` self-stops a manually started unit** (~40 ms), so `systemctl
  start kinoite-llm-sleep` runs both edges back to back and is not a pausable test — call
  `kinoite-llm-sleep pre` / `post` directly. The real path is unaffected: during a sleep
  cycle sleep.target holds a reference until resume.
- **Hibernate is unavailable.** `/sys/power/state` is `freeze mem` with no `disk`, and
  logind logs `Lockdown: … hibernation is restricted`. Secure Boot lockdown, not config.


### Build

Standing procedure, not a verification: if a build fails on a GPG mismatch, run
`build_files/scripts/lib/check-keys.sh` — it diffs the pins against the live vendor keys
and exits nonzero on drift. Last run 2026-08-22: **all 6 pinned keys match** (bazzite-org,
pvermeer/sunshine, ilyaz/LACT, 1Password, Google Chrome x9, Tailscale x2).
