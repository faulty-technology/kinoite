# kinoite-north — hardware notes

AMD 9900X, dual Radeon AI PRO R9700 (RDNA4 / gfx1201), ASUS ProArt B850-Creator
WiFi Neo. Validated on the real box 2026-08-08/09 on kernel 7.1.7-200.fc44 with
mesa 26.1.6. **Settled** records constraints and non-obvious causes worth keeping;
**Open** is what's left to verify. Code that depends on an open item carries a
`TODO(hardware):` comment pointing here.

## Settled

**GPU node map** (`ls -l /dev/dri/by-path/` + `lspci -nn`). Numbering is not stable
across kernel or slot changes — re-derive rather than trusting it.

| PCI     | card  | render     | GPU                  |
|---------|-------|------------|----------------------|
| 03:00.0 | card1 | renderD128 | R9700 #1 (Navi 48)   |
| 06:00.0 | card2 | renderD129 | R9700 #2 (Navi 48)   |
| 10:00.0 | card3 | renderD130 | iGPU (Granite Ridge) |

**The display cable decides which GPU does everything.** With the dummy plug in the
motherboard HDMI port, Sunshine encoded on the iGPU (`vaapi vendor: ...
raphael_mendocino`) — the output owns the compositor, and the VAAPI device follows
the compositor. Moving the plug to an R9700 port fixed it and brought AV1 encode
with it. `adapter_name` is the wrong fix: it repoints only the encoder, leaving the
compositor on the iGPU and the cross-GPU copy in place. Keep the plug on a dGPU.

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

## Open

### Sunshine — `build_files/profiles/north/sunshine.sh`

- [ ] Crash safety, the one that matters most: `systemctl --user kill -s KILL
      app-dev.lizardbyte.app.Sunshine.service` mid-stream, and confirm the
      `ExecStopPost` teardown drops the virtual monitor and re-enables the physical
      output. A failure here in exclusive mode means a black desk.
- [ ] Clean restore on normal disconnect — physical output back, previous primary
      restored, desk window layout intact after `--exclusive`.
- [ ] Refresh rate follows the client: a 120Hz client should get `addCustomMode` +
      `mode` applied (krfb only ever creates the monitor at 60Hz). Only 60Hz seen
      so far, where the mode already exists and `addCustomMode` is correctly
      skipped. Check `kscreen-doctor -o` mid-stream for the `*` on `WxH@120.00`.

### GPU — `build_files/profiles/north/amdgpu.sh`, `tuning.sh`

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

- [ ] Pick a gfx1201-capable ROCm **7.2+** container image (Fedora 44's host ROCm is
      too old — this is why ROCm stays containerized).
- [ ] `TAG+="uaccess"` actually lands on `/dev/kfd` — it's a non-DRM device, so
      whether logind assigns it to a seat is the open question. Check `getfacl
      /dev/kfd` while logged in locally: the login user should appear in the ACL
      without being in `render`. If not, the `usermod -aG render,video` fallback
      becomes mandatory again — and it stays mandatory for headless/SSH use either
      way, since no active seat means no ACL.
- [ ] Rootless podman passes through `/dev/kfd` + `/dev/dri` (see `70-kfd.rules` in
      `amdgpu.sh`).
- [ ] lemonade runs against the R9700 in a container.
- [ ] Codify the working setup as a Quadlet `.container` unit baked into the image
      and enabled from `services-north.sh` (replaces the current no-op in `llm.sh`).

### Build

- [ ] If a build fails on a GPG mismatch, re-verify every pinned fingerprint with
      `build_files/scripts/lib/check-keys.sh` (it diffs pins against the live vendor
      keys and exits nonzero on drift).
