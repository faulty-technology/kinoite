# Motherboard sensors

ASUS ProArt B850-Creator WiFi Neo, NCT6701D reported as nct6799 by the kernel
(`nct6799-isa-0290`). Fan RPM, voltage rails and most temps work out of the box.
`acpi_enforce_resources=lax` is NOT needed — the driver probes without it on
Fedora 44, and both the karg and the `modules-load.d` force-load were removed
from `motherboard.sh` as verified unnecessary.

## Cosmetic readings — ignore rather than chase

nct6799 quirks, all harmless:

- `AUXTIN3` at -61 °C
- `AUXTIN4` at +86 °C, flagged ALARM
- `PCH_*` at 0 °C
- `PCH_CHIP_CPU_MAX_TEMP`, `PCH_CHIP_TEMP` and `PCH_CPU_TEMP` at 0 °C (driver
  doesn't populate them)
- several `inN` rails flagged against a 0 V max

## GPU fan readings

`sensors` reports `fan1: N/A` on a runtime-suspended card. That is correct, not
an error — hwmon registers are unreadable on a powered-down card.

1950–2050 RPM is what an *awake* R9700 does. See
[explanation/gpu-power-and-fans](../explanation/gpu-power-and-fans.md) for why
that floor exists and why it is not a firmware fault report.
