# kinoite-north: LLaMA-Factory fine-tuning (rootless Quadlet)

> Paths beginning `docs/` are in the source repo, not on this machine. The
> runbooks beside this one (`vllm.md`, `lemonade.md`, `llamafactory.md`) are
> here in `/usr/share/kinoite/`.

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
