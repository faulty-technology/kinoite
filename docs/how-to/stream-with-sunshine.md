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
