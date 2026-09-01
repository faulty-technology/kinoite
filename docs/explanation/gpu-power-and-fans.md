# GPU power, fans, and why tuning here is hard

Three findings shape every tuning decision on this box: the OverDrive karg has
to be applied a specific way, nothing in the OverDrive table survives an idle
cycle, and the fan floor is firmware.

## The karg did not arrive through `kargs.d`, and the mechanism is unexplained

`/usr/lib/bootc/kargs.d` is read by `bootc install`/`switch`/`upgrade` and by
nothing else, and `rpm-ostree rebase`/`upgrade` ignores the directory outright.
That was the original explanation and it is wrong: this box updates with `bootc
upgrade` — `bootc-fetch-apply-updates.timer` active and enabled,
`rpm-ostreed-automatic.timer` masked, in place since 2026-03-04 — while all
three entries (`10-amdgpu`, `20-sensors`, `30-gaming`) were added 2026-08-08
through 2026-08-23. All three sat in `/usr` while `/proc/cmdline` carried only
`split_lock_detect=off`. Re-measured 2026-08-24: `20-sensors` is still absent
from the booted *and* staged deployments, so it is not a pending-reboot
artifact. Nothing logs the omission.

The cost was the entire GPU tuning story. Without `amdgpu.ppfeaturemask` there
is no `pp_od_clk_voltage` and no `gpu_od/` directory, so LACT drops the voltage
offset with `custom clock settings are present but will be ignored … Could not
read file pp_od_clk_voltage` at ERROR, once per card, and keeps running as if
healthy. Both cards also read `power1_cap = 300000000` rather than the
configured 210 W. The undervolt in `/etc/lact/config.yaml` had never executed a
single time.

Fix is one command per machine plus a reboot:

    rpm-ostree kargs --append=amdgpu.ppfeaturemask=0xfff7ffff

That writes it into the ostree deployment, which persists across updates from
either tool. Keep the `kargs.d` file anyway — it is still correct for a fresh
`bootc install`.

## Nothing in the OverDrive table survives an idle cycle

`power1_cap` is durable across a D3→D0 transition; the undervolt and the fan
curve are not
([runs/2026-08-23-tuning-durability](../runs/2026-08-23-tuning-durability.md)).

This is the fact the whole tuning design is built around, and it is not a
suspend/resume edge case — it fires every time the cards go idle for ten
seconds, many times a day. A "set it and forget it" undervolt is impossible.

What *is* possible is re-applying the offset once the card is awake for a
workload. A loaded vLLM pins both cards in D0 for the life of the session, so an
offset applied after the model loads holds for exactly as long as it matters. At
idle the card is in D3 drawing nearly nothing, where an undervolt buys nothing
anyway.

LACT can only own a setting for as long as LACT is resident — stopping `lactd`
reverts the cap immediately — so there is no "start LACT, let it apply, stop it"
design available.

## The ~1950 RPM floor was pollers, then firmware

The floor has two separate stories and they are often confused.

**Why the cards never idled:** `coolercontrold` and `lactd` each read GPU hwmon
about once a second, and every amdgpu hwmon read calls `pm_runtime_get_sync()` /
`mark_last_busy()`. A 1 s poll against the 5 s autosuspend delay resets the
timer forever. Stop them and both cards suspend within 30 s. CoolerControl was
dropped from the image — it could not drive this board's NCT6701D anyway. LACT
stays because it applies the power cap and undervolt.

Worth keeping refuted, because you will meet it again in AMD's own tracker:
ROCm#6078's "fans are WONTFIX / an intended ~30% curve" is **not** the reason for
this box's noise.

**Why an awake card cannot go quieter:** `fan_minimum_pwm` reads 30 with an
OD_RANGE of `30 100`, and 30% of `fan1_max` 6500 RPM is 1950. A curve point
below 30% is rejected. A curve can only make an awake card *louder* than 1950
RPM, never quieter
([runs/2026-08-25-overdrive-fan-curve](../runs/2026-08-25-overdrive-fan-curve.md)).
Letting the card runtime-suspend is the only way below it.

## Fan control works, and the vBIOS reading was wrong

"R9700 fan control is dead" was the missing karg, not the vBIOS. With OverDrive
unlocked, `gpu_od/fan_ctrl/fan_curve` exists on both cards and commits a full
five-point curve, taking them from 33–39% PWM at 88–93 °C hotspot to 89% PWM at
70–78 °C under an unchanged vLLM load.

The reason the earlier reading was unsafe is worth keeping: `gpu_od/` is
OverDrive-gated, so an absent `gpu_od/fan_ctrl/` cannot distinguish a firmware
limitation from a locked OverDrive. Re-test fan control only with the karg live.

## Also ruled out

Not causes of the fan floor: the ppfeaturemask karg (correctly ruled out *for
that question* — it is the cause of the missing OD nodes, which is different),
processes holding DRM nodes, the HDMI audio function, and the kernel itself.

`MODE1 reset` on the resume path is expected noise, not a hang. Real trouble
looks like ring timeouts, or a reset with no surrounding `PM: suspend
entry`/`exit`.

LACT 0.10.0 no longer holds the dGPUs awake — with `lactd` resident, no GUI
client, `fan_control_enabled: false` and the LLM stack down, both R9700s sat at
`runtime_status=suspended` for a straight 100 s sample. Upstream #828 was fixed
by PR #836, and v0.8.4 carries "the daemon no longer needlessly keeps AMD GPUs …
awake". **Re-test on LACT bumps rather than assuming it either way.**
