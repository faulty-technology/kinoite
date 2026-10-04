---
date: 2026-10-04
subject: Flux reinstalled on nuc, authenticating as GitHub App faulty-technology-flux
harness: none. The commands in how-to/bootstrap-flux-on-nuc.md, run by hand from the laptop, using flux-cli ghcr.io/fluxcd/flux-cli@sha256:b1ac18156f227af9a524b842a96f2c20986c7a779ef721df3ba4e4540f449d76 (v2.9.6) and kubectl registry.k8s.io/kubectl:v1.36.4
box: kinoite-nuc (NUC12WSKi7), k3s v1.36.5+k3s1
---

# Flux on nuc, reinstalled with GitHub App auth

Supersedes [2026-10-04-nuc-flux-bootstrap](2026-10-04-nuc-flux-bootstrap.md),
which used an SSH deploy key. Why the switch:
[decisions/2026-10-04-flux-github-app-over-deploy-key](../decisions/2026-10-04-flux-github-app-over-deploy-key.md).

## What was run

Done by hand on GitHub before the run:

- Created GitHub App `faulty-technology-flux`, App ID 5187039. Permissions:
  Contents read-only and Metadata read-only. Webhook off. Installable only on
  this account.
- Installed the App on `faulty-technology/homelab`.
- Saved the private key to 1Password.
- Deleted the bootstrap deploy key from homelab.

The run itself:

1. `flux uninstall --silent`, which removed all eleven Flux CRDs and the
   `flux-system` namespace, including the old SSH secret.
2. homelab `4058977`: `gotk-sync.yaml` rewritten to
   `url: https://github.com/faulty-technology/homelab`, `provider: github`,
   `secretRef: flux-system-github-app`. `gotk-components.yaml` regenerated with
   `flux install --export`. It came out identical to what bootstrap had
   committed.
3. Runbook steps 3–7: pre-flight, `flux install`,
   `flux create secret githubapp`, apply the sync manifests, verify.

## Results

Uninstall, 14:59:21Z: `✔ uninstall finished`, 0 `fluxcd` CRDs left, and the
namespace was gone before the reinstall started.

Pre-flight and install, 14:59:42Z:

    flux: v2.9.6
    ✔ Kubernetes 1.36.5+k3s1 >=1.33.0-0
    ✔ prerequisites checks passed
    ✔ install finished          (4/4 controllers ready)

App secret: `githubapp secret 'flux-system-github-app' created`. Key names
present: `githubAppID`, `githubAppInstallationOwner`, `githubAppPrivateKey`.
Values were not printed.

Sync apply, 15:00:09Z. The local homelab clone was at `origin/main`
`4058977c1cd28ef253aeb047d950f1fe0e759e7e`. Applying the whole
`clusters/nuc/flux-system` directory with `kubectl apply --server-side -k`
**conflicted** with the `flux` field manager on the four controller
Deployments (`GOMEMLIMIT`, `RUNTIME_NAMESPACE` env, `limits.cpu`) and on
`ResourceQuota/critical-pods-flux-system` (`.spec.hard.pods`). The values were
identical, because both sides come from the same v2.9.6 manifests. Only
ownership clashed. `GitRepository/flux-system` and `Kustomization/flux-system`
applied cleanly. The runbook now applies `gotk-sync.yaml` alone.

Verification, 15:00:26Z:

    ✔ fetched revision main@sha1:4058977c1cd28ef253aeb047d950f1fe0e759e7e
    ✔ applied revision main@sha1:4058977c1cd28ef253aeb047d950f1fe0e759e7e
    ✔ distribution: flux-v2.9.6
    ✔ all checks passed
    GitRepository flux-system/flux-system   main@sha1:4058977c  Ready  stored artifact for revision 'main@sha1:4058977c'
    Kustomization flux-system/flux-system   main@sha1:4058977c  Ready  Applied revision: main@sha1:4058977c
    spec: https://github.com/faulty-technology/homelab github flux-system-github-app
    pods: helm, kustomize, notification, source-controller, all 1/1 Running, 0 restarts

Field managers on `Deployment/source-controller` after the first reconcile are
`flux` (Apply), `kustomize-controller` (Apply) and `k3s` (Update). No
`kubectl` manager remains, so the failed `-k` apply left nothing behind.

## What it means

Flux pulls homelab over HTTPS as the GitHub App. The deploy key had already
been deleted from GitHub when the fetch at `4058977c` succeeded. That fetch is
therefore the proof that App authentication works, not a fallback to the old
key.

Not verified here:

- **That the App's GitHub-side permissions are exactly Contents and Metadata,
  read-only.** That is operator-reported, and this run had no API access to the
  App settings.
- **That the stray second `.pem` in `~/Downloads` was deleted.** That is left to
  the operator.
