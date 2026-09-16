---
date: 2026-09-14
subject: Muse Glimmer 30B UD-Q8_K_XL on lemonade: recipe load, DFlash, tensor vs layer split by depth
harness: ~/bench/glimmer-arms.sh (orchestration), glimmer-seed.py (hand-added recipe) and glimmer-smoke.py (text, vision, tool call), driving ~/bench/depth.sh and ~/bench/depth.py; raw output ~/bench/glimmer/{arms.log,lemonade-load.log}, ~/bench/depth-glimmer-{tensor-dflash,layer-dflash,tensor-nospec}.log and ~/bench/glimmer-pull.log (off-repo, on the box)
box: kinoite-north
---

# Muse Glimmer 30B UD-Q8_K_XL on lemonade: recipe load, DFlash, tensor vs layer split by depth

## What was measured

Three questions about `user.Muse-Glimmer-30B-Q8XL`:

- Does it load and serve on this box exactly as it is baked?
- Which split mode should it carry?
- Does its DFlash drafter pay?

Software: lemonade 11.9.0 (image `17bd2aa`, built 2026-09-02) and its installed rocm-nightly llama.cpp bundle b1328, commit `8172e65`. lemonade logged that GitHub was unreachable and used the installed backend without checking for updates. Files came from `unsloth/Muse-Glimmer-30B-GGUF` snapshot `faa5b02`:

    Muse-Glimmer-30B-UD-Q8_K_XL.gguf      32.30 GB
    mmproj-Muse-Glimmer-30B-BF16.gguf      3.85 GB
    dflash-kquant.gguf                     1.63 GB

### The recipe, through lemonade

- The shipped `user_models.json` and `recipe_options.json` entries were added by hand to north's user config (`glimmer-seed.py`). The running image did not ship the key yet, so the seeder left it alone.
- Recipe settings: `-sm tensor -fa on --spec-draft-n-max 15`, ctx 131072, labels `custom vision reasoning coding dflash`.
- Loaded with `POST /api/v1/load`, then tested with `glimmer-smoke.py`:
  - a text question (17 × 23)
  - a 448×448 image with a red left half and a blue right half
  - a `get_weather` tool call
- All three requests were non-streaming, at temperature 0 with `reasoning_effort: low`.

### Three raw arms

All three ran on the same b1328 bundle through `depth.sh`, with `-c 98304 -np 1` and both R9700s selected by visibility. The harness was `depth.py <log> 512 3`: decode timed from first content token to last, median of 3 reps after a discarded warm-up.

- **tensor + DFlash:** `-sm tensor -fa on --spec-type draft-dflash -md dflash-kquant.gguf -ngld 99 --spec-draft-n-max 15`
- **layer + DFlash:** the same without `-sm tensor`
- **tensor, no speculation:** `-sm tensor -fa on`

### Baseline, not re-measured

Arm B of [runs/2026-09-13-r9v-flash-next](2026-09-13-r9v-flash-next.md): `Qwen3.8-27B-UD-Q8_K_XL` with its Q4_0 MTP draft at n-max 4. That is the recipe behind `user.Qwen3.8-27B-Q8XL`, run with the same launcher, bundle, ctx and harness.

It differs from these arms in two ways:

- **Reasoning.** `depth.py` sends `chat_template_kwargs: {"enable_thinking": false}`. Glimmer's template has no such variable; it reads `reasoning_strength`. So these arms ran at Glimmer's default strength, `high`. `depth.py` times reasoning and content tokens the same way, so the decode rate is comparable. Whether the 512 tokens were reasoning or answer was not checked.
- **Context size.** The lemonade load ran at ctx 131072; the raw arms ran at 98304.

## Numbers

### Recipe load through lemonade

`{"status":"success"}` came back 13 s after the request. The files had been downloaded minutes earlier, so this is not a cold-disk load time.

Load log, in timestamp order:

    W common_fit_params: failed to fit params to free device memory: llama_params_fit is not implemented for SPLIT_MODE_TENSOR, abort
    W internal AllReduce init failed (n_devices != 2?); falling back to meta-backend butterfly
    I common_speculative_init_result: loading draft model '.../dflash-kquant.gguf'
    W internal AllReduce init failed (n_devices != 2?); falling back to meta-backend butterfly
    I srv    load_model: loaded multimodal model, '.../mmproj-Muse-Glimmer-30B-BF16.gguf'
    I common_speculative_impl_draft_dflash: adding speculative implementation 'draft-dflash'
    I common_speculative_impl_draft_dflash: - n_max=15, n_min=0, p_min=0.00
    I common_speculative_impl_draft_dflash: - block_size=16, mask_token_id=201818, n_extract=5, sample_from_anchor=true
    W set_sampler: backend sampling not supported with SPLIT_MODE_TENSOR; using CPU
    W spec common_specu: backend offload failed for seq_id=0; using CPU sampler

No `not implemented for architecture` line.

VRAM with the model loaded (sysfs `mem_info_vram_used`) was 20,884 MiB and 16,955 MiB on the two R9700s, and 325 MiB on the iGPU. After `unload`, each R9700 was back to 57 MiB.

Smoke tests, 3/3 pass:

| test | wall | completion tokens | answer | draft acceptance, mean len |
|---|---|---|---|---|
| text + reasoning | 1.1 s | 42 | `391`, with 107 chars of reasoning | 37 / 75, 8.40 |
| vision | 1.1 s | 66 | "The left half is red and the right half is blue." | 57 / 120, 8.12 |
| tool call | 1.4 s | 109 | `get_weather({"city":"Reykjavik","unit":"c"})`, finish `tool_calls` | 93 / 240, 6.81 |

