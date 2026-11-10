---
type: Run
date: 2026-11-09
subject: "moonlight Error 503 after auto-update — the hardcoded WAYLAND_DISPLAY socket was stale"
harness: "Ad hoc over `ssh north@kinoite-north 'bash -s'` with a read-only evidence bundle (session, kscreen-doctor, DRM topology, unit + journal, config, versions, deploy timing). No harness committed; the commands are quoted inline below. Encoder matrix was left unbounded and hung on the first render node — see follow-ups."
box: kinoite-north
---

# moonlight Error 503 after auto-update — the hardcoded WAYLAND_DISPLAY socket was stale

## What was measured

Moonlight failed every codec — H.264, HEVC and AV1 all returned **Error 503** — on a
box that had streamed fine before the bootc auto-update (deployed `2026-11-09`,
booted `12:15`). All three codecs failing points at capture or session, not at encoder
capability, so the iGPU/dGPU question was set aside as a secondary finding.

The service was up and enabled, the session was active with linger on, and KWin was
running. The unit log carried the failure at startup:

    [kwingrab] cannot connect to Wayland display: wayland-0
    Encoder [nvenc] failed / [vulkan] failed / [vaapi] failed / [software] failed
    Fatal: Unable to find display or encoder during startup.

`/run/user/1000` held exactly one compositor socket, `wayland-1`, and KWin had been
started `--socket wayland-1`. There is no `wayland-0` on this box. The image drop-in
`app-dev.lizardbyte.app.Sunshine.service.d/10-kinoite-north.conf` pins
`Environment=WAYLAND_DISPLAY=wayland-0`, so capture could never attach, the encoder
probe found nothing to encode, and — because Sunshine chooses its capture method and
encoder once at process start (upstream PR #6052 is not in the shipped `sunshine-2026.914.233613-4.fc44`) — every client got 503 for the life of the process regardless of display state later.

The same wrong socket explains a misleading log line:
`sunshine-virtual-display: refusing to tear down: no connected physical output to fall
back to`. The helper's `outputs_state()` runs `kscreen-doctor -o 2>/dev/null` and never
checks the exit status, so "cannot reach the compositor" is indistinguishable from
"genuinely headless". That message was a dead compositor, not missing hardware.

## Numbers

Fix applied as the user (`~/.config/systemd/user/app-dev.lizardbyte.app.Sunshine.service.d/20-wayland-socket.conf`, `[Service] Environment=WAYLAND_DISPLAY=wayland-1`, `daemon-reload`, restart):

| Check | Before | After |
| --- | --- | --- |
| `systemctl --user show -p Environment` | `WAYLAND_DISPLAY=wayland-0` | `WAYLAND_DISPLAY=wayland-1` |
| `[kwingrab] cannot connect` | every startup | absent |
| capture | none | `[pipewire] Streaming display 'Virtual-sunshine-vm' 1920x1080` |
| encoder | all four failed | `Creating encoder [hevc_vaapi]` |
| Moonlight | Error 503 on H.264/HEVC/AV1 | streams |

Secondary findings, not causal:

- DRM topology: `card1` and `card2` are PCI `1002:7551` (the two R9700s) with no
  connected display connector at all; `card3` is `1002:13c0`, the Ryzen iGPU, and owns
  the only connected output, `HDMI-A-3`. The dummy plug is on a motherboard port, which
  contradicts invariant (a) of [explanation/sunshine-capture](../explanation/sunshine-capture.md)
  — VAAPI follows the output, so encoding is happening on the iGPU. It still works:
  `hevc_vaapi` came up and the stream ran. What the iGPU costs is AV1 and the cross-GPU
  copy, not the ability to stream.
- Seeded config intact: `capture = kwin`, `output_name = Virtual-sunshine-vm`,
  `global_prep_cmd` with the `ensure`/`down` pair. No stale `up` variant.
- Versions at failure: `sunshine-2026.914.233613-4.fc44`, `plasma-workspace-6.8.2-1.fc44`,
  `libkscreen-6.8.2-1.fc44`, `krfb-26.08.2-2.fc44`, `mesa-va-drivers-freeworld-26.2.6-1.fc44`.

## What it means

The auto-update did not break Sunshine's code, but it did change something: `/run/user/1000`
contains no `wayland-0` at all, only `wayland-1` and its lock. That is the signature of a
second compositor having held `wayland-0` earlier in the boot and released it — normally an
SDDM Wayland greeter — which pushes the session KWin to `wayland-1`. The drop-in's
`wayland-0` was correct while the session landed on socket 0, so the rebase is the trigger
even though the stale hard-code is the cause. **The trigger is unconfirmed**: it needs
`loginctl session-info` and `[General] DisplayServer` from `/etc/sddm.conf{,.d/}` on the box,
which was not collected this session. What is confirmed is that any hard-coded socket number
is a latent bug, because socket numbering depends on what else was running before KWin.

**The working state rests on a per-user file.** `~/.config/systemd/user/…` survives a
bootc rebase and will mask an image-level fix once one ships, so the follow-up is not
optional:

1. Remove `Environment=WAYLAND_DISPLAY=wayland-0` from both places in
   `build_files/profiles/north/sunshine.sh` — the Sunshine drop-in (line 395) and
   `sunshine-virtual-monitor.service` (line 426, identical bug). A user unit starts
   before KWin exists, so it cannot inherit the variable either; resolve the socket at
   exec time. **Globbing `$XDG_RUNTIME_DIR/wayland-*` is not sufficient** — at boot that
   glob can match the greeter's transient `wayland-0` (the same bug), or come back empty
   because KWin has not started yet. The resolver must *probe for a compositor that
   answers* and retry with a deadline: for each candidate socket, export
   `WAYLAND_DISPLAY` and require `kscreen-doctor -o` to return at least one output before
   accepting it, preferring the highest-numbered live socket only as a tie-break. Write
   the winner to an `EnvironmentFile=%t/sunshine-wayland.env` from `ExecStartPre`, or
   export it in an `ExecStart` wrapper and `exec` — the latter also fixes
   `global_prep_cmd`, since the helper inherits Sunshine's environment.
2. Delete the per-user override once the image fix is deployed, so it cannot hide a
   future regression.
3. The helper should distinguish "cannot reach the compositor" from "no outputs" —
   check `kscreen-doctor`'s exit status in `outputs_state()` instead of swallowing it.
4. Move the dummy plug to an R9700 port for AV1 and to keep VAAPI on the GPU that owns
   the compositor; not required to stream.
5. An encoder probe hung indefinitely (`ffmpeg -vaapi_device … -f null -`, first render
   node). Wrap each probe in `timeout`.

Whether this warrants an upstream report is unclear: the init-once encoder probe is
already fixed upstream in PR #6052, and the stale socket is ours, not LizardByte's.

## Decision on the plug

Follow-up 4 was closed as declined on 2026-11-09: with HEVC encoding correctly on the
iGPU and the stream stable, the operator chose to leave the dummy plug on the motherboard
port rather than open the case for AV1. Invariant (a) of
[explanation/sunshine-capture](../explanation/sunshine-capture.md) is unchanged by this — it
describes which GPU ends up doing the work, not a requirement to stream at all.

## Follow-up 1 landed (same day)

`build_files/profiles/north/sunshine.sh` now ships `/usr/libexec/sunshine-wayland-env`, and
both units read `EnvironmentFile=-%t/sunshine-wayland.env` instead of a pinned socket: the
hardcoded `Environment=WAYLAND_DISPLAY=wayland-0` is gone from the Sunshine drop-in and from
`sunshine-virtual-monitor.service`. The resolver asks KWin (uid-filtered, via its own
`--socket` in `/proc/<pid>/cmdline`) which socket it opened and requires that
`kscreen-doctor -o` enumerate an output through it before accepting it; with no usable KWin
it probes every `wayland-*` candidate highest-numbered first, retrying to a 60 s deadline and
exiting 1 with a message if nothing ever answers. The uid filter is what keeps a greeter's
transient socket out of the running — a bare glob would have matched it.

Harness: `/usr/libexec/sunshine-wayland-env` driven against a stub `kscreen-doctor` in a
scratch `XDG_RUNTIME_DIR` holding both `wayland-0` and `wayland-1`. Three cases passed — only
`wayland-1` answering, both answering (highest wins), nothing answering (exit 1 after the
deadline). The KWin-cmdline branch was checked by parsing a captured real cmdline, not against
a live KWin; it is the fallback that carries the three harness cases.

Still owed: delete `~/.config/systemd/user/app-dev.lizardbyte.app.Sunshine.service.d/20-wayland-socket.conf`
on north after an image containing this lands, or it keeps masking the shipped resolver. The
trigger for the socket change (SDDM greeter holding `wayland-0`) remains unconfirmed — the
resolver makes it moot for streaming, not for understanding it.

## Addendum — two defects in the fix above (same day)

The resolver as first written traded one failure mode for two others, both found in review
before shipping rather than on the box.

**Liveness was measured as output count.** The probe required `kscreen-doctor -o` to print an
`Output:` line, but KWin keeps running with zero outputs on a headless box — the exact state
`sunshine-virtual-monitor.service` exists to serve. That socket is live yet produced no
answer, so the resolver spun its full deadline, exited 1, and left both units without
`WAYLAND_DISPLAY`: the fix for today's stale socket would have foreclosed the headless path
and any future `video=` karg attempt. It now tests that the socket exists (`-S`) and that
either `kscreen-doctor` exits 0 or a KWin owned by this uid names that socket, and it logs the
output count separately — `using wayland-1 (0 output(s))` is a success, not a failure.

**The socket was resolved once and frozen.** A user unit resolves at start and
`global_prep_cmd` only inherits Sunshine's copy, so a mid-session KWin restart (crash, display
reconfigure) can move the session to another socket while Sunshine keeps pointing at the dead
one — same Error 503 symptom, new trigger, and harder to see with no hard-code left to blame.
`sunshine-virtual-display` now checks its inherited socket per prep command and re-runs the
resolver when it is not live. The check branches on a leading `/`, because `WAYLAND_DISPLAY`
may legitimately hold an absolute socket path; joining that onto `$XDG_RUNTIME_DIR` would test
a nonsense path and re-resolve over a good value every time.

Harness, same scratch-runtime-dir method as above with real AF_UNIX sockets bound (a `touch`ed
file is not a socket and `-S` correctly rejects it — that was a fixture bug, not a code bug):

| Case | Result |
| --- | --- |
| live socket, zero outputs, 60 s deadline | resolved immediately, rc=0, `(0 output(s))` — previously rc=124 with no env file |
| inherited bare `wayland-1`, socket present | untouched, no re-resolve |
| inherited absolute `/run/user/…/wayland-1` | untouched, no re-resolve |
| inherited `wayland-0`, not present | one re-resolve, lands on `wayland-1` |

Still true from the earlier section: none of this is exercised against a live KWin until an
image containing it is built.
