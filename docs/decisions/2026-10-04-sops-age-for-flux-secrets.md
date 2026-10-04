---
date: 2026-10-04
subject: secrets for the nuc cluster are SOPS-encrypted in homelab with one age key; External Secrets + 1Password deferred, not rejected
---

# SOPS + age for Flux secrets

## Decision

Secrets for `nuc` are committed to `faulty-technology/homelab` encrypted with
SOPS against one age key. Only the `data` and `stringData` values are
encrypted. kustomize-controller decrypts them with the Secret
`flux-system/sops-age`. The private key is also kept in 1Password.

## Why

Flux decrypts SOPS natively, so the cluster gains no new components. The
expected secrets are few, for example a Plex claim token, VPN credentials and a
tunnel token. The *arr API keys live in each app's own config. Encrypted
values also keep the option of making homelab public later.

## Alternatives

- **External Secrets Operator with 1Password.** Deferred, not rejected. Git
  would hold no secret material at all, and rotation would happen in
  1Password. It costs an operator in the cluster plus a 1Password
  service-account token, and it can't sync anything new while 1Password is
  unreachable. Revisit it if the secret count grows or rotation becomes a chore.
  The two can run side by side: a Secret created by ESO and one decrypted by
  SOPS are both just Secrets to the apps that use them.
- **Sealed Secrets.** Rejected. Its key pair is generated inside the cluster,
  so rebuilding the cluster means backing up and restoring the controller key.
  With SOPS, that key is the one already kept in 1Password.
- **One age key per environment.** Rejected for now: there is one cluster.

## Cost

- If the age key leaks, everything ever committed can be decrypted, including
  git history. Recovery means rotating the secrets, not just the key.
- Secret names, namespaces and key names stay readable in git.
