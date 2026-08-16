#!/bin/bash
set -ouex pipefail

# Lemonade Server (local LLM) as a rootless Quadlet. No host ROCm — lemonade's
# llama.cpp builds bundle their own ROCm 7 runtime.
#
# Deliberately NOT enabled: no [Install], nothing in services-north.sh. Started by
# hand with `systemctl --user start lemonade`. Runbook and gotchas are in
# /usr/share/kinoite/lemonade.md, written below.
#
# TODO(hardware): none of this has run on the box yet. See notes/.

# crun specifically — GroupAdd=keep-groups is a crun-only feature.
for bin in podman crun; do
    command -v "$bin" >/dev/null || { echo "llm.sh: missing $bin" >&2; exit 1; }
done

### 1. Seeded lemonade defaults
# nightly channel is correctness, not preference: stable has no gfx1201 support and
# silently runs on CPU at ~1/7th speed. ctx_size because lemonade auto-tunes to 157140
# on a 27B — raise per-model if you have headroom. rocm_args is the one combination
# measured working (~35 tok/s vs ~29 on vulkan); whether --load-mode mmap is actually
# load-bearing was never isolated after the SELinux fix landed, so it stays.
mkdir -p /usr/share/kinoite
cat > /usr/share/kinoite/lemonade-defaults.json << 'EOF'
{
  "ctx_size": 131072,
  "rocm_channel": "nightly",
  "llamacpp": {
    "backend": "rocm",
    "rocm_args": "--load-mode mmap"
  }
}
EOF

### 1b. Curated custom-model recipes (always-present superset)
# Baked to /usr/share/kinoite/lemonade-recipes, conditionally seeded into the user's
# lemonade config on first start (see the ExecStartPre lines in the Quadlet below).
# Names become user.<name> at runtime — run one with `lemonade run user.<name>`.
#
# This is a coding/testing box: Q6 quality floor AND big context. These ctx_size values
# exceed one card, so they rely on the layer split across both R9700s — which is the
# AUTOMATIC default here (measured: a 27B put ~14 GB on each R9700 and nothing on the
# iGPU, no pinning). KV cost is ~0.25 GB/1K tokens for the dense 27Bs (64 layers, 4 KV
# heads, head_dim 256) and ~0.10 GB/1K for the MoEs — 27B Q6 at 128K = 22.9 GB weights +
# ~33 GB KV = ~56 GB, ~28 GB per card. Whether 128K still fits the pair cleanly (and stays
# off the iGPU) at that size is an on-box check; fallback is lower ctx or q8_0 KV-quant.
# See lemonade.md.
#
# checkpoint pins the exact GGUF filename (all single-file here — no split parts, so no
# `checkpoints` object). The two 27B dense models and the 35B MoE are vision-capable
# (mmproj-F16.gguf); the coder is text-only.
command -v python3 >/dev/null || { echo "llm.sh: missing python3 (JSON validation)" >&2; exit 1; }

mkdir -p /usr/share/kinoite/lemonade-recipes
cat > /usr/share/kinoite/lemonade-recipes/user_models.json << 'EOF'
{
  "Qwen3.8-27B": {
    "source": "huggingface",
    "checkpoint": "unsloth/Qwen3.8-27B-GGUF:Qwen3.8-27B-Q6_K.gguf",
    "mmproj": "mmproj-F16.gguf",
    "recipe": "llamacpp",
    "size": 22.9,
    "labels": ["vision", "reasoning", "coding"]
  },
  "Qwen3.6-27B": {
    "source": "huggingface",
    "checkpoint": "unsloth/Qwen3.6-27B-GGUF:Qwen3.6-27B-Q6_K.gguf",
    "mmproj": "mmproj-F16.gguf",
    "recipe": "llamacpp",
    "size": 22.5,
    "labels": ["vision", "reasoning"]
  },
  "Qwen3.6-35B-A3B": {
    "source": "huggingface",
    "checkpoint": "unsloth/Qwen3.6-35B-A3B-GGUF:Qwen3.6-35B-A3B-UD-Q6_K.gguf",
    "mmproj": "mmproj-F16.gguf",
    "recipe": "llamacpp",
    "size": 29.3,
    "labels": ["vision", "reasoning"]
  },
  "Qwen3-Coder-30B": {
    "source": "huggingface",
    "checkpoint": "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Qwen3-Coder-30B-A3B-Instruct-Q6_K.gguf",
    "recipe": "llamacpp",
    "size": 25.1,
    "labels": ["coding"]
  }
}
EOF

