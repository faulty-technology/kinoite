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

**R9700 fan control does not work, in any tool.** hwmon exposes `fan1_enable`,
`fan1_target`, `fan1_input`, `fan1_min/max` but no `pwm1_enable` and no
`gpu_od/fan_ctrl/`; reading `fan1_enable` returns EINVAL. This matches reports of
an amdgpu SMU interface version mismatch specific to the R9700 that breaks fan
control across LACT, rocm-smi and amd-smi alike, while undervolt/clock/power tuning
keeps working. A greyed-out fan curve is this, not a LACT or karg problem.
Monitoring is unaffected — `sensors` reports fan RPM, edge/junction/mem temps, and
`PPT (cap = 210.00 W)`, confirming the LACT power cap persists.

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
same file fine and emits `lemonade.service`. Hence `llm.sh` writes to `/etc`, which
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
tuning knob — hence the seeded `rocm_channel` in `llm.sh`.

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
- [ ] Fan control, decisive local check: `cat .../fan1_target`, then `echo 2600 |
      sudo tee .../fan1_target` and watch `fan1_input`. Raise only — a low setpoint
      on a workstation blower is a thermal risk. Reverts on reboot.
- [ ] Recheck fan control on kernel/linux-firmware bumps; it's a driver bug, not a
      hardware limit. Don't bake a fan curve until a write is proven to take effect.
- [ ] HDR, if wanted: `mesa-vulkan-drivers-freeworld` supersedes `VK_hdr_layer`,
      but RPM Fusion trails Fedora's mesa (26.0.3 vs 26.1.6), so we don't swap it —
      a Vulkan downgrade on RDNA4 is the worse trade. Revisit if RPM Fusion catches
      up and gamescope HDR turns out to matter.

### Containerized ROCm + lemonade — `build_files/profiles/north/llm.sh`

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
      user: `ls -ln ~/.local/share/lemonade/huggingface` after the first model pull. A
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

**Baked recipe set (resolved 2026-08-15).** `llm.sh` now seeds four Unsloth Qwen custom
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
