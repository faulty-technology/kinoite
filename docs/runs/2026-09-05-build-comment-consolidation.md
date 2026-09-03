# Build-comment consolidation (2026-09-05)

Measurements, rejected alternatives, errata, and decision histories moved out
of build-script comments into this single file. Each section names the source
file and what was there; the build scripts now carry a one-line link here.

## amdgpu.sh

### Prior udev rule (removed)

This image used to ship `70-kfd.rules` with `MODE="0660"` + `TAG+="uaccess"`.
That tightened the base 0666, then handed access back only to the active-seat
user (via the uaccess ACL) or to members of `render`. The practical cost was
that a headless SSH session, having no seat, needed `usermod -aG render` for
something that was never restricted in the first place. Dropping the rule
restored 0666 and removed that fallback.

The uaccess tag did work — `getfacl` on a seated login showed the user ACL land
on `/dev/kfd`. It is simply redundant at mode 0666.

## gaming.sh

### Split lock detection cost

The kernel's split-lock throttling costs some Proton titles ~10× frame rate.
Hence the `split_lock_detect=off` karg.

## lemonade.sh

### Nightly channel pin

lemonade-sdk/lemonade#1787: ROCm preview/stable channels silently fall back to
CPU on gfx1201 (RDNA4) — 7× performance regression vs v10.2.0. Neither
`preview` (ROCm 7.12 / TheRock) nor `stable` (ROCm 7.2) contains HIP support
for gfx1201; `llama-server --list-devices` prints an empty device list and the
server runs on CPU with no error and no warning — ~70 tok/s becomes ~10. Only
`nightly` ships the per-arch builds that detect the R9700. Hence
`rocm_channel=nightly` pinned in defaults.json.

lemonade auto-tunes ctx_size to 157140 on a 27B — hence the explicit override
to 131072.

`--load-mode mmap` was pinned throughout the SELinux bisect and carried forward
untested. Isolated afterwards by loading a model without it under full
confinement — ROCm loads fine, so it was removed from the recipe args.

### Why Q6 floor, why MTP, why two packaging shapes

Q6_K is the quality floor on this coding/testing box. The IQ4_XS Fast variant
has been benchmarked but NOT quality-tested. Why Q6 rather than Q8 costs
nothing here: [explanation/quant-selection.md].

Sizing for ctx values uses measured MiB/token/card, not a per-architecture
estimate. Qwen3.8-27B is hybrid qwen3_5: 48 of 64 layers linear-attention with
constant-size state, so a dense KV estimate is off by roughly 4×.

checkpoint pins the exact GGUF filename. The UD- prefix is load-bearing —
`Qwen3.8-27B-Q6_K.gguf` does not exist in that repo.

unsloth ships MTP in two packagings needing different recipe shapes:
1. Separate draft file, same repo — needs the `checkpoints` object form with a
   `draft` key. mmproj moves inside the object and values are fully qualified
   `repo:file`.
2. Embedded in the main GGUF, in a sibling repo — stays the scalar `checkpoint`
   form, just repoint the repo.

MTP worth: [runs/2026-08-20-mtp-speculation](../runs/2026-08-20-mtp-speculation.md).

### `-sm tensor` split across recipes

`-sm tensor -fa on` is baked on the four Qwen3.8-27B recipes and NOT on the
other three. ON: +44.4% over layer split on this model, composes with MTP, and
layer split loses to vLLM below ~6-7K context on the heavy quants. OFF on
Qwen3.6-27B, Qwen3.6-35B-A3B, and Qwen3-Coder-30B because none has been loaded
here — `-sm tensor`'s architecture gate failure mode is a hard load failure.

Four constraints: `-fa on` mandatory, iGPU exclusion at visibility not per
flag, ctx values hand-computed (0.0444 MiB/token/card + 12174 MiB/card fixed
term; 131072 → ~17.9 GB/card, 262144 → ~23.8 GB/card), and
`--chat-template-kwargs` must carry both keys in one JSON object.

Measured: [runs/2026-08-30-tensor-split](../runs/2026-08-30-tensor-split.md),
[runs/2026-08-30-quant-sweep](../runs/2026-08-30-quant-sweep.md).

### Reasoning effort pin

