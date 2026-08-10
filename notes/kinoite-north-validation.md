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

The Quadlet is now baked (`/usr/share/containers/systemd/users/lemonade.container`),
deliberately **not** enabled — no `[Install]`, nothing in `services-north.sh`. Nothing
below has been run on the box yet; on-box runbook is `/usr/share/kinoite/lemonade.md`.

- [ ] `TAG+="uaccess"` actually lands on `/dev/kfd` — it's a non-DRM device, so
      whether logind assigns it to a seat is the open question. `getfacl -p /dev/kfd`
      while logged in locally: the login user should appear without being in `render`.
      No active seat (SSH) means no ACL either way. Do the `stat` check under GPU
      above first — it may make this moot.
- [ ] Rootless podman can open the devices at all. Cheapest probe, before any Quadlet:
      `podman run --rm --device /dev/kfd --device /dev/dri
      ghcr.io/lemonade-sdk/lemonade-server:latest sh -c 'exec 3<>/dev/kfd && echo OK'`.
      Devices display as `nobody:nobody` inside a userns — cosmetic; the kernel checks
      the unmapped gid. Judge by the open, not by `ls`.
- [ ] SELinux `map` on `/dev/kfd`. `container-selinux` grants `hsa_device_t:chr_file
      rw_chr_file_perms` unconditionally, but that set is `{open getattr read write
      append ioctl lock}` — no `map`, and ROCm mmaps the node. (`/dev/dri` is fine:
      `container_use_dri_devices` defaults on and `dev_rw_dri` grants `map`
      explicitly.) Look for `sudo ausearch -m AVC -ts recent | grep hsa_device_t`; fix
      with `sudo setsebool -P container_use_devices on`. Not baked on purpose —
      `setsebool -P` state lives in `/var/lib/selinux` and can't ship in the image
      (same constraint as `nix-selinux.service`), and the boolean grants `map` on every
      device to every container. If it proves permanent, narrow it to a CIL module for
      `hsa_device_t` installed from a oneshot.
- [ ] `UserNS=keep-id:uid=10001,gid=10001` gives host-side files owned by the login
      user: `ls -ln ~/.local/share/lemonade/huggingface` after the first model pull. A
      subuid owner means keep-id didn't apply and the bind mounts are pointless. Needs
      `grep "^$USER:" /etc/subuid` non-empty and sized > 10001.
- [ ] `GroupAdd=keep-groups` — confirm effective or delete the key. Known-flaky here:
      containers/podman#27876 (inert in rootless Quadlets; groups come from the
      `systemd --user` manager, so `usermod -aG` needs `loginctl terminate-user`) and
      #28364 (device gids under keep-id). Only matters if `/dev/kfd` isn't 0666 *and*
      the box is driven headless.
- [ ] lemonade actually *uses* the R9700 rather than silently falling back to CPU.
      The failure mode is quiet, so this needs a tok/s comparison against a CPU run,
      not a "does it start" check.
- [ ] The `nightly` seed took: `podman exec lemonade lemonade config get rocm_channel`.
      lemond only honours `defaults.json` on the first run — after that `config.json`
      shadows it, so a stale config dir looks identical to a failed seed.
- [ ] The iGPU warmup segfault. lemonade-sdk/lemonade#1921 and llamacpp-rocm#96: ROCm
      llama.cpp segfaults at model warmup when a gfx1201 dGPU and a gfx1036 iGPU are
      both enumerated. This box is exactly that pair (10:00.0) and `AddDevice=/dev/dri`
      exposes all three. Not designed around on purpose. If it bites:
      `llamacpp.rocm_args="-mg 0 -sm none"`, or shadow the unit from
      `~/.config/containers/systemd/` pinning only the R9700 render nodes (re-derive
      them from `by-path`). Re-test on lemonade bumps.
- [ ] Whether it stays hand-started. If it earns its keep the change is `[Install]
      WantedBy=default.target` in the quadlet plus `loginctl enable-linger` — *not* a
      line in `services-north.sh`, since `systemctl --global enable` doesn't apply to
      generator-produced units.

### Build

- [ ] If a build fails on a GPG mismatch, re-verify every pinned fingerprint with
      `build_files/scripts/lib/check-keys.sh` (it diffs pins against the live vendor
      keys and exits nonzero on drift).
