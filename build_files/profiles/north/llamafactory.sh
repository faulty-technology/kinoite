#!/bin/bash
set -ouex pipefail

# LLaMA-Factory fine-tuning as a rootless Quadlet — the THIRD local-LLM stack on this box, and
# the only one that trains. lemonade.sh does llama.cpp GGUF inference; vllm.sh does batched
# tensor-parallel inference; this produces the weights they load. All three share the same
# HuggingFace model store (see the volume below), so a base model pulled here is already present
# for inference, and an adapter exported to GGUF here is already visible to lemonade.
#
# Deliberately NOT enabled: no [Install], nothing in services-north.sh beyond the sleep hook.
# Started by hand with `systemctl --user start llamafactory`. Runbook lives in
# /usr/share/kinoite/llamafactory.md; this file explains WHY, that file explains WHAT TO TYPE.
#
# REPLACED unsloth.sh. Unsloth itself worked here — the image built, the gfx1201 filter picked
# both R9700s, and torch/triton/bitsandbytes all resolved. What did not work was Unsloth Studio,
# its no-code UI: `pip install unsloth[studio]` cannot produce a runnable one (no frontend in
# package data, and the CLI gates on a venv only unsloth.ai/install.sh builds), and the documented
# workaround installs a SECOND torch stack that trains on different wheels than the image pins.
# LLaMA Board is a plain Gradio app with no installer gate, so the GUI stops being a caveat.
#
# WHY THE IMAGE IS BUILT ON THE BOX RATHER THAN PULLED. Upstream ships docker/docker-rocm, but it
# bases on rocm/pytorch:rocm7.2_ubuntu24.04_py3.12_pytorch_release_2.7.1, whose gfx1201 coverage
# is unproven — those images target CDNA first. What IS proven on this box is AMD's own
# whl-multi-arch index, which has a real gfx1201 target, so we keep that recipe and swap only the
# trainer on top of it. That is also why `pip freeze` is captured into the image: it is built
# outside CI, so the manifest inside it is the only record of what actually landed.
for bin in podman crun; do
    command -v "$bin" >/dev/null || { echo "llamafactory.sh: missing $bin" >&2; exit 1; }
done

mkdir -p /usr/share/kinoite/llamafactory

### 1. The image recipe
# Python 3.12, not Fedora's 3.14: AMD's playbook targets 3.12, and it is the version upstream's
# own ROCm image ships. The AMD index does carry cp314 wheels, so 3.14 is a later experiment.
cat > /usr/share/kinoite/llamafactory/Containerfile << 'CONTAINERFILEEOF'
# Built on the box by llamafactory.container's ExecStartPre, not in CI. See llamafactory.sh.
FROM docker.io/library/python:3.12-slim