# Per-model ctx, keyed by the fully-qualified user.<name> id. Sized for the automatic
# two-card layer split (64 GB pool): 128K on the dense 27Bs and 35B, native 256K on the
# coder. On a single card these OOM — drop ctx or add q8_0 KV-quant. At 128K the KV is
# large; if it won't fit the pair or spills to the iGPU, see lemonade.md. backend inherits
# rocm from defaults.json.
cat > /usr/share/kinoite/lemonade-recipes/recipe_options.json << 'EOF'
{
  "user.Qwen3.8-27B":     { "ctx_size": 131072 },
  "user.Qwen3.6-27B":     { "ctx_size": 131072 },
  "user.Qwen3.6-35B-A3B": { "ctx_size": 131072 },
  "user.Qwen3-Coder-30B": { "ctx_size": 262144 }
}
EOF

# Fail the build loudly on a JSON typo rather than shipping a config lemonade rejects.
for f in user_models recipe_options; do
    python3 -m json.tool "/usr/share/kinoite/lemonade-recipes/$f.json" >/dev/null
done

### 2. SELinux: let containers mmap /dev/kfd
# container-selinux grants container domains hsa_device_t {open read write ioctl ...}
# but NOT map, and ROCm mmaps /dev/kfd. Without this every model load dies ~25ms in
# with an HSA abort — "Memory critical error by agent node-0 ... Reason: Memory in
# use.", exit 134 — which looks nothing like a permission problem and cost a long
# bisect to find. Confirmed by the only AVC in the whole trace:
#   denied { map } tclass=chr_file tcontext=...:hsa_device_t:s0
#
# Boolean state lives in /var/lib/selinux, so it can't ship in the image — same
# constraint as nix-selinux.service, and the same fix: a guarded oneshot. The check
# makes it a no-op after first boot.
#
# The alternative that also "worked" — SecurityLabelDisable=true or --ipc=host on the
# container (podman drops label separation when sharing host IPC) — buys the same thing
# by turning SELinux off for the container entirely. Not worth it for one permission.
# Narrower still would be a CIL module granting only map on hsa_device_t; worth doing
# if this boolean's breadth ever matters.
for bin in getsebool setsebool; do
    command -v "$bin" >/dev/null || { echo "llm.sh: missing $bin" >&2; exit 1; }
done

cat > /usr/lib/systemd/system/lemonade-selinux.service << 'EOF'
[Unit]
Description=SELinux boolean allowing containers to mmap GPU compute devices
Documentation=file:///usr/share/kinoite/lemonade.md
ConditionSecurity=selinux

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'getsebool container_use_devices | grep -q " on$" || setsebool -P container_use_devices on'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

### 3. Rootless Quadlet unit
# /etc, not /usr: podman 5.8.4 only searches /etc/containers/systemd/users{,/$UID}
# for rootless units — the /usr/share equivalent is documented but not scanned.
# users/ (not users/$UID/) — the UID isn't knowable at build time.
mkdir -p /etc/containers/systemd/users
cat > /etc/containers/systemd/users/lemonade.container << 'EOF'
[Unit]
Description=Lemonade Server (local LLM, containerized ROCm)
Documentation=https://lemonade-server.ai/docs/
Documentation=file:///usr/share/kinoite/lemonade.md

[Container]
Image=ghcr.io/lemonade-sdk/lemonade-server:latest
ContainerName=lemonade

# The image runs as UID 10001, which maps to a subuid by default — bind mounts would
# come back subuid-owned. keep-id makes it you, which also lets the volumes skip :U
# (a recursive chown on every start).
UserNS=keep-id:uid=10001,gid=10001

