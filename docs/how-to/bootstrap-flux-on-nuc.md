# Bootstrap Flux on the NUC

Installs Flux on the `nuc` k3s cluster and connects it to the private repo
`faulty-technology/homelab`, at the path `clusters/nuc`. The cluster pulls the
repo with a read-only SSH deploy key. The GitHub token is used once, from the
laptop, and is never stored in the cluster.

Run it from the laptop. Save the output of every step marked **receipt**: they
make up the run record in `docs/runs/`.

## Prerequisites

- `~/.kube/nuc.yaml` works: `kubectl --kubeconfig ~/.kube/nuc.yaml get nodes`
  shows `nuc Ready`. To recreate it, see [Recreate the kubeconfig](#recreate-the-kubeconfig).
- The NUC is reachable as `nuc` on the tailnet.

## 1. Define the pinned flux CLI

The CLI runs from a container pinned by digest. Nothing is installed, so this
works the same after the laptop is wiped. To bump Flux, update both the tag
comment and the digest.

    # flux-cli v2.9.6
    flux() {
      podman run --rm -i --network host \
        --userns=keep-id --user "$(id -u):$(id -g)" \
        -v "$HOME/.kube/nuc.yaml":/kubeconfig:ro,Z -e KUBECONFIG=/kubeconfig \
        -e GITHUB_TOKEN \
        ghcr.io/fluxcd/flux-cli@sha256:b1ac18156f227af9a524b842a96f2c20986c7a779ef721df3ba4e4540f449d76 \
        "$@"
    }

`--user` and `--userns=keep-id` are required. The image runs as user 65534,
which cannot read a `0600` kubeconfig.

## 2. Pre-flight — receipt

    flux version --client
    flux check --pre

The check must end with `✔ prerequisites checks passed`.

## 3. Create the repo

In the GitHub web UI, create **`faulty-technology/homelab`**:

- Visibility: **Private**.
- Initialize with a README, so `main` exists.

## 4. Create a short-lived token

Go to GitHub → Settings → Developer settings → **Fine-grained tokens** →
Generate new token:

| Field | Value |
|---|---|
| Expiration | 7 days |
| Repository access | Only select repositories → `homelab` |
| Administration | Read and write |
| Contents | Read and write |
| Metadata | Read-only |

`Administration: Read and write` is what lets bootstrap register the deploy key.

## 5. Bootstrap — receipt

Export the token in your own shell; don't paste it into anything else. Then
run:

    read -rs GITHUB_TOKEN && export GITHUB_TOKEN
    flux bootstrap github \
      --token-auth=false \
      --read-write-key=false \
      --owner=faulty-technology \
      --personal \
      --repository=homelab \
      --private=true \
      --branch=main \
      --path=clusters/nuc \
      2>&1 | tee ~/flux-bootstrap.log
    unset GITHUB_TOKEN

The log must end with `✔ all components are healthy`. It also shows the two
commits bootstrap pushed (components, then sync) and the deploy key it added.

## 6. Verify — receipt

    flux check
    flux get sources git -A
    flux get kustomizations -A
    kubectl --kubeconfig ~/.kube/nuc.yaml -n flux-system get pods

What to expect:

- Every controller is `✔` healthy.
- `GitRepository/flux-system` is Ready, at revision `main@sha1:<bootstrap commit>`.
- `Kustomization/flux-system` is Ready, at the same revision.

Compare the cluster's deploy key with the one GitHub shows under the repo's
Settings → Deploy keys:

    kubectl --kubeconfig ~/.kube/nuc.yaml -n flux-system get secret flux-system \
      -o jsonpath='{.data.identity\.pub}' | base64 -d | ssh-keygen -lf -

The fingerprints must match. The GitHub key must show **read-only**.

## 7. Revoke the token

On the fine-grained tokens page, delete the token now. Flux does not need it
again: the deploy key does the pulling.

## Roll back

    flux uninstall --namespace=flux-system

Then:

- Delete the deploy key under the repo's Settings → Deploy keys.
- Delete `clusters/nuc/` from the repo.

Anything else Flux deployed stays running until you delete it.

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
