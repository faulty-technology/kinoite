---
type: Decision
date: 2026-11-14
subject: R9700 GPU gauges come from a 15 s oneshot timer that gates every hwmon read behind power/runtime_status, written to Alloy's textfile directory
---

# north GPU metrics: runtime_status-gated timer

## Decision

`kinoite-gpu-metrics.timer` (OnBootSec=60s, OnUnitActiveSec=15s, AccuracySec=5s)
runs `/usr/libexec/kinoite-gpu-metrics`, which for each R9700 (PCI ID `1002:7551`,
labelled by `PCI_SLOT_NAME`, never card index):

1. reads `power/runtime_status` and `power/control` **first** — passive, they
   never wake the card — and emits `north_gpu_awake{pci}` and
   `north_gpu_power_control{pci,mode}`;
2. **stops there if the card is not `active`** — no hwmon read at all;
3. only for an already-active card emits busy %, VRAM used/total, edge temp,
   power W vs cap, fan RPM and sclk/mclk, then writes the file atomically
   (`amdgpu.prom.tmp` → `mv`) into `/var/lib/alloy/textfile`, where
   `host.alloy`'s textfile collector serves it.

A `north_gpu_metrics_last_run_timestamp_seconds` gauge makes a dead timer visible
as stale data rather than silent absence. The final poll interval is set by the
measured idle cost in [runs/2026-11-14-north-gpu-metrics-idle-cost](../runs/2026-11-14-north-gpu-metrics-idle-cost.md).

## Why a gate at all

[how-to/measure-gpu-idle](../how-to/measure-gpu-idle.md) documents the failure
mode: every amdgpu hwmon read calls `pm_runtime_get_sync()` and wakes the card,
and [explanation/gpu-power-and-fans](../explanation/gpu-power-and-fans.md) records
CoolerControl being removed because 1 s hwmon polling kept the GPUs awake. An
unconditional exporter (the usual amdgpu_exporter design) re-introduces exactly
that regression at a slower rate. The gate costs one passive read per poll; a
suspended card contributes two gauges and no wake.

## Implementation notes that differ from the obvious approach

- **Clocks come from hwmon `freq1_input`/`freq2_input`, not `pp_dpm_sclk`/`pp_dpm_mclk`.**
  This kernel/driver exposes the DPM clocks as hwmon freq channels labelled
  `sclk`/`mclk`; the pp_dpm files do not exist. The script picks the channel by
  its label, so a rename degrades to missing data, not a wrong number.
- **The 610M iGPU (card3) is excluded by PCI ID.** It is pinned
  `power/control=on` by the display manager and reports desktop compositing, not
  LLM workload; including it would pollute every "GPU" panel with a card that can
  never suspend.
- **Missing or non-numeric sources emit nothing** rather than a fake zero —
  `power1_cap` returns EBUSY on a suspended card and the gate already keeps us
  off it, but any transient read failure must not show as "0 W cap".

## Rejected alternatives

See [2026-11-14-north-host-metrics-alloy-unix-exporter](2026-11-14-north-host-metrics-alloy-unix-exporter.md#rejected-alternatives-for-the-gpu-gauges-the-other-half-of-host-telemetry):
`amd-smi` (core-dumps on gfx1201), `rocm-smi` (needs host ROCm), an
`amdgpu_exporter` container (second daemon + port, unconditional polling), and
`lactd` (disabled; re-test on bumps).