# Headless/SSH fallback for render/video membership; no active seat means no ACL.
# May be inert here (containers/podman#27876, #28364) — confirm or drop.
GroupAdd=keep-groups

# Directory: podman adds every node under it, iGPU included. See notes/.
AddDevice=/dev/kfd
AddDevice=/dev/dri

# Unauthenticated API — the 127.0.0.1 prefix is what keeps it off the tailnet.
PublishPort=127.0.0.1:13305:13305

# %h is expanded by systemd, not Quadlet. :z not :Z — :Z would relabel the whole
# model cache on every start, since Quadlet builds a new container each time.
Volume=%h/.local/share/lemonade/huggingface:/opt/lemonade/.cache/huggingface:z
Volume=%h/.local/share/lemonade/llama:/opt/lemonade/llama:z
Volume=%h/.local/share/lemonade/config:/opt/lemonade/.cache/lemonade:z

# Mounting this from /usr/share directly fails: container_t can't read usr_t, and
# :z can't fix it because /usr is read-only. Hence the ExecStartPre copy below.
Environment=LEMONADE_DEFAULTS_PATH=/opt/lemonade/.cache/lemonade/defaults.json

[Service]
# First start pulls a multi-GB image against systemd's 90s default.
TimeoutStartSec=900

# Podman doesn't create missing bind-mount sources.
ExecStartPre=/usr/bin/mkdir -p %h/.local/share/lemonade/huggingface %h/.local/share/lemonade/llama %h/.local/share/lemonade/config
ExecStartPre=/usr/bin/install -m 0644 /usr/share/kinoite/lemonade-defaults.json %h/.local/share/lemonade/config/defaults.json

# Recipe seeds, conditional (unlike defaults.json above): lemonade reads user_models.json
# every start and the user may add their own custom models to it, so only seed when
# absent — first run only, like the defaults.json note in lemonade.md. %h is expanded by
# systemd before bash sees it.
ExecStartPre=/bin/bash -c 'test -f %h/.local/share/lemonade/config/user_models.json || install -m 0644 /usr/share/kinoite/lemonade-recipes/user_models.json %h/.local/share/lemonade/config/user_models.json'
ExecStartPre=/bin/bash -c 'test -f %h/.local/share/lemonade/config/recipe_options.json || install -m 0644 /usr/share/kinoite/lemonade-recipes/recipe_options.json %h/.local/share/lemonade/config/recipe_options.json'

# No [Install] — hand-started on purpose.
EOF

### 4. On-box notes
# The box won't have this repo checked out when something breaks.
cat > /usr/share/kinoite/lemonade.md << 'EOF'
# kinoite-north: Lemonade Server (rootless Quadlet)

Ships at /etc/containers/systemd/users/lemonade.container, NOT enabled.

    systemctl --user daemon-reload      # only after an image update
    systemctl --user start lemonade
    curl -s http://127.0.0.1:13305/live

Web UI and API on http://127.0.0.1:13305 — loopback only, unauthenticated.
`systemctl --user enable lemonade` is expected to fail: generator-produced units
have no [Install] to act on. That's the guardrail, not a bug.

## Recipes (baked custom models)

Curated Unsloth Qwen GGUFs, seeded into config/user_models.json on the FIRST start.
List and run (via the Web UI, or the CLI inside the container):

    podman exec lemonade lemonade list
    podman exec lemonade lemonade run user.Qwen3.8-27B     # downloads on first run

    user.Qwen3.8-27B      newest dense, vision+thinking, MTP, Developer Role   Q6_K      22.9 GB   ctx 128K
    user.Qwen3.6-27B      dense, vision+thinking                               Q6_K      22.5 GB   ctx 128K
    user.Qwen3.6-35B-A3B  fast MoE (~3B active), vision+thinking               UD-Q6_K   29.3 GB   ctx 128K
    user.Qwen3-Coder-30B  agentic coding MoE, 256K native, text-only           Q6_K      25.1 GB   ctx 256K

