# kinoite — what's where, and what's open

Disposable and assumed stale. When this conflicts with a file in `docs/runs/`,
the run file is right and this one gets fixed.

Two bootc images from one tree: `kinoite` (laptop) and `kinoite-north` (AMD
9900X, dual Radeon AI PRO R9700 / gfx1201, gaming + local LLM).

## Map

    docs/reference/     gpu-topology, gpu-sysfs, sensors
    docs/how-to/        vllm, lemonade, llamafactory, r9v, radiance  <- these SHIP to /usr/share/kinoite
                        benchmark-engines, measure-gpu-idle, stream-with-sunshine,
                        fix-build-key-drift
    docs/explanation/   engine-choice, quant-selection, llama-cpp-tensor-split,
                        vllm-decode-budget, gpu-power-and-fans, sunshine-capture,
                        quadlets-and-selinux, suspend-and-wake
    docs/runs/          append-only measurements, dated
    docs/decisions/     append-only, alternatives rejected

Start at `docs/explanation/engine-choice.md` for the LLM stack, or
`docs/reference/gpu-topology.md` for hardware.

## Current state of the LLM stack

Five stacks, none enabled, all hand-started. They cannot run at once — each
wants most of both cards.

    lemonade    :13305   llama.cpp GGUF, the decode path
    vLLM        :8000    + Open WebUI :3000, the OpenAI surface
    LLaMA-Factory :7860  + Jupyter :8889, the only one that trains
    R9V         :8004    Qwen3.8 Flash Next 177B MoE on patched vLLM, one request at a time
    radiance    :8005    Qwen3.8-27B MXFP4 + DFlash2 on patched vLLM, 8 sequences, 262K context

lemonade ships Q6_K seeds with MTP and `-sm tensor` on the seven Qwen3.8-27B
recipes (four stock Unsloth, three DavidAU `-Turbo` uncensored fine-tune), plus
Meta's Muse Glimmer 30B at UD-Q8_K_XL with a DFlash drafter and `-sm tensor`,
loaded and benchmarked here [runs/2026-09-14-muse-glimmer-q8xl-load.md].
All seven Qwen3.8 recipes sit at ctx 262,144, the checkpoint's native window;
they were at half of it until 2026-09-18. Q8XL is the only one with slots: three,
sharing that pool, because lemonade otherwise passes `--parallel 1` and
serializes every concurrent sub-agent request
[runs/2026-09-18-lemonade-parallel-slots.md]. Three is one per live conversation
in this box's core-agent-plus-two-workers fan-out, which is what a slot is sized
by; it was 4, then briefly 2
[decisions/2026-09-18-three-slots-on-q8xl.md].
vLLM ships FP8, MTP k=4, prefix caching on, strict tool calling off.

GPU tuning is `kinoite-gpu-tune.service`: a 250 W cap per card at boot, with
`VOLTAGE_OFFSET_MV` and `FAN_CURVE` knobs shipped unset because the OverDrive
table does not survive an idle cycle. The cap number is a choice, not a
measurement [decisions/2026-09-15-gpu-power-cap-250w.md]. `lactd` ships
disabled.

## Open

### GPU tuning — `amdgpu.sh`, `tuning.sh`

- [ ] **Decide whether an undervolt is worth maintaining at all.** No longer
      blocked, but wiped on every idle cycle, so keeping one means re-running
      `kinoite-gpu-tune apply` once a loaded model pins the cards awake. If it
      earns its keep, tune per card (start -50 mV, step -25 mV under sustained
      load until unstable, back off one step; two dies may differ) and load-test
      before baking a default.
- [ ] **Fan curve is available but unused.** Wiped on every idle cycle and
      bounded below by the 30% firmware floor, so it can only shape ramp-up on an
      already-awake card. Worth a curve only if the cards sit awake and audible
      under sustained load.
- [x] **Removed `/etc/lact/config.yaml`.** Carried stale `power_cap: 210`
      and `voltage_offset: -70` from earlier hand-tuning. `lactd` is disabled,
      so it was inert, but it was a latent conflict.
