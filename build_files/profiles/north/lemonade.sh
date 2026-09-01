#!/bin/bash
set -ouex pipefail

# Lemonade Server (local LLM) as a rootless Quadlet. No host ROCm — lemonade's
# llama.cpp builds bundle their own ROCm 7 runtime.
#
# Deliberately NOT enabled: no [Install], nothing in services-north.sh. Started by
# hand with `systemctl --user start lemonade`. Runbook and gotchas are in
# /usr/share/kinoite/lemonade.md (source: docs/how-to/lemonade.md).
#
# crun is still required: podman needs an OCI runtime and crun is what this image ships.
for bin in podman crun; do
    command -v "$bin" >/dev/null || { echo "lemonade.sh: missing $bin" >&2; exit 1; }
done

### 1. Seeded lemonade defaults
# nightly channel is CORRECTNESS, NOT PREFERENCE — do not "simplify" it to stable or preview.
# Cited, so the next person does not have to take it on trust: lemonade-sdk/lemonade#1787
# ("v10.3.0: ROCm preview/stable channels silently fall back to CPU on gfx1201 (RDNA4) — 7x
# performance regression vs v10.2.0", open since 2026-05-03). Neither `preview` (ROCm 7.12 /
# TheRock) nor `stable` (ROCm 7.2) contains HIP support for gfx1201; `llama-server --list-devices`
# prints an empty device list and the server then runs on CPU with NO error and NO warning —
# ~70 tok/s becomes ~10. Only `nightly` ships the per-arch builds
# (llama-bXXXX-ubuntu-rocm-gfx120X-x64.zip) that detect the R9700 at all. A silent 7x is the
# worst possible failure mode, which is why this is a pin and not a default.
# ctx_size because lemonade auto-tunes to 157140
# on a 27B — raise per-model if you have headroom. No rocm_args: `--load-mode mmap` was pinned
# throughout the SELinux bisect and carried forward untested. Isolated afterwards by loading a
# model without it under full confinement — ROCm loads fine, so it is gone. (lemonade passes its
# own `--no-mmap` to llama-server regardless, which is probably why it never mattered.)
mkdir -p /usr/share/kinoite
cat > /usr/share/kinoite/lemonade-defaults.json << 'EOF'
{
  "ctx_size": 131072,
  "rocm_channel": "nightly",
  "llamacpp": {
    "backend": "rocm"
  }
}
EOF

