---
date: 2026-10-04
subject: Flux v2.9.6 bootstrapped on the nuc k3s cluster from faulty-technology/homelab
harness: none — the commands in how-to/bootstrap-flux-on-nuc.md, run by hand from the laptop. flux-cli ghcr.io/fluxcd/flux-cli@sha256:b1ac18156f227af9a524b842a96f2c20986c7a779ef721df3ba4e4540f449d76 (v2.9.6); kubectl registry.k8s.io/kubectl:v1.36.4
box: kinoite-nuc (NUC12WSKi7), k3s v1.36.5+k3s1
---

# Flux bootstrap on nuc

## What was run

These are steps 2–6 of
[how-to/bootstrap-flux-on-nuc](../how-to/bootstrap-flux-on-nuc.md), with the
kubeconfig `~/.kube/nuc.yaml` pointed at `https://nuc:6443` over the tailnet.

    flux bootstrap github --token-auth=false --read-write-key=false \
      --owner=faulty-technology --personal --repository=homelab --private=true \
      --branch=main --path=clusters/nuc

The repo `faulty-technology/homelab` was created by hand beforehand: private,
initialized with a README. Auth was a fine-grained token limited to that one
repo (Administration RW, Contents RW, Metadata R, 7-day expiry). It was used
only by the CLI on the laptop. The cluster pulls with an SSH deploy key.

## Results

Pre-flight, 2026-10-03, before bootstrap:

    ✔ Kubernetes 1.36.5+k3s1 >=1.33.0-0
    ✔ prerequisites checks passed

Bootstrap log, `~/flux-bootstrap.log` on the laptop, condensed:

    ✔ committed component manifests to "main" ("33c9366fd05d87883c5abe7e679993cc90dd104c")
    ✔ configured deploy key "flux-system-main-flux-system-./clusters/nuc" for "https://github.com/faulty-technology/homelab"
    ✔ committed sync manifests to "main" ("babbc1aac663ac5c4eca37318332c874e2280a65")
    ✔ GitRepository reconciled successfully
    ✔ Kustomization reconciled successfully
    ✔ all components are healthy

Verification, 2026-10-04T14:36:03Z. From `flux check`:

    ✔ distribution: flux-v2.9.6
    ✔ bootstrapped: true
    helm-controller          v1.6.5  ready
    kustomize-controller     v1.9.6  ready
    notification-controller  v1.9.4  ready
    source-controller        v1.9.6  ready
    ✔ all checks passed

The rest of the verification:

    GitRepository flux-system/flux-system   main@sha1:babbc1aa  Ready
    Kustomization flux-system/flux-system   main@sha1:babbc1aa  Ready  "Applied revision: main@sha1:babbc1aa"
    flux-system pods: 4/4 Running, 0 restarts

Deploy key, cluster secret against the key in the bootstrap log:

    cluster  384 SHA256:ISaVZd0vDBgOz3icH3DvtXBdruEvX1EnkWtgJOCG+2Q (ECDSA)
    log      384 SHA256:ISaVZd0vDBgOz3icH3DvtXBdruEvX1EnkWtgJOCG+2Q (ECDSA)

## What it means

Flux is installed, healthy and reconciling `clusters/nuc` at the sync commit
`babbc1aa`.

Not verified here:

- **That GitHub shows the deploy key as read-only.** The repo is private and
  this run had no API access to it. `--read-write-key=false` requests
  read-only; check under Settings → Deploy keys.
- **That the token was revoked.** That is an operator step in the GitHub UI.