REASONING EFFORT pinned to MEDIUM on the four Qwen3.8-27B recipes. Absence
selects xhigh (template resolves `reasoning_effort|default('xhigh')`). medium
is the one level that renders empty. Not set on the other three — templates
grepped 2026-08-31: the Qwen3.6 pair has enable_thinking/preserve_thinking and
no reasoning_effort, and Qwen3-Coder-30B has none of the three. No quality A/B
has been run either way.

Measured: [runs/2026-08-31-reasoning-effort-tokens](../runs/2026-08-31-reasoning-effort-tokens.md).

### SELinux map denial on /dev/kfd

container-selinux grants container domains hsa_device_t {open read write ioctl
...} but NOT map, and ROCm mmaps /dev/kfd. Without this every model load dies
~25 ms in with an HSA abort — "Memory critical error by agent node-0 ...
Memory in use.", exit 134 — which looks nothing like a permission problem and
cost a long bisect to find. Confirmed by the only AVC in the trace: `denied {
map } tclass=chr_file tcontext=...:hsa_device_t:s0`.

The alternative that also "worked" — `SecurityLabelDisable=true` or
`--ipc=host` on the container — buys the same thing by turning SELinux off for
the container entirely. Not worth it for one permission. Narrower still would
be a CIL module granting only map on hsa_device_t.

### Recipe seeding: add-only was the first cut and failed

Recipe seeds are reconciled per key on every start. Add-only was the first cut
and it failed the moment a shipped recipe CHANGED rather than appeared:
2570e9b put `-sm tensor -fa on --spec-draft-p-min 0.1` on all four Qwen3.8
recipes, and only the two brand-new keys got it — `user.Qwen3.8-27B` and
`-Fast` already existed, so they kept `{"ctx_size": 131072}` and the measured
24%-and-tensor-split work simply never reached the box, silently.

### GroupAdd=keep-groups removed

