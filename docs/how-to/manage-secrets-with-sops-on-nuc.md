# Manage secrets with SOPS on the NUC

Secrets live in the homelab repo encrypted with SOPS against one age key. Flux's
kustomize-controller decrypts them at apply time with the private key in Secret
`flux-system/sops-age`. Only the `data` and `stringData` values are encrypted.
Names, namespaces and key names stay readable.

Where each piece lives:

| Piece | Location |
|---|---|
| Public key | `.sops.yaml` in homelab. Encrypting needs nothing else. |
| Private key | 1Password, the `flux-system/sops-age` Secret, and `~/.config/sops/age/keys.txt` on the laptop. Only reading or editing an existing secret needs it. |

Steps marked **receipt** feed the run record in `docs/runs/`.

## Tools

All run from pinned containers. Nothing is installed.

    # sops v3.13.3. Run from inside ~/Source/homelab.
    sops() {
      podman run --rm -i --userns=keep-id --user "$(id -u):$(id -g)" \
        -v "$HOME/Source/homelab":/homelab:Z -w /homelab \
        -v "$HOME/.config/sops/age/keys.txt":/keys.txt:ro,Z -e SOPS_AGE_KEY_FILE=/keys.txt \
        ghcr.io/getsops/sops@sha256:0d10ea06e9c02d88ff017c4d9b3edb1c46bed8d8a6ade6b576c26bebe5fb3a2b \
        "$@"
    }

    # flux-cli v2.9.6 and kubectl v1.36.4, for the one-time setup checks below
    flux() {
      podman run --rm -i --network host --userns=keep-id --user "$(id -u):$(id -g)" \
        -v "$HOME/.kube/nuc.yaml":/kubeconfig:ro,z -e KUBECONFIG=/kubeconfig \
        ghcr.io/fluxcd/flux-cli@sha256:b1ac18156f227af9a524b842a96f2c20986c7a779ef721df3ba4e4540f449d76 "$@"
    }
    kubectl() {
      podman run --rm -i --network host --userns=keep-id --user "$(id -u):$(id -g)" \
        -v "$HOME/.kube/nuc.yaml":/kubeconfig:ro,z -e KUBECONFIG=/kubeconfig \
        registry.k8s.io/kubectl@sha256:484eff4657707d5ba697035d45b38fd00883c60c1b764f618af708db95cd3a2d "$@"
    }

## Encrypt a new secret

1. Write the Secret manifest under `clusters/nuc/`, with values in `stringData`.
2. Encrypt it in place:

       sops --encrypt --in-place clusters/nuc/<path>/secret.yaml

3. Before committing, check that no plaintext is left. Any filename this prints
   is **not** encrypted:

       grep -rL 'ENC\[' $(grep -rl '^kind: Secret' clusters/)

4. Commit and push. Flux applies it decrypted.

## Edit an existing secret

    sops clusters/nuc/<path>/secret.yaml        # opens decrypted in $EDITOR, re-encrypts on save

## One-time setup

These were done on 2026-10-04 and are only needed again to rebuild from
scratch.

### 1. Generate the key

    install -d -m 700 ~/.config/sops/age
    podman run --rm -v "$HOME/.config/sops/age":/out:Z quay.io/fedora/fedora:44 \
      bash -c 'dnf -q -y install age >/dev/null && age-keygen -o /out/keys.txt'
    chmod 600 ~/.config/sops/age/keys.txt

It prints `Public key: age1…`.

Save the file `~/.config/sops/age/keys.txt` to 1Password. To restore after a
wipe, put it back at that path with mode `0600`.

### 2. Give the key to Flux

Attach `keys.txt` to the 1Password item that `scripts/bootstrap.sh` reads
(`OP_AGE_KEY_REF`), then run the script. It creates `flux-system/sops-age`
from it ([bootstrap-flux-on-nuc](bootstrap-flux-on-nuc.md)).

### 3. Tell sops and Flux — receipt

`.sops.yaml` at the homelab root:

    creation_rules:
      - path_regex: clusters/.*\.ya?ml$
        encrypted_regex: ^(data|stringData)$
        age: <public key>

In `clusters/nuc/flux-system/gotk-sync.yaml`, add this to the `Kustomization`
spec:

    decryption:
      provider: sops
      secretRef:
        name: sops-age

Commit, push, then:

    flux reconcile kustomization flux-system --with-source
    flux get kustomizations -A

The Kustomization must be Ready at the new revision.

### 4. Prove decryption with a canary — receipt

`clusters/nuc/sops-canary.yaml` is a Secret in `flux-system` with a
non-sensitive value. It stays in the repo as a standing check that decryption
works.

    sops --encrypt --in-place clusters/nuc/sops-canary.yaml
    grep -c 'ENC\[' clusters/nuc/sops-canary.yaml        # must be ≥ 1
    grep -c 'sops-ok' clusters/nuc/sops-canary.yaml      # must be 0

Commit, push, then:

    flux reconcile kustomization flux-system --with-source
    kubectl -n flux-system get secret sops-canary -o jsonpath='{.data.canary}' | base64 -d; echo

The output must be the plaintext value that was encrypted.

## If the private key leaks

Generate a new key and update `.sops.yaml`. Re-encrypt every secret with
`sops updatekeys`, then replace the `sops-age` Secret. Then **rotate the
secrets themselves**: every version still in git history can be decrypted with
the old key.
