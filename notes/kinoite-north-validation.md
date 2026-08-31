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

**P2P between the two R9700s is ENABLED, and it is PCIe-speed, not a fast link.** Measured
2026-08-30 by running `stilldeadcode/vllm-radiance:0.9.3` by hand purely for its startup
`RADIANCE_RUN_BWTEST` sweep (`rocm-bandwidth-test` 2.6.0) and killing it before the model loaded.
Radiance's own banner reports `P2P access : ENABLED   0<->1`, and the raw matrices agree —
Inter-Device Access is 1 for every pair, iGPU included:

    Device: 0  AMD Ryzen 9 9900X          Device: 1  R9700  03:0.0
    Device: 3  AMD Radeon Graphics 10:0.0 Device: 2  R9700  06:0.0

    NUMA distance      CPU<->GPU 20      GPU<->GPU 40      (single NUMA node)

    Unidirectional peak GB/s        Bidirectional peak GB/s
       1 <-> 2   28.158 / 28.156       1 <-> 2   55.642
       0 <-> 1   28.772 / 28.157       0 <-> 1   50.729
       1 -> 1   483.284 (on-card)      3 <-> 1/2 35.560 / 35.296
       2 -> 2   531.850 (on-card)

**The number that matters is 28.2 GB/s: a peer copy between the two R9700s is exactly as fast as
a copy to host memory.** There is no direct link — P2P here means "the driver will let you DMA
card to card over PCIe", not "there is a faster path". So P2P being available does not change the
arithmetic that already said comm is ~11% of the token budget; it removes a host bounce, nothing
more. Two consequences:

- **For llama.cpp:** `GGML_CUDA_P2P=1` is safe to try (access is genuinely enabled, and no IOMMU
  kargs are set on this box) but should not be expected to transform `-sm tensor`. It changed
  nothing observable in the runs above.
- **For radiance:** its TP=2 one-shot all-reduce (`RADIANCE_USE_R4D_AR`, `ar_oneshot_2rank_exact`)
  *does* have working P2P to stand on, so the claim is not vacuous. It is still bounded by our own
  measurement of the comm share.

Note the on-card copy figures (483 / 532 GB/s) are copy bandwidth (read+write), not the ~588 GB/s
synthetic large-read figure recorded under vLLM — do not compare them directly. The iGPU is
markedly slower to both dGPUs (17.8 GB/s), one more reason to keep it out of any split.

**ROCm never lands on the host, and doesn't have to.** lemonade's `llamacpp-rocm` builds
bundle their own ROCm 7 runtime, so `amdgpu.sh` installs firmware and monitoring only. The
`nightly` channel is the only one shipping per-arch `gfx120X` builds — `stable` and `preview`
have no gfx1201 HIP support and *silently* run on CPU at ~1/7th speed
(lemonade-sdk/lemonade#1787). A correctness trap, not a tuning knob, hence the seeded
`rocm_channel`.

**`-sm row` is still unavailable, and that no longer matters — `-sm tensor` works.** Upstream
deprecated `row` (it split only dense weights) and replaced it with `tensor`, which splits weights
*and* KV. Measured 2026-08-30 on the shipped `llamacpp-rocm` **b1305** (llama.cpp `c745be2`,
2026-08-02), using `unsloth/Qwen3.5-4B-MTP-GGUF` — GGUF `general.architecture = qwen35`, the same
GDN-hybrid arch as Qwen3.8-27B (verified by reading both GGUF headers), so the arch result carries
even though the throughput numbers do not:

- `-sm row` -> `llama_model_load: error loading model: device ROCm0 does not support split
  buffers`, exits. Unchanged from the original finding. Stop citing it as the ceiling.
- `-sm tensor -fa on -ctk f16 -ctv f16` -> **loads, serves, generates text byte-identical to
  `-sm layer` at temperature 0.** The documented architecture gate never fired: the string
  *"LLAMA_SPLIT_MODE_TENSOR not implemented for architecture '...'"* did not appear, and `qwen35`
  is not on upstream's exclusion list (which does name Jamba, Falcon-H1, Kimi-Linear, Nemotron-H,
  Mamba). **llama.cpp TP is a live option here, not a dead end.**

Four conditions, each measured:

1. `-fa on` is mandatory — `-fa off` gives `llama_init_from_model: SPLIT_MODE_TENSOR requires
   flash_attn to be enabled`. Incidentally the first hard evidence that **flash attention works on
   gfx1201** in this build.
2. **The iGPU must be excluded.** With all three ROCm devices visible, `-sm tensor` loads and then
   aborts on the first decode with `ggml/src/ggml-cuda/ggml-cuda.cu:106: ROCm error / ROCm error:
   invalid kernel file` — the gfx120X-only build has no kernels for gfx1036, and tensor split uses
   every visible device. `-dev ROCm0,ROCm1` (or `ROCR_VISIBLE_DEVICES=0,1`) fixes it. Layer split
   never hit this because it simply put no layers there, so this is a NEW reason to pin devices.
3. `--fit` is unsupported: `common_fit_params: ... llama_params_fit is not implemented for
   SPLIT_MODE_TENSOR, abort` (a warning; the load continues). Size `-c` by hand.
4. **No RCCL, confirmed at the binary.** Every run logs `internal AllReduce init failed
   (n_devices != 2?); falling back to meta-backend butterfly` *even with exactly two devices*,
   because RCCL is a build-time opt-in (`-DGGML_HIP_RCCL=ON`) that upstream leaves off and this
   build does not set. Verified three ways in the shipped bundle: no `librccl*` file, no RCCL in
   `ldd libggml-hip.so`, no RCCL symbols in `nm -D`. There is a runtime selector,
   `GGML_CUDA_ALLREDUCE`, and `internal`/`nccl` are genuinely accepted values (a bogus one logs
   `unknown GGML_CUDA_ALLREDUCE value: bogus`) — but both were tried under `-sm tensor` and both
   still logged the butterfly fallback. So **this is a ceiling, not a setting**: lifting it means
   building llamacpp-rocm ourselves and leaving lemonade's prebuilt binaries. `GGML_CUDA_P2P=1` changed nothing
   observable. Every tensor-split number below is therefore a FLOOR.