### 1b. Curated custom-model recipes (always-present superset)
# Baked to /usr/share/kinoite/lemonade-recipes and merged into the user's lemonade config
# on every start, per key (see kinoite-lemonade-seed and the ExecStartPre in the Quadlet).
# Names become user.<name> at runtime — run one with `lemonade run user.<name>`.
#
# This is a coding/testing box: a Q6 quality floor with big context. `Qwen3.8-27B-Fast` is the
# one deliberate exception — the same model at IQ4_XS, kept ALONGSIDE the Q6_K entry rather than
# replacing it, so the quality floor stays the default and speed is an explicit choice. It has
# been benchmarked but NOT quality-tested. Why Q6 rather than Q8 costs nothing here:
# docs/explanation/quant-selection.md.
#
# Sizing for these ctx values is in the recipe_options block below — the measured
# MiB/token/card figure, not a per-architecture estimate. Do not size against a dense-model KV
# rule of thumb: Qwen3.8-27B is hybrid qwen3_5, 48 of 64 layers linear-attention with
# constant-size state, and a dense estimate is off by roughly 4x.
#
# checkpoint pins the exact GGUF filename (all single-file here — no split parts). The two 27B
# dense models and the 35B MoE are vision-capable (mmproj-F16.gguf); the coder is text-only.
#
# PIN FILENAMES AGAINST THE API, NOT AGAINST THE PATTERN. The main file here is
# `Qwen3.8-27B-UD-Q6_K.gguf` — the UD- prefix is load-bearing and there is no plain
# `Qwen3.8-27B-Q6_K.gguf` in that repo, so a plausible-looking name fails on first pull:
#
#     curl -s https://huggingface.co/api/models/<repo> | python3 -c 'import json,sys;
#     [print(f["rfilename"]) for f in json.load(sys.stdin)["siblings"]]'
#
# EVERY model here that has an MTP head available uses it, and unsloth ships MTP in two
# packagings that need DIFFERENT recipe shapes:
#
#   1. SEPARATE draft file, same repo — Qwen3.8-27B, at
#      unsloth/Qwen3.8-27B-GGUF:MTP/mtp-Qwen3.8-27B-Q4_0.gguf (1.37 GB).
#      Needs the `checkpoints` OBJECT form with a `draft` key. In that form mmproj moves
#      INSIDE the object and every value is fully qualified `repo:file` — the bare-filename
#      mmproj only works alongside the scalar `checkpoint` key.
#
#   2. EMBEDDED in the main GGUF, in a sibling repo — Qwen3.6-27B and Qwen3.6-35B-A3B, via
#      unsloth/<model>-MTP-GGUF. There is no mtp-*.gguf in those repos; the head is inside the
#      weights, which is why the same quant is slightly larger there. Stays the scalar
#      `checkpoint` form — repoint the repo. Q6_K filenames are identical in both, so this is a
#      pure repo swap, not a requant.
#
# In both forms lemonade adds `--spec-type draft-mtp --spec-draft-n-max 3` itself; form 2 passes
# no `-md`, because llama.cpp reads the head out of the main file. Nothing here passes them
# manually. Verified on-box by grepping the launched llama-server command line for each form.
#
# Qwen3-Coder-30B is the one model with no MTP option — neither
# unsloth/Qwen3-Coder-30B-A3B-Instruct-MTP-GGUF nor -Coder-30B-MTP-GGUF exists (both 404 via a
# 401 from the HF API), and the base repo has no mtp file. Recheck on a model bump.
#
# What MTP is worth here: docs/runs/2026-08-20-mtp-speculation.md.

command -v python3 >/dev/null || { echo "lemonade.sh: missing python3 (JSON validation)" >&2; exit 1; }

mkdir -p /usr/share/kinoite/lemonade-recipes
cat > /usr/share/kinoite/lemonade-recipes/user_models.json << 'EOF'
{
  "Qwen3.8-27B": {
    "source": "huggingface",
    "checkpoints": {
      "main": "unsloth/Qwen3.8-27B-GGUF:Qwen3.8-27B-UD-Q6_K.gguf",
      "draft": "unsloth/Qwen3.8-27B-GGUF:MTP/mtp-Qwen3.8-27B-Q4_0.gguf",
      "mmproj": "unsloth/Qwen3.8-27B-GGUF:mmproj-F16.gguf"
    },
    "recipe": "llamacpp",
    "size": 23.4,
    "labels": ["custom", "vision", "reasoning", "coding", "mtp"]
  },
  "Qwen3.8-27B-Fast": {
    "source": "huggingface",
    "checkpoints": {
      "main": "unsloth/Qwen3.8-27B-GGUF:Qwen3.8-27B-UD-IQ4_XS.gguf",
      "draft": "unsloth/Qwen3.8-27B-GGUF:MTP/mtp-Qwen3.8-27B-Q4_0.gguf",
      "mmproj": "unsloth/Qwen3.8-27B-GGUF:mmproj-F16.gguf"
    },
    "recipe": "llamacpp",
    "size": 15.6,
    "labels": ["custom", "vision", "reasoning", "coding", "mtp", "fast"]
  },
  "Qwen3.8-27B-Q6XL": {
    "source": "huggingface",
    "checkpoints": {
      "main": "unsloth/Qwen3.8-27B-GGUF:Qwen3.8-27B-UD-Q6_K_XL.gguf",
      "draft": "unsloth/Qwen3.8-27B-GGUF:MTP/mtp-Qwen3.8-27B-Q4_0.gguf",
      "mmproj": "unsloth/Qwen3.8-27B-GGUF:mmproj-F16.gguf"
    },
    "recipe": "llamacpp",
    "size": 25.3,
    "labels": ["custom", "vision", "reasoning", "coding", "mtp"]
  },
  "Qwen3.8-27B-Q8XL": {
    "source": "huggingface",
    "checkpoints": {
      "main": "unsloth/Qwen3.8-27B-GGUF:Qwen3.8-27B-UD-Q8_K_XL.gguf",
      "draft": "unsloth/Qwen3.8-27B-GGUF:MTP/mtp-Qwen3.8-27B-Q4_0.gguf",
      "mmproj": "unsloth/Qwen3.8-27B-GGUF:mmproj-F16.gguf"
    },
    "recipe": "llamacpp",
    "size": 31.5,
    "labels": ["custom", "vision", "reasoning", "coding", "mtp"]
  },
  "Qwen3.6-27B": {
    "source": "huggingface",
    "checkpoint": "unsloth/Qwen3.6-27B-MTP-GGUF:Qwen3.6-27B-Q6_K.gguf",
    "mmproj": "mmproj-F16.gguf",
    "recipe": "llamacpp",
    "size": 22.9,
    "labels": ["custom", "vision", "reasoning", "mtp"]
  },
  "Qwen3.6-35B-A3B": {
    "source": "huggingface",
    "checkpoint": "unsloth/Qwen3.6-35B-A3B-MTP-GGUF:Qwen3.6-35B-A3B-UD-Q6_K.gguf",
    "mmproj": "mmproj-F16.gguf",
    "recipe": "llamacpp",
    "size": 30.0,
    "labels": ["custom", "vision", "reasoning", "mtp"]
  },
  "Qwen3-Coder-30B": {
    "source": "huggingface",
    "checkpoint": "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Qwen3-Coder-30B-A3B-Instruct-Q6_K.gguf",
    "recipe": "llamacpp",
    "size": 25.1,
    "labels": ["custom", "coding"]
  }
}
EOF

