# Decisions

- [Strict Tool Calling Off](./2026-08-23-strict-tool-calling-off.md) - run vLLM with strict tool calling off rather than bumping the image
- [Drop Padded Drafter Batch](./2026-08-24-drop-padded-drafter-batch.md) - drop `disable_padded_drafter_batch`, keep `--max-num-seqs 4`
- [Windows Wsl2 Rejected](./2026-08-24-windows-wsl2-rejected.md) - stay native Linux dual-card, not Windows/WSL2
- [Llamafactory Over Unsloth](./2026-08-30-llamafactory-over-unsloth.md) - LLaMA-Factory replaces Unsloth for fine-tuning
- [Vllm Prefix Caching On](./2026-08-31-vllm-prefix-caching-on.md) - vLLM ships with prefix caching on by default
- [Gpu Power Cap 250W](./2026-09-15-gpu-power-cap-250w.md) - per-card power cap is 250 W; the bench meant to justify a cap number is dropped
- [Three Slots On Q8Xl](./2026-09-18-three-slots-on-q8xl.md) - Q8XL gets 3 slots (slot count follows live conversations)
- [Four Slots And A Client Concurrency Cap](./2026-09-19-four-slots-and-a-client-concurrency-cap.md) - Q8XL gets 4 slots + client cap of one simultaneous subagent; one decision
- [Radiance At 057 And 131K](./2026-09-25-radiance-at-057-and-131k.md) - radiance at 0.57 mem ceiling / 131K context, 131K client window, two subagents
- [Radiance Back To Full Cards](./2026-09-25-radiance-back-to-full-cards.md) - radiance back to upstream full-card settings on dfdfa38 pin; client back to 262K / four
- [Nuc K3S Flux](./2026-10-03-nuc-k3s-flux.md) - NUC12 is a third image: headless fedora-bootc k3s, apps via Flux from a separate repo
- [Flux Github App Over Deploy Key](./2026-10-04-flux-github-app-over-deploy-key.md) - Flux authenticates as GitHub App, not per-repo deploy keys
- [Sops Age For Flux Secrets](./2026-10-04-sops-age-for-flux-secrets.md) - nuc secrets SOPS-encrypted with one age key; External Secrets + 1Password deferred
- [Nfs Over Tailnet](./2026-10-06-nfs-over-tailnet.md) - NUC mounts Unraid NFS over the tailnet (100.x), not LAN
- [Velero To B2](./2026-10-07-velero-to-b2.md) - nuc app volumes backed up by Velero (kopia) to B2; app DBs stay local
- [Radiance Engine Over Vllm Radiance](./2026-10-18-radiance-engine-over-vllm-radiance.md) - radiance.container switches from patched-vLLM to StillDeadcode's radiance engine 1.8.1, same weights, on trial
