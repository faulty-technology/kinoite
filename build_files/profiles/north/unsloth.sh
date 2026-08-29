#!/bin/bash
set -ouex pipefail

# Unsloth fine-tuning as a rootless Quadlet — the THIRD local-LLM stack on this box, and the
# only one that trains rather than serves. lemonade.sh does llama.cpp GGUF inference; vllm.sh
# does batched tensor-parallel inference; this produces the weights they load. All three share
# the same HuggingFace model store (see the volume below), so a base model pulled here is
# already present for inference, and an adapter exported to GGUF here is already visible to
# lemonade.
#
# Deliberately NOT enabled: no [Install], nothing in services-north.sh. Started by hand with
# `systemctl --user start unsloth`. Runbook and gotchas live in /usr/share/kinoite/unsloth.md.
#
# TODO(hardware): none of this has run on the box yet. See notes/kinoite-north-validation.md.
#
# WHY THE IMAGE IS BUILT ON THE BOX RATHER THAN PULLED. There is no Unsloth image for gfx1201
# anywhere. The official `unsloth/unsloth` is CUDA-only (it wants the NVIDIA Container Toolkit),
# and the community ROCm rebuilds only publish gfx942 and gfx1100 tags. What DOES exist is
# AMD's documented pip path, which has a real gfx1201 target — so we bake the recipe and let
# podman build it once, locally. That is also why `pip freeze` is captured into the image: it
# is built outside CI, so the manifest inside it is the only record of what actually landed.
for bin in podman crun; do
    command -v "$bin" >/dev/null || { echo "unsloth.sh: missing $bin" >&2; exit 1; }
done

mkdir -p /usr/share/kinoite/unsloth

### 1. The image recipe
# Python 3.12, not Fedora's 3.14: AMD's playbook targets 3.12 and unsloth's own rocm extras
# stop at 3.13. The AMD index does carry cp314 wheels, so 3.14 is a later experiment, not a
# blocker — but the middle of the tested band is the right place to start.
#
# ORDERING IS LOAD-BEARING. AMD's torch must be installed BEFORE unsloth, because unsloth's
# `amd` extra is deliberately torch-less — it resolves to `unsloth[huggingfacenotorch]` plus
# `bitsandbytes>=0.50.0` and leaves whatever torch it finds alone. Install it first and it
# would drag in a CUDA torch from PyPI that then gets kept.
#
# bitsandbytes>=0.50.0 comes from that extra and is what makes 4-bit work here: upstream's own
# pyproject comment calls 0.50.0 "the first PyPI release carrying the full path" for RDNA
# (blocksize/warp decoupling, fused SIMT GEMM, the RDNA3/4 workgroup fix). Anything older is
# unreliable at 4-bit decode on ROCm, so do not relax that floor.
#
# The `studio` extra carries Studio's server stack (fastapi/uvicorn/typer/pydantic/pyjwt/
# cryptography), but that is NOT enough to run `unsloth studio`. The frontend is not shipped as
# package data — `site-packages/studio/frontend/dist` does not exist, and upstream gitignores
# it — and the CLI additionally gates on an installer-managed venv at
# $UNSLOTH_STUDIO_HOME/unsloth_studio. Only unsloth.ai/install.sh builds that venv, and pip
# ships the package rather than the repo, so the installer is not in the image either. Hence
# UNSLOTH_UI=jupyter by default, with Studio one documented command away. See unsloth.md.
#
# That installer builds a SECOND, self-contained stack inside the venv — its own torch, its own
# unsloth, a Vite frontend, a prebuilt llama.cpp — so it cannot disturb the wheels below. Told
# the arch, it routes torch to repo.amd.com/rocm/whl/gfx120X-all (torch 2.11.x), which is NOT
# the whl-multi-arch gfx1201 set this recipe pins: Studio trains on its own stack, not this one.
# Telling it the arch is what UNSLOTH_ROCM_GFX_ARCH on the unit is for — see the quadlet.
cat > /usr/share/kinoite/unsloth/Containerfile << 'CONTAINERFILEEOF'
# Built on the box by unsloth.container's ExecStartPre, not in CI. See unsloth.sh.
FROM docker.io/library/python:3.12-slim