- [x] **Three PCH temp channels read 0°C.** PCH_CHIP_CPU_MAX_TEMP, PCH_CHIP_TEMP
      and PCH_CPU_TEMP — the nct6799 driver recognizes the NCT6701D but doesn't
      populate those three. Driver quirk, not a sensor-gap; no asus-ec-sensors
      entry needed (nct6799 handles the Super I/O directly). Documented in
      [reference/sensors.md] along with the other harmless quirks (AUXTIN3 at
      -61°C, AUXTIN4 ALARM).
- [x] `acpi_enforce_resources=lax` never landed and nct6799 works anyway.
      Removed from `motherboard.sh` — the karg and `modules-load.d` force-load
      were dead weight. Rechecked on Fedora 44 kernel: full sensors output with
      neither aid. If a future kernel regresses, both can return.

### lemonade — `lemonade.sh`

- [ ] Narrow `container_use_devices` to a CIL module granting only
      `container_domain → hsa_device_t:chr_file map`.
- [ ] `-sm tensor` is NOT baked on Qwen3.6-27B, Qwen3.6-35B-A3B or
      Qwen3-Coder-30B. None has been loaded here, and the architecture gate's
      failure mode is a hard load failure. Load each once before baking.
- [ ] **Two of the three `-Turbo` recipes have never been loaded.** Added
      2026-09-10. `-sm tensor` and the `medium` reasoning pin are baked on the
      strength of the GGUF headers matching the stock Qwen3.8 seeds exactly —
      architecture `qwen35`, 866 tensors, 65 blocks, embedded `blk.64.nextn.*`
      head. Turbo-Q8 has since been loaded at ctx 262144 and served with both
      flags [runs/2026-09-18-lemonade-parallel-slots.md], which clears the
      architecture gate for that tensor layout; `-Turbo` and `-Turbo-Fast` are
      still untested.
- [ ] **MTP acceptance on the `-Turbo` seeds is unmeasured.** Upstream says to
      fall back to the plain non-MTP builds if acceptance drops below ~50%, and
      ships them; nothing here has checked which side of that line this box is
      on. `bench.py` against `-Turbo` vs `-Turbo-Fast` would settle it.
- [ ] **The other six Qwen3.8 recipes still ship one slot.** Only Q8XL was
      measured and baked [runs/2026-09-18-lemonade-parallel-slots.md]. The same
      two flags apply to any of them, but each costs the VRAM of its own pool and
      none has been loaded with slots here.
- [ ] **Three slots is fitted to the current fan-out, not a swept optimum.**
      One slot per live conversation [decisions/2026-09-18-three-slots-on-q8xl.md];
      a wider fan-out needs a wider setting. Slot counts were never swept against
      each other, and the 262,144 pool was sized to clear this box's p90 prompt
      depth with the VRAM left over, not to a measured knee. The pool still
      cannot hold the observed 565K peak of concurrent demand, and two ~170K
      sessions collide at any slot count.
- [ ] **Muse Glimmer is benchmarked, not evaluated.** Output quality against the
      Qwen3.8 Q8XL daily driver is untested. Only `--spec-draft-n-max 15` was
      run, and decode was measured on raw llama-server at ctx 98304 rather than
      through lemonade at the shipped 131072.
      [runs/2026-09-14-muse-glimmer-q8xl-load.md]

### vLLM — `vllm.sh`

- [ ] **radiance-vllm-mxfp4 quality is measured on arithmetic only.** GSM8K 500q
      paired: 88.80% against the Q8XL daily driver's 88.00%, p = 0.618
      [runs/2026-09-15-radiance-gsm8k-q8xl.md]. That rules out gross damage from
      the 4-bit weights, not a 2–3 point loss. Prose, code and multi-turn tool
      use are still unchecked.
- [ ] **DFlash2 drafter vs KV-cache group padding — documented, not yet
      triggered.** The current MTP head is already optimal; the trap only fires
      if a multi-layer drafter is swapped in. See
      [explanation/vllm-kv-cache-padding.md].
