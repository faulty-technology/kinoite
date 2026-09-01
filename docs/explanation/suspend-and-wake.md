# Suspend, resume, and waking the box

Two mechanisms that have to be understood together: the LLM suspend hook exists
because S3 with a model loaded hangs the box, and Wake-on-WLAN only recovers a
box that suspended *correctly*.

## The suspend hook is mandatory, not a nicety

`kinoite-llm-sleep.service` stops the LLM stacks before sleep and restores what
was running on resume.

A loaded `Qwen/Qwen3.8-27B-FP8` holds ~28.1 GiB on each R9700 — ~56 GB against
62.8 GB of RAM — and `/sys/power/mem_sleep` is `deep`, so S3 takes the full
amdgpu eviction path. The `pre` edge drains both cards to ~57 MiB in 2–3 s, and
ExecStart completes ~23 ms before `PM: suspend entry`.

In sustained daily use it does what it says: VRAM drains on the way down and
rehydrates on the way back, across days of ordinary suspend/resume cycles. A
side effect worth knowing, because it is the easiest way to tell the hook fired
without reading a journal — **a suspended box is silent.** With the stacks
stopped and VRAM released, nothing holds the cards in D0, so they runtime-suspend
and the fans stop entirely. Fans still spinning after the box goes down means
something is still holding a card awake; see
[gpu-power-and-fans](gpu-power-and-fans.md#the-1950-rpm-floor-was-pollers-then-firmware).

**The failure it prevents is a hard hang, not a failed suspend.** Negative
control, hook disabled, model loaded — the kernel log ends and never resumes:

    PM: suspend entry (deep)
    Filesystems sync: 0.009 seconds
    <nothing>

Every *successful* cycle continues `Freezing user space processes` → `PM: suspend
devices took 0.116 seconds` → `PM: suspend exit`. The wedge dies in the
device-suspend phase with no error, no OOM, no eviction warning. At the desk:
powered, fans audible, blank monitor, no network. Only a held power button
recovers it. Nothing is lost (ostree plus persistent journal).

**That is why the unit is `RequiredBy=sleep.target`.** A soft `Wants=` would let
a failed hook suspend into that hang. It also means opting out is
`systemctl disable`, not `mask` — masking leaves sleep.target requiring a masked
unit and the box cannot suspend at all.

## Constraints worth not re-discovering

- **`systemctl --user --machine=<user>@.host` does not work on this image.**
  sd-bus implements it by spawning a transient system unit running
  `systemd-stdio-bridge` (`-pUser=… -pPAMName=login`), and that spawn fails with
  `Connection reset by peer`. `systemd-run -M` fails identically, so it is not
  systemctl; zero AVCs, so it is not SELinux. Root exporting `XDG_RUNTIME_DIR`
  and calling `systemctl --user` is refused too, and systemd's own hint is to use
  `--machine`. What works, including from a service context (`initrc_t`):

      runuser -u <user> -- env XDG_RUNTIME_DIR=/run/user/<uid> systemctl --user

  `setpriv` works too and skips the PAM session pairs that runuser logs. runuser
  inherits the caller's cwd, hence the `cd /` in the helper.
- **systemd freezes `user.slice` across sleep.** That rules out a
  `/usr/lib/systemd/system-sleep/` drop-in, which runs inside
  `systemd-suspend.service` — inside the frozen window — and is why the hook is a
  unit ordered `Before=sleep.target` instead.
- **Quadlet dependency directions** (podman 5.8.4): members get
  `BindsTo=north-llm-pod.service`, the pod gets `Wants=` + `Before=` its members,
  and `Upholds=` is empty everywhere. So stopping the pod tears down members, and
  starting any one member starts both.
- **`StopWhenUnneeded=yes` self-stops a manually started unit** (~40 ms), so
  `systemctl start kinoite-llm-sleep` runs both edges back to back and is not a
  pausable test — call `kinoite-llm-sleep pre` / `post` directly. The real path is
  unaffected: during a sleep cycle sleep.target holds a reference until resume.
- **Hibernate is unavailable.** `/sys/power/state` is `freeze mem` with no
  `disk`, and logind logs `Lockdown: … hibernation is restricted`. Secure Boot
  lockdown, not configuration.

## Wake-on-WLAN

Works end to end. The trigger is armed (`iw phy0 wowlan show` → `wake up on magic
packet`), the PCIe function reads `power/wakeup = enabled` — so rtw89 does
implement cfg80211's `set_wakeup` and **no udev rule is needed** — and a magic
packet to the Wi-Fi MAC wakes the box.

Not routable: the sender must be on the same L2 segment, so this never works over
Tailscale.

For contrast, both r8169 NICs read `wakeup = disabled`. That is where a rule
would go if wired WoL is ever wanted.

**WoL recovers a suspended box, not a hung one.** A wedged machine sits powered
with the network dead and no packet reaches it. That asymmetry is exactly why the
suspend hook is `RequiredBy=sleep.target`: it refuses the suspend rather than
entering a state you cannot recover remotely.

Already ruled out, do not re-add: `ethtool -s <wlan> wol g` — mac80211's
`ieee80211_ethtool_ops` has no `set_wol`, so it is EOPNOTSUPP on every mac80211
driver — and `iw dev ... set power_save off`, which is runtime power save, not a
wake trigger. Both look like they work, because the failure is silent.
