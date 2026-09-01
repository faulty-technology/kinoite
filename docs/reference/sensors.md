# Motherboard sensors

ASUS ProArt B850-Creator WiFi Neo, NCT6701D. `nct6775` reports it as
`nct6799-isa-0290`, with fan RPM.

`acpi_enforce_resources=lax` never landed as a karg, yet the module is loaded
and reporting anyway. That karg looks unnecessary on this board and kernel — a
candidate for removal from `motherboard.sh`, unverified.

## Cosmetic readings — ignore rather than chase

NCT6701D quirks, all harmless:

- `AUXTIN3` at -61 °C
- `AUXTIN4` at +86 °C, flagged ALARM
- `PCH_*` at 0 °C
- several `inN` rails flagged against a 0 V max

## GPU fan readings

`sensors` reports `fan1: N/A` on a runtime-suspended card. That is correct, not
an error — hwmon registers are unreadable on a powered-down card.

1950–2050 RPM is what an *awake* R9700 does. See
[explanation/gpu-power-and-fans](../explanation/gpu-power-and-fans.md) for why
that floor exists and why it is not a firmware fault report.
