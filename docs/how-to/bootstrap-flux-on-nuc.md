# Install Flux on the NUC

Run `scripts/bootstrap.sh` in the homelab repo. It takes the `nuc` k3s cluster
from "node Ready" to "Flux reconciling `faulty-technology/homelab` at
`clusters/nuc`". It installs Flux and creates the two hand-placed secrets from
1Password. Then it applies the sync and checks that everything from git came up:
the SOPS canary decrypts and the GPU plugin registered.

Every step creates or updates, so re-running it is safe. Each run writes a
receipts log to `~/.local/state/homelab/bootstrap-<UTC timestamp>.log`.

## Prerequisites

- **The k3s node is Ready.** On a fresh install, that's after the first boot.
- **homelab is cloned at `~/Source/homelab`.** It must be clean and at
  `origin/main`, or the script refuses to run.
- **The 1Password CLI works through the app.** `op` is in the laptop image. In
  the app, turn on Settings → Developer → *Integrate with 1Password CLI*.
- **The GitHub App exists and its key is in 1Password.** If not, see
  [GitHub App (once)](#github-app-once).

## Run

    cd ~/Source/homelab
    scripts/bootstrap.sh                       # install or repair
    scripts/bootstrap.sh --refresh-kubeconfig  # also re-fetch ~/.kube/nuc.yaml (prompts for the NUC sudo password)
    scripts/bootstrap.sh --reinstall           # flux uninstall first, then rebuild (asks to confirm)

Run it in a real terminal. `--reinstall` and `--refresh-kubeconfig` both
prompt, and 1Password may ask you to approve the `op read`.

It must end with `== … done` and print the receipts path. On failure it prints
`FAIL: <reason>` and stops at that step. Fix the cause and run it again.

## What it reads

| Input | Where |
|---|---|
| GitHub App private key | `op://Private/ogpe3a62c7zkzpzxgj5kmvl7bu/flux-app.pem`, override with `OP_APP_KEY_REF` |
| SOPS age key | `op://Private/ogpe3a62c7zkzpzxgj5kmvl7bu/keys.txt`, override with `OP_AGE_KEY_REF` |
| App ID / owner | `5187039` / `faulty-technology`, set in the script |
| Kubeconfig | `~/.kube/nuc.yaml`, override with `KUBECONFIG_PATH` |

Both keys are written to a `0700` directory under `$XDG_RUNTIME_DIR` for the
few seconds the secrets take to create, and are never printed.

## GitHub App (once)

Do this only if the App does not exist yet.

1. On GitHub, go to Settings → Developer settings → **GitHub Apps** → New
   GitHub App:

   | Field | Value |
   |---|---|
   | Name | `faulty-technology-flux` |
   | Homepage URL | `https://github.com/faulty-technology/homelab` |
   | Webhook | Uncheck **Active** |
   | Repository permissions | **Contents: Read-only** (Metadata: Read-only is added automatically) |
   | Where can it be installed | **Only on this account** |

2. Generate a private key. Attach the `.pem` file to the 1Password item above
   as `flux-app.pem`.
3. Install the App on `faulty-technology`, with **Only select repositories**:
   `homelab` and any private app repos.
4. If the App ID changes, update `GITHUB_APP_ID` in the script.

## Add another private repo

1. Install the App on that repo.
2. In homelab, add a `GitRepository` with `provider: github` and
   `secretRef: { name: flux-system-github-app }`.

## Upgrade Flux

1. In `scripts/bootstrap.sh`, update the `FLUX_IMAGE` digest.
2. Regenerate the components file:

       podman run --rm <new FLUX_IMAGE> install --export > clusters/nuc/flux-system/gotk-components.yaml

3. Commit and push. Flux applies the new components to itself.

Don't use `flux bootstrap github`. It has no GitHub App option.

## Remove

    flux uninstall --namespace=flux-system

This removes the controllers, the CRDs and both secrets. Workloads Flux
deployed keep running.
