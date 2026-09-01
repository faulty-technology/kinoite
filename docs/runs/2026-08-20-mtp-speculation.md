---
date: 2026-08-20
subject: llama.cpp MTP draft head speedup on Qwen3.8-27B
harness: llama-server driven directly on the pair
box: kinoite-north
---

# MTP speculation on the 27B

## What was measured

Qwen3.8-27B-UD-IQ4_XS (14.0 GB), `-ngl 99 -c 32768`, 512-token runs, driving
`llama-server` directly on the pair.

Speculated arm: `--spec-type draft-mtp -md mtp-Qwen3.8-27B-Q4_0.gguf -ngld 99
--spec-draft-n-max 4`.

## Numbers

| arm | tok/s |
|---|---|
| baseline | 30.40 |
| MTP draft head | **56.86** (+87%) |

Acceptance 0.45–0.67, mean accepted length 2.8–3.7.

Baseline is dead flat across workloads (30.45 / 30.43 / 30.33). The MTP arm
varies 51–65 because acceptance is workload-dependent.

Also measured that session, for the packaging check: form-1 (separate draft
file) via Gemma-4-12B-it-MTP-GGUF and form-2 (embedded head) via
Qwen3.5-4B-MTP-GGUF. In both cases lemonade adds `--spec-type draft-mtp
--spec-draft-n-max 3` by itself; form 2 passes no `-md`, because llama.cpp reads
the head out of the main file.

## What it means

Quote the **baseline** when comparing engines — the MTP arm's workload variance
makes it the wrong number for a cross-engine claim.

30.40 tok/s on 14.0 GB is only ~426 GB/s effective, ~67% of the 640 GB/s spec.
llama.cpp's HIP backend leaves real bandwidth on the table, which is worth
remembering before blaming quantisation for any llama.cpp-vs-vLLM gap.

Older Q5_K_M (21.2 GB) figures of 31–35 tok/s ROCm / ~29 Vulkan predate this
wiring and are unspeculated.
