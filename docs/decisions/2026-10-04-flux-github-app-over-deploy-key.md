---
date: 2026-10-04
subject: Flux on nuc authenticates to GitHub as a GitHub App, not with per-repo SSH deploy keys; installed without flux bootstrap
---

# Flux uses a GitHub App, not deploy keys

## Decision

Flux on `nuc` authenticates as the GitHub App `faulty-technology-flux` (App ID
5187039), which has Contents and Metadata read-only. Its private key lives in
the cluster Secret `flux-system/flux-system-github-app` and in 1Password, never
in git.

Flux is installed with `flux install` plus `kubectl apply` of `gotk-sync.yaml`,
following [how-to/bootstrap-flux-on-nuc](../how-to/bootstrap-flux-on-nuc.md).
`flux bootstrap github` has no GitHub App option, so it is no longer used.

## Why

Private app repos are expected alongside homelab. With deploy keys, every one
of them needs its own key, its own cluster secret and its own GitHub setting.
With the App, adding a repo means installing the App on it and pointing a
`GitRepository` at the one shared secret.

The App also sends GitHub only short-lived (1 h) installation tokens instead of
a long-lived key, and its access is logged under the App's identity.

## Alternatives rejected

- **Keep the read-only deploy key from bootstrap.** For homelab alone it is
  about as narrow as the App: one repo, read-only. Rejected because each
  further private repo adds another key to rotate and track.
- **Migrate the bootstrapped install in place** with a kustomize patch, a
  throwaway auth test and a rollback through `kubectl`. Rejected because
  nothing was deployed through Flux yet, so a clean reinstall was simpler. It
  also leaves a single runbook that rebuilds the cluster from scratch, which
  bootstrap can no longer do.
- **Token auth (`--token-auth`) with a PAT stored in the cluster.** It ties
  cluster access to a person's long-lived token.

## Cost

- The App's private key reaches every repo the App is installed on. Keep the
  install list to the repos Flux actually needs.
- Upgrading Flux means running `flux install --export` and committing the
  output, instead of re-running bootstrap.