It was a headless fallback for render/video membership, and it is measured
unnecessary: /dev/kfd and the render nodes are mode 0666 from systemd-udev's
base rules, so no group membership is involved. Removing it also sidesteps the
known rootless flakiness (containers/podman#27876, #28364). Verified by
loading a model with it absent.

### Device visibility: why ROCR not HIP, why derived not literal

ROCR_VISIBLE_DEVICES indexes the KFD GPU-agent list in topology-node order.
HIP orders by PCI BDF, which agrees here only because the nodes happen to be in
ascending bus order — a coincidence.

Literal index: DRM numbering reshuffles across kernels and boots. The rule is
"keep every GPU agent of the same gfx target as the most capable one", which
generalises. Matching a kernel list instead: the bundle covers gfx1200,
gfx1201, and gfx1250; gfx1250 is 125000 rather than 1200xx, so a "1200xx"
filter would silently exclude a supported card. The bundle also lives under
~/.local/share/lemonade, downloaded at runtime, and is not readable at first
start.

## llamafactory.sh

### Replaced unsloth.sh

REPLACED unsloth.sh. The image is BUILT ON THE BOX rather than pulled —
upstream's docker-rocm bases on a rocm/pytorch image whose gfx1201 coverage is
unproven, while AMD's whl-multi-arch index has a real gfx1201 target.

Decision: [decisions/2026-08-30-llamafactory-over-unsloth](../decisions/2026-08-30-llamafactory-over-unsloth.md).

### bitsandbytes version floor

`>=0.50.0` is a CORRECTNESS bound, not a preference: upstream's pyproject
comment calls it the first PyPI release carrying the full RDNA path
(blocksize/warp decoupling, fused SIMT GEMM, the RDNA3/4 workgroup fix).
Anything older is unreliable at 4-bit on ROCm. 0.50.2 is the version verified
on this box.

### NOT installed: flash-attn, deepspeed, liger-kernel

Rejected for measured or documented reasons:

- `flash-attn` — no RDNA4 support. Upstream's own ROCm Dockerfile defaults it off.
- `deepspeed` — multi-node sharding; this is one box and the posture is single-card.
- `liger-kernel` — Triton kernels written against CUDA/CDNA; unproven on RDNA4.

## services-north.sh

### Sleep hook: two rejected shapes

Two shapes were rejected:

- A USER unit. The systemd user manager ships no sleep-related target, so a
  user unit cannot order After=sleep.target.
- A `/usr/lib/systemd/system-sleep/` drop-in. systemd-suspend.service(8) calls
  that directory "hacks" and it runs synchronously.

The chosen shape: a system unit (WantedBy=sleep.target, StopWhenUnneeded=yes)
that calls runuser.

### krfb: shipped disabled to avoid pinning a GPU awake

The virtual monitor unit shipped `--global enable`d in earlier images, so every
login started krfb whether or not anyone streamed. krfb-virtualmonitor holds a
DRM render node for as long as it runs, which pins whichever GPU backs it into
D0. On this box that meant a dedicated GPU awake at ~30% fan around the clock
for a monitor nobody was looking at. Changed 2026-08-18 to shipped-but-not-enabled.

## sunshine.sh

### Virtual display unit: shipped but not enabled

Same krfb history as services-north.sh. It used to be `systemctl --global
enable`d. Changed 2026-08-18. Streaming does not need it at login: the seeded
`global_prep_cmd` runs `ensure`, which falls through to `up` and creates the
display on demand when a stream starts.

## tuning.sh

### ppfeaturemask: 0xfff7ffff, not 0xffffffff

0xfff7ffff, not the 0xffffffff every guide repeats. The driver default is
0xfff7bfff and OverDrive is PP_OVERDRIVE_MASK (0x4000). 0xffffffff would
additionally set PP_GFX_DCS_MASK (0x80000), which the driver deliberately
leaves off, plus every reserved bit. Re-derive from amd_shared.h if a kernel
bump changes the default.

### kargs.d delivery is unreliable

Entries in kargs.d have been observed not reaching /proc/cmdline at all, by
a mechanism nobody has explained. Always verify against /proc/cmdline. Fix,
once per machine: `rpm-ostree kargs --append=amdgpu.ppfeaturemask=0xfff7ffff
&& systemctl reboot`. kinoite-gpu-tune.service asserts this at boot.

### LACT daemon disabled

Two measured reasons, both in
[runs/2026-08-23-tuning-durability](../runs/2026-08-23-tuning-durability.md):

- LACT reverts the power cap when it stops. `systemctl stop lactd` puts
  `power1_cap` straight back to 300 W. A setting LACT owns only holds for as
  long as LACT is resident.
- Nothing it can apply is worth a resident daemon here.

What is NOT a reason any more: holding the dGPUs awake. That was true of the
version measured earlier and is fixed as of 0.10.0 (upstream #828 / PR #836) —
100 s resident with both cards at `runtime_status=suspended` throughout.

### GPU tuning durability

Measured by hand with lactd stopped:

| node | survives idle cycle | notes |
|---|---|---|
| `power1_cap` | yes | set once, sticks |
| voltage offset | **no** | wiped to 0 mV on every D3→D0, ~10 s of idle |
| fan curve | **no** | wiped to 0C 0% on every D3→D0, same OD table |

So only the power cap is genuinely "apply at boot and forget."

### Fan curve thermal analysis

Under sustained 27B decode the stock firmware curve is far too quiet, and at
88-93°C the cards leak enough extra current to pin themselves against the power
cap, which clamps sclk. Cooling them releases all of that — and changes
throughput by -0.1%, because batch-1 decode is memory-bandwidth bound and mclk
never leaves top DPM either way. Worth applying for ~18°C and ~90 W across the
pair.

A/B: [runs/2026-08-25-vllm-context-and-clocks](../runs/2026-08-25-vllm-context-and-clocks.md).

## vllm.sh

### NCCL_PROTO=Simple measured faster

A 2-rank RCCL all-reduce benchmark on this box, 2026-08-19:

```
10 KiB   Simple 27.6 us/op   auto 35.0 us/op    -> Simple wins
40 KiB   Simple 26.9         auto 32.7
 1 MiB   Simple 82.2         auto 82.3          -> equal once bandwidth-bound
```

Simple is ~7 us/op faster at the 10 KiB size decode actually uses. At ~128
all-reduces per token, that's ~1 ms/token — comm at only ~4.5 ms of the ~41 ms
token budget (~11%). The old form was an unconditional export in
`/etc/profile.d/01-rocm-envs.sh` and could not be overridden at all; it's now
a Quadlet `Environment=` knob.

### MTP k is not capped by mtp_num_hidden_layers

This is the draft head's depth, not the speculation width. Misreading it as a
cap pinned k=1 and cost ~42% of achievable throughput. Greedy output will not
be byte-identical to non-speculative; that is expected — batch shape alone
flips the same tokens.

The MTP head costs ~1 extra layer of VRAM. Do not chase a newer image for it.

### disable_padded_drafter_batch removed

DO NOT re-add it. It is +19.1% single-stream and crashes the engine at n≥3
concurrent requests. Bisected on-box 2026-08-24: four parallel 16K prompts, n=2
fine, n=3 and n=4 crash with EngineDeadError.

Decision: [decisions/2026-08-24-drop-padded-drafter-batch](../decisions/2026-08-24-drop-padded-drafter-batch.md).

### `--no-async-scheduling` removed

Was required by `disable_padded_drafter_batch` and stayed after that flag was
removed, on the assumption it cost 3.2% independently. Measured
2026-09-03 at k=4: costs nothing (the 08-22 figure was the drafter-batch flag,
not async scheduling). Removed for cleanliness.

### Strict tool calling off while MTP is on

Upstream vllm-project/vllm#44006, fixed by #44297 on 2026-07-04. This image's
2026-06-13 build is three weeks short of it. The launcher therefore exports
`VLLM_ENFORCE_STRICT_TOOL_CALLING=0` whenever speculation is on.

The alternative (bump to an image with the fix) costs ~15% of MTP decode and
was rejected. That image-bump rule has THREE conditions: post-07-04, not a
decode regression, and not reintroducing the TP=2 hang (RCCL moves as a side
effect).

Decision: [decisions/2026-08-23-strict-tool-calling-off](../decisions/2026-08-23-strict-tool-calling-off.md).

### Prefix caching forced on for hybrid model

ON by default since 2026-08-31. Worth 1.73× end-to-end on the agentic workload
measured 2026-09-03. Upstream gates prefix caching for hybrid models — the
`is_prefix_caching_supported` check in `config/model.py` returns False for any
`attn_type == "hybrid"` model, and Qwen3.8-27B is qwen3_5 (hybrid). This
default overrides that experimental gate. Correctness spot-checks passed
2026-08-22; no quality A/B has been run. If output quality is ever suspect,
`VLLM_PREFIX_CACHING=false` is the first thing to try.

Decision: [decisions/2026-08-31-vllm-prefix-caching-on](../decisions/2026-08-31-vllm-prefix-caching-on.md).

### Reasoning effort pinned to medium

Down from the model's own default (xhigh — template resolves
`reasoning_effort|default('xhigh')`). Unset = highest level, not neutral.
medium is the one level that renders empty.

It is a throughput knob: at ~70K an agentic loop, context is 64% of the
forward pass. medium is the conservative middle, not a benchmarked optimum, and
no quality A/B has been run.

The flag is guarded: the launcher greps the installed vLLM for the option
rather than trusting it. Upstream also shipped a window where the flag parsed
but was silently ignored (merged 2026-01-05); this 2026-06-13 build is past it.

### GPU memory utilization lowered to 0.80

Down from 0.95 on 2026-08-24. 0.95 is a "fill the card" instruction — it had
reached 344,064 tokens, 2.63× the 128K max context. Measured on-box 2026-08-24
at 0.80: KV 7.87 GiB = 225,652 tokens, still 1.72× a full 128K request; idle
VRAM 30.09 → 24.41 GiB/card, freeing ~7.4 GiB/card (~14.9 GB across the pair).

KV bytes/token measured at 36.6 KiB/token/card. Sizing formula:
`KV_GiB ~= 31.86*util - 18.26`.

### max-num-batched-tokens lowered to 8192 after VRAM OOM

Down from 16384 after the 2026-08-24 VRAM OOM. At 16384 a ~16K prompt was
scheduled as a single unchunked step whose bf16 GEMM output alone was 538 MiB,
against ~1.3 GiB of headroom (~4.1 GiB of non-torch overhead).

Full ledger: [runs/2026-08-24-vllm-prefill-oom](../runs/2026-08-24-vllm-prefill-oom.md).

### Restart=always, not on-failure

Learned from the 2026-08-24 OOM: when a worker dies, EngineCore raises
EngineDeadError and the API server shuts itself down CLEANLY — container exit
0, systemd records Result=success. `on-failure` sees a successful exit and
does nothing, so the server stays dead silently. `always` recovers.

### Pre-pull timeout

podman hard-caps the implicit pull inside `podman run` at 5 minutes. Confirmed
on-box: first start died at exactly 5m03s on the 32 GB image.