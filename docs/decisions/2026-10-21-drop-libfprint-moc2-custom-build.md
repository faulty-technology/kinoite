---
type: Decision
date: 2026-10-21
subject: the custom libfprint-moc2 build chain is removed from the base image; stock floating libfprint returns
---

# The custom libfprint-moc2 RPM is dropped

## Decision

The entire custom `libfprint` build chain is removed from the base (laptop)
image, which now keeps Fedora's stock floating `libfprint`. Removed: the
"Build libfprint-moc2 RPM" step in `.github/workflows/build.yml`,
`scripts/build-libfprint-moc2-rpm.sh`,
`scripts/patches/elanmoc2-bounded-retry-wait.patch`,
`build_files/scripts/libfprint-moc2.sh`, and its call from
`build_files/profiles/base/build.sh`. Nothing else changed.

## Why

The custom RPM put the box in a worse place than no reader at all (operator
report, unverified by this repo): the fingerprint touch was accepted but never
properly read — the enroll hang the bounded-retry patch targeted still surfaced
— and 1Password could no longer be unlocked with the local password. The
displaced-build regression broke the password fallback path, which is worse
than a non-functional reader: a broken authentication path beats a missing
feature.

The chain existed because of two stacked upstream `fprintd`/`libfprint` defects
on the Elan MOC sensor (USB `04f3:0c99`), documented in
[runs/2026-09-27-fingerprint-reader-diagnosis](../runs/2026-09-27-fingerprint-reader-diagnosis.md),
[runs/2026-09-27-fingerprint-elan-0c99-identity](../runs/2026-09-27-fingerprint-elan-0c99-identity.md),
[runs/2026-09-27-fingerprint-elan-claim-race](../runs/2026-09-27-fingerprint-elan-claim-race.md) and
[runs/2026-09-27-fingerprint-elan-final-verdict](../runs/2026-09-27-fingerprint-elan-final-verdict.md).
Those records stand as history; this decision supersedes their "package as a
local RPM" next step.

Alternatives rejected:

- **Keep the custom RPM and patch it further.** It regressed the password
  fallback (1Password unlock), so iterating on the driver does not fix the worst
  symptom — the broken fallback stays broken until the displaced build is gone.
- **Binary-patch `libfprint-2.so` in the image.** Already rejected in
  [runs/2026-09-27-fingerprint-elan-0c99-identity](../runs/2026-09-27-fingerprint-elan-0c99-identity.md):
  a raw `/usr/lib` patch does not survive base updates.
- **File the upstream Fedora patch and wait on it.** That is the durable path,
  but it does not unblock the box now; stock floating `libfprint` stays until
  it lands.

## What this does not settle

**The reader still does not work on stock `libfprint`.** The upstream driver
gap stands; re-test after each `fprintd`/`libfprint` update with the clean
protocol in [runs/2026-09-27-fingerprint-elan-final-verdict](../runs/2026-09-27-fingerprint-elan-final-verdict.md)
(restart `fprintd` → 30 s → one `sudo ls`).

**Why the displaced build broke 1Password's local-password unlock is not
diagnosed.** The operator report names the symptom, not the mechanism; if it
returns with a future custom build, that is the first thing to trace.

## Revert

Restore the chain from git history at the pre-removal commit: the CI step,
`scripts/build-libfprint-moc2-rpm.sh`, the patch, `build_files/scripts/libfprint-moc2.sh`,
and the call in `build_files/profiles/base/build.sh`.
