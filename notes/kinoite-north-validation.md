# kinoite-north — hardware notes

AMD 9900X, dual Radeon AI PRO R9700 (RDNA4 / gfx1201), ASUS ProArt B850-Creator
WiFi Neo. Validated on the real box, currently kernel 7.1.9-200.fc44.x86_64 with mesa 26.1.7.
**Settled** records constraints, dead ends and non-obvious causes — things that would cost
real work to rediscover. **Open** is what is left to verify. Code that depends on an open
item carries a `TODO(hardware):` comment pointing here.

## Settled

**Never bake a card, renderD or device index.** DRM numbering reshuffles across kernels
and boots; only the PCI address is stable (observed twice with different numbering).

| PCI | GPU | `gfx_target_version` |
|---|---|---|
| 03:00.0 / 06:00.0 | R9700 (Navi 48) | 120001 |
| 10:00.0 | iGPU (Granite Ridge) | 100306 |

Re-derive with `ls -l /dev/dri/by-path/`, `lspci -nn`, and `grep -H gfx_target_version
/sys/class/kfd/kfd/topology/nodes/*/properties`. Per-GPU VRAM in use reads from
`/sys/class/drm/card*/device/mem_info_vram_used`.

**The display cable decides which GPU does everything.** The output owns the compositor and
the VAAPI device follows it — with the dummy plug on the motherboard HDMI, Sunshine encoded
on the iGPU. Moving it to an R9700 port fixed that and brought AV1 encode. `adapter_name` is
the wrong fix: it repoints only the encoder, leaving the compositor on the iGPU and the
cross-GPU copy in place. Keep the plug on a dGPU. Cost: that R9700 then owns compositing and
coil-whines on UI animations (disabling desktop animations stops it); harmless, not a fault.

**A dummy plug is required, but only for Sunshine's startup probe.** With no output KWin
keeps running with zero outputs; what dies is the encoder probe at launch (`[kwingrab] no
wl_output found` → `Fatal: Unable to find display or encoder`). This is a *timing* problem,
not a mechanism one: `global_prep_cmd` fires when a client connects, long after the probe,
so **no command-driven display can ever satisfy it.** Ways to drop the plug, all untested:

- `video=<connector>:1920x1080@60e` in `kargs.d` — preferred: a real DRM output with no
  userspace process holding a render node. Caveat: `video=` matches by connector name and
  with three amdgpu devices those names are not unique; confirm which card takes it.
- `drm.edid_firmware=<connector>:edid/<file>.bin` with a blob in `/usr/lib/firmware/edid/`.
  May need it in initramfs.
- Persistent `krfb-virtualmonitor` unit ordered before Sunshine. Last resort: krfb holds a
  render node the whole time it runs, which buys back the always-awake dGPU that going
  on-demand eliminated.

**Why the Sunshine config is seeded — don't "simplify" it away.** Default `kms` capture
enumerates DRM connectors only, so it discarded the virtual monitor (`Unknown Monitor
connector type`) and silently streamed the physical panel. Hence `capture = kwin`,
`output_name` and `global_prep_cmd` seeded from `ExecStartPre`. The Arch-only
`CAP_SYS_NICE` bug doesn't apply (Fedora sets `%caps(cap_sys_nice=ep)` on `kwin_wayland`),
and `KWIN_WAYLAND_NO_PERMISSION_CHECKS=1` is not needed. Seeding only ever adds *missing*
keys — an existing `sunshine.conf` keeps a stale `undo … ensure`; fix it in the Web UI or
delete the `global_prep_cmd` line and let it re-seed.

**`--exclusive` is needed in practice.** Making the virtual output primary governs only
*new* windows; disabling the physical outputs is what migrates existing ones.

**Restore state must outlive whatever it restores.** `--exclusive` recorded disabled outputs
in `$XDG_RUNTIME_DIR` (tmpfs) while the damage it undid — KDE's
`~/.config/kwinoutputconfig.json` — persists on disk, so any abnormal end to a stream left
outputs off permanently. It presented as "the iGPU doesn't work". Fixed by moving state to
`$XDG_STATE_HOME/sunshine-vm/` (`PIDFILE` deliberately stays in the runtime dir — a PID from
a previous boot is worse than none) plus a login-path net that re-enables connected outputs
when none are on. Recovery: `kscreen-doctor output.HDMI-A-3.enable`. Note a `systemctl
--global enable` cannot be undone with `--user disable`; it needs `--user mask`.

**The virtual monitor is on-demand, not at login.** krfb pins whichever GPU backs it into
D0 for as long as it runs. So `sunshine-virtual-monitor.service` ships un-enabled (still the
right answer for a genuinely headless box), the seeded `undo` is `down` rather than `ensure`
so the monitor dies with the stream, and `down` refuses to run when no physical output is
*connected* so it cannot strand a headless box.

**The ~1950 RPM "fan floor" was never firmware — it was pollers.** 1950–2050 RPM is what an
*awake* R9700 does. `coolercontrold` and `lactd` each read GPU hwmon about once a second,
and every amdgpu hwmon read calls `pm_runtime_get_sync()` / `mark_last_busy()`, so a 1 s
poll against the 5 s autosuspend delay resets the timer forever. Stop them and both cards
suspend within 30 s, after which `sensors` reports `fan1: N/A` — which is correct, not an
error: hwmon registers are unreadable on a powered-down card. CoolerControl was dropped from
the image (it couldn't drive this board's NCT6701D anyway); LACT stays because it applies the
power cap and undervolt. Still worth keeping refuted, because you will meet it again in AMD's
own tracker: ROCm#6078's "fans are WONTFIX / an intended ~30% curve" is **not** the reason
for this box's noise.

