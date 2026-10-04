# Install Flux on the NUC

Installs Flux on the `nuc` k3s cluster and syncs it from the private repo
`faulty-technology/homelab`, at the path `clusters/nuc`. Flux authenticates as
the GitHub App **`faulty-technology-flux`**. The same App gives Flux access to
any other private repo it is installed on.

This does not use `flux bootstrap github`, which has no GitHub App option. The
manifests live in the repo:

- `clusters/nuc/flux-system/gotk-components.yaml`
- `clusters/nuc/flux-system/gotk-sync.yaml`

Install means applying those manifests, plus one secret that is never stored in
git.

Run it from the laptop. Save the output of each step marked **receipt**: those
outputs go into the run record in `docs/runs/`.

## Prerequisites

- `~/.kube/nuc.yaml` works, and `get nodes` shows `nuc Ready`. To recreate it,
  see [Recreate the kubeconfig](#recreate-the-kubeconfig).
- The homelab repo is cloned at `~/Source/homelab`.
- The App's private key is available, from 1Password or from step 2.

## 1. Define the pinned tools

The CLIs run from containers pinned by version. Nothing is installed, so this
works the same after a wipe.

    # flux-cli v2.9.6
    flux() {
      podman run --rm -i --network host \
        --userns=keep-id --user "$(id -u):$(id -g)" \
        -v "$HOME/.kube/nuc.yaml":/kubeconfig:ro,Z -e KUBECONFIG=/kubeconfig \
        -v "$HOME/Downloads":/dl:ro,Z \
        ghcr.io/fluxcd/flux-cli@sha256:b1ac18156f227af9a524b842a96f2c20986c7a779ef721df3ba4e4540f449d76 \
        "$@"
    }
    kubectl() {
      podman run --rm -i --network host \
        --userns=keep-id --user "$(id -u):$(id -g)" \
        -v "$HOME/.kube/nuc.yaml":/kubeconfig:ro,Z -e KUBECONFIG=/kubeconfig \
        -v "$HOME/Source/homelab":/homelab:ro,Z \
        registry.k8s.io/kubectl:v1.36.4 "$@"
    }

`--user` and `--userns=keep-id` are required: the images run as user 65534,
which cannot read a `0600` kubeconfig.

To bump Flux, change the digest above and regenerate the components file:

    flux install --export > ~/Source/homelab/clusters/nuc/flux-system/gotk-components.yaml

Then commit the regenerated file to homelab.

## 2. GitHub App (once)

Skip this step if the App already exists and its key is in 1Password.

On GitHub, go to Settings → Developer settings → **GitHub Apps** → New GitHub
App:

| Field | Value |
|---|---|
| Name | `faulty-technology-flux` |
| Homepage URL | `https://github.com/faulty-technology/homelab` |
| Webhook | Uncheck **Active** |
| Repository permissions | **Contents: Read-only** (Metadata: Read-only is added automatically) |
| Everything else | No access |
| Where can it be installed | **Only on this account** |

Then:

1. Note the **App ID**.
2. Under Private keys, click Generate a private key. Save the `.pem` file to
   1Password.
3. Under Install App, install it on `faulty-technology` with **Only select
   repositories**: `homelab`, plus any private app repos.

## 3. Pre-flight — receipt

    flux version --client
    flux check --pre

The check must end with `✔ prerequisites checks passed`.

## 4. Install the controllers

    flux install

It must end with `✔ install finished`.

## 5. Create the App secret

Put the key at `~/Downloads/flux-app.pem`, then run:

    flux create secret githubapp flux-system-github-app \
      --namespace=flux-system \
      --app-id=<APP_ID> \
      --app-installation-owner=faulty-technology \
      --app-private-key=/dl/flux-app.pem
    rm ~/Downloads/flux-app.pem

**Receipt**: this prints key names only, never the values.

    kubectl -n flux-system get secret flux-system-github-app -o jsonpath='{.data}' | grep -o '"[a-zA-Z]*":' | tr -d '":'

You should see `githubAppID`, `githubAppInstallationOwner` and `githubAppPrivateKey`.

## 6. Apply the sync

The clone must match `origin/main`. Flux takes over from git as soon as this
is applied, so anything that is only local gets reverted.

    git -C ~/Source/homelab fetch -q && git -C ~/Source/homelab status -sb | head -1
    kubectl apply --server-side -f /homelab/clusters/nuc/flux-system/gotk-sync.yaml

Apply only `gotk-sync.yaml`. Step 4 already installed the components under the
`flux` field manager, so applying the whole directory with `-k` conflicts on
the controller Deployments and the ResourceQuota. Flux applies the full
directory itself on its first reconcile.

## 7. Verify — receipt

    flux reconcile kustomization flux-system --with-source
    flux check
    flux get sources git -A
    flux get kustomizations -A
    kubectl -n flux-system get gitrepository flux-system -o jsonpath='{.spec.url} {.spec.provider} {.spec.secretRef.name}{"\n"}'
    kubectl -n flux-system get pods

Expect:

- Every controller is `✔` healthy.
- `GitRepository/flux-system` and `Kustomization/flux-system` are both Ready, at
  the homelab `main` HEAD.
- The URL line reads `https://github.com/faulty-technology/homelab github flux-system-github-app`.

## Add another private repo

1. Install the App on the repo (GitHub → the App → Install App → configure).
2. In homelab, add a `GitRepository` with `provider: github` and
   `secretRef: { name: flux-system-github-app }`.

## Roll back / remove

    flux uninstall --namespace=flux-system

This removes the controllers, the CRDs, and the secret along with the
namespace. Workloads Flux deployed keep running until you delete them.

## Recreate the kubeconfig

On the NUC:

    sudo install -m 600 -o "$USER" /etc/rancher/k3s/k3s.yaml ~/k3s.yaml

On the laptop:

    scp faultytechnology-nuc@nuc:k3s.yaml ~/.kube/nuc.yaml && chmod 600 ~/.kube/nuc.yaml
    sed -i -e 's#https://127.0.0.1:6443#https://nuc:6443#' \
           -e 's/^\(\s*\)name: default$/\1name: nuc/' \
           -e 's/^- name: default$/- name: nuc/' \
           -e 's/^\(\s*\)cluster: default$/\1cluster: nuc/' \
           -e 's/^\(\s*\)user: default$/\1user: nuc/' \
           -e 's/^current-context: default$/current-context: nuc/' ~/.kube/nuc.yaml
    ssh faultytechnology-nuc@nuc 'rm -f ~/k3s.yaml'