# git: LLaMA-Factory is cloned below rather than installed from PyPI. ca-certificates: for both
# indexes. libatomic1 + libgomp1: AMD's TheRock wheels link against both and python:3.12-slim
# carries neither. Without them `import torch` dies in _dlopen and the launcher's gfx1201 filter
# takes its "no device found" branch — which silently leaves training on the iGPU.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git ca-certificates libatomic1 libgomp1 \
 && rm -rf /var/lib/apt/lists/*

# gfx1201 (Radeon AI PRO R9700). This trio is the set AMD's playbook documents TOGETHER, and it
# is the exact combination verified working on this box under the previous trainer. Newer exists
# at the same index and is the upgrade path, but do not bump it casually.
#
# These are TheRock multi-arch wheels: they bundle their own ROCm runtime, so the container needs
# no ROCm base image and the host still has no ROCm installed — the same posture lemonade.sh
# documents for its llama.cpp builds.
#
# triton arrives HERE, as a dependency of this torch (observed: 3.7.1+git0263a6a6.rocm7.14.0).
# Nothing below pins it and it does not need a separate install; if a future torch drops it,
# the AMD index has a triton/ directory to install from explicitly.
RUN pip install --no-cache-dir --index-url https://repo.amd.com/rocm/whl-multi-arch/ \
      "torch[device-gfx1201]==2.12.0+rocm7.14.0" \
      "torchvision[device-gfx1201]==0.27.0+rocm7.14.0" \
      "torchaudio==2.11.0+rocm7.14.0"

# Cloned rather than pip-installed from a git URL so that data/ survives: it carries
# dataset_info.json and upstream's example datasets, which the launcher seeds into the workspace
# volume so LLaMA Board's dataset dropdown is populated on a fresh box. A `pip install git+...`
# keeps only the package and would leave the GUI with nothing to select.
RUN git clone --depth 1 https://github.com/hiyouga/LLaMA-Factory.git /opt/llamafactory

# MUST come after torch, and MUST NOT pull the `torch` extra. Same trap the previous trainer
# documented: an extra that names torch can resolve a CUDA build from PyPI straight over the AMD
# wheels above, and pip will keep it. `metrics` is BLEU/ROUGE scoring for the eval tab.
# --no-build-isolation so the build backend sees the torch already installed.
RUN pip install --no-cache-dir --no-build-isolation -e "/opt/llamafactory[metrics]"

# QLoRA is the working path on gfx1201 — full-precision LoRA is reported to crash in rocBLAS
# Tensile GEMM on this arch — so 4-bit is not optional here. Previously this arrived via unsloth's
# `amd` extra; nothing pulls it in now, so it is explicit.
#
# The >=0.50.0 floor is a CORRECTNESS bound, not a preference: upstream's own pyproject comment
# calls it the first PyPI release carrying the full RDNA path (blocksize/warp decoupling, fused
# SIMT GEMM, the RDNA3/4 workgroup fix). Anything older is unreliable at 4-bit on ROCm.
# 0.50.2 is the version verified on this box. Do not relax the floor.
RUN pip install --no-cache-dir "bitsandbytes>=0.50.0"

# NOT installed, each for a measured or documented reason:
#   flash-attn    — no RDNA4 support. Upstream's own ROCm Dockerfile defaults it off.
#   deepspeed     — multi-node sharding; this is one box and the posture below is single-card.
#   liger-kernel  — Triton kernels written against CUDA/CDNA; unproven on RDNA4.

# Jupyter is the code-first half. LLaMA Board trains but does NOT author datasets, and the first
# project here is dataset-shaped — a labelling rubric has to be written somewhere.
RUN pip install --no-cache-dir jupyterlab

# Built outside CI, so this manifest is the ONLY provenance for what a given image contains.
# `podman exec llamafactory cat /opt/kinoite-versions.txt` after a rebuild to see what moved.
RUN pip freeze > /opt/kinoite-versions.txt
CONTAINERFILEEOF

### 2. Launcher
# Baked to /usr/share/kinoite/llamafactory/ and copied into the container at start
# (ExecStartPre), because /usr is read-only and usr_t-labeled — container_t can't read it and :z
# can't relabel a read-only mount. Same gotcha lemonade.sh and vllm.sh both document.
cat > /usr/share/kinoite/llamafactory/llamafactory-start.sh << 'STARTEOF'
#!/bin/bash
# Entry point for llamafactory.container. Selects the R9700s, warns about VRAM already in use,
# seeds the dataset dir, and starts LLaMA Board with Jupyter alongside it.
#
# HOW TO OVERRIDE ANYTHING HERE — this is a QUADLET container, and the obvious way does not work.
# A systemd drop-in with [Service] Environment= sets the variable on the PODMAN process on the
# host; podman only forwards what the .container file declares, so it never reaches the
# container. Use [Container] Environment= in a SHADOWED unit instead:
#     mkdir -p ~/.config/containers/systemd/users
#     cp /etc/containers/systemd/users/llamafactory.container ~/.config/containers/systemd/users/
#     # add e.g.  Environment=HIP_VISIBLE_DEVICES=0   under [Container]
#     systemctl --user daemon-reload && systemctl --user restart llamafactory
# A shadowed unit is a full copy and will NOT pick up changes from a later image build.
set -euo pipefail

log()  { printf '[llamafactory] %s\n' "$*"; }
warn() { printf '[llamafactory] %s\n' "$*" >&2; }

### GPU selection
# Never bake a device index: notes/kinoite-north-validation.md records DRM numbering reshuffling
# across kernels and boots twice, and only the PCI address is stable. So derive it every start,
# from torch's own view of the HIP devices.
#
# HIP_VISIBLE_DEVICES, NOT ROCR_VISIBLE_DEVICES or CUDA_VISIBLE_DEVICES: vllm-serve.sh records
# those two conflicting with HIP and hanging distributed init. Skipped entirely if the caller
# already set it, so a shadowed unit can pin devices by hand.
if [ -z "${HIP_VISIBLE_DEVICES:-}" ]; then
    # This box has three HIP-visible GPUs: two R9700s (gfx1201) and the Granite Ridge iGPU
    # (gfx1036). Training on the iGPU is not slow, it is broken — keep only gfx1201.
    detected=$(python - <<'PY' || true
import sys
try:
    import torch
except Exception as exc:                      # noqa: BLE001 - any import failure is fatal here
    print(f"torch import failed: {exc}", file=sys.stderr)
    sys.exit(1)
keep = []
for i in range(torch.cuda.device_count()):
    # gcnArchName reads like "gfx1201:sramecc-:xnack-", so take the part before the colon.
    arch = (torch.cuda.get_device_properties(i).gcnArchName or "").split(":")[0]
    if arch == "gfx1201":
        keep.append(str(i))
print(",".join(keep))
PY
    )
    if [ -n "${detected:-}" ]; then
        export HIP_VISIBLE_DEVICES="$detected"
        log "HIP_VISIBLE_DEVICES=$HIP_VISIBLE_DEVICES (gfx1201 only)"
    else
        # Not fatal: a torch that cannot see a GPU should fail loudly in the trainer, with a real
        # traceback, rather than be second-guessed by the launcher.
        warn "no gfx1201 device found — leaving HIP_VISIBLE_DEVICES unset."
        warn "Training will fall back to whatever torch enumerates, INCLUDING the iGPU."
    fi
else
    log "HIP_VISIBLE_DEVICES=$HIP_VISIBLE_DEVICES (preset; detection skipped)"
fi

### VRAM already in use?
# Warn, never block. The three stacks are mutually exclusive in practice: vLLM alone idles at
# ~24 GiB/card at the shipped 0.80 utilisation, and a fine-tune needs room for weights, gradients
# and optimiser state on top. The failure mode without this warning is a torch OOM several
# minutes into a run, which reads like a batch-size problem and is not.
#
# Same sysfs path kinoite-llm-sleep's vram_settle() reads, and the same 4 GiB idle ceiling.
VRAM_IDLE_MAX=$((4 * 1024 * 1024 * 1024))
worst=0
report=''
for f in /sys/class/drm/card*/device/mem_info_vram_used; do
    [ -r "$f" ] || continue
    card=${f#/sys/class/drm/}
    card=${card%%/*}
    # Per-connector dirs (card1-DP-1) point at the same pci node; skip so nothing double-counts.
    case $card in *-*) continue ;; esac
    used=''
    read -r used < "$f" || continue
    case $used in '' | *[!0-9]*) continue ;; esac
    report="$report $card=$((used / 1024 / 1024))MiB"
    if [ "$used" -gt "$worst" ]; then
        worst=$used
    fi
done
if [ -n "$report" ] && [ "$worst" -gt "$VRAM_IDLE_MAX" ]; then
    warn "VRAM ALREADY IN USE:${report}"
    warn "Another LLM stack is almost certainly running. Training will likely OOM."
    warn "  systemctl --user stop north-llm-pod lemonade"
elif [ -n "$report" ]; then
    log "VRAM at start:${report}"
fi

### Dataset directory
# LLaMA Board's "Data dir" box defaults to the RELATIVE path `data`, so running from /workspace
# is what makes the GUI's default resolve onto the persistent volume rather than into the
# container's throwaway filesystem. Do not drop this cd.
cd /workspace

# Seed once from the clone in the image, so a fresh box opens the GUI with a valid
# dataset_info.json and upstream's examples already selectable. Never overwrite: after the first
# start this directory is the user's, and their registrations live in the same file.
if [ ! -e /workspace/data/dataset_info.json ]; then
    log "seeding /workspace/data from the image's bundled datasets"
    mkdir -p /workspace/data
    cp -r /opt/llamafactory/data/. /workspace/data/
fi

### UIs
# 0.0.0.0 inside the container is deliberate and safe: the unit's PublishPort carries a 127.0.0.1
# prefix, and THAT is what keeps both UIs off the tailnet — exactly how lemonade's 13305 and
# vLLM's 8000 are confined. Binding to the container's loopback instead would make the published
# port unreachable.
#
# LLaMA Board is the exec'd process, so it owns the unit's lifetime: if Jupyter dies the container
# stays up and `systemctl --user restart llamafactory` brings it back. Jupyter prints its token to
# the journal on first start.
log "starting Jupyter Lab on :8889 (background)"
jupyter lab --ip 0.0.0.0 --port 8889 --no-browser --allow-root \
    --ServerApp.root_dir=/workspace &

# GRADIO_SHARE stays off: it would tunnel the UI out through gradio.live, defeating the loopback
# publish above.
export GRADIO_SERVER_NAME=0.0.0.0
export GRADIO_SERVER_PORT=7860
export GRADIO_SHARE=0

log "starting LLaMA Board on :7860"
exec llamafactory-cli webui
STARTEOF
chmod 0755 /usr/share/kinoite/llamafactory/llamafactory-start.sh

# Fail the build loudly on a shell typo rather than shipping a launcher bash rejects.
bash -n /usr/share/kinoite/llamafactory/llamafactory-start.sh

### 3. Host-side HuggingFace store
# packages.sh installs python3-huggingface-hub, which ships /usr/bin/hf. This points it at the
# SAME store all three containers mount, which buys two things at once:
#   - `hf download` lands where lemonade, vLLM and this stack already look, so a model is pulled
#     once for the whole box.
#   - `hf auth login` writes its token to $HF_HOME/token, which is inside that store — so every
#     container gets the credential with no per-container secret plumbing at all.
#
# ACCEPTED TRADEOFF: the token is then readable by anything that mounts the shared store, which
# today is all three LLM stacks. On a single-user box that is the point; if it ever stops being
# one, move the token back to ~/.cache/huggingface and pass HF_TOKEN explicitly to the one
# container that needs it.
#
# uid-guarded so root's $HOME (/var/roothome) never grows a second, half-populated store.
cat > /etc/profile.d/kinoite-hf.sh << 'PROFILEEOF'
# Point host-side HuggingFace tools at the shared model store the LLM containers mount.
# See /usr/share/kinoite/llamafactory.md. Only set for regular login accounts, and never
# overrides an HF_HOME the user has already chosen.
if [ -z "${HF_HOME:-}" ] && [ "$(id -u)" -ge 1000 ] && [ "$(id -u)" -lt 60000 ]; then
    export HF_HOME="$HOME/.local/share/models/huggingface"
fi
PROFILEEOF
sh -n /etc/profile.d/kinoite-hf.sh

### 4. Rootless Quadlet unit
# /etc, not /usr: podman 5.8.4 only searches /etc/containers/systemd/users{,/$UID} for rootless
# units — the /usr/share equivalent is documented but not scanned. users/ (not users/$UID/)
# because the UID isn't knowable at build time. Same as lemonade.sh and vllm.sh.
mkdir -p /etc/containers/systemd/users

cat > /etc/containers/systemd/users/llamafactory.container << 'QUADLETEOF'
[Unit]
Description=LLaMA-Factory fine-tuning (gfx1201 / dual R9700)
Documentation=https://github.com/hiyouga/LLaMA-Factory
Documentation=file:///usr/share/kinoite/llamafactory.md

# Bounds a rebuild loop. ExecStartPre builds the image, and a build that fails for a durable
# reason (index down, a wheel pulled) would otherwise retry every RestartSec forever.
StartLimitIntervalSec=1h
StartLimitBurst=3

[Container]
Image=localhost/kinoite-llamafactory:latest
ContainerName=llamafactory

# Directory: podman adds every node under it, iGPU included — the launcher excludes it via
# HIP_VISIBLE_DEVICES. See notes/.
AddDevice=/dev/kfd
AddDevice=/dev/dri

# NO --ipc=host and NO --group-add, unlike vllm.container and unlike upstream's own compose file.
# lemonade.sh measured both unnecessary here: /dev/kfd and the render nodes are mode 0666 straight
# from systemd-udev's base rules, so no group membership is involved, and --ipc=host additionally
# makes podman drop SELinux label separation for the whole container. The only thing --ipc=host
# was buying a single-process trainer is shared memory for dataloader workers, so raise that
# directly and keep the container confined.
#
# CONSEQUENCE, stated plainly: multi-GPU (RCCL) training is UNTESTED under this posture.
# Single-card QLoRA is the assumption. If a distributed run needs host IPC, add it in a shadowed
# unit and accept that it turns the label separation off.
PodmanArgs=--shm-size=16g

# Unauthenticated-by-default web UIs — the 127.0.0.1 prefix is what keeps them off the tailnet,
# the same posture as lemonade's 13305 and vLLM's 8000/3000.
#
# LLaMA-Factory's API server (upstream compose publishes it on 8000) is deliberately NOT
# published: 8000 is already vllm.container's, and the GUI does not need it. If you ever want the
# API, map it to a free HOST port in a shadowed unit — do not reuse 8000.
PublishPort=127.0.0.1:7860:7860
PublishPort=127.0.0.1:8889:8889

# THE SHARED MODEL STORE — the same HuggingFace hub cache lemonade and vLLM mount. A base model
# pulled by any of them is reused by all, an adapter exported here is immediately visible to
# lemonade, and the host's `hf auth login` token is already inside it.
# :z (shared label), not :Z — :Z would relabel the whole store on every start, since Quadlet
# builds a new container each time.
Volume=%h/.local/share/models/huggingface:/root/.cache/huggingface:z
Environment=HF_HOME=/root/.cache/huggingface

# Datasets, adapters, notebooks, training output. Yours to inspect, prune and back up. Also the
# launcher's cwd, which is what makes LLaMA Board's default relative "data" dir land here.
Volume=%h/.local/share/llamafactory/workspace:/workspace:z

# Copied-in launcher (see the /usr read-only note in the build script).
Volume=%h/.local/share/llamafactory/bin:/opt/kinoite:z

# Persistent triton/inductor kernel caches, so the first training step's compile is paid once
# rather than on every container start. Version-hashed, so a rebuild misses and recompiles
# cleanly; rm the dir to force that by hand.
Volume=%h/.local/share/llamafactory/cache:/opt/llamafactory-cache:z
Environment=TRITON_CACHE_DIR=/opt/llamafactory-cache/triton
Environment=TORCHINDUCTOR_CACHE_DIR=/opt/llamafactory-cache/inductor

Exec=/opt/kinoite/llamafactory-start.sh

[Service]
# on-failure, not always: unlike vLLM (whose engine death exits CLEANLY and so needs `always` to
# recover), there is no equivalent silent-success failure mode here, and a training box should not
# resurrect itself in a loop while you are reading the traceback that killed it.
Restart=on-failure
RestartSec=10

# First start BUILDS the image — a multi-GB torch+ROCm pip install — before anything runs.
TimeoutStartSec=5400

# Build only when the image is missing, so routine restarts don't rebuild. Same shape and same
# reasoning as vllm.container's guarded pre-pull: the implicit path inside `podman run` is
# hard-capped at 5 minutes under systemd, which no build of this size will meet. Updating is then
# a deliberate `podman build --no-cache` (see llamafactory.md), never a surprise on restart.
ExecStartPre=/bin/sh -c 'podman image exists localhost/kinoite-llamafactory:latest || podman build -t localhost/kinoite-llamafactory:latest -f /usr/share/kinoite/llamafactory/Containerfile /usr/share/kinoite/llamafactory'

# Podman doesn't create missing bind-mount sources.
ExecStartPre=/usr/bin/mkdir -p %h/.local/share/models/huggingface %h/.local/share/llamafactory/workspace %h/.local/share/llamafactory/bin %h/.local/share/llamafactory/cache
ExecStartPre=/usr/bin/install -m 0755 /usr/share/kinoite/llamafactory/llamafactory-start.sh %h/.local/share/llamafactory/bin/llamafactory-start.sh

# No [Install] — hand-started on purpose.
QUADLETEOF

### 5. On-box runbook
# The box won't have this repo checked out when something breaks. WHAT TO TYPE goes here; WHY a
# decision was made stays at the code above.
cat > /usr/share/kinoite/llamafactory.md << 'MDEOF'
# kinoite-north: LLaMA-Factory fine-tuning (rootless Quadlet)

The third local-LLM stack, and the only one that TRAINS. lemonade (lemonade.md) and vLLM
(vllm.md) serve models; this one makes them. All three share one HuggingFace store, so a base
model pulled here is already there for inference, and an adapter exported to GGUF here is
immediately loadable by lemonade.

Ships at /etc/containers/systemd/users/llamafactory.container, NOT enabled.

    systemctl --user stop north-llm-pod lemonade   # free the GPUs FIRST — see below
    systemctl --user start llamafactory
    journalctl --user -u llamafactory -f           # Jupyter's token appears here

    LLaMA Board   http://127.0.0.1:7860    no-code training UI
    Jupyter Lab   http://127.0.0.1:8889    notebooks, rooted at the workspace

Loopback only, both of them. `systemctl --user enable llamafactory` is expected to FAIL:
generator-produced units have no [Install] to act on. That's the guardrail, not a bug.

## The first start builds the image (this is not a hang)

Upstream's ROCm image targets CDNA, so this box builds its own against AMD's gfx1201 wheels:
`podman build` runs from the baked recipe at /usr/share/kinoite/llamafactory/Containerfile — a
multi-GB torch+ROCm pip install. Expect a long silent stretch; the unit allows 90 minutes.

It builds ONLY when the image is missing, so restarts are fast. To update deliberately:

    podman build --no-cache -t localhost/kinoite-llamafactory:latest \
        -f /usr/share/kinoite/llamafactory/Containerfile /usr/share/kinoite/llamafactory
    systemctl --user restart llamafactory

The image is built here rather than in CI, so the only record of what it contains is inside it:

    podman exec llamafactory cat /opt/kinoite-versions.txt

Expect torch 2.12.0+rocm7.14.0. A plain `2.12.0` with no +rocm suffix means a CUDA wheel won the
resolution and nothing will see a GPU — rebuild.

## Use QLoRA, not full-precision LoRA

Set `Quantization bit: 4` in LLaMA Board. Full-precision LoRA is reported to crash in rocBLAS
Tensile GEMM on gfx1201 while the 4-bit path is clean. If you hit

    Memory access fault by GPU node-N ... rocBLAS

that is this, not your hyperparameters.

Write learning rates as decimals (`0.0002`), not scientific notation (`2e-4`) — some transformers
versions reject the latter from the GUI's text field.

## Only one stack can hold the GPUs

vLLM alone idles at ~24 GiB per card at the shipped 0.80 utilisation, and a fine-tune needs room
for weights, gradients and optimiser state on top. Stop the others first:

    systemctl --user stop north-llm-pod lemonade

The launcher warns at start if a card is already holding more than 4 GiB, because the failure
without that warning is a torch OOM several minutes into a run — which reads like a batch-size
problem and is not.

## Suspend / resume

Handled by `kinoite-llm-sleep.service`, the same hook that covers lemonade and vLLM. It is not
optional politeness: amdgpu evicts VRAM into system RAM to suspend, this box has 64 GB of RAM
against 64 GB of VRAM, and suspending with the GPUs loaded HANGS THE MACHINE hard enough to need
the power button, with nothing in the kernel log.

The important caveat here, which does not apply to the inference stacks: resume restores the
SERVER, not your training run. That process died with the container. For a long fine-tune, keep
the box awake instead:

    systemd-inhibit --what=sleep --why='fine-tune' sleep infinity

...or checkpoint often enough that losing the tail doesn't matter.

## Storage

    ~/.local/share/models/huggingface        models + auth token (SHARED with lemonade and vLLM)
    ~/.local/share/llamafactory/workspace    datasets, adapters, output  (both UIs' root)
    ~/.local/share/llamafactory/workspace/data   dataset_info.json + your JSONL
    ~/.local/share/llamafactory/cache        triton / inductor kernel caches
    ~/.local/share/llamafactory/bin          the launcher, copied from /usr at each start

## Adding your own dataset

The workspace's data/ is seeded once from the image on first start, so LLaMA Board opens with
upstream's examples already selectable. To add your own:

1. Drop `mydata.jsonl` in ~/.local/share/llamafactory/workspace/data/
2. Register it in `dataset_info.json` in the same directory:

       "my_dataset": { "file_name": "mydata.jsonl" }

3. It appears in the Dataset dropdown — no rebuild, no restart.

The GUI's "Data dir" box says `data`, which is relative to the launcher's cwd (/workspace). Leave
it alone unless you moved the files.

## Hugging Face CLI

`hf` is installed on the HOST (python3-huggingface-hub). /etc/profile.d/kinoite-hf.sh points
HF_HOME at the shared store, so:

    echo "$HF_HOME"          # ~/.local/share/models/huggingface
    hf auth login            # token -> $HF_HOME/token, mode 0600
    hf download Qwen/Qwen3.5-4B-Instruct

Because the token lives INSIDE the shared store, and all three containers mount that store, every
stack gets the credential with no per-container secret plumbing. The tradeoff is the other side of
that coin: anything mounting the store can read the token. On a single-user box that is the deal.

If downloads misbehave with xet-related errors, `export HF_HUB_DISABLE_XET=1` — the documented
workaround, not baked because it has not been needed here.

## GPU selection

The launcher sets HIP_VISIBLE_DEVICES to the gfx1201 cards only, derived at every start from
`torch.cuda.get_device_properties(i).gcnArchName`. This box has THREE HIP-visible GPUs — two
R9700s and the gfx1036 iGPU — and training on the iGPU is not slow, it is broken.

Never bake an index: DRM numbering reshuffles across kernels and boots (observed twice), and only
the PCI address is stable. Check what it picked in the journal:

    journalctl --user -u llamafactory | grep HIP_VISIBLE_DEVICES

Expect `HIP_VISIBLE_DEVICES=0,1 (gfx1201 only)` — two indices. The "no gfx1201 device found"
warning instead means the filter failed, and torch will enumerate the iGPU too.

DO NOT check this with a bare `podman exec ... torch.cuda.device_count()`. The launcher exports
HIP_VISIBLE_DEVICES into its own process, which becomes the server; `podman exec` starts a fresh
process that inherits only what the unit declares, so it always reports 3 devices including the
gfx1036 and looks like a failure that isn't. Pass it explicitly to check from inside:

    podman exec -e HIP_VISIBLE_DEVICES=0,1 llamafactory python -c \
      "import torch; print(torch.cuda.device_count()); \
       print([torch.cuda.get_device_properties(i).gcnArchName for i in range(torch.cuda.device_count())])"

HIP_VISIBLE_DEVICES specifically — NOT ROCR_VISIBLE_DEVICES or CUDA_VISIBLE_DEVICES, which
conflict with HIP and hang distributed init (recorded in vllm.md). Preset it in a shadowed unit to
pin devices by hand; the launcher then skips detection.

## Multi-GPU is untested

This container runs WITHOUT --ipc=host and WITHOUT --group-add, unlike vllm.container and unlike
upstream's own compose file. lemonade.sh measured both unnecessary (the devices are 0666 from
udev's base rules), and --ipc=host additionally drops SELinux label separation.
--shm-size=16g covers what a dataloader actually needs.

So: single-card QLoRA is the assumption. A distributed run may need host IPC — add it in a
shadowed unit, and know that doing so turns the confinement off.

## If ROCm dies at model load

Same symptom and same cause as lemonade's, and the fix is already applied at boot:

    Memory critical error by agent node-0 ... Reason: Memory in use.

That is SELinux denying `map` on /dev/kfd, which ROCm mmaps. `lemonade-selinux.service` flips
`container_use_devices` at boot for exactly this, and it covers every container on the box, so
this stack inherits the fix. If it looks like this is happening:

    systemctl status lemonade-selinux.service
    sudo ausearch -m AVC -ts recent | grep hsa_device_t

Full detail in lemonade.md.

## Back into inference

The point of training here is to serve the result from a stack already on this box:

1. Train a LoRA in LLaMA Board.
2. Export tab: merge the adapter and export. Point the export dir into the shared store.
3. Convert to GGUF if lemonade is the target, add a `user.` recipe per "Recipes" in lemonade.md,
   and run it with `podman exec lemonade lemonade run user.<name>`.

Because the store is shared, step 2 lands the file exactly where lemonade already looks — no copy
step.

## First project: bash command risk scoring

Base model in the 4B class (e.g. Qwen3.5-4B-Instruct) is the right size to start: it fits one
card comfortably, trains in minutes rather than hours, and the task is classification-shaped
rather than generation-shaped.

The hard part is not the training, it is the dataset — a `command -> risk` rubric that is
consistent enough to learn. Build that in Jupyter on :8889, register it per "Adding your own
dataset" above, then train it from LLaMA Board.
MDEOF

### 6. Gate the generated unit
# Quadlet units are not systemd units until the generator runs, so `systemd-analyze verify` can't
# check one directly. Grep for the misplaced-key class instead — the same failure shape
# services-north.sh guards kinoite-llm-sleep.service against, and one that systemd accepts
# silently. Environment= under [Service] would be the live trap here: it would set the variable on
# podman rather than in the container, and the knob would quietly do nothing.
awk '/^\[Service\]/{s=1} s && /^Environment=/{print FILENAME": Environment= under [Service] — belongs in [Container]"; bad=1} END{exit bad?1:0}' \
    /etc/containers/systemd/users/llamafactory.container \
    || { echo "llamafactory.sh: bad key placement in llamafactory.container (see above)" >&2; exit 1; }