# Per-model ctx and llamacpp_args, keyed by the fully-qualified user.<name> id.
# backend inherits rocm from defaults.json.
#
# `-sm tensor -fa on` is baked on the four Qwen3.8-27B recipes and NOT on the other three.
# That split is deliberate, and each half has a reason:
#
#   ON, because tensor split is +44.4% over layer split on this model and composes with the
#   MTP head rather than trading against it, and because layer split LOSES to vLLM below
#   ~6-7K context on the heavy quants — which is what an agentic loop's opening turns look
#   like. Measured: docs/runs/2026-08-30-tensor-split.md, docs/runs/2026-08-30-quant-sweep.md.
#
#   OFF on Qwen3.6-27B, Qwen3.6-35B-A3B and Qwen3-Coder-30B because none has been loaded here.
#   `-sm tensor` has an architecture gate whose failure mode is a HARD LOAD FAILURE, not a slow
#   path, and upstream's exclusion list names MoE families — two of these three are MoE.
#   Load one by hand before baking the flag on it.
#
# Four constraints this configuration depends on. Breaking any of them is a load failure or a
# silent regression, not a slowdown:
#
#   1. `-fa on` is mandatory. Without it: `SPLIT_MODE_TENSOR requires flash_attn to be enabled`.
#
#   2. Device exclusion is NOT expressible here and must stay at the container. Do not "fix"
#      this by adding `-dev ROCm0,ROCm1` — it restricts the MAIN model only, and every MTP
#      recipe also loads a draft model with its own `-devd` list defaulting to all devices.
#      Measured: `-dev` alone still aborts with `invalid kernel file`. The ExecStartPre that
#      writes ROCR_VISIBLE_DEVICES is the other half of this file and they cannot ship apart.
#      lemonade's own `--llamacpp-device` does not help either — it sets LLAMA_ARG_DEVICE,
#      which is `--device`, main model only.
#
#   3. These ctx values are HAND-COMPUTED CONSTANTS, because `--fit` does not run under tensor
#      split. From 0.0444 MiB/token/card plus a 12174 MiB/card fixed term (Q6_K_XL + MTP):
#      131072 -> ~17.9 GB/card, 262144 -> ~23.8 GB/card, both inside a 32 GB card.
#      Re-check on a model or quant bump; nothing will do it for you.
#
#   4. `--chat-template-kwargs` must carry BOTH keys in one JSON object. lemonade merges arg
#      layers per flag, and the `qwen35` architecture default already sets that flag with
#      `preserve_thinking`. A recipe setting it REPLACES the object, so splitting the keys
#      silently loses preserve_thinking.
#
# Passthrough is the only route for any of this: the lemond binary contains no `--split-mode`,
# `-sm`, `-devd`, `--spec-draft-device`, `-ngld` or `--gpu-layers-draft` string at all. Recipe
# `llamacpp_args` is appended LAST and merges per flag, so it can override what lemonade
# generates without wiping the qwen35 sampler block. Note config.json `llamacpp.rocm_args` is a
# second, global route — it is lemonade's own file, seeded from defaults.json on first run only,
# so check what a live box actually carries there before adding anything.
#
# By hand against the bundled binary, where nothing derives visibility for you:
#
#     HIP_VISIBLE_DEVICES=0,1 llama-server -m <gguf> -ngl 99 -c 32768 -sm tensor -fa on \
#         --spec-type draft-mtp -md <mtp.gguf> -ngld 99 --spec-draft-n-max 4

