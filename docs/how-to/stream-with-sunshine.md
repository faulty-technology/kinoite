---
type: How-To
title: "Stream the north box with Sunshine"
description: "Streaming the north box over Sunshine: enabled for every user at login, pairing is the only manual step, the virtual monitor is created on demand at the client's geometry, and what to read when Moonlight returns Error 503."
---

# Stream the north box with Sunshine

Sunshine is enabled for every user at login. Pairing is the only manual step.

## First stream

1. Open `https://127.0.0.1:47990` and pair your client.
2. Stream. The virtual monitor is created on demand at the client's geometry and
   torn down when the stream ends.

Nothing else needs configuring. `capture`, `output_name` and `global_prep_cmd`
are seeded into `~/.config/sunshine/sunshine.conf` on service start.

A dummy plug (or a forced connector) must be present at boot. Sunshine's
launch-time encoder probe needs an output that exists before any prep command
runs, so no command-driven display can satisfy it — see
[explanation/sunshine-capture](../explanation/sunshine-capture.md).

## If Moonlight fails with Error 503

The client connects, then reports **Error 503** for every codec — H.264 included. That
means the host found no display or encoder when it started; nothing the client picks can
fix it. Sunshine chooses its capture method and encoder once at process start, so a host
that started with nothing lit keeps refusing until it is restarted, even after displays
come back.

Read the startup log first:

    systemctl --user restart app-dev.lizardbyte.app.Sunshine.service
    journalctl --user -u app-dev.lizardbyte.app.Sunshine.service -b --no-pager | tail -40

Then check what the compositor can see. Over SSH there is no session environment, so set
it — and take the socket name from the runtime directory rather than assuming it:

    export XDG_RUNTIME_DIR=/run/user/$(id -u)
    export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
    export WAYLAND_DISPLAY=$(ls "$XDG_RUNTIME_DIR" | grep -oE '^wayland-[0-9]+$' | head -1)
    kscreen-doctor -o

| Log line | What it means |
| --- | --- |
| `[kwingrab] cannot connect to Wayland display: wayland-N` | The unit's `WAYLAND_DISPLAY` names a socket that does not exist. Compare with `ls $XDG_RUNTIME_DIR \| grep wayland-`; KWin prints its own with `pgrep -a kwin_wayland`. The units resolve the socket at start via `/usr/libexec/sunshine-wayland-env`, which logs `using wayland-N` — if that line is missing, or it names a socket you do not see in `$XDG_RUNTIME_DIR`, check for a stale per-user override under `~/.config/systemd/user/app-dev.lizardbyte.app.Sunshine.service.d/` pinning the variable. |
| `[kwingrab] no wl_output found` | No output is lit. `kscreen-doctor dpms.on`, enable the connected outputs, restart Sunshine. |
| `sunshine-virtual-display: inherited WAYLAND_DISPLAY=[…] is not a live socket; re-resolving` | KWin restarted mid-session and the session came back on a different socket. The helper re-resolves per stream, but Sunshine's capture method was chosen when it started — restart the unit. |
| `Fatal: Unable to find display or encoder during startup` | The startup probe found nothing — a dummy plug or forced connector must be present at boot. |

If no output is enabled (an aborted `--exclusive` stream), light one and restart:

    kscreen-doctor output.HDMI-A-3.enable

To test the display path on its own, run the helper by hand with the session environment
above — `/usr/libexec/sunshine-virtual-display ensure 1920 1080 60` then `kscreen-doctor -o`
must list `Virtual-sunshine-vm`. If that works but the stream still fails, the problem is
capture or encode, not display creation; finish with `/usr/libexec/sunshine-virtual-display down`.

The dummy plug belongs on a dGPU port, not the motherboard: the output it sits in owns the
compositor and VAAPI follows it. Identify it by PCI id — `1002:7551` is an R9700, `1002:13c0`
is the Ryzen iGPU:

    for c in /sys/class/drm/card[0-9]; do echo "$c $(grep PCI_ID $c/device/uevent)"; done

Encoding on the iGPU still streams (HEVC works), it just costs AV1. Why the cable decides
this is in [explanation/sunshine-capture](../explanation/sunshine-capture.md); the 2026-11-09
incident, where a stale hard-coded socket name produced this exact 503, is in
[runs/2026-11-09-north-sunshine-503](../runs/2026-11-09-north-sunshine-503.md).

## If the stream arrives at the wrong aspect ratio

Seeding only ever adds *missing* keys, so a pre-existing config keeps whatever
it had. Check these three under **Configuration → Advanced / General**:

    capture           kwin
    output_name       Virtual-sunshine-vm
    global_prep_cmd   do:   /usr/libexec/sunshine-virtual-display ensure
                      undo: /usr/libexec/sunshine-virtual-display down

To re-seed a key, delete its line and restart the service.

## Migrating a pre-2026-08 config

If `global_prep_cmd` points at `sunshine-virtual-display up`, or its `undo` is
`ensure`, edit `~/.config/sunshine/sunshine.conf` to the `ensure` / `down` pair
above.

`undo: ensure` leaves the monitor running between streams, which keeps krfb
holding a render node and prevents the GPU behind it from runtime-suspending.
That is the whole reason the monitor is on-demand.

## Streaming with the physical panels off

By default only *new* windows open on the virtual display — making it primary is
all KWin honours. Disabling the physical outputs is what migrates windows already
running on them.

Change the **Do** command, globally or on a single app entry:

    /usr/libexec/sunshine-virtual-display ensure --exclusive

Per-app is the point of the flag: Sunshine parses prep commands without a shell,
so an env var cannot be set from an app entry.

The seeded `undo` (`down`) re-enables whatever `--exclusive` disabled, and
`ExecStopPost` does the same if Sunshine stops mid-stream.

## If the desktop is left with all outputs off

A stream that ended abnormally before its undo ran:

    kscreen-doctor output.HDMI-A-3.enable

A login-path net also re-enables connected outputs when none are on.

## Headless

`sunshine-virtual-monitor.service` ships un-enabled, because krfb pins whichever
GPU backs the monitor into D0 for as long as it runs. For a genuinely headless
box that trade is worth it:

    systemctl --user enable --now sunshine-virtual-monitor.service

Use `--user`, not `--global`: a `systemctl --global enable` cannot be undone with
`--user disable`, only with `--user mask`.
