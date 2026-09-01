---
date: 2026-08-25
subject: fan curve control on the R9700 with OverDrive unlocked
harness: kinoite-gpu-tune, under an unchanged vLLM load
box: kinoite-north
---

# Fan control with the karg live

## What was measured

With `amdgpu.ppfeaturemask=0xfff7ffff` on `/proc/cmdline` (applied via
`rpm-ostree kargs`), whether `gpu_od/fan_ctrl/fan_curve` exists and accepts a
curve.

## Numbers

Present on both cards. Reads five `0C 0%` points, `OD_RANGE` hotspot `25C-100C`
and speed `30%-100%`.

Writing `45:40 55:55 65:70 75:85 85:100` through `kinoite-gpu-tune`, under an
unchanged vLLM load:

| | before | after |
|---|---|---|
| PWM | 33–39 % | 89 % |
| hotspot | 88–93 °C | 70–78 °C |

Floor measurement: `fan_minimum_pwm` reads 30 with OD_RANGE `30 100`, the
curve's own speed floor is 30%, and `pwm1` idles at 76/255 = 29.8%. 30% of
`fan1_max` 6500 RPM = 1950.

## What it means

Fan control is fully available, and the earlier "the vBIOS flash fixed it"
reading is wrong — it was the locked OverDrive, not the firmware. `gpu_od/` is
OverDrive-gated, so an absent `gpu_od/fan_ctrl/` cannot distinguish a firmware
limitation from a locked OverDrive.

The curve cannot go **below** ~30% on an awake card. That is a firmware minimum
PWM: `fan_minimum_pwm` will not accept a value below 30, and a curve point below
30% is rejected. A curve can only make an awake card louder than 1950 RPM, never
quieter.