**q8_0 KV-quant and tensor split are NOT mutually exclusive here**, contradicting upstream's doc
("Support for quantized KV cache is not implemented and trying to use it will result in an
error"). On b1305, `-sm tensor -fa on -ctk q8_0 -ctv q8_0` loads, serves, gives identical output,
and at ctx 65536 saves **477 MiB** across the pair (6352 -> 5875 MiB). The saving is small for
*this* model because a GDN hybrid keeps only 16-of-64 full-attention layers; the rest is
constant-size SSM state KV-quant does not touch.

**What it is worth, measured on the 27B the same day: +44%, and it does not cost MTP anything.**
The 4B was the wrong model to ask (tensor 106.69 vs layer 105.59 — noise, on a model small enough
that layer split costs nothing). Qwen3.8-27B-UD-IQ4_XS, `-ngl 99 -c 32768`,
`HIP_VISIBLE_DEVICES=0,1`, fresh load per arm, thinking off, decode timed first-content-token to
last (`~/bench/tp.sh`, same harness as the MTP table):

| arm | rust | python | prose | MEAN | vs layer | card A | card B | pair |
|---|---|---|---|---|---|---|---|---|
| layer + MTP | 53.78 | 64.99 | 51.06 | 56.61 | — | 9099 M | 11739 M | 20838 M |
| **tensor + MTP** | 82.76 | 92.32 | 70.16 | **81.75** | **+44.4%** | 10353 M | 10353 M | 20706 M |
| layer no MTP | 30.43 | 30.41 | 30.42 | 30.42 | — | 7820 M | 8955 M | 16775 M |
| tensor no MTP | 42.20 | 42.11 | 42.11 | 42.14 | +38.5% | 8296 M | 8296 M | 16592 M |

Both layer arms reproduce the recorded baselines (56.86 and 30.40) to within 0.5%, and the MTP arm
reproduces them with the same acceptance figures, so the tensor arms are measured against a live
baseline. Four readings:

- **`-sm tensor` and `--spec-type draft-mtp` coexist — there is no conflict to work around.**
  Acceptance under tensor split is 0.464 / mean accepted length 2.85, indistinguishable from
  layer split's 0.448–0.476 / 2.79–2.90. The levers compose: MTP is 1.86x on layer and 1.94x on
  tensor, so tensor + MTP is **2.69x** the unspeculated layer baseline.
- Tensor split balances the pair exactly (10353/10353, 8296/8296) where layer split leaves a
  2.6 GB imbalance, and uses slightly less total VRAM. That balance IS the mechanism: layer split
  pipelines, so at batch 1 one card computes while the other waits.
- The no-MTP arms are dead flat across all three workloads (30.43/30.41/30.42, 42.20/42.11/42.11)
  — bandwidth-bound signature intact. Tensor split moves that ceiling 30.4 -> 42.1, realising
  ~1.39x of a theoretical 2x; the rest is the reduction.
- **Floor, not verdict.** The butterfly-fallback warning still fires at 27B — twice per MTP run,
  once for the main model and once for the draft — so every tensor arm ran the slow generic
  reduction (see condition 4). RCCL would presumably raise it; by how much is unknown.

One cost that is specific to this combination: `-sm tensor` disables backend sampling
(`set_sampler: backend sampling not supported with SPLIT_MODE_TENSOR; using CPU`, then `spec
common_specu: backend offload failed for seq_id=N; using CPU sampler` per slot), so the MTP draft
sampler runs on the CPU under tensor split. That is already inside the +44.4%.

**THREE QUANTS NOW, AND THE WEIGHT-SIZE AXIS IS FLAT ABOVE ~25 GB.** Q6_K_XL was measured
2026-08-30 (`~/bench/q6-suite.sh`, `q6-results.txt`) on the identical harness, identical MTP
draft head and identical depths as the IQ4_XS and Q8_K_XL runs, so all three are one-variable
comparisons. Single stream, `-c 98304`, `-np 1`, decode timed first-content-token to last:

| depth | IQ4_XS 14.0 GB | **Q6_K_XL 25.3 GB** | Q8_K_XL 31.5 GB | vLLM FP8 27.8 GB |
|---|---|---|---|---|
| control mean, tensor | 82.80 | **65.53** | 65.91 | 55.63 |
| control mean, layer | 55.96 | **45.22** | 42.21 | 55.63 |
| short (189), tensor | 92.41 | **80.19** | 77.39 | 63.33 |
| short (189), layer | 69.66 | **54.16** | 51.96 | 63.33 |
| 9K, tensor | 80.21 | **72.58** | 78.58 | 49.81 |
| 9K, layer | 61.52 | **52.57** | 47.96 | 49.81 |
| 38K, tensor | 71.75 | **60.67** | 62.14 | 31.56 |
| 38K, layer | 48.05 | **40.89** | 42.63 | 31.56 |
| 70K, tensor | 67.83 | **54.31** | 55.67 | 34.05 (layer) / 21.31 vLLM |
| 70K, layer | 43.54 | **34.20** | 34.05 | 21.31 |

**Q6 lands on Q8, not between Q8 and IQ4.** 25.3 GB and 31.5 GB of weights decode at the same
rate to within noise (tensor control mean 65.53 vs 65.91; 70K 54.31 vs 55.67), while 14.0 GB is
26% faster. Do not model this box's decode as proportional to weight bytes — read the ms/pass
decomposition instead, which Q6 validates for the third time:

| arm | slope (ms per 1K ctx) | intercept (ms) | weights |
|---|---|---|---|
| IQ4_XS tensor | 0.2045 | 41.04 | 14.0 GB |
| **Q6_K_XL tensor** | **0.2057** | **49.72** | 25.3 GB |
| Q8_K_XL tensor | 0.1971 | 49.48 | 31.5 GB |
| IQ4_XS layer | 0.4149 | 56.56 | 14.0 GB |
| **Q6_K_XL layer** | **0.4068** | **71.92** | 25.3 GB |
| Q8_K_XL layer | 0.3972 | 73.21 | 31.5 GB |

Slope is the context/KV term and is constant across all three quants (KV is f16 regardless), as
already recorded. What Q6 adds is that the INTERCEPT — the weight term — is *also* flat between
Q6 and Q8 and only drops at IQ4. A 2.21x change in weight bytes (IQ4 -> Q8) moves the intercept
21%, and the 1.24x from Q6 -> Q8 moves it 0%. The large fixed per-pass cost (butterfly reduction,
CPU draft sampler, launch overhead) dominates, so **quantising down from Q8 buys nothing until
you go well below Q6.** The practical reading: if Q6 is chosen for quality, Q8 is nearly free;
if speed is the goal, only a jump to ~IQ4 pays.

**Where Q6 sits against vLLM, which is the number that matters for the seeds.** The seeded
recipes are Q6_K, and this is the first direct measurement of that quant rather than an
extrapolation from the Q8 re-run:

- **tensor split wins at every depth**: 1.27x short, 1.46x at 9K, 1.92x at 38K, 2.55x at 70K.
- **layer split LOSES below roughly 6-7K context** (0.86x at a 189-token prompt, 1.06x at 9.5K)
  and only pulls ahead deeper: 1.30x at 38K, 1.60x at 70K.

So the Q8 finding holds at Q6 with the crossover moved down from ~11.1K to ~6-7K. It is still a
real loss zone, and short prompts are exactly what an agentic loop's first turns look like.
**For the Q6_K seeds, `-sm tensor` remains the difference between beating vLLM everywhere and
losing to it on short prompts.**

Concurrency, same suite (4 slots; short = `-c 32768`, deep = 4 x 38K at `-c 196608`):

| arm | 4x short, aggregate | 4 x 38K, decode-agg |
|---|---|---|
| IQ4_XS tensor | 178.27 | 161.03 |
| **Q6_K_XL tensor** | **162.99** | **144.77** |
| Q8_K_XL tensor | 170.18 | 148.38 |
| IQ4_XS layer | 134.47 | 101.96 |
| **Q6_K_XL layer** | **118.70** | **90.15** |
| Q8_K_XL layer | 126.71 | 93.03 |
| vLLM FP8 | **189.93** | 60.42 |

Unchanged shape from the other two quants, and worth restating because it is the one place vLLM
still wins: **vLLM leads on 4-way SHORT concurrency and loses catastrophically on 4-way DEEP**
(60.42 vs 144.77, 2.4x). Q6 again sits with Q8 rather than between the two.

**VRAM, and the ctx arithmetic that was blocking the bake.** Measured pair figures for Q6_K_XL
with the MTP head:

| config | tensor | layer |
|---|---|---|
| `-c 98304 -np 1` | 16535 / 16536 MiB | 15113 / 18751 MiB |
| `-c 196608 -np 4` | 20896 / 20896 MiB | 19158 / 22828 MiB |

Two points scale to a per-token cost of **0.0444 MiB/token/card** under tensor split, and a
fixed (weights + non-KV) term of **12174 MiB/card**. That gives the seeded sizes directly:

- `ctx_size 131072` -> ~**17.9 GB/card**, 14 GB of headroom on a 32 GB card.
- `ctx_size 262144` -> ~**23.8 GB/card**, still comfortable.

Both fit, so **`--fit` being unavailable under SPLIT_MODE_TENSOR is no longer a blocker for the
Q6 seeds** — the hand-computed numbers exist now and both have wide margins. Note the estimate
is deliberately conservative: the `-c 196608` point had 4 slots against the `-c 98304` point's
1, so slot-count overhead is folded into the slope rather than being netted out.

**`-dev` is NOT sufficient once a draft model is in play, and this is the second consumer of the
iGPU-exclusion rule.** `-sm tensor -fa on -dev ROCm0,ROCm1` with `--spec-type draft-mtp` still
aborts with `invalid kernel file`: `-dev` restricts the MAIN model only, and the draft model has
its own device list (`-devd` / `--spec-draft-device`) that defaults to every device. Either add
`-devd ROCm0,ROCm1` or — better — exclude at visibility, which covers every model the process
loads. Both variables were verified that day, each on its own with no `-dev` and no `-devd`:
`HIP_VISIBLE_DEVICES=0,1` and `ROCR_VISIBLE_DEVICES=0,1` each ran `-sm tensor` +
`--spec-type draft-mtp` clean, same 10252 MiB per card, same acceptance.

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

### LLaMA-Factory fine-tuning — `build_files/profiles/north/llamafactory.sh`

Replaced `unsloth.sh` on 2026-08-29. Unsloth itself was **not** the problem — it built and ran on
the box (image built, `gcnArchName` filter selected both R9700s, Jupyter served). What could not
be made to work was Unsloth **Studio**, its no-code UI: pip cannot produce a runnable one, and the
documented installer builds a second torch stack that trains on different wheels than the image
pins. LLaMA Board is a plain Gradio app with no installer gate, so the GUI stops being a caveat.

**Verified on the box under the previous trainer, and carried over unchanged** — do not re-derive:
AMD's `whl-multi-arch` gfx1201 recipe resolves and runs (`torch 2.12.0+rocm7.14.0`); **triton
arrives as a dependency of that torch** (`3.7.1+git0263a6a6.rocm7.14.0`) and needs no separate
install; `bitsandbytes` 0.50.2 installs clean; the `gcnArchName` filter correctly excludes the
gfx1036 iGPU and yields `HIP_VISIBLE_DEVICES=0,1`. Ordering is still load-bearing: AMD's torch
first, and never an extra that names `torch`, or a CUDA wheel wins the resolution and is kept.

- [ ] **Does a LLaMA-Factory QLoRA run actually complete on gfx1201?** Nothing has been trained on
      this box yet under either stack — the substrate is proven, the training path is not. This is
      the single biggest unknown; everything below is downstream of it.
- [ ] **What does a 4B QLoRA cost in VRAM, and is one card enough?** AMD's playbook says 24 GB
      minimum for Radeon on Linux; each R9700 has 32 GB. This governs whether the "stop the other
      stacks first" rule can ever be relaxed. Record peak VRAM and wall clock on the first run.
- [ ] **Does full-precision LoRA hit the rocBLAS Tensile GEMM crash here?** A published R9700
      write-up reports full-precision LoRA crashing on this arch while 4-bit is clean, which is why
      the runbook says QLoRA. Confirm once, deliberately, and record it as settled either way — an
      unverified warning in a runbook decays into folklore.
- [ ] **Is `/workspace/data` seeding correct in practice?** The launcher copies the image's bundled
      `data/` in only when `dataset_info.json` is absent, and LLaMA Board's default relative `data`
      dir depends on the launcher's `cd /workspace`. Both are untested against the real GUI.
- [ ] **Multi-GPU training is untested and currently unsupported by choice.** The container runs
      without `--ipc=host` and without `--group-add`, following lemonade's measured finding that
      both are unnecessary and that `--ipc=host` drops SELinux label separation. If a distributed
      run is ever wanted, it needs host IPC in a shadowed unit — and that turns the confinement
      off, so measure whether it is worth it.
- [ ] **`Restart=on-failure` vs the vLLM lesson.** vllm.container needs `Restart=always` because a
      dead engine exits *cleanly* and `on-failure` never fires. No equivalent silent-success exit
      is known for LLaMA Board/Jupyter, so `on-failure` is the choice here — but it is an
      assumption, not an observation. If the container is ever found dead with `Result=success`,
      this is why.


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

Residual risk, CLOSED 2026-08-30. It used to read: llama.cpp's iGPU exclusion is *emergent*
(no pinning) where vLLM's is enforced via `HIP_VISIBLE_DEVICES`, so a near-full load could in
principle spill. It is no longer emergent — `kinoite-lemonade-gpus` derives
`ROCR_VISIBLE_DEVICES` and `lemonade.container` reads it, so both stacks now enforce the
exclusion rather than one relying on the allocator's good behaviour. See the Device selection
item below.

- [x] **Flash-attention on gfx1201 WORKS, and `-ctk q8_0 -ctv q8_0` loads** (measured 2026-08-30,
      llamacpp-rocm b1305, Qwen3.5-4B `qwen35`) — under `-sm layer` and `-sm tensor` alike, with
      correct output. **But it does not "roughly halve KV" on these models and must not be baked
      on that assumption**: at ctx 65536 it saved 477 MiB across the pair, ~7.5% of the 6352 MiB
      footprint, because a GDN hybrid has only 16-of-64 growing-KV layers. The halving rule is a
      dense-attention rule. Remember `-fa on` is now mandatory for a second reason too
      (`-sm tensor`).

      **The dense case was set up and then deliberately dropped, 2026-08-30 — not pending.**
      `user.Qwen3-Coder-30B` (qwen3_moe, dense attention, ~0.098 GB/1K, seeded at 256K) is the
      ONLY seed where the halving rule can apply, so it was the one arm worth measuring. The
      bench harness exists (`~/bench/coder.sh`, f16 vs q8_0 at `-c 262144`, reporting pair VRAM,
      decode delta and prompt-eval delta) but the 25.1 GB Q6_K GGUF was never in the cache and
      the pull was abandoned at ~74% after measuring the link at a sustained **1.75-2.2 MB/s**,
      authenticated or not — being logged in to HF changed nothing, so the constraint is not
      account-level. Dropped on the grounds that nothing on this box runs that model: the only
      hand-added entry in the live `user_models.json` is a `qwen3_5` HYBRID
      (`DavidAU/Qwen3.6-27B-Fable-Fusion-...-MTP-GGUF:Q5_K_M`), for which the answer is already
      the 7.5% above. Re-open only if a dense seed actually gets used; the harness is ready and
      only needs `CODER_GGUF` pointed at the file.
- [x] **`-sm tensor` on the 27B with its MTP head: DONE 2026-08-30, +44.4%, table in Settled.**
      Both questions this item raised are answered: the `--spec-type draft-mtp` wiring survives
      tensor split intact (same acceptance, and the two levers compose to 2.69x), and the no-RCCL
      butterfly fallback still fires at 27B — so +44.4% is a floor. What it turned into is a
      DEVICE-SELECTION item, not a performance one; see the next box.
- [x] **Device selection: DONE 2026-08-30.** `kinoite-lemonade-gpus` (an ExecStartPre installed
      by `lemonade.sh`) derives `ROCR_VISIBLE_DEVICES` from KFD topology into an `EnvironmentFile`
      that `lemonade.container` reads, so the iGPU is excluded before llama-server starts. The
      rule is index-free: keep every GPU agent whose `gfx_target_version` matches the agent with
      the most SIMDs. Fails OPEN — the file is truncated first, so any failure leaves it EMPTY and
      lemonade starts unconstrained on layer split. That ordering is load-bearing: podman treats a
      MISSING `--env-file` as fatal, so "absent" would have been fail-closed. Reasoning in
      `lemonade.sh` under "Device visibility"; runbook in `lemonade.md` under the same name.
      This turns the old "if a load spills onto the iGPU, exclude it" advisory into a default.
- [ ] **Bake `-sm tensor` — BOTH old blockers are now gone; what is left is the decision.**
      Device selection was solved 2026-08-30 (previous box). Ctx sizing was solved the same
      evening by the Q6_K_XL suite: the two measured VRAM points give 0.0444 MiB/token/card plus
      a 12174 MiB/card fixed term under tensor split, so `ctx_size 131072` lands at ~17.9 GB/card
      and `262144` at ~23.8 GB/card, both with wide margin on 32 GB (arithmetic and the measured
      table are in "Containerized ROCm + lemonade" above). `--fit` still does not run under
      SPLIT_MODE_TENSOR, so those numbers stay hand-maintained and must be re-checked on a model
      bump — that is a maintenance cost, not a blocker.

      **AND THE RECIPE HALF IS NOW MEASURED END TO END, NOT INFERRED.** See the `llamacpp_args`
      box below: a per-recipe `llamacpp_args` reaches the launched `llama-server`, merges with
      rather than replaces the architecture and global layers, and lands last. Tested on the 27B
      Q6_K_XL itself. So the one-line recipe change in (a) of `lemonade.sh` is confirmed to work.

      **THE HEAVY-QUANT ARGUMENT, now measured at Q6 rather than extrapolated from Q8.** At
      IQ4_XS layer split beats vLLM at every depth, so tensor split is pure upside and easy to
      defer. At Q8_K_XL layer split loses to vLLM below ~11.1K context. **At Q6_K_XL — which is
      what the seeds actually are — layer split loses to vLLM below roughly 6-7K** (0.86x at a
      189-token prompt, 1.06x at 9.5K) and only `-sm tensor` leads everywhere (1.27x -> 2.55x).
      The crossover moved down from Q8 but did not disappear, and short prompts are what an
      agentic loop's opening turns look like. The seeded Q6_K recipes are therefore the ones that
      most need the flag, not the IQ4_XS `-Fast` entry that would show it off best.

      What is genuinely left is a judgement call, not a measurement: `-sm tensor` costs the
      backend sampler (CPU draft sampling), makes ctx a hand-maintained constant, and couples
      every recipe to container-level device pinning because `llamacpp_args` is per-recipe while
      visibility is per-container. All three are already characterised; none is unknown.
- [x] **Q6 tok/s: DONE 2026-08-30, and it is comfortably usable.** The old worry here — that Q6's
      bigger weights and far bigger KV would drag it toward the Q5_K_M ~31-35 tok/s figure — was
      wrong in the direction that matters. Qwen3.8-27B-UD-Q6_K_XL with its MTP head measures a
      **65.53 tok/s** control mean under tensor split and **45.22** under layer split, and still
      holds **54.31 / 34.20** at 70K context. Even the layer-split number beats the Q5_K_M
      baseline, because those old figures predate the MTP wiring. Full three-quant table above.
- [x] **`llamacpp_args` PASSTHROUGH: MEASURED END TO END 2026-08-30. It works, it merges, and
      it lands last.** This closes `lemonade.sh` (a)'s *"Ordering looks safe but is NOT yet
      measured"*. Method was the one that file asks for: set the key, load the model, read the
      launched process's command line (`/proc/<pid>/cmdline` inside the container).

      With `"user.<name>": {"ctx_size": 98304, "llamacpp_args": "-sm tensor -fa on"}`, the
      launched `llama-server` argv ends `... --no-mmap --chat-template-kwargs
      {"preserve_thinking":true} --load-mode mmap --min-p 0.00 --repeat-penalty 1.0 --temp 1.0
      --top-k 20 --top-p 0.95 -fa on -sm tensor`. Three layers are present at once and lemonade
      names the behaviour itself in its log: **`merge_args=true`**.

      | layer | source | survives? |
      |---|---|---|
      | architecture defaults | `resources/architecture_defaults.json`, key `qwen35` | yes |
      | global backend args | `config.json` `llamacpp.rocm_args` (`--load-mode mmap`) | yes |
      | per-recipe | `recipe_options.json` `llamacpp_args` | yes, **appended last** |

      Two consequences worth having in writing. **`llamacpp_args` is a real recipe-option key,
      not a guess** — `architecture_defaults.json` documents itself as *"recipe option key-value
      pairs that override global config defaults but are overridden by model-level
      recipe_options"*, and its values are `llamacpp_args` strings. And **merging is per-flag,
      not whole-string**: our `-sm tensor` did NOT wipe the `qwen35` sampler block, so a recipe
      that adds one flag keeps `--chat-template-kwargs '{"preserve_thinking":true}'` and the
      rest. Because passthrough lands last it can also OVERRIDE anything lemonade generates,
      which is what the next box depends on.

      **One addition to `lemonade.sh` (a)'s flag survey — that list is correct but not
      exhaustive.** Re-verified against the binary 2026-08-30: `--split-mode`, `-sm`, `-devd`,
      `--spec-draft-device`, `--device-draft`, `-ngld` and `--gpu-layers-draft` are all genuinely
      zero hits, as it says. What it omits is that lemonade has a device knob of its own —
      `llamacpp_device` / `--llamacpp-device`, in its "Llama.cpp Backend Options" group next to
      `llamacpp_backend` and `llamacpp_args` — which sets **`LLAMA_ARG_DEVICE`**, llama.cpp's env
      form of `--device`. That does not weaken the visibility-exclusion argument; it strengthens
      it, because `--device` restricts the MAIN model only, so even lemonade's own knob cannot
      cover the draft head. Worth recording so nobody reaches for `--llamacpp-device` expecting
      it to solve the iGPU problem.
- [x] **A tensor-split recipe without the device work is a HARD LOAD FAILURE, not a slow path.
      Measured 2026-08-30.** On the box's *deployed* quadlet — which predates
      `kinoite-lemonade-gpus` — the recipe above fails the load outright:

          E ROCm error: invalid kernel file
          E   current device: 2, in function ggml_cuda_kernel_launch
          llama-server process has terminated with exit code: 134

      `current device: 2` is the gfx1036 iGPU. Adding `ROCR_VISIBLE_DEVICES=0,1` to the
      container — same image, same mounts, same recipe — loads clean. So the recipe half and the
      device half cannot ship independently, and the failure mode if they do is a 500 from
      `/api/v1/load`, not degraded throughput. (Verified with a hand-run container on its own
      name and port; `/etc` and the real `lemonade.service` were not touched.)
- [x] **LEMONADE'S OWN `--spec-draft-p-min 0.75` COSTS 24%, AND IT IS THE ONLY THING BETWEEN A
      RECIPE AND THE RAW-CLI NUMBER. Measured 2026-08-30 on Qwen3.8-27B-UD-Q6_K_XL.** A recipe
      carrying just `-sm tensor -fa on` measured **49.13** tok/s against the raw CLI's **65.53**
      on the same model, model file and prompts. The gap is not the proxy and not the harness:
      re-running the raw `llama-server` under the SAME measurement script gave 65.03 with the
      CLI flags and **49.72 with lemonade's flags**, reproducing the shortfall outside lemonade
      entirely. Bisected one flag at a time from the CLI baseline:

      | arm | control mean | vs baseline |
      |---|---|---|
      | CLI baseline (`-ngl 99 -np 1 -sm tensor -fa on` + MTP, `--spec-draft-n-max 4`) | 65.03 | — |
      | + `--load-mode mmap` | 64.81 | none |
      | + `--min-p/--repeat-penalty/--temp/--top-k/--top-p` (the `qwen35` block) | 64.43 | none |
      | + `--jinja --metrics --reasoning-format auto --chat-template-kwargs` | 64.56 | none |
      | + `--no-mmap` | 64.65 | none |
      | drop `-ngl 99 -ngld 99` | 64.85 | none |
      | `--spec-draft-n-max 3` alone | **66.99** | slightly FASTER |
      | **`--spec-draft-p-min 0.75`** | **49.76** | **-24%** |
      | `--spec-draft-p-min 0.1` | 64.65 | none |

      **The trap here is that acceptance goes UP while throughput goes DOWN.** Under p-min 0.75
      mean accepted length is 3.01 against the baseline's 2.90. The gate makes the draft head
      bail out early, so each pass drafts fewer tokens even though a higher fraction of them are
      accepted. Anyone tuning speculation on this box by watching `mean len` alone will tune it
      backwards — quote tok/s, and treat acceptance as diagnostic only. This is the same
      discipline the MTP table above already applies for a different reason.

      **The fix is one flag, and it restores everything.** Through a lemonade recipe:

          "user.<name>": { "ctx_size": <hand>, "llamacpp_args": "-sm tensor -fa on --spec-draft-p-min 0.1" }

      measures **66.97** tok/s, i.e. at or slightly above the raw CLI's 65.03-65.53, on 16381
      MiB per card. Adding `--spec-draft-n-max 3` as well changes nothing (66.77). So the answer
      to *"can lemonade reach llama.cpp's numbers through a recipe, or must it be run from the
      CLI like vLLM?"* is: **a recipe reaches them, with two flags, and no CLI launcher is
      needed.** `--spec-draft-n-max` is NOT one of the two — lemonade's 3 is fine, and the notes
      elsewhere that pair `-sm tensor` with `--spec-draft-n-max 4` should not be read as
      requiring the 4.

      **THE TWO HEAVY-QUANT SEEDS ARE NOW BAKED AND VERIFIED VERBATIM, 2026-08-30.**
      `Qwen3.8-27B-Q6XL` and `Qwen3.8-27B-Q8XL` were added to `lemonade.sh`, each with
      `{"ctx_size": 131072, "llamacpp_args": "-sm tensor -fa on --spec-draft-p-min 0.1"}`, and
      then re-measured with those exact lines rather than with the hand-tuned variant that
      produced the 66.97 figure (which used `-c 98304` and `-np 1`):

      | seed | control mean | VRAM/card | slots |
      |---|---|---|---|
      | `user.Qwen3.8-27B-Q6XL` | **67.30** tok/s | 18446 MiB | 4 @ 131072 |
      | `user.Qwen3.8-27B-Q8XL` | **60.69** tok/s | 21368 MiB | 4 @ 131072 |

      Both land within ~600 MiB of the VRAM predicted by the arithmetic above (17.9 and 20.4
      GB/card), which is the first independent check on that extrapolation, and both leave ~11
      GB of headroom on a 32 GB card at four full-context slots. Dropping `-np 1` cost nothing.

      **One caveat that qualifies the "Q6 lands on Q8" finding.** That result was measured at
      `-c 98304`, one slot, p-min at llama.cpp's default (65.53 vs 65.91 — indistinguishable).
      At the SHIPPED settings — ctx 131072, four slots, p-min 0.1 — Q8 reads about 10% below Q6
      (60.69 vs 67.30), and the Q8 run is also more spread across workloads (55.96-68.94 against
      Q6's 61.22-73.20). Not enough to overturn the ms/pass decomposition, which was fitted over
      four depths per quant, but it does mean **"Q8 is nearly free" holds for the single-stream
      depth series and NOT for the shipped multi-slot configuration.** Untangling it would mean
      re-running the depth series at 131072/4 slots; nobody has.

      Not yet measured, and worth doing before this is baked: whether p-min 0.75 is equally
      expensive under `-sm layer` (the layer arm through lemonade read 39.88 against a CLI 45.22,
      a 12% gap rather than 24%, which hints it is cheaper there but was not bisected), and
      whether 0.1 versus llama.cpp's own default costs anything in output quality. Both arms
      produced correct-looking output at temperature 0; neither was A/B'd for quality.
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
  it. Forcing it works (7.4x TTFT on a shared prefix, correctness clean) and ships as the
  `VLLM_PREFIX_CACHING` knob — **opt-in until 2026-08-31, ON by default since**, once the
  multi-turn agentic arm measured 1.73x end-to-end with decode unaffected. It still overrides an
  upstream experimental gate and no quality A/B has been run; `VLLM_PREFIX_CACHING=false` reverts.
  Full write-up in `notes/lemonade-vs-vllm.md`.
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

Settled 2026-08-27:

- **Evaluated a Discord claim that KV-cache regrouping freed ~21% on the same model — real
  mechanism, does not apply to this box.** vLLM groups layers by KV spec with group size = the
  smallest bucket (`kv_cache_utils.py`, upstream FIXME acknowledges it); that claim's setup is a
  5-layer DFlash2 drafter forming a third bucket (48/16/5 -> min=5, 15 groups, 75 slots for 69
  layers). Here the 1-layer MTP head merges into the full-attention bucket, so buckets are 48/17:
  min=17, 4 groups, 68 slots for 65 layers, 3 padding — exactly the `Add 3 padding layers, may
  waste at most 6.25%` warning in our startup log. 17 is provably optimal under the never-more-
  groups constraint (gcd(48,17)=1; ceiling ~4% of the pool), so no patch and no image bump buys
  anything on this config. Full write-up in `vllm.md`. Rule of thumb kept: swap to a multi-layer
  drafter and re-read that warning line.

Settled 2026-08-30:

- **The upstream gfx1201 TP=2 deadlock does not affect us, and we are the counter-example.** Two
  OPEN reports describe a hard TP=2 hang on this exact hardware — both cards at 100% with nothing
  in flight, TP=1 fine: [vllm-project/vllm#40980](https://github.com/vllm-project/vllm/issues/40980)
  (kyuz0, 2026-04-27; labels `bug`/`rocm`, assigned to an AMD engineer, project status **In
  Progress**) and [ROCm/rocm-systems#5480](https://github.com/ROCm/rocm-systems/issues/5480)
  (same author, same day; **still `status: triage`**, assigned `tcgu-amd`, no AMD reply on the
  thread). Both attribute it to RCCL: **2.27.3 works, 2.27.7 hangs**. `NCCL_P2P_DISABLE=1` and
  `--enforce-eager` are recorded as not helping.

  Read out of the images 2026-08-30 (`strings librccl.so.1 | grep 'RCCL version'`):

  | image | built | vLLM | RCCL | `trim_reasoning_for_advance` |
  |---|---|---|---|---|
  | `:latest` (what we run) | 2026-06-13 | 0.22.1rc1.dev499 | **2.29.7** | absent |
  | `:dev` = `:rocm7.14.0-torch2.11.0-vllm0.27.1` | 2026-08-12 | 0.27.1 | **2.30.4** | present |

  So this box has served TP=2 since 2026-08-16 on RCCL 2.29.7, two minor versions past the one
  those issues call broken. That is a datum neither issue has. It does **not** vindicate 2.27.7 —
  we never ran it — it says the hang is version- or config-specific rather than inherent to
  gfx1201 TP=2.

- **The image-bump rule is now THREE conditions**, because RCCL moves as a side effect of a bump:
  post-2026-07-04 (carries #44297), **and** not a decode regression, **and** does not reintroduce
  the TP=2 hang. Nobody has data on 2.30.4 — not us, not either issue — so a bump carries an
  unquantified hang risk on top of the already-measured ~15% MTP decode regression. Verify the
  third condition by starting the candidate at TP=2 and watching for the deadlock signature
  before benchmarking; a deadlocked engine reads as a slow one until you check `rocm-smi`.

- **Two tag names are not two builds.** Re-surveyed the whole kyuz0 tag list: the date-stamped
  tags still stop at `20260613-143121`, and everything newer than `:latest` is ONE image —
  `dev`, `rocm7.14.0-torch2.11.0-vllm0.27.1` and `sha-c5dd87e` all resolve to
  `sha256:f36940bd…` (2026-08-12T18:56:46Z). Every other `sha-*` tag predates `:latest`
  (`sha256:55fa7796…`, 2026-06-13T14:54:38Z). Compare digests, not names.

- [ ] **vllm-radiance, still unevaluated for throughput** (surveyed 2026-08-22; re-surveyed
      2026-08-30, nothing benchmarked yet): [vllm-radiance](https://codeberg.org/StillDeadcode/vllm-radiance/).
      The `vllm.md` dead end *"upgrading the image"* does **not** cover it — that was a stock
      version bump on the same generic RDNA4 paths; radiance ships hand-written gfx1201 kernels.

      `RADIANCE_GDN_WMMA` is still the best candidate for the **~15 ms unexplained**, because the
      48 GDN layers hold constant-size state and so contribute nothing to the GEMV term — exactly
      where a slow generic kernel hides without showing up in the bandwidth accounting. Its other
      selling points from the first survey (prefix caching, the drafter flag) turned out to be
      flags our image already had, now adopted.

      **THE 2026-08-25 RE-WEIGHTING WAS RIGHT ABOUT GDN-WMMA AND WRONG AS A VERDICT ON RADIANCE.**
      That entry discounted the whole image on the ctx->0 intercept: the context model
      (`ms/pass = 1.186*ctxK + 47.2`, see `vllm.md`) makes the ~15 ms only ~11.5% of a 130 ms
      forward pass at 70K, while the context term is 64% of it. That reasoning still holds *for
      GDN-WMMA*, which is a fix to the fixed term. It does NOT transfer to the rest of the image,
      and applying it there was the error — corrected 2026-08-30:

        - The **R4D attention backend** (`--attention-backend R4D`) claims **+14.6% prefill at 64K**
          and +4.1% at 16K, decode unchanged. That is a *context-scaling* claim, not an intercept
          one: it gets better as context grows, and 40-70K is precisely the band this box runs an
          agentic loop in. It is the one radiance feature aimed at the regime we are actually in.
          Shape constraints are strict (head_dim 256, paged block 16, 6 q-heads per kv-head, causal,
          bf16 query, bf16 or fp8_e4m3 KV) and it refuses at startup with a reason if unmet — so
          "does it even engage on Qwen3.8-27B-FP8" is a five-minute check, not a project.
        - The **TP=2 one-shot all-reduce** (`RADIANCE_USE_R4D_AR=1`, `ar_oneshot_2rank_exact` from
          libr4d) claims a 42% cut in per-step all-reduce, with a Walsh-Hadamard-quantised variant
          (`RADIANCE_USE_R4D_AR_QUANT=1`) claiming +7.2% prefill at 16K / +3.5% at 32K. Our own
          measurement caps this: comm is ~11% of the token budget here (4.5 of 41 ms), so 42% of
          it is ~4-5% at best, and the quantised variant is explicitly NOT bit-identical to RCCL.
          Worth having, not worth chasing on its own.

      Note this is no longer the same software that was surveyed. Radiance is at **0.9.3**
      (2026-08-25), not 0.7.4: `0.7.4` is 2026-08-23, and DFlash2 support plus the libr4d kernel
      switch both landed between them. Read the version off Docker Hub before quoting a feature.

      **The tcclaviger objection is resolved, and `tcclaviger/vllm` is off the list.** The old
      objection was that it shipped no public source, so adopting it meant pinning an unauditable
      binary. That is moot: tcclaviger now contributes to radiance in the open — PR #20
      ("Nrank ar wired in for TP4 and 8 setups") was merged by StillDeadcode on 2026-08-26 — and
      radiance itself is a set of readable patch scripts (`patch_r4d.py`, `radiance_allreduce.py`,
      `patch_gdn_wmma.py`, `patch_dflash2.py`, …) applied over upstream vLLM in its Dockerfile.
      So the auditable path and the hand-written kernels are now the same project; evaluate
      radiance and stop tracking tcclaviger separately.

      **THE BIGGEST CAVEAT, and it is new: radiance 0.9.3 is built on vLLM 0.27.1.** Read straight
      off its startup banner 2026-08-30 (`radiance 0.9.3 / vllm 0.27.1 / torch 2.11.0+rocm7.14 /
      triton 3.6.0 / aiter 0.1.17 / rocm 7.14.0`). 0.27.1 is the exact version this box already
      measured at **~15% slower MTP decode** (34.66 vs 40.75, see `vllm.md`). So radiance does not
      start from our current throughput — it starts ~15% below it, and every hand-written kernel
      has to buy that back before it wins anything. Any A/B has to be radiance-vs-`:latest`
      end to end, never "radiance's claimed +X% on top of what we have now".

      Two smaller things worth knowing before an evaluation:
        - Its baked-in list includes an **"MTP drafter unpad fix (enables
          `disable_padded_drafter_batch` single-stream path)"**. That is the flag we removed on
          2026-08-24 because it crashed EngineCore at concurrency >= 3. Radiance's fix is described
          as the *single-stream* path, so it is NOT evidence the concurrency crash is fixed — check
          n=4 parallel prompts explicitly before believing the +19.1% is available again.
        - `RADIANCE_USE_R4D_AR` is described in its own banner as **byte-identical to RCCL**, while
          `RADIANCE_USE_R4D_AR_QUANT` (rotated 6-bit, ON by default in the image) is explicitly
          **not**. If numerics ever look off, that is the first toggle to turn off.

      Swapping is still a **launcher rewrite**, not a one-line `Image=` change — radiance wants
      `ROCM_AITER_UNIFIED_ATTN` (or `R4D`) where `vllm-serve.sh` hard-codes `TRITON_ATTN` for RDNA4
      numerics, and its own recipe sets ten `VLLM_ROCM_USE_AITER_*` toggles. Test by hand with
      `podman run` against the shared model cache and `bench.py` before touching the quadlet.
      The image is small (4.0 GB compressed vs kyuz0's 32 GB) and is already pulled on the box as
      `docker.io/stilldeadcode/vllm-radiance:0.9.3`, so the pull is no longer part of the cost.
      Its documented run recipe needs `--shm-size 4g --cap-add SYS_PTRACE`; do NOT copy its
      `--group-add render/video` — those groups do not exist in the container and rootless podman
      fails with `Unable to find group render`. `/dev/kfd` is 0666 here anyway.

- [ ] **DFlash2 drafter vs KV-cache group padding — a live coupling, not a rule of thumb.**
      The 2026-08-27 entry above closed the KV-regrouping question with "swap to a multi-layer
      drafter and re-read that warning line". That was a hypothetical when it was written. It is
      not any more: radiance shipped DFlash2 drafter support on 2026-08-25 (`patch_dflash2.py`,
      `--speculative-config '{"method":"dflash",...}'`), so the multi-layer drafter is now a thing
      this box could actually be running, and the two decisions are coupled.

      The arithmetic, restated as a live constraint: our buckets today are 48 GDN + 17 full-attn
      (16 model + the 1-layer MTP head, which merges into the full-attention bucket), min=17,
      4 groups, 68 slots for 65 layers — 3 padding, the 6.25% in the startup warning, and provably
      optimal (gcd(48,17)=1). A DFlash2 drafter forms a THIRD bucket and collapses the group size
      to its own layer count. At 5 layers that is 48/16/5 -> min=5, 15 groups, 75 slots for 69
      layers, ~8% wasted before per-request round-ups — which is where the ~21% reclaim figure in
      the Discord claim came from. So adopting DFlash2 does not just trade acceptance for draft
      cost; it also silently changes how much of the KV pool is real.

      What to do rather than assume: if a DFlash2 arm is ever benchmarked, record `Add N padding
      layers` and the reported KV-cache token count from the SAME startup, alongside tok/s. A
      drafter whose layer count divides evenly into 48 and 16 (4 or 8) costs nothing here; 5 or 7
      is where the pool shrinks. That is a selection criterion for `num_speculative_tokens`' sibling
      knob, not a footnote.

- [ ] Cheap side-lead on the ~15 ms: [ROCm#6347](https://github.com/ROCm/ROCm/issues/6347) reports
      gfx1201 decode locking to ~33 **or** ~26 tok/s at process spawn, randomly, unrecoverable
      without restart. Evidence here is against it — twelve service starts never exceeded 24.3,
      which is one band, not two. Rule it out properly: spawn 5-6 times, record the
      non-speculative baseline each time.

- [ ] **STACK CONSOLIDATION ONTO llama.cpp — scoped 2026-08-30, NOT STARTED.** The decode case is
      made (see the head-to-head in `vllm.md`), so what is left is everything that is not decode.
      Written down so the next session decides rather than re-derives. Order matters: step 1 can
      kill the whole idea in ten minutes.

      **1. Tool calling through lemonade — THE GATE. Test this first, believe nothing until you
      have.** vLLM ships `--enable-auto-tool-choice --tool-call-parser qwen3_coder`, but the bar
      is LOWER than that reads: the launcher forces `VLLM_ENFORCE_STRICT_TOOL_CALLING=0` because
      strict mode 500s with MTP on, so what actually runs today is unconstrained
      `extract_tool_calls`, not grammar-guaranteed syntax. llama.cpp is well placed to match it —
      `--jinja` is DEFAULT-ENABLED on the shipped b1305 build, with `--reasoning-format` for
      `reasoning_content` and GBNF `--grammar` available if constrained output is ever wanted.
      What is UNVERIFIED is the proxy in front of it: whether lemonade's `/api/v1` passes `tools`
      through to llama-server and returns the parsed `tool_calls` shape. Nothing here has ever
      sent a tool-calling request through lemonade. If it does not work, stop — nothing below
      matters.

      **2. The OpenAI surface, which is not a one-line move.** vLLM is `:8000/v1`, model id
      `Qwen/Qwen3.8-27B-FP8`, and it is a POD member — Open WebUI (`:3000`) reaches it pod-locally
      and `BindsTo=north-llm-pod.service`. lemonade is `:13305/api/v1`, model ids `user.<name>`,
      and a STANDALONE container. So consolidation changes every agent config, Open WebUI's
      connection, and the pod topology; the sleep/wake hook already handles both, so that part is
      free.

      **3. Prefix caching — ANSWERED 2026-08-31, this item is closed.** It used to read "vLLM has
      it and it is OFF, which inverts the usual assumption". `VLLM_PREFIX_CACHING` now **defaults
      to true**, so both engines cache prefixes and the asymmetry is gone. Measured: end-to-end
      agentic throughput 24.09 -> 41.63 tok/s, which closes llama.cpp's lead from 2.01x to 1.16x;
      decode unaffected (ms/pass flat within ±0.6%). The advice to test before consolidating was
      right — testing it moved the number that consolidation turns on. Detail in
      `notes/lemonade-vs-vllm.md`.

      **4. Concurrency semantics — the sharpest real difference, and it is a planning constraint.**
      vLLM does continuous batching over a shared paged pool at `--max-num-seqs 4`; a 5th request
      queues and is scheduled as slots free. llama.cpp uses `-np N` FIXED slots and DIVIDES `-c`
      across them — measured this session, `-c 196608 -np 4` gives `n_ctx_slot = 49152`. So on
      llama.cpp max context per stream is `c/np`: raising concurrency lowers per-stream context
      unless total `-c` rises, and VRAM rises with it. vLLM has no such coupling. Any consolidation
      has to pick a (concurrency, per-stream context) point up front instead of leaving it dynamic.

      **5. Quantisation is a quality change nobody has measured.** vLLM runs FP8 (27.8 GB);
      lemonade's fast seed is IQ4_XS (14.0 GB). No quality A/B has ever been run on this box. The
      Q6_K seed exists precisely to keep a higher floor available — decide this deliberately.

      **What `-DGGML_HIP_RCCL=ON` would cost, in image terms.** Today the image ships NO ROCm and
      NO llama.cpp: lemonade downloads a 2.3 GB prebuilt `rocm-nightly` bundle at runtime into
      `~/.local/share`, and the `nightly` pin is what makes gfx1201 work at all (lemonade#1787).
      Building it ourselves means leaving that, two shapes, both real work:

        (a) Ship our own bundle in the image: +2.3 GB for the bundle plus ~0.4 GB for RCCL
            (`librccl.so.1` measured at 350-407 MB inside the vLLM image — it carries per-arch
            kernels). Call it +2.7 GB on an image carrying none of this today, AND we take over
            tracking llama.cpp releases, losing lemonade's auto-update.
        (b) Build in CI, publish the bundle as a release artifact, point lemonade at it. No image
            growth, but new infrastructure, a version pin to maintain, and it is UNVERIFIED
            whether lemonade can be told to use a custom binary path at all.

      Either way the build side needs a HIP/ROCm SDK container for gfx1201 plus RCCL headers —
      build-time cost, not image content.

      **AND THE PAYOFF IS UNQUANTIFIED, so do not lead with this.** Every tensor-split number on
      this box ran on ggml's butterfly fallback. The ceiling can be BOUNDED but not predicted: the
      no-MTP arms realise 1.39x of a theoretical 2x (30.42 -> 42.14), so a perfect reduction would
      be ~60 tok/s there, i.e. up to ~1.4x more. Nobody has measured how much of that gap RCCL
      actually closes. Find a cheaper way to measure the gap before spending an image on it.

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