**R9700 fan control needed a vBIOS flash.** Before it, hwmon exposed `fan1_*` but no
`pwm1_enable`, no `gpu_od/fan_ctrl/`, and `fan1_enable` returned EINVAL — dead across LACT,
rocm-smi and amd-smi alike, while undervolt/clock/power tuning kept working. **The SMU
interface mismatch is not the health signal** — driver 0x2e vs fw 0x33 survives the flash and
both cards init fine. Check whether `gpu_od/fan_ctrl/` exists and whether writes take.

Firmware baseline to diff against after a bump: R9700 vBIOS `115-G287BP00-100` build
00180814, SMC `0x00684f00`; iGPU `102-RAPHAEL-008`, SMC `0x00625400`. Read with `sudo sh -c
'cat /sys/kernel/debug/dri/*/amdgpu_firmware_info'` — the glob must be expanded *by root*
(`/sys/kernel/debug` is 0700, so `sudo cat` with a shell glob fails with ENOENT). Note
`<smu_v14_0_0>` in dmesg is the generic IP block version, not which `smu_v14_0_*_ppt.c`
drives the card.

**`MODE1 reset` on the resume path is expected noise, not a hang.** Real trouble looks like
ring timeouts, or a reset with no surrounding `PM: suspend entry`/`exit`.

**Every fan OD node is irrelevant, and some fail silently.** They govern an *awake* card, and
the card was only awake because something watched it. `fan_minimum_pwm` OD_RANGE is `30 100`
(writes below 30 error); `fan_zero_rpm_enable` is an inert stub; `acoustic_target_rpm_threshold`
and `fan_target_temperature` accept writes, commit without error, and do nothing. Keep all
four out of any LACT profile. `pp_table` does not exist on gfx1201 — no soft PowerPlay
override. Also ruled out as causes: the ppfeaturemask karg, processes holding DRM nodes, the
HDMI audio function, and the kernel itself.

**`kargs.d` did not deliver the powerplay karg — the mechanism is unexplained.**
`/usr/lib/bootc/kargs.d` is read by `bootc install`/`switch`/`upgrade` and by nothing else;
`rpm-ostree rebase`/`upgrade` ignores the directory outright. That was the original explanation
recorded here, and it is wrong: this box updates with `bootc upgrade` —
`bootc-fetch-apply-updates.timer` active and enabled, `rpm-ostreed-automatic.timer` masked, in
place since 2026-03-04 — while all three entries (`10-amdgpu`, `20-sensors`, `30-gaming`) were
added 2026-08-08 through 2026-08-23. All three sat in `/usr` while `/proc/cmdline` carried only
`split_lock_detect=off`. Re-measured 2026-08-24: `20-sensors` is still absent from the booted
*and* staged deployments, so it is not a pending-reboot artifact. Nothing logs the omission.

The cost was the entire GPU tuning story. Without `amdgpu.ppfeaturemask` there is no
`pp_od_clk_voltage` and no `gpu_od/` directory at all, so LACT drops the voltage offset with
`custom clock settings are present but will be ignored, could not get clocks table … Could not
read file pp_od_clk_voltage` at ERROR, once per card, and keeps running as if healthy. Both cards
also read `power1_cap = 300000000` (stock) rather than the configured 210 W, because `lactd` is
disabled locally. **The undervolt in `/etc/lact/config.yaml` had never executed a single time.**

Note this does *not* contradict "ruled out as causes" above — the karg was correctly ruled out as
a cause of the ~1950 RPM floor. It is the cause of the missing OD nodes, which is a different
question, and it also makes the earlier "vBIOS flash fixed fan control" reading unsafe: `gpu_od/`
is OverDrive-gated, so an absent `gpu_od/fan_ctrl/` cannot distinguish a firmware limitation from
a locked OverDrive. Re-test fan control only with the karg live.

**ANSWERED 2026-08-25 — it was the locked OverDrive, not the firmware.** With the karg live
(`rpm-ostree kargs` fix applied, `amdgpu.ppfeaturemask=0xfff7ffff` on `/proc/cmdline`),
`gpu_od/fan_ctrl/fan_curve` is present on both cards, reads five `0C 0%` points and an `OD_RANGE`
of `25C-100C` / `30%-100%`, and accepts a curve: writing `45:40 55:55 65:70 75:85 85:100` through
`kinoite-gpu-tune` took both cards from 33-39% PWM at 88-93C hotspot to 89% PWM at 70-78C under an
unchanged vLLM load. So fan control is fully available and the "vBIOS flash fixed it" reading can
be retired. The one thing the curve still cannot do is go **below** ~30% on an awake card — that
is the `fan_minimum_pwm` firmware floor and the real source of the ~1950 RPM figure, which stands
as previously recorded.

Fix is one command per machine, `rpm-ostree kargs --append=amdgpu.ppfeaturemask=0xfff7ffff` plus a
reboot: that writes it into the ostree deployment, which persists across updates from either tool.
Keep the kargs.d file anyway — it is still correct for a fresh `bootc install`.

Loose end from the same probe: `acpi_enforce_resources=lax` never landed either, yet `nct6775` is
loaded and `sensors` reports `nct6799-isa-0290` with fan RPM. That karg looks unnecessary on this
board/kernel — a candidate for removal from `motherboard.sh`, unverified.