### Decode versus depth

`depth.py`, 512 tokens, 3 reps. In the tables:

- **tok/s** is the median of the 3 reps.
- **acc** is the mean accepted length.
- **ms/pass** is the time per target-model forward pass.

On every point, the min–max spread across the 3 reps was under 1%. The widest was 69.27–69.88 tok/s, tensor + DFlash at 69,939 tokens.

| prompt | tensor+DFlash tok/s | ms/pass | acc | layer+DFlash tok/s | ms/pass | acc | tensor no-spec tok/s |
|---|---|---|---|---|---|---|---|
| rust, 28 tok | 56.46 | 52.25 | 2.950 | 47.89 | 74.13 | 3.550 | 30.98 |
| python, 31 tok | 71.23 | 52.37 | 3.730 | 49.02 | 74.26 | 3.640 | 30.91 |
| prose, 29 tok | 47.62 | 52.50 | 2.500 | 33.12 | 74.27 | 2.460 | 30.89 |
| control mean | 58.44 | | 3.060 | 43.34 | | 3.217 | 30.93 |
| 191 tok | 88.56 | 52.51 | 4.650 | 62.41 | 74.50 | 4.650 | 30.91 |
| 9,503 tok | 61.55 | 54.59 | 3.360 | 53.80 | 76.58 | 4.120 | 30.47 |
| 37,962 tok | 67.56 | 56.10 | 3.790 | 47.41 | 78.67 | 3.730 | 30.18 |
| 69,939 tok | 69.88 | 56.67 | 3.960 | 47.74 | 81.49 | 3.890 | 29.81 |

Ratios. The 27B column gives its own tok/s in brackets, and its prompt depths were 189, 9,479, 37,763 and 69,751 tokens.

| prompt | tensor / layer | tensor+DFlash / no-spec | Glimmer tensor+DFlash / 27B Q8XL | ms/pass, Glimmer vs 27B |
|---|---|---|---|---|
| rust | 1.18x | 1.82x | 0.84x (66.97) | |
| python | 1.45x | 2.30x | 0.99x (72.20) | |
| prose | 1.44x | 1.54x | 0.83x (57.28) | |
| control mean | 1.35x | 1.89x | 0.89x (65.48) | 52.25–52.50 vs 49.13–49.41 |
| 191 tok | 1.42x | 2.87x | 1.16x (76.49) | 52.51 vs 49.55 |
| 9,503 tok | 1.14x | 2.02x | 0.88x (69.79) | 54.59 vs 51.16 |
| 37,962 tok | 1.43x | 2.24x | 1.09x (61.93) | 56.10 vs 57.16 |
| 69,939 tok | 1.46x | 2.34x | 1.24x (56.24) | 56.67 vs 63.48 |

VRAM under load in the raw arms, as `depth.sh` prints it from `amd-smi`:

| arm | card 1 | card 2 |
|---|---|---|
| tensor + DFlash | 17,027 MB | 17,027 MB |
| layer + DFlash | 16,597 MB | 18,163 MB |
| tensor, no speculation | 15,608 MB | 15,608 MB |

The butterfly fallback was logged twice by the tensor + DFlash arm, once by the tensor no-speculation arm and zero times by the layer + DFlash arm.

## What it means

- **The recipe works as baked.** On b1328:
  - `muse-glimmer` passes the `-sm tensor` architecture check.
  - DFlash engages at its trained block of 16 with `n_max=15`.
  - Vision and tool calls come back well-formed through lemonade.

  Not measured: output quality, and decode speed through lemonade itself at ctx 131072 (the arms ran on raw llama-server at 98304).
- **Tensor split wins at every depth**, 1.14–1.46x on tok/s. ms/pass, which acceptance does not affect, is 1.40–1.44x lower on tensor split at every point. The two narrower tok/s ratios (rust 1.18x, 9,503 tokens 1.14x) are points where layer split happened to accept more tokens. `-sm tensor -fa on` is baked.
- **DFlash pays at every depth.** It is 1.54–2.30x faster on the three control prompts (1.89x on their mean), and 2.87x, 2.02x, 2.24x and 2.34x faster at 191, 9,503, 37,962 and 69,939 tokens. Unspeculated decode itself falls only from 30.91 to 29.81 tok/s between 191 and 69,939 tokens.
  - A tensor + DFlash pass costs about 52.5 ms, against about 32.3 ms per token without speculation. So the drafter breaks even at an accepted length of about 1.6.
  - The lowest accepted length measured in any arm was 2.46.
- **Against the Q8XL daily driver:**
  - Slower on the short control (0.89x) and at 9.5K (0.88x).
  - Faster at 191 tokens (1.16x), 38K (1.09x) and 70K (1.24x).
  - Its time per pass grows 7.9% from 191 to 70K tokens, against 28.1% for the 27B. That fits 39 of its 52 layers attending over a 2,048-token window, but this is an interpretation that was not tested here.
  - Acceptance is not like for like: the 27B generated answers with thinking off, while Glimmer ran at reasoning strength `high`.
- **Acceptance on the depth harness (2.5–4.7) is well below the smoke tests (6.8–8.4).** The smoke answers were short and ran at `reasoning_effort: low`; the harness writes 512 tokens of code, prose and log summary. Only `--spec-draft-n-max 15` was run; no lower value was tested.
