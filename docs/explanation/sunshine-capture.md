# Why the Sunshine setup looks the way it does

Every non-obvious piece of `sunshine.sh` is defending against something that
presents as a different problem than it is.

## The display cable decides which GPU does everything

The output owns the compositor and the VAAPI device follows it. With the dummy
plug on the motherboard HDMI, Sunshine encoded on the iGPU. Moving it to an
R9700 port fixed that and brought AV1 encode.

`adapter_name` is the wrong fix: it repoints only the encoder, leaving the
compositor on the iGPU and the cross-GPU copy in place. Keep the plug on a dGPU.

Cost: that R9700 then owns compositing and coil-whines on UI animations.
Disabling desktop animations stops it. Harmless, not a fault.

## A dummy plug is required, but only for the startup probe

With no output, KWin keeps running with zero outputs. What dies is Sunshine's
encoder probe at launch (`[kwingrab] no wl_output found` → `Fatal: Unable to
find display or encoder`).

This is a **timing** problem, not a mechanism one: `global_prep_cmd` fires when
a client connects, long after the probe, so **no command-driven display can ever
satisfy it.**

Ways to drop the plug, all untested:

- `video=<connector>:1920x1080@60e` in `kargs.d` — preferred, a real DRM output
  with no userspace process holding a render node. Caveat: `video=` matches by
  connector name and with three amdgpu devices those names are not unique;
  confirm which card takes it.
- `drm.edid_firmware=<connector>:edid/<file>.bin` with a blob in
  `/usr/lib/firmware/edid/`. May need it in initramfs.
- A persistent `krfb-virtualmonitor` unit ordered before Sunshine. Last resort:
  krfb holds a render node the whole time it runs, which buys back the
  always-awake dGPU that going on-demand eliminated.

## Why the config is seeded — don't "simplify" it away

Default `kms` capture enumerates DRM connectors only, so it discarded the
virtual monitor (`Unknown Monitor connector type`) and silently streamed the
physical panel. Hence `capture = kwin`, `output_name` and `global_prep_cmd`
seeded from `ExecStartPre`.

The Arch-only `CAP_SYS_NICE` bug does not apply — Fedora sets
`%caps(cap_sys_nice=ep)` on `kwin_wayland` — and
`KWIN_WAYLAND_NO_PERMISSION_CHECKS=1` is not needed.

Seeding only ever adds *missing* keys, so an existing `sunshine.conf` keeps a
stale `undo … ensure`. Fix it in the Web UI, or delete the `global_prep_cmd`
line and let it re-seed.

## `--exclusive` is needed in practice

Making the virtual output primary governs only *new* windows. Disabling the
physical outputs is what migrates existing ones.

## Restore state must outlive whatever it restores

`--exclusive` recorded disabled outputs in `$XDG_RUNTIME_DIR` (tmpfs) while the
damage it undid — KDE's `~/.config/kwinoutputconfig.json` — persists on disk. So
any abnormal end to a stream left outputs off permanently. It presented as "the
iGPU doesn't work".

Fixed by moving state to `$XDG_STATE_HOME/sunshine-vm/`, plus a login-path net
that re-enables connected outputs when none are on. `PIDFILE` deliberately stays
in the runtime dir — a PID from a previous boot is worse than none.

Recovery: `kscreen-doctor output.HDMI-A-3.enable`.

Note a `systemctl --global enable` cannot be undone with `--user disable`; it
needs `--user mask`.

## The virtual monitor is on-demand, not at login

krfb pins whichever GPU backs it into D0 for as long as it runs. So
`sunshine-virtual-monitor.service` ships un-enabled — still the right answer for
a genuinely headless box — the seeded `undo` is `down` rather than `ensure` so
the monitor dies with the stream, and `down` refuses to run when no physical
output is *connected*, so it cannot strand a headless box.

## Not Sunshine's job

Clipboard sync is KDE Connect's. Sunshine has none in any build: upstream closed
host→client on security grounds (#1539) and the text-only proposal as
`not_planned` (#5384).