# REASONING EFFORT is pinned to MEDIUM on the four Qwen3.8-27B recipes — the llama.cpp half of
# vllm.sh's VLLM_REASONING_EFFORT pin.
#
# Absence is NOT neutral: Qwen3.8's template resolves `reasoning_effort|default('xhigh')`, so
# omitting the key selects the MAXIMUM level and prepends a think-harder paragraph to every
# request. medium is the one level that renders empty. It adds no budget and no cap.
# Measured: docs/runs/2026-08-31-reasoning-effort-tokens.md.
#
# Not set on the other three, and that is settled rather than untested — templates grepped
# 2026-08-31: the Qwen3.6 pair has enable_thinking/preserve_thinking and no reasoning_effort,
# and Qwen3-Coder-30B has none of the three. Setting it there is inert, not harmful.
#
# To revert: drop the key (absence = xhigh). No quality A/B has been run either way.

cat > /usr/share/kinoite/lemonade-recipes/recipe_options.json << 'EOF'
{
  "user.Qwen3.8-27B":      { "ctx_size": 131072,
                             "llamacpp_args": "-sm tensor -fa on --spec-draft-p-min 0.1 --chat-template-kwargs '{\"preserve_thinking\":true,\"reasoning_effort\":\"medium\"}'" },
  "user.Qwen3.8-27B-Fast": { "ctx_size": 131072,
                             "llamacpp_args": "-sm tensor -fa on --spec-draft-p-min 0.1 --chat-template-kwargs '{\"preserve_thinking\":true,\"reasoning_effort\":\"medium\"}'" },
  "user.Qwen3.8-27B-Q6XL": { "ctx_size": 131072,
                             "llamacpp_args": "-sm tensor -fa on --spec-draft-p-min 0.1 --chat-template-kwargs '{\"preserve_thinking\":true,\"reasoning_effort\":\"medium\"}'" },
  "user.Qwen3.8-27B-Q8XL": { "ctx_size": 131072,
                             "llamacpp_args": "-sm tensor -fa on --spec-draft-p-min 0.1 --chat-template-kwargs '{\"preserve_thinking\":true,\"reasoning_effort\":\"medium\"}'" },
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
    command -v "$bin" >/dev/null || { echo "lemonade.sh: missing $bin" >&2; exit 1; }
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
### Recipe seeding
# Merges the image's seeds into the user's config PER KEY, and is why this is a script rather
# than the obvious `test -f <file> || install <file>`. That form is all-or-nothing per FILE:
# lemonade's Web UI writes user_models.json the first time anyone adds a custom model, and from
# then on every image seed is blocked forever — silently, because the conditional is doing
# exactly what it says. Observed on the box: one user-added model kept all five seeded recipes
# out of the model list indefinitely. Merging per key keeps user entries untouched and still
# delivers seeds the user has never seen.
#
# THE IMAGE OWNS THE KEYS IT SHIPS. Every key present in the baked seed is reconciled on each
# start, not merely added when absent. Add-only was the first cut and it failed the moment a
# shipped recipe CHANGED rather than appeared: 2570e9b put `-sm tensor -fa on
# --spec-draft-p-min 0.1` on all four Qwen3.8 recipes, and only the two brand-new keys got it —
# `user.Qwen3.8-27B` and `-Fast` already existed, so they kept `{"ctx_size": 131072}` and the
# measured 24%-and-tensor-split work simply never reached the box, silently. Nothing in the
# journal said so, because the conditional was doing exactly what it said.
#
# What this costs: a hand edit to a SHIPPED recipe (through the Web UI or the file) is reverted
# on the next start. To keep a tweak, fork it under a new name — a key the image does not ship
# is never touched, which is what protects the user's own models. What it buys: recipe fixes
# land on reboot, with no `rm` ritual, and re-seeding is idempotent (the diff is per key, so an
# unchanged file is not rewritten at all).
install -D -m 0755 /dev/stdin /usr/libexec/kinoite-lemonade-seed << 'SEEDEOF'
#!/usr/bin/python3
"""Reconcile baked lemonade recipe seeds into the user's config, per key."""
import json
import os
import sys
import tempfile

PAIRS = (
    ("/usr/share/kinoite/lemonade-recipes/user_models.json", "user_models.json"),
    ("/usr/share/kinoite/lemonade-recipes/recipe_options.json", "recipe_options.json"),
)
dest_dir = os.path.join(os.path.expanduser("~"), ".local/share/lemonade/config")


def load(path):
    try:
        with open(path) as fh:
            obj = json.load(fh)
        return obj if isinstance(obj, dict) else None
    except FileNotFoundError:
        return {}
    except (ValueError, OSError) as exc:
        print(f"kinoite-lemonade-seed: cannot read {path}: {exc}", file=sys.stderr)
        return None


os.makedirs(dest_dir, exist_ok=True)
for src, name in PAIRS:
    seeds = load(src)
    if not seeds:
        continue
    dest = os.path.join(dest_dir, name)
    cur = load(dest)
    # A corrupt or non-dict user file is left strictly alone: overwriting it would be the
    # data loss this whole approach exists to avoid.
    if cur is None:
        print(f"kinoite-lemonade-seed: leaving {name} untouched", file=sys.stderr)
        continue
    added = [k for k in seeds if k not in cur]
    updated = [k for k in seeds if k in cur and cur[k] != seeds[k]]
    if not added and not updated:
        continue
    merged = dict(cur)
    for k in added + updated:
        merged[k] = seeds[k]
    try:
        fd, tmp = tempfile.mkstemp(dir=dest_dir, prefix=f".{name}.")
        with os.fdopen(fd, "w") as fh:
            json.dump(merged, fh, indent=2)
            fh.write("\n")
        os.replace(tmp, dest)      # atomic; lemonade reads this file on every start
        os.chmod(dest, 0o644)
        note = [f"added {', '.join(added)}"] if added else []
        note += [f"updated {', '.join(updated)}"] if updated else []
        print(f"kinoite-lemonade-seed: {name}: {'; '.join(note)}")
    except OSError as exc:
        print(f"kinoite-lemonade-seed: cannot write {name}: {exc}", file=sys.stderr)
SEEDEOF
python3 -c 'import ast,sys; ast.parse(open("/usr/libexec/kinoite-lemonade-seed").read())'

### Device visibility for the lemonade container
# WHY THIS EXISTS: the gfx120X-only llamacpp-rocm bundle has no kernels for the gfx1036 iGPU,
# and podman's `AddDevice=/dev/dri` hands the container every render node including it. Layer
# split survived that by accident — it assigned no layers to a device it could see — but
# anything that uses EVERY visible device dies on the first decode with
# `ROCm error: invalid kernel file`. That is `-sm tensor`, which the seeds now carry.
#
# WHY VISIBILITY AND NOT A FLAG. `-dev` restricts only the MAIN model, and every MTP recipe also
# loads a draft model with its own `-devd` list that lemonade cannot emit (the string is not in
# the lemond binary). A visibility variable is one setting, process-wide, covering every model
# llama-server opens now or later. See docs/reference/gpu-topology.md.
#
# WHY ROCR_VISIBLE_DEVICES AND NOT HIP_VISIBLE_DEVICES. Both work. ROCR indexes the KFD
# GPU-agent list in topology-node order — exactly the order the loop below walks. HIP orders by
# PCI BDF, which agrees here only because the nodes happen to be in ascending bus order; that is
# a coincidence this file would then depend on.
#
# WHY A DERIVED FAMILY AND NOT A LITERAL `0,1`. DRM numbering reshuffles across kernels and
# boots. The rule is "keep every GPU agent of the same gfx target as the most capable one",
# which needs no index and no model name, and generalises correctly: a mismatched pair is not a
# tensor-split candidate anyway.
#
# WHY NOT MATCH THE BUNDLE'S KERNEL LIST INSTEAD. It would have to be a *set* — the bundle
# covers gfx1200, gfx1201 and gfx1250, and gfx1250 is 125000 rather than 1200xx, so a "1200xx"
# filter would silently exclude a supported card. The bundle also lives under
# ~/.local/share/lemonade, is downloaded at runtime, and so is not readable at first start.
# simd_count is in /sys and is always there.
#
# FAILS OPEN, DELIBERATELY, AND THE ORDERING IS THE MECHANISM. The file is TRUNCATED FIRST and
# only then filled in, so every path that goes wrong leaves an EMPTY env file rather than a
# stale or absent one. Empty means podman constrains nothing and lemonade starts on layer split.
# Absent is fatal: `EnvironmentFile=` becomes `--env-file`, and podman treats a missing env file
# as an error, so a derivation bug would become a container that will not start.
install -D -m 0755 /dev/stdin /usr/libexec/kinoite-lemonade-gpus << 'GPUEOF'
#!/bin/bash
# Write ROCR_VISIBLE_DEVICES for lemonade.container, derived from KFD topology.
# Pure /sys: no ROCm, no python, no container. Runs as an ExecStartPre on the host,
# because the value has to be in the container's environment before it is created.
#
# Fail open: an empty output file means "constrain nothing", which is the pre-2026-08-30
# behaviour. Never exits nonzero — a derivation problem must not block the server.
set -u

out="${1:?usage: kinoite-lemonade-gpus <output-env-file>}"
nodes=/sys/class/kfd/kfd/topology/nodes

mkdir -p "${out%/*}" 2>/dev/null || true
: > "$out" 2>/dev/null || {
    echo "kinoite-lemonade-gpus: cannot write $out; starting unconstrained" >&2
    exit 0
}
# From here on the file exists and is empty, so every early exit below is a fall back
# to unconstrained rather than a failed container start. No atomic replace is needed:
# podman reads this only in ExecStart, strictly after this helper has exited.

# ROCR_VISIBLE_DEVICES numbers GPU agents only, in KFD node order. Walk the nodes
# numerically and skip CPU agents (simd_count 0, node 0 here) — the count of GPU
# agents emitted so far IS the index, so no index is ever written down.
agents=$(
    for n in $(ls -1 "$nodes" 2>/dev/null | grep -xE '[0-9]+' | sort -n); do
        p="$nodes/$n/properties"
        [ -r "$p" ] || continue
        read -r simd gfx <<< "$(awk '
            $1 == "simd_count"          { s = $2 }
            $1 == "gfx_target_version"  { g = $2 }
            END                         { print s+0, g+0 }' "$p")"
        [ "$simd" -gt 0 ] 2>/dev/null || continue
        [ "$gfx"  -gt 0 ] 2>/dev/null || continue
        printf '%s %s\n' "$gfx" "$simd"
    done
)
[ -n "$agents" ] || {
    echo "kinoite-lemonade-gpus: no GPU agent found under $nodes; starting unconstrained" >&2
    exit 0
}

# The most capable agent's gfx target is the family to keep; NR-1 is its GPU-agent index.
target=$(printf '%s\n' "$agents" | sort -k2,2nr -k1,1nr | awk 'NR == 1 { print $1 }')
csv=$(printf '%s\n' "$agents" | awk -v t="$target" '$1 == t { printf "%s%d", (n++ ? "," : ""), NR - 1 }')
[ -n "$csv" ] || exit 0

printf 'ROCR_VISIBLE_DEVICES=%s\n' "$csv" > "$out"
total=$(printf '%s\n' "$agents" | wc -l)
echo "kinoite-lemonade-gpus: gfx_target_version $target -> ROCR_VISIBLE_DEVICES=$csv (of $total GPU agents)"
GPUEOF
bash -n /usr/libexec/kinoite-lemonade-gpus

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

# No GroupAdd=keep-groups. It was a headless fallback for render/video membership, and it is
# measured unnecessary: /dev/kfd and the render nodes are mode 0666 from systemd-udev's base
# rules, so no group membership is involved. Removing it also sidesteps the known rootless
# flakiness (containers/podman#27876, #28364). Verified by loading a model with it absent.

# Directory: podman adds every node under it, iGPU included. See docs/reference/gpu-topology.md.
AddDevice=/dev/kfd
AddDevice=/dev/dri

# Unauthenticated API — the 127.0.0.1 prefix is what keeps it off the tailnet.
PublishPort=127.0.0.1:13305:13305

# %h is expanded by systemd, not Quadlet. :z not :Z — :Z would relabel the whole
# model cache on every start, since Quadlet builds a new container each time.
# The huggingface cache is the SHARED model store (see vllm.sh) — same HF hub layout,
# so lemonade and vLLM download once and reuse. llama/ and config/ stay lemonade-specific.
Volume=%h/.local/share/models/huggingface:/opt/lemonade/.cache/huggingface:z
Volume=%h/.local/share/lemonade/llama:/opt/lemonade/llama:z
Volume=%h/.local/share/lemonade/config:/opt/lemonade/.cache/lemonade:z

# Mounting this from /usr/share directly fails: container_t can't read usr_t, and
# :z can't fix it because /usr is read-only. Hence the ExecStartPre copy below.
Environment=LEMONADE_DEFAULTS_PATH=/opt/lemonade/.cache/lemonade/defaults.json

# Which GPU agents llama.cpp may use, computed per start by the ExecStartPre below.
# Keep the `%t` BARE. podman-systemd.unit(5) says to write `./%t` for a path starting with a
# specifier, and that advice is for paths meant to resolve against the unit directory — it is
# wrong here and silently so: `quadlet -dryrun` expands `./%t/...` to
# `/etc/containers/systemd/users/%t/...`, a literal `%t` directory that will never exist, and
# podman treats a missing --env-file as fatal. Bare `%t` is passed through verbatim for systemd
# to expand at runtime, which is what this needs. Verified both ways with `quadlet -dryrun`.
EnvironmentFile=%t/kinoite-lemonade/gpus.env

[Service]
# First start pulls a multi-GB image against systemd's 90s default.
TimeoutStartSec=900

# Podman doesn't create missing bind-mount sources.
ExecStartPre=/usr/bin/mkdir -p %h/.local/share/models/huggingface %h/.local/share/lemonade/llama %h/.local/share/lemonade/config
ExecStartPre=/usr/bin/install -m 0644 /usr/share/kinoite/lemonade-defaults.json %h/.local/share/lemonade/config/defaults.json

# Recipe seeds, reconciled PER KEY: lemonade reads user_models.json every start and its Web UI
# writes the same file when a user adds a custom model, so the seeder rewrites only the keys
# the image ships and leaves every other key alone. Runs on every start, not just the first —
# that is how a CHANGED recipe reaches the box. See the helper.
ExecStartPre=/usr/libexec/kinoite-lemonade-seed

# Excludes the iGPU by VISIBILITY before the container exists. Fails open — see the helper.
ExecStartPre=/usr/libexec/kinoite-lemonade-gpus %t/kinoite-lemonade/gpus.env

# No [Install] — hand-started on purpose.
EOF

### 4. On-box runbook
# The box won't have this repo checked out when something breaks. Source is docs/how-to/lemonade.md.
install -D -m 0644 /ctx/docs/how-to/lemonade.md /usr/share/kinoite/lemonade.md