**The undervolt does not survive an idle cycle. The power cap does.** Measured 2026-08-23 with the
karg live, `lactd` stopped, and both values written by hand straight to sysfs, so LACT is not in
the picture at all. Apply `power1_cap=210000000` and `vo -25`+`c` to an awake card, let it
runtime-suspend (~9-12 s), wake it, re-read: the cap is still 210 W, `OD_VDDGFX_OFFSET` is back to
`0mV`. Reproducible over two consecutive cycles. So amdgpu restores the power cap across a D3→D0
transition and drops the OverDrive table.

**The fan curve goes the same way.** A committed 5-point curve reads back as `0C 0%` on all
five points after one idle cycle. It is the same OverDrive table, so the rule is simply: *`power1_cap`
is durable, everything in the OD table is not.*

This is the fact the whole tuning design has to be built around, and it is not a suspend/resume
edge case — it fires every time the cards go idle for ten seconds, many times a day. A "set it and
forget it" undervolt or fan curve is impossible here. What *is* possible is re-applying the offset once the
card is awake for a workload: a loaded vLLM pins both cards in D0 for the life of the session, so
an offset applied after the model loads holds for exactly as long as it matters. At idle the card
is in D3 drawing nearly nothing, where an undervolt buys nothing anyway.

**`lactd` reverts the power cap when it stops.** `systemctl stop lactd` → `power1_cap` goes
straight back to 300000000 on both cards. README used to claim "already-applied settings persist";
it does not. That rules out any "start LACT, let it apply, stop it" design, and it means LACT can
only own a setting for as long as LACT is resident.

**LACT 0.10.0 no longer holds the dGPUs awake — the old finding is superseded.** With `lactd`
resident, no GUI client, `fan_control_enabled: false`, and the LLM stack down, both R9700s sat at
`runtime_status=suspended` for a straight 100 s sample. The earlier measurement stands for whatever
version was installed at the time; upstream #828 was fixed by PR #836 and v0.8.4 carries "the
daemon no longer needlessly keeps AMD GPUs … awake". **Re-test this on LACT bumps rather than
assuming it either way.** It does apply both values correctly at startup — `power1_cap` 210 W and
`OD_VDDGFX_OFFSET -70mV` were both live seconds after `systemctl start lactd`.

**Fan curves work. "R9700 fan control is dead" was the missing karg, not the vBIOS.** With
OverDrive unlocked `gpu_od/fan_ctrl/` exists on both cards and contains **`fan_curve`**, which the
earlier "every fan OD node is irrelevant" survey never listed because without the karg the
directory did not exist at all. A full curve commits cleanly:

    for pt in "0 40 30" "1 50 40" "2 60 55" "3 70 75" "4 80 100"; do echo "$pt" > fan_curve; done
    echo c > fan_curve      # rc=0

**All five points must be in range before you commit.** Staging one point and committing returns
EINVAL — the staged value still reads back, which makes it look like it worked. Worse, the
rejected commit poisons the table: the next `c` on `pp_od_clk_voltage` also fails with EINVAL until
the curve is reset. If a commit ever returns nonzero, `echo r > fan_curve; echo c > fan_curve`
before doing anything else. Ranges are hotspot `25C 100C` and speed `30% 100%`.

hwmon still has no `pwm1_enable`, so manual fixed-PWM remains dead; the PMFW curve is the whole
interface. `fan_zero_rpm_enable` is still an empty stub that fails to parse.

**And this finally explains the ~1950 RPM floor mechanically.** `fan_minimum_pwm` reads 30 with
OD_RANGE `30 100`, the curve's own speed floor is 30%, and `pwm1` idles at 76/255 = 29.8%. 30% of
`fan1_max` 6500 RPM = 1950. So the floor is a firmware minimum PWM that **cannot be lowered by any
curve** — `fan_minimum_pwm` will not accept a value below 30, and a curve point below 30% is
rejected. A curve can only make an awake card louder than 1950 RPM, never quieter. Letting the card
runtime-suspend remains the only way to get below it, exactly as the Settled entry above says.

**Smaller results from the same session:**
- `power1_cap_max` rises 300 W → 330 W with the karg. The OverDrive headroom is real, so 210 W is a
  cap against 330, not 300.
- OD writes need no `performance_level=manual`. `vo -25` + `c` commits at `auto`, rc=0, and `vo 0`
  + `c` cleanly reverts. Keep LACT on Automatic as before.
- **`pp_od_clk_voltage` and `power1_cap` return EBUSY on a runtime-suspended card rather than
  waking it.** They are passive instruments, unlike `sensors` — read them first, and do not read an
  EBUSY as an error. It also means you cannot verify a setting without first waking the card;
  `echo on > power/control`, read, `echo auto` is the controlled way, and leaving it at `on` is the
  exact stray pin warned about above.
- **`amd-smi` is not an option for any of this, in two independent ways.** It *aborts* on
  gfx1201 once OverDrive is unlocked — `amd-smi metric` dumps core on `rocm_smi.cc:1595 … Assertion
  'txt_power_dev_od_voltage.contains_title_key(kTAG_GFXCLK) || … kTAG_OD_SCLK' failed`, because it
  parses `pp_od_clk_voltage` and gfx1201 exposes `OD_SCLK_OFFSET`, which it does not know
  (`amd-smi list` still works; anything touching OD info does not). And even working, `amd-smi set`
  has **no voltage-offset argument at all** and no curve concept — its `--fan` sets a fixed PWM
  through hwmon, which needs the `pwm1_enable` this card does not have. Tool version 26.2.0.
  Read and write sysfs directly.
