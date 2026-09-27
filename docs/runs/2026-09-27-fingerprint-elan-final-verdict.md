---
date: 2026-09-27
subject: fingerprint reader final verdict — two stacked upstream fprintd/libfprint defects on the Elan MOC sensor; 1Password theory refuted
harness: none (diagnosis, continuation) — commands run by hand on the box: systemctl restart fprintd, sudo ls (biometric PAM prompt), busctl status, ps
box: kinoite (laptop)
---

# Fingerprint reader: final verdict

Closes out [2026-09-27-fingerprint-elan-claim-race](2026-09-27-fingerprint-elan-claim-race.md)
and, through it,
[2026-09-27-fingerprint-reader-diagnosis](2026-09-27-fingerprint-reader-diagnosis.md).
The pipeline-audit portion (non-north build touches nothing biometric) stands
unchanged: **the build is exonerated**.

## The 1Password suspect is refuted

With 1Password quit, collisions continued immediately. Mapping the colliding
D-Bus connections (`:1.276`, `:1.293`, `:1.298`) showed all were transient
children of the user manager — `:1.293` was PID 23613, **`systemsettings`**,
i.e. the operator's own GUI test attempts. No third-party claimer exists in
the picture; 1Password was a red herring.

## Verdict: two stacked upstream defects, both fprintd/libfprint-side

**Defect 1 — verification never matches (root).** Clean protocol:
`sudo systemctl restart fprintd`, ~30s settle, a single `sudo ls` attempt
(biometric PAM prompt: "Place your right index finger on the fingerprint
reader"). Result: the prompt engages, the sensor reads, but verification
never matches — repeated attempts end in `Verification timed out` and
fallback to password. No claim error involved; a fresh daemon with an empty
claim state cannot verify at all on this build.

**Defect 2 — claims not released after failed/interrupted operations
(why recovery needs a restart).** Failed or interrupted attempts leave the
device claim held; the next attempt then gets
`Authorization denied ... 'Claim' for device 'Elan MOC Sensors': Device was
already claimed` → UI "Device already in use by another user".
`sudo systemctl restart fprintd` frees it (confirmed twice).

**Supporting evidence (measured 2026-09-27):**

- fprintd ABRT crashes: 3 in 7 days; `NRestarts=0` on the current instance.
- `fpi_ssm_mark_failed: assertion 'machine != NULL' failed` fires ~1s after
  *every* fprintd start (the on-start probe hits the libfprint assertion).
- Linger off (`Linger=no`); no `kinoite-linger.service` in the base image.
- Full D-Bus roster captured; biometric-capable clients are plasmalogin,
  polkit-kde-auth, fprintd, and the operator's own test tools only.
- Stack: kernel `7.2.7-200.fc44.x86_64`, fprintd `1.94.5-5.fc44`,
  libfprint `1.94.100-1.fc44`; hardware Dell 14 Plus 2-in-1 DB04250,
  sensor reported by fprintd as "Elan MOC Sensors".

## Unverified (labelled)

The delete-and-re-enroll probe was not run; it would split defect 1 into
template drift across enumerations vs a driver-level read failure. Either
sub-cause stays inside the same upstream domain.

## Watch list (final)

1. **fprintd / libfprint package updates** (`1.94.5-5.fc44` /
   `1.94.100-1.fc44`) — both defects live there; re-test after each update
   with the clean protocol above.
2. **Kernel updates** — the sensor-driver half of defect 1, lower priority.

**Bug-report material** (if filing upstream): Elan MOC sensor + the
`fpi_ssm_mark_failed` assertion-on-start + non-released claims after failed
verification + the journal excerpts from 2026-09-27 13:11–13:46.
