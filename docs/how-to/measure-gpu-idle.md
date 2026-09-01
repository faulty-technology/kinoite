# Measure GPU idle and power on the north box

Every gotcha below cost hours. Read the whole page before trusting a number.

## Before measuring anything

Check for stray `power/control=on` pins:

    grep -r . /etc/tmpfiles.d/ /etc/udev/rules.d/ 2>/dev/null | grep -i 'power/control'

One left behind by a D3 test forbade runtime suspend on 06:00.0 across every
reboot. Hours of "it never suspends" was measuring the pin.

## Read in the right order

    cat /sys/class/drm/card*/device/power/runtime_status    # FIRST
    sensors                                                  # second

**Reading hwmon wakes the GPU.** `sensors` is not a passive instrument — every
amdgpu hwmon read calls `pm_runtime_get_sync()`. Read `runtime_status` first or
you measure your own observation.

`pp_od_clk_voltage` and `power1_cap` are the opposite: they return EBUSY on a
suspended card rather than waking it. To verify a setting you must wake the card
deliberately:

    echo on > /sys/class/drm/cardN/device/power/control
    # read
    echo auto > /sys/class/drm/cardN/device/power/control

Leaving it at `on` is the exact stray pin warned about above.

## Nodes that do not exist here

`runtime_usage` and `runtime_enabled` need `CONFIG_PM_ADVANCED_DEBUG` and are
absent on Fedora. Use `runtime_suspended_time` to answer "has it ever
suspended" — it works while the GPU is busy.

## Finding what holds a card awake

`fuser /dev/dri/*` does **not** see hwmon readers, which is the usual culprit.
Daemons that block idle may be *system* services, so stopping the display
manager misses them. The display manager here is `plasmalogin.service`, not
sddm.

Anything polling GPU hwmon on a ~1 s interval defeats the 5 s autosuspend delay
outright. See
[explanation/gpu-power-and-fans](../explanation/gpu-power-and-fans.md#the-1950-rpm-floor-was-pollers-then-firmware).

## Two traps in test setup

- `udevadm trigger --action=bind` does **not** prove boot behaviour. `amdgpu.ko`
  is in the initramfs and udev never replays `bind`. Use `tmpfiles.d` for sysfs
  writes that must happen at boot.
- Testing GPU idle from a Sunshine session is self-defeating — the stream holds
  the GPU.

## Output formatting

`kscreen-doctor` colours its output even when piped:

    kscreen-doctor -o | sed 's/\x1b\[[0-9;]*m//g'