- LACT's config still errors on `pmfw_options.zero_rpm`/`zero_rpm_threshold`:
  `fan_zero_rpm_enable` is an empty stub that fails to parse, and `fan_zero_rpm_stop_temperature`
  does not exist. Drop both keys from `/etc/lact/config.yaml`.

**Measurement gotchas — each of these cost hours:**
- **Reading hwmon wakes the GPU.** `sensors` is not a passive instrument. Read
  `power/runtime_status` FIRST, `sensors` second, or you measure your own observation.
- **Check for stray `power/control=on` pins before trusting any idle measurement** —
  `/etc/tmpfiles.d/` and `/etc/udev/rules.d/`. One left behind by a D3 test forbade runtime
  suspend on 06:00.0 across every reboot; hours of "it never suspends" was measuring the pin.
- `runtime_usage`/`runtime_enabled` don't exist on Fedora (need `CONFIG_PM_ADVANCED_DEBUG`).
  `runtime_suspended_time` answers "has it ever suspended" and works while the GPU is busy.
- `fuser /dev/dri/*` does not see hwmon readers.
- Daemons that block idle may be *system* services — stopping the display manager misses them.
- `udevadm trigger --action=bind` does NOT prove boot behaviour: amdgpu.ko is in the initramfs
  and udev never replays `bind`. Use tmpfiles.d for sysfs writes that must happen at boot.
- Testing GPU idle from a Sunshine session is self-defeating; the stream holds the GPU.
- `kscreen-doctor` colours output even when piped — strip with `sed 's/\x1b\[[0-9;]*m//g'`.
- The display manager here is `plasmalogin.service`, not sddm.

**Rootless Quadlets must ship in `/etc`, not `/usr`.** `podman-systemd.unit(5)` lists
`/usr/share/containers/systemd/users/` as a search path but podman 5.8.4 does not use it —
the generator searches only `/run/user/$UID/containers/systemd`,
`~/.config/containers/systemd`, `/etc/containers/systemd/users` and `.../users/$UID`. A unit
under `/usr/share/...` is silently ignored: no error, the unit simply doesn't exist. Recheck
after a podman bump with `QUADLET_UNIT_DIRS=/usr/share/containers/systemd/users
/usr/lib/systemd/user-generators/podman-user-generator --user --dryrun`.

