---
date: 2026-10-04
subject: homelab scripts/bootstrap.sh --reinstall rebuilds Flux on nuc end to end in 39 s
harness: homelab scripts/bootstrap.sh at 239be937, run by the operator from the laptop. Receipts are in ~/.local/state/homelab/bootstrap-20261004T182910Z.log on the laptop. Tools are pinned in the script: flux-cli v2.9.6, kubectl v1.36.4, op 2.40.0.
box: kinoite-nuc (NUC12WSKi7), k3s v1.36.5+k3s1, SELinux enforcing
---

# bootstrap.sh rebuild test

The script replaces the hand-run steps of
[2026-10-04-nuc-flux-github-app](2026-10-04-nuc-flux-github-app.md) and
[2026-10-04-nuc-sops-age](2026-10-04-nuc-sops-age.md). Both secrets now come
from 1Password through `op read`. The GPU plugin from
[2026-10-04-nuc-intel-gpu-plugin](2026-10-04-nuc-intel-gpu-plugin.md) arrives
from git, and the script checks it directly.

## First attempt — failed, fixed

The run at 18:20:02Z (log `bootstrap-20261004T182002Z.log`, homelab `d9a434d`)
got through preflight, uninstall, install and both secrets. It then stopped on:

    Error: statfs /run/user/1000/homelab-bootstrap.sIWxu8: no such file or directory

The script deleted the temporary secrets directory but left `SECRETS_DIR` set.
Its container wrapper mounts that path whenever the variable is set, so podman
refused the mount. The EXIT trap had already removed the directory, and nothing
was left in `/run/user/1000`. The fix (homelab `239be93`) unsets the variable
after the delete and makes the trap `${SECRETS_DIR:-}`-safe under `set -u`.

## Rebuild — passed

`scripts/bootstrap.sh --reinstall` at homelab `239be937b971a96d30944fd0d5ccd017b4994c4a`:

    18:29:10Z  preflight                 homelab HEAD 239be937…, clean, == origin/main
    18:29:10Z  cluster reachable         nuc Ready
    18:29:11Z  flux uninstall            ✔ uninstall finished
    18:29:20Z  flux pre-flight           ✔ prerequisites checks passed
    18:29:21Z  flux install              ✔ install finished
    18:29:38Z  secrets from 1Password    flux-system-github-app keys: githubAppID githubAppInstallationOwner githubAppPrivateKey
                                         sops-age keys: age.agekey
    18:29:41Z  apply gotk-sync.yaml      ✔ fetched / applied revision main@sha1:239be937…
    18:29:46Z  verify flux               ✔ distribution: flux-v2.9.6, ✔ all checks passed
                                         gitrepository/flux-system           main@sha1:239be937    Ready
                                         gitrepository/intel-device-plugins  v0.37.1@sha1:6e5cf25a Ready
                                         flux-system=True  intel-gpu-plugin=True
    18:29:48Z  verify sops               canary decrypted: sops-ok-2026-10-04
    18:29:48Z  verify gpu plugin         daemon set "intel-gpu-plugin" successfully rolled out
                                         gpu.intel.com/i915 allocatable: 4
    18:29:49Z  done

## What it means

The whole Flux layer rebuilds from three sources and nothing hand-placed:

- this repo, for the manifests,
- 1Password, for two file attachments on one item,
- a k3s node that reports Ready.

The run took 39 s and needed one confirmation from the operator. The cluster
reached the same verified state as the hand-run setup.

Not covered: `--refresh-kubeconfig`, because the existing `~/.kube/nuc.yaml`
was reused. That path has only been run by hand. A first-boot install, where
k3s has never had Flux, is also untested. `--reinstall` gets close, since
`flux uninstall` removes the namespace, CRDs and secrets.
