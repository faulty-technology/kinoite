# Explanations

- [Engine Choice](./engine-choice.md) - why llama.cpp (lemonade) is the decode path: lemonade Q8XL ~22 GB/card vs vLLM FP8 ~28 GB of 32, they can't coexist
- [Gpu Power And Fans](./gpu-power-and-fans.md) - three findings shaping tuning: OverDrive karg must be applied a specific way, nothing survives an idle cycle, fan floor is firmware
- [Llama Cpp Tensor Split](./llama-cpp-tensor-split.md) - why `-sm tensor`: the largest decode lever (+44.4% on 27B with MTP head)
- [Quadlets And Selinux](./quadlets-and-selinux.md) - two silent-fail constraints: rootless Quadlets must ship in `/etc` not `/usr`; SELinux confinement
- [Quant Selection](./quant-selection.md) - why seeded recipes are Q6_K with one IQ4_XS exception (weight-size axis flat above ~25 GB)
- [Sunshine Capture](./sunshine-capture.md) - why the Sunshine setup looks the way it does; each non-obvious piece defends against something
- [Suspend And Wake](./suspend-and-wake.md) - LLM suspend hook exists because S3 with a model loaded hangs the box; WoWLAN only recovers correct suspends
- [Vllm Decode Budget](./vllm-decode-budget.md) - where vLLM decode time goes: 24.3 tok/s baseline (~41 ms/token), every line measured
- [Vllm Kv Cache Padding](./vllm-kv-cache-padding.md) - why the KV-cache group padding warning happens, and the DFlash2 trap