# git: unsloth installs from a git ref below. ca-certificates: for both indexes.
# libatomic1 + libgomp1: AMD's TheRock wheels link against both and python:3.12-slim carries
# neither. Without them `import torch` dies in _dlopen and the launcher's gfx1201 filter takes
# its "no device found" branch — which silently leaves training on the iGPU.
#
# curl + pciutils are for the opt-in Studio install, not for anything the image runs. curl
# fetches unsloth.ai/install.sh and backs that script's own download() helper, which exits
# without curl or wget. pciutils gives it lspci: with no rocminfo or amd-smi in here (the
# wheels bundle ROCm, they do not install its tools) lspci is the only GPU probe it has left.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git ca-certificates curl pciutils libatomic1 libgomp1 \
 && rm -rf /var/lib/apt/lists/*

# gfx1201 (Radeon AI PRO R9700). This trio is the set AMD's playbook documents TOGETHER;
# newer exists at the same index (torch 2.13.0, torchvision 0.28.0) and is the upgrade path,
# but a matched, written-down recipe beats a newer guess for a first build.
#
# These are TheRock multi-arch wheels: they bundle their own ROCm runtime, so the container
# needs no ROCm base image and the host still has no ROCm installed — the same posture
# lemonade.sh documents for its llama.cpp builds.
RUN pip install --no-cache-dir --index-url https://repo.amd.com/rocm/whl-multi-arch/ \
      "torch[device-gfx1201]==2.12.0+rocm7.14.0" \
      "torchvision[device-gfx1201]==0.27.0+rocm7.14.0" \
      "torchaudio==2.11.0+rocm7.14.0"

# MUST come after torch — the `amd` extra is torch-less by design and keeps what it finds.
RUN pip install --no-cache-dir \
      "unsloth[amd,studio] @ git+https://github.com/unslothai/unsloth.git"

# Jupyter is the code-first half: Studio drives training runs, Jupyter is where a bespoke
# dataset and labelling rubric get written. Small next to the torch stack.
RUN pip install --no-cache-dir jupyterlab

# Built outside CI, so this manifest is the ONLY provenance for what a given image contains.
# `podman exec unsloth cat /opt/kinoite-versions.txt` after a rebuild to see what moved.
RUN pip freeze > /opt/kinoite-versions.txt
CONTAINERFILEEOF

### 2. Launcher
# Baked to /usr/share/kinoite/unsloth/ and copied into the container at start (ExecStartPre),
# because /usr is read-only and usr_t-labeled — container_t can't read it and :z can't relabel
# a read-only mount. Same gotcha lemonade.sh and vllm.sh both document.
cat > /usr/share/kinoite/unsloth/unsloth-start.sh << 'STARTEOF'
#!/bin/bash
# Entry point for unsloth.container. Selects the R9700s, warns about VRAM already in use, and
# starts the UI(s) named by $UNSLOTH_UI.
#
# HOW TO OVERRIDE ANYTHING HERE — this is a QUADLET container, and the obvious way does not
# work. A systemd drop-in with [Service] Environment= sets the variable on the PODMAN process
# on the host; podman only forwards what the .container file declares, so it never reaches the
# container. Use [Container] Environment= in a SHADOWED unit instead:
#     mkdir -p ~/.config/containers/systemd/users
#     cp /etc/containers/systemd/users/unsloth.container ~/.config/containers/systemd/users/
#     # add e.g.  Environment=UNSLOTH_UI=jupyter   under [Container]
#     systemctl --user daemon-reload && systemctl --user restart unsloth
# A shadowed unit is a full copy and will NOT pick up changes from a later image build.
set -euo pipefail

log()  { printf '[unsloth] %s\n' "$*"; }
warn() { printf '[unsloth] %s\n' "$*" >&2; }

### GPU selection
# Never bake a device index: notes/kinoite-north-validation.md records DRM numbering
# reshuffling across kernels and boots twice, and only the PCI address is stable. So derive it
# every start, from torch's own view of the HIP devices.
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
        # Not fatal: a torch that cannot see a GPU should fail loudly in the trainer, with a
        # real traceback, rather than be second-guessed by the launcher.
        warn "no gfx1201 device found — leaving HIP_VISIBLE_DEVICES unset."
        warn "Training will fall back to whatever torch enumerates, INCLUDING the iGPU."
    fi
else
    log "HIP_VISIBLE_DEVICES=$HIP_VISIBLE_DEVICES (preset; detection skipped)"
fi

### VRAM already in use?
# Warn, never block. The three stacks are mutually exclusive in practice: vLLM alone idles at
# ~24 GiB/card at the shipped 0.80 utilisation, and a fine-tune needs room for weights,
# gradients and optimiser state on top. The failure mode without this warning is a torch OOM
# several minutes into a run, which reads like a batch-size problem and is not.
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

### UI
# 0.0.0.0 inside the container is deliberate and safe: the unit's PublishPort carries a
# 127.0.0.1 prefix, and THAT is what keeps both UIs off the tailnet — exactly how lemonade's
# 13305 and vLLM's 8000 are confined. Binding to the container's loopback instead would make
# the published port unreachable.
#
# Whichever server ends up in the foreground prints its own credential on first start — read it
# out of the journal. In `both` Studio is the exec'd one, so it owns the unit's lifetime: if
# Jupyter dies the container stays up and `systemctl --user restart unsloth` brings it back.
#
# STUDIO IS NOT RUNNABLE from the plain pip install this image performs — the CLI gates on an
# installer-managed venv that only unsloth.ai/install.sh creates, and without it every `unsloth
# studio` subcommand, `update` included, exits 1 with "venv not found at .../unsloth_studio".
# Being the exec'd process in `both`, that took Jupyter down with it and crash-looped the unit
# until StartLimitBurst. So check first and fall back: asking for a Studio you don't have costs
# a warning, not the container. See the Containerfile note above for why it isn't baked in.
#
# The check is the venv's interpreter because that is the path the CLI itself resolves, and the
# installer puts EVERYTHING there — venv, frontend, sqlite, launcher — under $UNSLOTH_STUDIO_HOME
# rather than in site-packages. That is what makes one install survive Quadlet's new container.
studio_ready() { [ -x "${UNSLOTH_STUDIO_HOME:-/opt/unsloth-studio}/unsloth_studio/bin/python" ]; }

studio_missing_note() {
    warn "Unsloth Studio is not installed (no venv under \$UNSLOTH_STUDIO_HOME)."
    warn "Install it once — it lands on the persistent studio volume, so it survives restarts:"
    warn "  podman exec -it unsloth sh -c 'curl -fsSL https://unsloth.ai/install.sh | \\"
    warn "      UNSLOTH_SKIP_AUTOSTART=1 sh'"
    warn "Several GB, and it builds a second torch stack of its own. See unsloth.md."
    warn "falling back to Jupyter Lab on :8889"
}

exec_jupyter() {
    exec jupyter lab --ip 0.0.0.0 --port 8889 --no-browser --allow-root \
        --ServerApp.root_dir=/workspace
}

case "${UNSLOTH_UI:-jupyter}" in
    studio)
        if studio_ready; then
            log "starting Unsloth Studio on :8888"
            exec unsloth studio -H 0.0.0.0 -p 8888
        fi
        studio_missing_note
        exec_jupyter
        ;;
    jupyter)
        log "starting Jupyter Lab on :8889"
        exec_jupyter
        ;;
    both)
        if studio_ready; then
            log "starting Jupyter Lab on :8889 (background) and Unsloth Studio on :8888"
            jupyter lab --ip 0.0.0.0 --port 8889 --no-browser --allow-root \
                --ServerApp.root_dir=/workspace &
            exec unsloth studio -H 0.0.0.0 -p 8888
        fi
        studio_missing_note
        exec_jupyter
        ;;
    *)
        warn "UNSLOTH_UI must be studio|jupyter|both, got '${UNSLOTH_UI:-}'"
        exit 1
        ;;
esac
STARTEOF
chmod 0755 /usr/share/kinoite/unsloth/unsloth-start.sh

# Fail the build loudly on a shell typo rather than shipping a launcher bash rejects.
bash -n /usr/share/kinoite/unsloth/unsloth-start.sh

### 3. Host-side HuggingFace store
# packages.sh installs python3-huggingface-hub, which ships /usr/bin/hf. This points it at the
# SAME store all three containers mount, which buys two things at once:
#   - `hf download` lands where lemonade, vLLM and unsloth already look, so a model is pulled
#     once for the whole box.
#   - `hf auth login` writes its token to $HF_HOME/token, which is inside that store — so
#     every container gets the credential with no per-container secret plumbing at all.
#
# ACCEPTED TRADEOFF: the token is then readable by anything that mounts the shared store,
# which today is all three LLM stacks. On a single-user box that is the point; if it ever
# stops being one, move the token back to ~/.cache/huggingface and pass HF_TOKEN explicitly
# to the one container that needs it.
#
# uid-guarded so root's $HOME (/var/roothome) never grows a second, half-populated store.
cat > /etc/profile.d/kinoite-hf.sh << 'PROFILEEOF'
# Point host-side HuggingFace tools at the shared model store the LLM containers mount.
# See /usr/share/kinoite/unsloth.md. Only set for regular login accounts, and never overrides
# an HF_HOME the user has already chosen.
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

cat > /etc/containers/systemd/users/unsloth.container << 'QUADLETEOF'
[Unit]
Description=Unsloth fine-tuning (gfx1201 / dual R9700)
Documentation=https://unsloth.ai/docs/basics/amd
Documentation=file:///usr/share/kinoite/unsloth.md

# Bounds a rebuild loop. ExecStartPre builds the image, and a build that fails for a durable
# reason (index down, a wheel pulled) would otherwise retry every RestartSec forever.
StartLimitIntervalSec=1h
StartLimitBurst=3

[Container]
Image=localhost/kinoite-unsloth:latest
ContainerName=unsloth

# Directory: podman adds every node under it, iGPU included — the launcher excludes it via
# HIP_VISIBLE_DEVICES. See notes/.
AddDevice=/dev/kfd
AddDevice=/dev/dri

# NO --ipc=host and NO --group-add, unlike vllm.container. lemonade.sh measured both
# unnecessary here: /dev/kfd and the render nodes are mode 0666 straight from systemd-udev's
# base rules, so no group membership is involved, and --ipc=host additionally makes podman drop
# SELinux label separation for the whole container. The only thing --ipc=host was buying a
# single-process trainer is shared memory for dataloader workers, so raise that directly and
# keep the container confined.
#
# CONSEQUENCE, stated plainly: multi-GPU (RCCL) training is UNTESTED under this posture.
# Single-card LoRA is the assumption. If a distributed run needs host IPC, add it in a shadowed
# unit and accept that it turns the label separation off.
PodmanArgs=--shm-size=16g

# Unauthenticated-by-default web UIs — the 127.0.0.1 prefix is what keeps them off the tailnet,
# the same posture as lemonade's 13305 and vLLM's 8000/3000.
PublishPort=127.0.0.1:8888:8888
PublishPort=127.0.0.1:8889:8889

# THE SHARED MODEL STORE — the same HuggingFace hub cache lemonade and vLLM mount. A base
# model pulled by any of them is reused by all, an adapter exported here is immediately
# visible to lemonade, and the host's `hf auth login` token is already inside it.
# :z (shared label), not :Z — :Z would relabel the whole store on every start, since Quadlet
# builds a new container each time.
Volume=%h/.local/share/models/huggingface:/root/.cache/huggingface:z
Environment=HF_HOME=/root/.cache/huggingface

# Notebooks, datasets, adapters. Yours to inspect, prune and back up.
Volume=%h/.local/share/unsloth/workspace:/workspace:z

# Copied-in launcher (see the /usr read-only note in the build script).
Volume=%h/.local/share/unsloth/bin:/opt/kinoite:z

# REQUIRED, not a nicety: studio.py keeps an sqlite database and its config under
# UNSLOTH_STUDIO_HOME, and Quadlet builds a NEW container on every start. Unmounted, every
# restart would silently discard your runs, datasets and settings.
Volume=%h/.local/share/unsloth/studio:/opt/unsloth-studio:z
Environment=UNSLOTH_STUDIO_HOME=/opt/unsloth-studio

# Read by unsloth.ai/install.sh and by install_llama_prebuilt.py, both of which run only if you
# opt into Studio — and both of which would otherwise guess wrong IN HERE. Their GPU probes are
# rocminfo, then amd-smi, then lspci, then /proc/cpuinfo for Strix APU model names: this image
# has no ROCm tools (the wheels bundle the runtime without them) and this box is neither Strix
# nor named in cpuinfo, so every probe comes up empty and the installer takes its documented
# CPU-only branch — a Studio that trains on the CPU and never says why. Set here rather than in
# the install command so `podman exec` inherits it and a re-run cannot forget it.
#
# gfx1201 is the R9700; the installer maps it to repo.amd.com/rocm/whl/gfx120X-all. The iGPU is
# not a concern for once: this names the arch outright, so nothing walks a device list.
Environment=UNSLOTH_ROCM_GFX_ARCH=gfx1201

# Persistent triton/inductor kernel caches, so the first training step's compile is paid once
# rather than on every container start. Version-hashed, so a rebuild misses and recompiles
# cleanly; rm the dir to force that by hand.
Volume=%h/.local/share/unsloth/cache:/opt/unsloth-cache:z
Environment=TRITON_CACHE_DIR=/opt/unsloth-cache/triton
Environment=TORCHINDUCTOR_CACHE_DIR=/opt/unsloth-cache/inductor

# studio | jupyter | both. jupyter is the default because Studio needs a separate installer
# pass that this image deliberately does not run; switch to `both` once you've done it. The
# launcher falls back to Jupyter rather than failing if you ask for a Studio that isn't there.
Environment=UNSLOTH_UI=jupyter

Exec=/opt/kinoite/unsloth-start.sh

[Service]
# on-failure, not always: unlike vLLM (whose engine death exits CLEANLY and so needs `always`
# to recover), there is no equivalent silent-success failure mode here, and a training box
# should not resurrect itself in a loop while you are reading the traceback that killed it.
Restart=on-failure
RestartSec=10

# First start BUILDS the image — a multi-GB torch+ROCm pip install — before anything runs.
TimeoutStartSec=5400

# Build only when the image is missing, so routine restarts don't rebuild. Same shape and same
# reasoning as vllm.container's guarded pre-pull: the implicit path inside `podman run` is
# hard-capped at 5 minutes under systemd, which no build of this size will meet. Updating is
# then a deliberate `podman build --no-cache` (see unsloth.md), never a surprise on restart.
ExecStartPre=/bin/sh -c 'podman image exists localhost/kinoite-unsloth:latest || podman build -t localhost/kinoite-unsloth:latest -f /usr/share/kinoite/unsloth/Containerfile /usr/share/kinoite/unsloth'

# Podman doesn't create missing bind-mount sources.
ExecStartPre=/usr/bin/mkdir -p %h/.local/share/models/huggingface %h/.local/share/unsloth/workspace %h/.local/share/unsloth/bin %h/.local/share/unsloth/cache %h/.local/share/unsloth/studio
ExecStartPre=/usr/bin/install -m 0755 /usr/share/kinoite/unsloth/unsloth-start.sh %h/.local/share/unsloth/bin/unsloth-start.sh

# No [Install] — hand-started on purpose.
QUADLETEOF

### 5. On-box notes
# The box won't have this repo checked out when something breaks.
cat > /usr/share/kinoite/unsloth.md << 'MDEOF'
# kinoite-north: Unsloth fine-tuning (rootless Quadlet)

The third local-LLM stack, and the only one that TRAINS. lemonade (lemonade.md) and vLLM
(vllm.md) serve models; this one makes them. All three share one HuggingFace store, so a base
model pulled here is already there for inference, and an adapter exported to GGUF here is
immediately loadable by lemonade.

Ships at /etc/containers/systemd/users/unsloth.container, NOT enabled.

    systemctl --user stop north-llm-pod lemonade   # free the GPUs FIRST — see below
    systemctl --user daemon-reload                 # only after an image update
    systemctl --user start unsloth
    journalctl --user -u unsloth -f                # first-run credentials appear here

    Unsloth Studio   http://127.0.0.1:8888    no-code training UI
    Jupyter Lab      http://127.0.0.1:8889    notebooks, rooted at the workspace

Loopback only, both of them. `systemctl --user enable unsloth` is expected to FAIL:
generator-produced units have no [Install] to act on. That's the guardrail, not a bug.

## The first start builds the image (this is not a hang)

There is no Unsloth image for gfx1201 anywhere — the official `unsloth/unsloth` is CUDA-only,
and the community ROCm rebuilds publish only gfx942 and gfx1100. So the first start runs
`podman build` against the baked recipe at /usr/share/kinoite/unsloth/Containerfile: a
multi-GB torch+ROCm+unsloth pip install. Expect a long silent stretch; the unit allows 90
minutes. Watch it with `journalctl --user -u unsloth -f`.

It builds ONLY when the image is missing, so restarts are fast. To update deliberately:

    podman build --no-cache -t localhost/kinoite-unsloth:latest \
        -f /usr/share/kinoite/unsloth/Containerfile /usr/share/kinoite/unsloth
    systemctl --user restart unsloth

The image is built here rather than in CI, so the only record of what it contains is inside it:

    podman exec unsloth cat /opt/kinoite-versions.txt

## Only one stack can hold the GPUs

vLLM alone idles at ~24 GiB per card at the shipped 0.80 utilisation, and a fine-tune needs
room for weights, gradients and optimiser state on top of that. Stop the others first:

    systemctl --user stop north-llm-pod lemonade

The launcher warns at start if a card is already holding more than 4 GiB, because the failure
without that warning is a torch OOM several minutes into a run — which reads like a
batch-size problem and is not.

## Suspend / resume

Handled by `kinoite-llm-sleep.service`, the same hook that covers lemonade and vLLM. It is not
optional politeness: amdgpu evicts VRAM into system RAM to suspend, this box has 64 GB of RAM
against 64 GB of VRAM, and suspending with the GPUs loaded HANGS THE MACHINE hard enough to
need the power button, with nothing in the kernel log.

The important caveat here, which does not apply to the inference stacks: resume restores the
SERVER, not your training run. That process died with the container. For a long fine-tune,
keep the box awake instead:

    systemd-inhibit --what=sleep --why='fine-tune' sleep infinity

...or checkpoint often enough that losing the tail doesn't matter.

## Storage

    ~/.local/share/models/huggingface     models + auth token (SHARED with lemonade and vLLM)
    ~/.local/share/unsloth/workspace      notebooks, datasets, adapters  (Jupyter's root)
    ~/.local/share/unsloth/studio         Studio's sqlite db + config    (UNSLOTH_STUDIO_HOME)
    ~/.local/share/unsloth/cache          triton / inductor kernel caches
    ~/.local/share/unsloth/bin            the launcher, copied from /usr at each start

The studio/ mount is REQUIRED, not decorative: Quadlet builds a new container on every start,
so without it every restart would silently discard your runs and settings.

## Hugging Face CLI

`hf` is installed on the HOST (python3-huggingface-hub). /etc/profile.d/kinoite-hf.sh points
HF_HOME at the shared store, so:

    echo "$HF_HOME"          # ~/.local/share/models/huggingface
    hf auth login            # token -> $HF_HOME/token, mode 0600
    hf download Qwen/Qwen3.5-4B-Instruct

Because the token lives INSIDE the shared store, and all three containers mount that store,
every stack gets the credential with no per-container secret plumbing. The tradeoff is the
other side of that coin: anything mounting the store can read the token. On a single-user box
that is the deal; if it stops being one, move the token back to ~/.cache/huggingface and pass
HF_TOKEN explicitly to the container that needs it.

If downloads misbehave with xet-related errors, `export HF_HUB_DISABLE_XET=1` — the documented
workaround, not baked because it has not been needed here.

## Which UI

`Environment=UNSLOTH_UI=jupyter` in the unit. Jupyter is the code-first half, and the only UI
this image can serve out of the box: notebooks for the work Studio doesn't cover, above all
inventing a labelling rubric and generating a bespoke dataset.

STUDIO NEEDS AN EXTRA INSTALL PASS, which is why it is not the default. `pip install
unsloth[studio]` gets the server stack but not a runnable Studio: the frontend is not shipped
as package data, and the CLI gates on an installer-managed venv under $UNSLOTH_STUDIO_HOME.
Only unsloth.ai/install.sh builds that venv, and EVERY `unsloth studio` subcommand is behind
the same gate — `update` included, so the CLI cannot install itself:

    python  venv not found at /opt/unsloth-studio/unsloth_studio
            Run install.sh first to create the environment:
            curl -fsSL https://unsloth.ai/install.sh | sh

Do exactly that, inside the container. Once, on the persistent studio volume:

    systemctl --user start unsloth        # it must be up to exec into
    podman exec -it unsloth sh -c \
        'curl -fsSL https://unsloth.ai/install.sh | UNSLOTH_SKIP_AUTOSTART=1 sh'

A piped install takes its options as environment variables (a bare `--flag` after the pipe
would be read by sh itself), which is why they sit before `sh` rather than after the script.
UNSLOTH_SKIP_AUTOSTART stops it trying to launch a browser and a desktop entry on a headless
box. The other two variables it needs, UNSLOTH_STUDIO_HOME and UNSLOTH_ROCM_GFX_ARCH, are
already in the unit and `podman exec` inherits them — see the quadlet for why the arch matters.

Know what that pulls in: a bundled Node, a Vite frontend build, a prebuilt llama.cpp, and its
OWN torch — several GB, all of it under $UNSLOTH_STUDIO_HOME. It installs whatever apt packages
it still needs as root, into the container layer, so those evaporate on the next restart; only
what lands in the volume persists, which is everything that matters. Nothing here touches the
image's site-packages, so the gfx1201 wheels the image was built on are not at risk.

The flip side, and the reason to keep Jupyter as the supported path: STUDIO TRAINS ON ITS OWN
STACK, not the one this image pins. Told UNSLOTH_ROCM_GFX_ARCH=gfx1201 it routes torch to
repo.amd.com/rocm/whl/gfx120X-all and takes torch 2.11.x, where the image runs 2.12.0+rocm7.14
from whl-multi-arch. Both are AMD's own gfx1201 wheels and neither can disturb the other, but a
result reproduced in Studio was not produced by the stack `pip freeze` in the image describes.
Treat a working Studio on this box as unproven.

Once installed, set UNSLOTH_UI to `studio` or `both` in a shadowed unit. Until then the
launcher warns and falls back to Jupyter rather than failing the unit. Studio is the exec'd
process in `both`, so it owns the unit's lifetime — if Jupyter dies the container stays up, and
a restart brings it back.

    mkdir -p ~/.config/containers/systemd/users
    cp /etc/containers/systemd/users/unsloth.container ~/.config/containers/systemd/users/
    # edit: Environment=UNSLOTH_UI=studio    (under [Container], NOT [Service])
    systemctl --user daemon-reload && systemctl --user restart unsloth

[Container], not [Service], is load-bearing — a [Service] Environment= sets the variable on
the podman process on the host, and podman forwards only what the .container declares, so the
knob silently does nothing. That trap is already recorded in vllm.md.

Note a shadowed unit is a full copy and will NOT pick up changes from a later image build.

## GPU selection

The launcher sets HIP_VISIBLE_DEVICES to the gfx1201 cards only, derived at every start from
`torch.cuda.get_device_properties(i).gcnArchName`. This box has THREE HIP-visible GPUs — two
R9700s and the gfx1036 iGPU — and training on the iGPU is not slow, it is broken.

Never bake an index: DRM numbering reshuffles across kernels and boots (observed twice), and
only the PCI address is stable. Check what it picked in the journal:

    journalctl --user -u unsloth | grep HIP_VISIBLE_DEVICES

Expect `HIP_VISIBLE_DEVICES=0,1 (gfx1201 only)` — two indices. The "no gfx1201 device found"
warning instead means the filter failed, and torch will enumerate the iGPU too.

DO NOT check this with a bare `podman exec ... torch.cuda.device_count()`. The launcher exports
HIP_VISIBLE_DEVICES into its own process, which becomes the server; `podman exec` starts a
fresh process that inherits only what the unit declares, so it always reports 3 devices
including the gfx1036 and looks like a failure that isn't. Pass it explicitly to check from
inside:

    podman exec -e HIP_VISIBLE_DEVICES=0,1 unsloth python -c \
      "import torch; print(torch.cuda.device_count()); \
       print([torch.cuda.get_device_properties(i).gcnArchName for i in range(torch.cuda.device_count())])"

HIP_VISIBLE_DEVICES specifically — NOT ROCR_VISIBLE_DEVICES or CUDA_VISIBLE_DEVICES, which
conflict with HIP and hang distributed init (recorded in vllm.md). Preset it in a shadowed
unit to pin devices by hand; the launcher then skips detection.

## Multi-GPU is untested

This container runs WITHOUT --ipc=host and WITHOUT --group-add, unlike vllm.container.
lemonade.sh measured both unnecessary (the devices are 0666 from udev's base rules), and
--ipc=host additionally makes podman drop SELinux label separation for the whole container.
--shm-size=16g covers what a dataloader actually needs.

So: single-card LoRA is the assumption. A distributed RCCL run may need host IPC — add it in a
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

1. Train a LoRA in Studio or a notebook.
2. Merge and export to GGUF into the shared store (unsloth's `save_pretrained_gguf`).
3. Add a `user.` recipe pointing at the local file, per "Recipes" in lemonade.md, and run it
   with `podman exec lemonade lemonade run user.<name>`.

Because the store is shared, step 2 lands the file exactly where lemonade already looks — no
copy step.

## First project: bash command risk scoring

Base model in the 4B class (e.g. Qwen3.5-4B-Instruct) is the right size to start: it fits one
card comfortably, trains in minutes rather than hours, and the task is classification-shaped
rather than generation-shaped.

The hard part is not the training, it is the dataset — a `command -> risk` rubric that is
consistent enough to learn. Build that in Jupyter on :8889, then point Studio at it.
MDEOF

### 6. Gate the generated unit
# Quadlet units are not systemd units until the generator runs, so `systemd-analyze verify`
# can't check one directly. Grep for the misplaced-key class instead — the same failure shape
# services-north.sh guards kinoite-llm-sleep.service against, and one that systemd accepts
# silently. Environment= under [Service] would be the live trap here: it would set the variable
# on podman rather than in the container, and the knob would quietly do nothing.
awk '/^\[Service\]/{s=1} s && /^Environment=/{print FILENAME": Environment= under [Service] — belongs in [Container]"; bad=1} END{exit bad?1:0}' \
    /etc/containers/systemd/users/unsloth.container \
    || { echo "unsloth.sh: bad key placement in unsloth.container (see above)" >&2; exit 1; }