**ROCm's real blocker was one missing SELinux permission: `map` on `/dev/kfd`.**
`container-selinux` grants container domains `hsa_device_t:chr_file` everything *except*
`map`, and ROCm mmaps the node. Every model load aborted ~25 ms in with `Memory critical
error by agent node-0 … Reason: Memory in use` → exit 134. Node 0 is the **CPU** agent, which
is why every llama.cpp-level knob missed it for a week. The only AVC in the whole trace was
`denied { map } tclass=chr_file tcontext=…:hsa_device_t`. Three things fix it and one does
not: `container_use_devices=on` (the baked fix), `SecurityLabelDisable=true`, and `--ipc=host`
all pass; `SeccompProfile=unconfined` never mattered. **The baked boolean alone is verified
sufficient** — a model loads and generates under `Enforcing` with zero AVCs and none of the
other overrides present. That went untested for a while because a leftover user drop-in
(`~/.config/containers/systemd/lemonade.container.d/`) from the original bisect was still
applying `SecurityLabelDisable=true` and `--ipc=host`, silently masking it. Check for stray
user drop-ins before trusting any container-confinement result. Two traps: `Ulimit=memlock` as a Quadlet
key is not the `PodmanArgs` form and was inert throughout — not part of the fix; and any
bisect must pin `llamacpp.rocm_args` first, since a leftover `-sm row` made six consecutive
tests fail for an unrelated reason. Don't re-chase: `ctx_size` capping, `-mg 0 -sm none`,
`--load-mode mmap` alone, `ROCR_VISIBLE_DEVICES`. This is **not** the iGPU warmup segfault
(lemonade#1921 / llamacpp-rocm#96) and the iGPU is not implicated.

**ROCm never lands on the host, and doesn't have to.** lemonade's `llamacpp-rocm` builds
bundle their own ROCm 7 runtime, so `amdgpu.sh` installs firmware and monitoring only. The
`nightly` channel is the only one shipping per-arch `gfx120X` builds — `stable` and `preview`
have no gfx1201 HIP support and *silently* run on CPU at ~1/7th speed
(lemonade-sdk/lemonade#1787). A correctness trap, not a tuning knob, hence the seeded
`rocm_channel`.

**`-sm row` is unavailable for this build** — `device ROCm0 does not support split buffers`.
Split buffers need peer-copy compiled in, so layer split is the ceiling: decode streams from
one card at a time and the second GPU adds capacity, not bandwidth. Recheck on bumps.
Layer split needs no device pinning — a loaded 27B put 14186 MiB on 06:00.0, 13680 MiB on
03:00.0 and 20 MiB (framebuffer only) on the iGPU.

**llama.cpp MTP is worth +87%, and every seeded recipe that can use it does.** Measured
driving `llama-server` directly on the pair (Qwen3.8-27B-UD-IQ4_XS, 14.0 GB, `-ngl 99 -c
32768`, 512-token runs): baseline **30.40** tok/s versus **56.86** with `--spec-type
draft-mtp -md mtp-Qwen3.8-27B-Q4_0.gguf -ngld 99 --spec-draft-n-max 4`. Acceptance 0.45–0.67,
mean accepted length 2.8–3.7. Baseline is dead flat across workloads (30.45/30.43/30.33) —
the signature of a bandwidth-bound loop — while the MTP arm varies 51–65 because acceptance
is workload-dependent, so quote the baseline when comparing engines.

**You do not pass the flags — lemonade adds them itself** when the recipe names a draft head,
verified by grepping the launched `llama-server`. Only `Qwen3-Coder-30B` runs unspeculated,
because no MTP build of it exists upstream. Note the old 30–35 tok/s Q5_K_M figures elsewhere
in these notes predate that wiring and are unspeculated — do not read them as current.

Q5_K_M (21.2 GB) at ctx 32768 measures ROCm 31–35 tok/s, Vulkan ~29; treat anything in the
low 30s as the same result, and compare only from a fresh load at a fixed prompt since
generation slows as KV fills. 30.40 tok/s on 14.0 GB is only ~426 GB/s effective, ~67% of the
640 GB/s spec — llama.cpp's HIP backend leaves real bandwidth on the table, which is worth
remembering before blaming quantisation for any llama.cpp-vs-vLLM gap.

**Windows / WSL2 — evaluated and rejected.** Stay on native Linux dual-card. Findings that
outlived the decision: FP8 27B is two-card-only (weights ≈27 GB fill a 32 GB card with no
room for KV — that is *why* TP=2); dual-GPU is what WSL2 least reliably delivers (ROCm-on-WSL
is preview, and gfx1201 multi-GPU RCCL is fragile even natively — vllm-project/vllm#40980,
ROCm/rocm-systems#5480); WSL2 has no `/dev/kfd` at all, so the rootless Quadlets would need
rework rather than a lift; and llamacpp-rocm#96 means gfx1201 segfaults if the iGPU is also
visible to ROCm.

**3DMark: two failures, one solved.** It hangs at startup collecting system info — disable
hardware monitoring in its settings (SystemInfo is genuinely Wine-incompatible). With that
off the benchmark itself still stalls, **cause unknown**. It *does* run on Bazzite on this
same hardware, so this is a gap between images, not a Proton limitation — leading suspect is
Proton version, and Proton-GE is now baked, so retest before investigating anything else.
32-bit Vulkan is fine (`radeon_icd.i686.json` present) and Vulkan picks an R9700, not the iGPU.

**Cosmetic, ignore rather than chase:** `AUXTIN3 -61°C`, `AUXTIN4 +86°C ALARM`, `PCH_*` at
0°C and several `inN` rails flagged against a 0 V max are NCT6701D quirks. And clipboard sync
is KDE Connect's job — Sunshine has none in any build, upstream closed host→client on
security grounds (#1539) and the text-only proposal as `not_planned` (#5384).

## Open

### Unsloth fine-tuning — `build_files/profiles/north/unsloth.sh`

**Nothing here has run on the box.** The whole stack is derived from documentation and from
reading unsloth's `pyproject.toml`, not from a build. The Quadlet itself is the one part that
*has* been checked: it round-trips through podman 5.8.4's Quadlet generator on the box and
`systemd-analyze verify` reports no unknown keys, and the generated `podman run` carries the
expected devices, five `:z` volumes, both loopback publishes and `--shm-size=16g`.

Design decisions worth not re-litigating blind: the image is built **on the box** because no
Unsloth image exists for gfx1201 (`unsloth/unsloth` is CUDA-only; community ROCm rebuilds ship
gfx942 and gfx1100 only). AMD's torch **must** be installed before `unsloth[amd,...]`, because
that extra resolves to `unsloth[huggingfacenotorch]` + `bitsandbytes>=0.50.0` and deliberately
keeps whatever torch it finds. `bitsandbytes>=0.50.0` is a correctness floor, not a preference —
upstream's own comment calls it the first PyPI release with the full RDNA 4-bit path.

- [ ] **Does `unsloth[amd,studio]` resolve against AMD's gfx1201 wheels?** The two halves are
      documented separately and have never been installed together here. This is the single
      biggest unknown; everything else is downstream of it.
- [ ] **Is `triton` present after the torch install?** Known soft spot. Unsloth's `amd` extra
      does not pin triton — only its `rocm*-torch*` extras do, and those pin a whole
      repo.radeon.com torch stack that would fight the gfx1201 wheels. So triton arrives only if
      AMD's torch depends on it. `podman exec unsloth python -c "import triton"`. If it fails,
      the AMD index has a `triton/` directory — add an explicit `--index-url` install to the
      Containerfile.
- [ ] **Does the `gcnArchName` filter actually exclude the gfx1036 iGPU?** The launcher keeps
      only devices whose arch is `gfx1201`, splitting on `:` because the string reads like
      `gfx1201:sramecc-:xnack-`. Expect `device_count()==2` and two gfx1201 entries. The filter
      handles non-contiguous indices (verified against a stub emitting `0,2`), which matters
      because the iGPU need not be last.
- [ ] **How does Unsloth Studio surface its first-run password under systemd?** `_password_prompt.py`
      plus `diceware` in the `studio` extra imply an interactive prompt, which a service cannot
      answer. The assumption baked into the docs is that it prints to stdout and therefore the
      journal. If it instead blocks on a TTY, the unit will hang at start and the fix is likely a
      `-t`-style flag or a pre-seeded credential file.
- [ ] **What does a 4B LoRA actually cost in VRAM, and is one card enough?** AMD's playbook says
      24 GB minimum for Radeon on Linux; each R9700 has 32 GB. Untested. This governs whether the
      "stop the other stacks first" rule can ever be relaxed.
- [ ] **Multi-GPU training is untested and currently unsupported by choice.** The container runs
      without `--ipc=host` and without `--group-add`, following lemonade's measured finding that
      both are unnecessary and that `--ipc=host` drops SELinux label separation. If a distributed
      RCCL run is ever wanted, it needs host IPC in a shadowed unit — and that turns the
      confinement off, so measure whether it is worth it.
- [ ] **`Restart=on-failure` vs the vLLM lesson.** vllm.container needs `Restart=always` because a
      dead engine exits *cleanly* and `on-failure` never fires. No equivalent silent-success exit
      is known for Studio/Jupyter, so `on-failure` is the choice here — but it is an assumption,
      not an observation. If the container is ever found dead with `Result=success`, this is why.


### GPU — `build_files/profiles/north/amdgpu.sh`, `tuning.sh`

Settled and now explained at the code: `70-kfd.rules` was **removed** — it tightened the
0666 the base `50-udev-default.rules` already gives `/dev/kfd`, which is what made
`usermod -aG render` look necessary headless (rationale in `amdgpu.sh`; verified `666
render` on the box). HDR is unblocked — RPM Fusion's `mesa-vulkan-drivers-freeworld` has
caught up to Fedora's mesa, so swapping no longer downgrades Vulkan; it is now purely a
"do you want gamescope HDR" call (rationale in `codecs.sh`).

Tuning is now applied by **`kinoite-gpu-tune.service`** (`tuning.sh` section 4), not by LACT: a
oneshot that writes `power1_cap` per discrete card at boot, with optional `VOLTAGE_OFFSET_MV` and
`FAN_CURVE` knobs shipped unset. Defaults live in the script, overrides in
`/etc/kinoite/gpu-tune.conf`, documented example at `/usr/share/kinoite/gpu-tune.conf.example`.
`lactd` ships **disabled** — it is the GUI for experiments, and it reverts the cap when it stops.
Everything behind that decision is in Settled: the durability asymmetry, the LACT 0.10.0 re-test,
the `interval_ms` refutation, the karg mechanism, and the fan-curve unlock.

Current cap is **235 W** against a 330 W ceiling, chosen to leave vLLM throughput alone. Note the
box also has `/etc/lact/config.yaml` carrying `power_cap: 210` and `voltage_offset: -70` from the
earlier hand-tuning; those only take effect if you start `lactd`, and the two sources will fight.
Reconcile or clear that file before doing any serious measurement.

- [ ] **Measure what the power cap actually costs.** Unmeasured, and the prediction is
      "almost nothing": decode here is bandwidth-bound (baseline flat at 30.40 tok/s
      across workloads), and mclk was already observed pinned at top DPM 1258 MHz under
      load with junction at 72C and no throttling. If that holds, a cap only bites once
      it is low enough to force memory clock down. Run `bench.py` at the default cap,
      235 W and 210 W from a fresh load at a fixed prompt, and record tok/s and
      `power1_average`. If the draw under load never approaches 235 W, the cap is
      cosmetic and the number can be chosen for acoustics instead.

- [ ] **Decide whether an undervolt is worth maintaining at all.** It is no longer
      blocked — the karg is applied and `vo N`+`c` commits cleanly at
      `performance_level=auto` — but it is *wiped on every idle cycle* (Settled), so it
      cannot simply be baked. Keeping one applied means re-running
      `kinoite-gpu-tune apply` once the cards are pinned awake by a loaded model, either
      by hand or from a trigger on the LLM start path. Decide after the cap measurement
      above: if the cards are not power-limited in this workload, an undervolt buys
      little and the machinery is not worth it. If it does earn its keep, tune per card
      (start -50 mV, step -25 mV under sustained load until unstable, back off one step;
      two dies may differ) and load-test before baking a default — a too-aggressive
      offset would make a fresh install unstable.

- [ ] **Fan curve is available but unused.** `gpu_od/fan_ctrl/fan_curve` accepts a
      committed 5-point curve (Settled), and the knob is wired in
      `kinoite-gpu-tune`. Also wiped on every idle cycle, and bounded below by the 30%
      firmware floor, so it can only shape ramp-up on an already-awake card. Worth a
      curve only if the cards turn out to sit awake and audible under sustained load;
      the idle case is already solved by letting them runtime-suspend.

### Containerized ROCm + lemonade — `build_files/profiles/north/lemonade.sh`

Quadlet baked at `/etc/containers/systemd/users/lemonade.container`, deliberately **not**
enabled. On-box runbook is `/usr/share/kinoite/lemonade.md`. Rootless device passthrough,
the `nightly` channel seed and the ROCm backend are all proven on the box; the SELinux `map`
gap and the measured throughput are in Settled.

KFD topology here: node 0 = CPU, nodes 1–2 = R9700, node 3 = iGPU. **`ROCR_VISIBLE_DEVICES`
indexes GPU agents only**, so `0,1` is the pair that excludes the iGPU.

If it ever earns auto-start, the change is `[Install] WantedBy=default.target` in the quadlet
plus linger — *not* a line in `services-north.sh`, since `systemctl --global enable` does not
apply to generator-produced units.

**Baked recipe set, and it fits.** `lemonade.sh` seeds four Unsloth Qwen models into
`~/.local/share/lemonade/config/{user_models,recipe_options}.json`, merged per key by
`kinoite-lemonade-seed`. Profile is **Q6 + big context** for coding. Sizing read from each
model's own `config.json` — note two of the three are HYBRID, which an earlier dense-only
estimate here got badly wrong:

| seed | arch | KV/1K | weights | KV | total |
|---|---|---|---|---|---|
| Qwen3.6-27B Q6_K @128K | qwen3_5, 16/64 full-attn | 0.066 | 22.9 G | 8.4 G | **31.3 G** |
| Qwen3.6-35B-A3B UD-Q6_K @128K | qwen3_5_moe, 10/40, kv=2 | 0.020 | 30.0 G | 12.5 G | **42.5 G** |
| Qwen3-Coder-30B Q6_K @256K | qwen3_moe, dense attn | 0.098 | 25.1 G | 25.1 G | **50.2 G** |

All fit the 64 GB pair. The only pessimistic case is Qwen3.6-27B if llama.cpp fails to engage
`llama_memory_hybrid` and falls back to dense KV (0.262/1K): 56.4 GB — still fits, but with
little margin. Every case exceeds ONE card, so all of them ride on the automatic layer split;
no pinning is baked. **vLLM independently demonstrates the envelope**: 28.1 GiB/card, ~56 GB
across the pair, iGPU untouched at ~320 MiB.

Residual risk, not worth an open item: llama.cpp's iGPU exclusion is *emergent* (no pinning),
verified at ctx 32768 and again at 131072, whereas vLLM's is enforced via
`HIP_VISIBLE_DEVICES`. If a near-full load ever spills onto the iGPU, the fix is one line —
`llamacpp.rocm_args="-ts 1,1,0"` or `ROCR_VISIBLE_DEVICES=0,1`.

- [ ] Flash-attention on gfx1201: does `-fa -ctk q8_0 -ctv q8_0` load and roughly halve KV? If
      so it ~doubles every seed and is worth baking into `recipe_options.json`.
- [ ] Q6 tok/s vs the measured Q5_K_M ~31–35 — bigger weights and far bigger KV will be
      slower; confirm it is still usable for agentic loops, from a fresh load at a fixed prompt.
- [ ] Narrow `container_use_devices` to a CIL module granting only `container_domain
      hsa_device_t:chr_file map`. The boolean grants `map` on every device node to every
      container — fine for a single-user box, worth tightening if that stops being true.

### vLLM + Open WebUI stack — `build_files/profiles/north/vllm.sh`

Working end to end since 2026-08-16 and exercised repeatedly since. What it is, how to
run it, the MTP sweep, the 256K/concurrency trade and the llama.cpp comparison all live in
`/usr/share/kinoite/vllm.md` — read that, not this. Only the things that would otherwise
be re-derived are kept here:

- **The 32 GB image pull is hard-capped at 5 min** by podman's implicit pull inside
  `podman run` under systemd, regardless of `TimeoutStartSec`. First start died at exactly
  `5min 03s`. Fixed with a guarded `ExecStartPre` plain pull. **The same exposure applies to
  `lemonade.container`** (multi-GB image, `TimeoutStartSec=900`) — add the same pre-pull
  there if it ever fails its first start.
- **`podman exec` into these containers fails under `runuser`** (`OCI permission denied`
  writing the payload cgroup) — no session cgroup delegation. Use `nsenter -t $(podman
  inspect north-llm-infra --format '{{.State.Pid}}') -n` for anything inside the pod, or a
  real login session.
- Cosmetic: `Unknown vLLM environment variable detected: VLLM_MODEL` — our launcher knobs
  collide with vLLM's reserved `VLLM_*` namespace. Harmless (bash reads them first). Rename
  to a non-`VLLM_` prefix if the log noise ever bothers.

Settled 2026-08-22, all detail and numbers in `vllm.md`:

- **Prefix caching was never disabled — it is never enabled, and the reason is logged at
  `logger.debug`.** `is_prefix_caching_supported` (`config/model.py`) returns False for any
  `attn_type == "hybrid"` model: *"Hybrid models do not support prefix caching since the feature
  is still experimental."* Qwen3.8-27B is `qwen3_5`, i.e. hybrid. `VLLM_LOGGING_LEVEL=DEBUG` shows
  it. Forcing it works (7.4x TTFT on a shared prefix, correctness clean) and now ships as the
  `VLLM_PREFIX_CACHING` knob, opt-in because it overrides an upstream experimental gate.
- ~~**`disable_padded_drafter_batch:true` is now the default**, +19% decode, coupled to
  `--no-async-scheduling` because that pairing is what was measured.~~ **REVERTED 2026-08-24 — it
  crashes EngineCore under concurrency** (n>=3 parallel prompts, `llm_base_proposer.py:1082`
  assertion), which the 08-22 benchmark missed by measuring every arm single-stream. The +19.1%
  is real but only available at `--max-num-seqs 2`; this box keeps 4 for parallel agent tool
  calls. Full bisect and the deliberate trade in `vllm.sh`'s `SPEC_DEFAULT` comment.
- **k sweep re-run under that default: the knee did not move, k=3 stays.** The flag lifts every k
  by about the same amount, so it and speculation depth are independent levers.
- **`ksweep.py` is baked** next to `bench.py` — re-running the sweep no longer means writing a
  driver first, which is how k=1 once survived a day.

Settled 2026-08-25:

- **Reasoning effort was never set, and unset means MAXIMUM.** Qwen3.8's chat template resolves
  `reasoning_effort|default('xhigh')` (`'xhigh' | 'medium' | 'low'`, with `'high'` aliased onto
  `'xhigh'`), so the absent knob was not neutral — it selected the highest of the three. Nothing in
  the stack set it and Open WebUI sends no `chat_template_kwargs` at all, so every real request ran
  at xhigh; only `bench.py` and `ksweep.py` escaped, by pinning thinking off. `--reasoning-parser
  qwen3` was never evidence to the contrary: it is a *parser*, it splits `<think>` out of the
  response and sets nothing.

  Now pinned to `medium` server-side (`--default-chat-template-kwargs`, exposed as
  `VLLM_REASONING_EFFORT`). **UNMEASURED** — no quality A/B has been run on this box, so treat it
  as a default someone chose, not one someone proved. The argument for it is the context model
  above: reasoning tokens stay in the context and are re-read on every later forward pass, and at
  70K the context term is 64% of `ms/pass`. The decode tables are unaffected — every one of them
  was measured with `enable_thinking: false`.

  Three things worth not re-deriving:
    - Request-level `chat_template_kwargs` **override** the server default, so the harness pins
      still hold and any client can ask for xhigh per request.
    - Upstream shipped a window where the flag *parsed but was silently ignored* (`[Frontend]
      [Bugfix] respect server-level default chat template kwargs`, merged 2026-01-05). This
      2026-06-13 image is well past it, but that is what to re-check after a bump — and per the
      `--help` trap below, finding the flag does not prove it applies. Verify by watching
      `usage.completion_tokens` on a fixed prompt.
    - The launcher **guards** the flag (greps the installed vLLM source, and if it is missing
      starts without it and warns) because this unit is `Restart=always`: an unrecognised argument
      is `2/INVALIDARGUMENT` in a restart loop, not a message you notice. It greps the *source*
      rather than `--help` for exactly the reason in the first trap below.

Two traps that cost real time and will again:

- **`vllm serve --help` is grouped in this version** and prints only section names, so
  `--help | grep <flag>` finds nothing and reads as proof the flag is absent. Use `--help=all`.
- **systemd strips bare double quotes from `Environment=`.** `Environment=VLLM_SPECULATIVE={"a":1}`
  reaches vLLM as `{a:1}` and the unit dies with `status=2/INVALIDARGUMENT`. Single-quote the
  whole `KEY=VALUE`.

- [ ] **Two gfx1201-patched vLLM images, unevaluated** (surveyed 2026-08-22, nothing run):
      [vllm-radiance](https://codeberg.org/StillDeadcode/vllm-radiance/) and `tcclaviger/vllm`.
      The `vllm.md` dead end *"upgrading the image"* does **not** cover them — that was a stock
      version bump on the same generic RDNA4 paths; these ship hand-written gfx1201 kernels.

      Only one reason left to try radiance: `RADIANCE_GDN_WMMA` is the best candidate yet for the
      **~15 ms unexplained**, because the 48 GDN layers hold constant-size state and so contribute
      nothing to the GEMV term — exactly where a slow generic kernel hides without showing up in
      the bandwidth accounting. Its other selling points (prefix caching, the drafter flag) turned
      out to be flags our image already had, now adopted.

      **RE-WEIGHTED 2026-08-25, and it is worth less than it looks for agentic work.** The context
      model measured that day (`ms/pass = 1.186*ctxK + 47.2`, see `vllm.md`) says the whole fixed
      term is 47.2 ms, so at the 70K context this box actually runs at, the ~15 ms is ~11.5% of a
      130 ms forward pass — and the context term is 64% of it. Radiance is a fix for the ctx->0
      intercept, which is the regime we are *least* in. Chase it for short-prompt work; for the
      agentic loop, capping working context is worth ~1.8x and costs a launcher rewrite of zero.

      Swapping is a **launcher rewrite**, not a one-line `Image=` change — radiance needs
      `ROCM_AITER_UNIFIED_ATTN` where `vllm-serve.sh` hard-codes `TRITON_ATTN` for RDNA4 numerics.
      Test by hand with `podman run` against the shared model cache and `bench.py` before touching
      the quadlet. tcclaviger ships **no public source**, so adopting it would pin an unauditable
      binary into `vllm.container`; that is the objection, not competence.

- [ ] Cheap side-lead on the ~15 ms: [ROCm#6347](https://github.com/ROCm/ROCm/issues/6347) reports
      gfx1201 decode locking to ~33 **or** ~26 tok/s at process spawn, randomly, unrecoverable
      without restart. Evidence here is against it — twelve service starts never exceeded 24.3,
      which is one band, not two. Rule it out properly: spawn 5-6 times, record the
      non-speculative baseline each time.

### Wake-on-WLAN — `build_files/profiles/north/wol.sh`

**Works end to end** (verified 2026-08-22): trigger armed (`iw phy0 wowlan show` →
`wake up on magic packet`), the PCIe function reads `power/wakeup = enabled` so rtw89 does
implement cfg80211's `set_wakeup` and **no udev rule is needed**, and a magic packet to the
Wi-Fi MAC wakes the box. Not routable — the sender must be on the same L2 segment, so this
never works over Tailscale. Suspend type is `deep` (S3). For contrast both r8169 NICs read
`wakeup = disabled`; that is where a rule would go if wired WoL is ever wanted.

**WoL recovers a SUSPENDED box, not a HUNG one.** A wedged machine (see the LLM suspend hook
below) sits powered with the network dead and no packet reaches it — only the power button.
That asymmetry is why that hook is `RequiredBy=sleep.target`: it refuses the suspend rather
than entering a state you cannot recover remotely.

Already ruled out, don't re-add: `ethtool -s <wlan> wol g` (mac80211's
`ieee80211_ethtool_ops` has no `set_wol` — EOPNOTSUPP on every mac80211 driver) and
`iw dev ... set power_save off` (runtime power save, not a wake trigger). Both look like
they work because the failure is silent.

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
