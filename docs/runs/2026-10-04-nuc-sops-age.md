---
date: 2026-10-04
subject: SOPS with one age key on nuc. Flux decrypts, canary verified
harness: none. Commands are the one-time setup in how-to/manage-secrets-with-sops-on-nuc.md, run by hand from the laptop. Tools — sops ghcr.io/getsops/sops@sha256:0d10ea06e9c02d88ff017c4d9b3edb1c46bed8d8a6ade6b576c26bebe5fb3a2b (v3.13.3), age 1.3.1-4.fc44 in quay.io/fedora/fedora:44, flux-cli v2.9.6 and kubectl v1.36.4 as in runs/2026-10-04-nuc-flux-github-app
box: kinoite-nuc (NUC12WSKi7), k3s v1.36.5+k3s1, Flux v2.9.6
---

# SOPS + age on nuc

Why SOPS and not External Secrets:
[decisions/2026-10-04-sops-age-for-flux-secrets](../decisions/2026-10-04-sops-age-for-flux-secrets.md).

## What was run

1. **Generate the key.** `age-keygen -o ~/.config/sops/age/keys.txt` ran in a
   throwaway Fedora container. The private key went only to that file (mode
   `600`, 184 bytes) and was never printed.
   - Public key: `age1mpdgesuzfqz57u9tcudut3w2l34jp0p42mejeull5hxealzpd3kscwccju`.
2. **Give it to Flux.** `kubectl -n flux-system create secret generic sops-age
   --from-file=age.agekey=…`.
3. **Configure sops and Flux.** homelab `f49a32d` added `.sops.yaml`
   (`path_regex: clusters/.*\.ya?ml$`, `encrypted_regex: ^(data|stringData)$`)
   and a `decryption: {provider: sops, secretRef: {name: sops-age}}` block in
   the `flux-system` Kustomization.
4. **Canary.** homelab `5238c61` added `clusters/nuc/sops-canary.yaml`, a
   Secret whose value `sops-ok-2026-10-04` was encrypted with
   `sops --encrypt --in-place` before the commit.

## Results

Secret, 15:25:02Z: `secret/sops-age created`. It has one key, `age.agekey`.

Decryption config, 15:25:21Z:

    ✔ applied revision main@sha1:f49a32d2d793b165e04a4aa0157164874d1507bf
    Kustomization flux-system  Ready  Applied revision: main@sha1:f49a32d2
    live spec.decryption: {"provider":"sops","secretRef":{"name":"sops-age"}}

Canary encryption, 15:25:38Z, `sops 3.13.3`:

    ENC count: 2              (the value + the sops MAC)
    plaintext count: 0        (grep for 'sops-ok' in the committed file)
    unencrypted Secret files under clusters/: none

Canary decryption, 15:26:00Z:

    ✔ applied revision main@sha1:5238c61582025710fff01195f807928ee6b60b4d
    Kustomization flux-system  Ready  Applied revision: main@sha1:5238c615
    decrypted canary: sops-ok-2026-10-04
    labels: kustomize.toolkit.fluxcd.io/name=flux-system, namespace=flux-system

## What it means

The chain works end to end. Git holds only ciphertext. kustomize-controller
decrypts it with `sops-age` at apply time, and the Secret it creates holds the
original value under Flux ownership. The canary stays in the repo as a standing
check.

Not verified here: that `~/.config/sops/age/keys.txt` was saved to 1Password.
That is an operator step. Until it is done, the laptop file and the cluster
Secret are the only copies.