- [x] Cheap side-lead on the ~15 ms:
      [ROCm#6347](https://github.com/ROCm/ROCm/issues/6347). Ruled out — six
      fresh spawns all clustered at 24.50–24.53 tok/s, one band.
      [runs/2026-09-03-rocmsidelead.md].
- [x] ~3% may be sitting in `--no-async-scheduling`. Measured — costs nothing
      at k=4 (the 08-22 figure was the drafter-batch flag, not async scheduling).
      Flag removed from the launcher for cleanliness.
      [runs/2026-09-03-async-scheduling.md].

### Stack consolidation onto llama.cpp — scoped, not started

The decode case is made and the tool-calling gate is cleared, so what is left is
everything that is not decode.

- [ ] **The OpenAI surface**, which is not a one-line move. vLLM is `:8000/v1`,
      model id `Qwen/Qwen3.8-27B-FP8`, and a POD member — Open WebUI reaches it
      pod-locally and `BindsTo=north-llm-pod.service`. lemonade is
      `:13305/api/v1`, model ids `user.<name>`, standalone. Consolidation changes
      every agent config, Open WebUI's connection, and the pod topology. The
      sleep/wake hook already handles both, so that part is free.
- [ ] **Pick a (concurrency, per-stream context) point up front.** llama.cpp
      divides `-c` across `-np N` fixed slots — measured, `-c 196608 -np 4` gives
      `n_ctx_slot = 49152` — while vLLM has no such coupling. See
      `docs/explanation/engine-choice.md`.
- [ ] **Quality is a change nobody has measured.** vLLM runs FP8 (27.8 GB);
      lemonade's fast seed is IQ4_XS (14.0 GB). Decide deliberately.

### Cross-cutting, never measured

- [ ] **Quality A/B between FP8, Q8_K_XL and IQ4_XS.** Bits-per-weight is not an
      output-quality metric, and every throughput table in this repo is silent on
      it.
- [ ] **Tool-call correctness A/B between the two engines.** That lemonade
      returns a well-formed `tool_calls` shape is measured; that it does so more
      *reliably* than vLLM is not.
- [ ] **RCCL.** Every `-sm tensor` figure is a floor. Cost and bounded payoff:
      `docs/explanation/llama-cpp-tensor-split.md`.
- [ ] **Prefix caching overrides an upstream experimental gate** for hybrid
      models. Correctness spot-checks passed 2026-08-22; no quality A/B on versus
      off has been run.

### LLaMA-Factory — `llamafactory.sh`

Nothing here has been trained yet. Verified under the previous trainer and
carried over unchanged — do not re-derive.

- [ ] **Does a QLoRA run actually complete on gfx1201?** Nothing has been trained
      on this box.
- [ ] **What does a 4B QLoRA cost in VRAM, and is one card enough?**
- [ ] **Does full-precision LoRA hit the rocBLAS Tensile GEMM crash here?** A
      published R9700 report says yes; untested here, hence the QLoRA default.
- [ ] **Is `/workspace/data` seeding correct in practice?**
- [ ] **Multi-GPU training is untested and unsupported by choice.**
- [x] **`Restart=on-failure` vs the vLLM lesson.** Settled: `on-failure` is
      correct here. Unlike vLLM (whose engine death exits cleanly and needs
      `always` to recover), a training crash has no silent-success failure mode
      and should not resurrect itself in a loop while you read the traceback.
- [ ] First project idea: bash command risk scoring.

### Gaming

- [x] **3DMark stalls once the benchmark starts, cause unknown.** Resolved —
      Proton-GE baked into the image was the fix. Hardware monitoring must still
      be disabled in 3DMark's settings (SystemInfo is Wine-incompatible regardless
      of Proton version). 32-bit Vulkan is fine and Vulkan picks an R9700, not the
      iGPU.

### Sunshine

- [ ] **Drop the dummy plug.** Three untested approaches in
      `docs/explanation/sunshine-capture.md`; `video=` in `kargs.d` is preferred.

### Unverified

- [x] Fedora ships `/dev/kfd` world-accessible (`SUBSYSTEM=="kfd", GROUP="render",
      MODE="0666"` in systemd-udev's `50-udev-default.rules`). The custom udev
      rule is already removed from `amdgpu.sh` — it was a net loss, tightening
      the base 0666 then handing access back only to the seated user.
