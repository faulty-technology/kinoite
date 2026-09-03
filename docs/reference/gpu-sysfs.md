# GPU tuning sysfs

Everything here needs `amdgpu.ppfeaturemask=0xfff7ffff` on `/proc/cmdline`.
Without it there is no `gpu_od/` directory at all. See
[explanation/gpu-power-and-fans](../explanation/gpu-power-and-fans.md) for why
that karg is applied with `rpm-ostree kargs` rather than `kargs.d`.

## Durability

| node | survives an idle cycle |
|---|---|
| `power1_cap` | yes |
| `OD_VDDGFX_OFFSET` (undervolt) | **no** |
| `gpu_od/fan_ctrl/fan_curve` | **no** |

Measured in [runs/2026-08-23-tuning-durability](../runs/2026-08-23-tuning-durability.md).
Anything in the OverDrive table is dropped on every D3→D0 transition.

## Ranges

| node | range | notes |
|---|---|---|
| `power1_cap` | up to `power1_cap_max` 330 W with the karg (300 W without) | durable |
| `fan_curve` temperature | 25 C – 100 C | five points |
| `fan_curve` speed | 30 % – 100 % | floor is firmware, see below |
| `fan_minimum_pwm` | 30 – 100 | writes below 30 error |

## Inert or absent nodes

Keep all of these out of any LACT profile — they accept writes, commit without
error, and do nothing:

- `fan_zero_rpm_enable` — an empty stub that fails to parse
- `fan_zero_rpm_stop_temperature` — does not exist
- `acoustic_target_rpm_threshold`
- `fan_target_temperature`
- `pp_table` — does not exist on gfx1201, so no soft PowerPlay override
- `pwm1_enable` — absent, so manual fixed-PWM is dead; the PMFW curve is the
  whole interface

Drop `pmfw_options.zero_rpm` and `zero_rpm_threshold` from
`/etc/lact/config.yaml`; LACT still errors on both.

## Writing a fan curve

All five points must be in range **before** you commit:

    for pt in "0 40 30" "1 50 40" "2 60 55" "3 70 75" "4 80 100"; do
        echo "$pt" > fan_curve
    done
    echo c > fan_curve      # rc=0

Partial commit returns EINVAL and poisons subsequent `pp_od_clk_voltage` commits
until the curve is reset:

    echo r > fan_curve; echo c > fan_curve

## Reading

`pp_od_clk_voltage` and `power1_cap` return EBUSY on a runtime-suspended card.
`performance_level=manual` is not required for voltage offset writes.

## amd-smi is not an option

`amd-smi metric` dumps core on gfx1201 because it cannot parse `OD_SCLK_OFFSET`
in `pp_od_clk_voltage`. `amd-smi set` has no voltage-offset argument and its
`--fan` needs `pwm1_enable`, which this card lacks. Read and write sysfs directly.