Qwen3.8-27B is the default all-rounder (MTP + Developer Role); Qwen3-Coder-30B is the
coding workhorse. Q6 quality floor WITH big context — these ctx exceed one card, so they
use the layer split across both R9700s, which is the AUTOMATIC default here (measured:
~14 GB per R9700, nothing on the iGPU). At 128K the KV cache is large (~33 GB on a dense
27B); if it doesn't fit the pair, drop ctx (~24K single-card) or add q8_0 KV-quant. If a
load ever spills onto the iGPU, exclude it (see "Context size & caching").

Even more context: add q8_0 KV-quant (-fa -ctk q8_0 -ctv q8_0 in a recipe's llamacpp_args)
for ~2x. More quality: move a model to Q8_0 in user_models.json. Backend falls back with
`lemonade config set llamacpp.backend=vulkan`.

Seeds are first-run only (like defaults.json below). To pull updated recipes after an
image update, delete and restart:

    rm ~/.local/share/lemonade/config/user_models.json      # and/or recipe_options.json
    systemctl --user restart lemonade

## Storage

    ~/.local/share/lemonade/huggingface   models
    ~/.local/share/lemonade/llama         llama.cpp + ROCm binaries (downloaded)
    ~/.local/share/lemonade/config        config.json, defaults.json, recipes

Owned by you (UserNS=keep-id), so du/rm/backup tools work normally.

## If ROCm dies at model load

Symptom, ~25ms into load_model, before any tensor output:

    Memory critical error by agent node-0 ... Reason: Memory in use.
    llama-server process has terminated with exit code: 134

This is SELinux denying `map` on /dev/kfd, which ROCm mmaps. It looks nothing like a
permission error. Check and fix:

    sudo ausearch -m AVC -ts recent | grep hsa_device_t
    systemctl status lemonade-selinux.service
    sudo setsebool -P container_use_devices on

lemonade-selinux.service does this at boot; if it's masked or failed, you get the abort.

Tested and does NOT help — don't re-chase: capping ctx_size, `-mg 0 -sm none`,
`--load-mode mmap` alone, `ROCR_VISIBLE_DEVICES`, seccomp=unconfined. `--ipc=host` and
`SecurityLabelDisable=true` DO work, but only because podman drops SELinux label
separation for the container — same fix, bigger hammer.

## Performance notes

Measured: 27B Q5_K_M (21.2 GB), layer split, ctx 32768 — ROCm ~35 tok/s, Vulkan ~29.
Fall back to vulkan any time with `lemonade config set llamacpp.backend=vulkan`.

Both are near the ~30 tok/s single-card bandwidth ceiling (~640 GB/s ÷ 21.2 GB), which
is why the backend gap is only ~20%. MTP speculation is what gets ROCm above the naive
ceiling. The lever with real headroom is a smaller model, not tuning.

`-sm row` (tensor split, would use both cards' bandwidth) is unavailable:
`device ROCm0 does not support split buffers` — needs peer-copy compiled into the
llamacpp-rocm build. Layer split is the ceiling; the second card adds capacity, not
bandwidth. Recheck on llamacpp-rocm bumps.

All three GPUs are visible to the container, so layer split may put layers on the
gfx1036 iGPU, which would bottleneck every one of them. Check:

    podman logs lemonade | grep -iE 'buffer size|assigned|ROCm[0-9]'

If it is, pin to the R9700s. Re-derive the indices rather than trusting these —
`grep -H gfx_target_version /sys/class/kfd/kfd/topology/nodes/*/properties`, where
120001 is an R9700 and 100306 the iGPU:

    llamacpp.rocm_args="--load-mode mmap -ts 1,1,0"     # zero weight to device 2
    # or, on the container: Environment=ROCR_VISIBLE_DEVICES=...

Not baked, because these indices move with kernel and slot changes.

## Context size & caching

The model download cache is already persistent (see Storage above) — models pull once.
llama.cpp also reuses the KV cache of a request's common prefix automatically; nothing to
configure for that.

The lever for LONG context is VRAM for the KV cache, which is SEPARATE from weights and
grows linearly with ctx_size. For the dense 27Bs (64 layers, 4 KV heads, head_dim 256)
it is ~0.25 GB per 1K tokens at fp16 — so 128K ~= 32 GB, on TOP of the ~23 GB weights;
the MoEs are ~0.10 GB/1K (2.5x lighter). So a 27B Q6 at 128K is ~56 GB total — it only
fits by SPLITTING across both R9700s, which is what the seeded contexts assume.

That split is AUTOMATIC here — default -sm layer already spreads layers (and their KV)
across both R9700s and, measured at ctx 32768, put nothing on the gfx1036 iGPU (only its
20 MiB framebuffer). -sm row is unavailable on this build, so layer split is the only mode
anyway. Two things to watch at 128K, where total memory is far larger: it must still fit
the 2x32 GB pair, and it must keep off the iGPU — if a load spills there, exclude it with
ROCR_VISIBLE_DEVICES=0,1 (GPU-agent indices; 2 is the iGPU) or the -ts note above. Bigger
context also costs prompt-processing time, so a smaller ctx is fine for quick edits.

KV-cache quantization roughly halves that KV footprint with little quality loss. Add to a
recipe's llamacpp_args in recipe_options.json:

    -fa -ctk q8_0 -ctv q8_0     # q8_0 ~halves KV; q4_0 ~quarters it

Not baked: V-cache quant needs flash attention (-fa), whose state on the gfx1201 ROCm
build is unverified. Confirm -fa works on the box first, then bake it into recipe_options
if you want it as a default.

## Coding / agent use

Two recipes suit agentic coding: user.Qwen3-Coder-30B (tuned for tool-calling / Codex-style
agents, 256K native ctx) and user.Qwen3.8-27B (Developer Role, plus vision + reasoning).
Coder is the default driver — MoE so it's fast, Q6_K, and its native 256K is the seeded
ctx (which the automatic two-card split makes room for).

Point your agent (opencode, aider, Continue, ...) at lemonade's OpenAI-compatible endpoint:

    base URL   http://127.0.0.1:13305/api/v1      (any api key; it's ignored)
    model      user.Qwen3-Coder-30B

Context: agentic coding uses far more than chat (multi-file, diffs, tool output, scratchpad).
The Coder seed is already the native 262144 (256K), which needs the two-card split — see
"Context size & caching". For a quick single-card session, drop ctx or add q8_0 KV-quant.

Keep it warm: an agent resends a large, mostly-unchanged prompt every turn, and llama.cpp
reuses the common prefix's KV automatically — but only while the model stays loaded. Enable
linger (below) and don't let it idle-unload, or you re-process the whole prompt each turn.

## Other gotchas

The stable ROCm channel has no gfx1201 support and silently falls back to CPU (~7x
slower, no error). The image pins rocm_channel=nightly, but seeds only apply on the
FIRST run; config.json wins after:

    podman exec lemonade lemonade config set rocm_channel=nightly
    podman exec lemonade lemonade backends install llamacpp:rocm

To change device passthrough you must SHADOW the unit, not drop in, since AddDevice=
is a repeated key:

    mkdir -p ~/.config/containers/systemd
    cp /etc/containers/systemd/users/lemonade.container ~/.config/containers/systemd/
    systemctl --user daemon-reload

Note this cannot hide a GPU from ROCm — ROCr enumerates agents from the KFD topology
(/sys/class/kfd/kfd/topology/nodes/), which is global. Use ROCR_VISIBLE_DEVICES.

## SELinux

/dev/dri works out of the box. /dev/kfd is allowed read/write but not `map`, which
ROCm needs. If the server starts but finds no GPU:

    sudo ausearch -m AVC -ts recent | grep hsa_device_t
    sudo setsebool -P container_use_devices on    # system-wide, all containers

Not baked into the image — setsebool -P state lives in /var/lib/selinux.

## Surviving logout

    loginctl enable-linger $USER
EOF
