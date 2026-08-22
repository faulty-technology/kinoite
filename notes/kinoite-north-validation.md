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

### GPU — `build_files/profiles/north/amdgpu.sh`, `tuning.sh`

Settled and now explained at the code: `70-kfd.rules` was **removed** — it tightened the
0666 the base `50-udev-default.rules` already gives `/dev/kfd`, which is what made
`usermod -aG render` look necessary headless (rationale in `amdgpu.sh`; verified `666
render` on the box). HDR is unblocked — RPM Fusion's `mesa-vulkan-drivers-freeworld` has
caught up to Fedora's mesa, so swapping no longer downgrades Vulkan; it is now purely a
"do you want gamescope HDR" call (rationale in `codecs.sh`). Fan control and the ~1950 RPM
floor are in Settled; operationally, keep OD nodes out of the LACT config and leave LACT on
**Automatic**.

**LACT can be made to poll politely.** `/etc/lact/config.yaml` carries `interval_ms: 500`
per profile — it polls twice a second, and it is a plain config key. Pushing it past the 5 s
autosuspend delay should let the dGPUs idle between polls (untested). Polling really is the
whole story: with `lactd` stopped both R9700s reach `runtime_status=suspended` while the iGPU
stays active driving the desktop. Note the box has `lactd` disabled locally even though
`tuning.sh` enables it in the image.

- [ ] Undervolt is the actual tuning goal (not a fan curve). The ppfeaturemask karg
      already baked is what unlocks the mV offset — no karg change needed. Tune a
      per-card negative GPU voltage offset in LACT (start −50 mV, step −25 mV under
      sustained load until unstable, back off one step; two dies may differ), pair
      with the existing 210 W PPT cap, confirm stable across a reboot via
      `/etc/lact/config.yaml`, THEN bake the proven offsets into `tuning.sh`. Bake
      only after load-testing — a too-aggressive offset would make a fresh install
      unstable at boot.

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
- **`disable_padded_drafter_batch:true` is now the default**, +19% decode, coupled to
  `--no-async-scheduling` because that pairing is what was measured.
- **k sweep re-run under that default: the knee did not move, k=3 stays.** The flag lifts every k
  by about the same amount, so it and speculation depth are independent levers.
- **`ksweep.py` is baked** next to `bench.py` — re-running the sweep no longer means writing a
  driver first, which is how k=1 once survived a day.

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
