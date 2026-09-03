# GPU topology

AMD 9900X, dual Radeon AI PRO R9700 (Navi 48, RDNA4), ASUS ProArt B850-Creator
WiFi Neo. Single NUMA node.

## Devices

| PCI | GPU | `gfx_target_version` | ROCm index |
|---|---|---|---|
| 03:00.0 | R9700 (Navi 48) | 120001 | 0 |
| 06:00.0 | R9700 (Navi 48) | 120001 | 1 |
| 10:00.0 | iGPU (Granite Ridge) | 100306 | 2 |

DRM numbering is unstable across boots; identify devices by PCI address:

    ls -l /dev/dri/by-path/
    lspci -nn
    grep -H gfx_target_version /sys/class/kfd/kfd/topology/nodes/*/properties

Per-GPU VRAM in use:

    /sys/class/drm/card*/device/mem_info_vram_used

## Interconnect

Peer access is enabled between every pair, but there is no fast link — a peer
copy between the two R9700s runs at 28.2 GB/s, the same as a copy to host
memory. The iGPU is markedly slower to both dGPUs at 17.8 GB/s. Measured in
[runs/2026-08-30-p2p-bandwidth](../runs/2026-08-30-p2p-bandwidth.md).

## The iGPU must be excluded from ROCm workloads

The `llamacpp-rocm` bundle is a gfx120X-only build with no kernels for gfx1036.
Two independent consumers of this rule:

- `-sm tensor` uses every visible device, so it loads and then aborts on the
  first decode with `invalid kernel file`.
- `--spec-type draft-mtp` gives the draft model its own device list
  (`-devd` / `--spec-draft-device`) defaulting to every device, so `-dev` alone
  is **not** sufficient.

Exclusion at visibility (`HIP_VISIBLE_DEVICES=0,1` or
`ROCR_VISIBLE_DEVICES=0,1`) covers every model the process loads.

Layer split needs no device pinning: under default -sm layer a loaded 27B put
14.2 and 13.7 GiB on the two R9700s and 20 MiB (framebuffer only) on the iGPU.
([runs/2026-08-30-engine-decode-depth](../runs/2026-08-30-engine-decode-depth.md))

## Firmware baseline

Diff against this after a bump:

| | vBIOS | SMC |
|---|---|---|
| R9700 | `115-G287BP00-100` build 00180814 | `0x00684f00` |
| iGPU | `102-RAPHAEL-008` | `0x00625400` |

    sudo sh -c 'cat /sys/kernel/debug/dri/*/amdgpu_firmware_info'

The glob must be expanded *by root* — `/sys/kernel/debug` is 0700, so `sudo cat`
with a shell glob fails with ENOENT.

`<smu_v14_0_0>` in dmesg is the generic IP block version, not which
`smu_v14_0_*_ppt.c` drives the card. The SMU interface mismatch (driver 0x2e vs
fw 0x33) is not a health signal — it survives a vBIOS flash and both cards init
fine.
