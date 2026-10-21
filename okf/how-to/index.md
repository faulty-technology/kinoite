# How-Tos

- [Back Up And Restore Nuc](./back-up-and-restore-nuc.md) - Velero backup/restore of NUC app data to B2 bucket `faulty-technology-nuc-velero`
- [Benchmark Engines](./benchmark-engines.md) - benchmark lemonade vs vLLM with `~/bench/` harnesses (off-repo); sequential, one engine at a time
- [Bootstrap Flux On Nuc](./bootstrap-flux-on-nuc.md) - install Flux on the NUC via homelab `scripts/bootstrap.sh`
- [Fix Build Key Drift](./fix-build-key-drift.md) - what to do when a build fails on a GPG fingerprint mismatch (keys pinned + vendored)
- [Lemonade](./lemonade.md) - north runbook: Lemonade Server rootless Quadlet (ships to `/usr/share/kinoite/`)
- [Llamafactory](./llamafactory.md) - north runbook: LLaMA-Factory fine-tuning rootless Quadlet
- [Maintaining the OKF bundle](./maintain-okf-bundle.md) - how to add/update pointer concepts in okf/ and validate with okflint
- [Manage Secrets With Sops On Nuc](./manage-secrets-with-sops-on-nuc.md) - SOPS + age key on NUC; Flux kustomize-controller decrypts at apply time
- [Measure Gpu Idle](./measure-gpu-idle.md) - measuring GPU idle/power on north; every gotcha cost hours, read fully first
- [R9V](./r9v.md) - north runbook: R9V Qwen3.8 Flash Next (177B MoE) rootless Quadlet
- [Radiance](./radiance.md) - north runbook: radiance Qwen3.8-27B MXFP4 rootless Quadlet
- [Stream With Sunshine](./stream-with-sunshine.md) - streaming the north box with Sunshine; pairing is the only manual step
- [Vllm](./vllm.md) - north runbook: vLLM + Open WebUI rootless Quadlet pod
