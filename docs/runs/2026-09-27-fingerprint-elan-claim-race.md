---
date: 2026-09-27
subject: fingerprint reader follow-up — Elan MOC sensor, fprintd aborts, D-Bus claim race; supersedes the missing-driver verdict of 2026-09-27-fingerprint-reader-diagnosis
harness: none (diagnosis) — commands run by hand on the box: loginctl, systemctl show fprintd, journalctl -u fprintd, busctl list/status + ps mapping
box: kinoite (laptop)
---

# Fingerprint reader: claim race + fprintd aborts (supersedes the driver-gap verdict)

Supersedes [2026-09-27-fingerprint-reader-diagnosis](2026-09-27-fingerprint-reader-diagnosis.md),
whose "no driver present" conclusion was based on a single broken boot and is
contradicted by later evidence. The pipeline-audit portion of that entry
(non-north build touches nothing biometric) still stands.

## What changed the picture

Enrollment succeeded at some point (the profile persists — the login screen
"sees" the added fingerprint), and the failure mode is fprintd's
**"Device already in use by another user"** — a device-ownership collision,
not an absent driver. The sensor is seen; the fight is over who holds it.

## Findings (all measured on the box, 2026-09-27)

- The sensor is an **Elan MOC** (fprintd device name), **not Goodix** — the
  `goodix_fp` / GXFP5130 watch items from the first entry are moot.
- **fprintd ABRT crashes: 3 in 7 days** (`journalctl -u fprintd --since "7
  days ago" | grep -c code=dumped`); the same daemon logged
  `fpi_ssm_mark_failed: assertion 'machine != NULL' failed`. Current instance:
  `NRestarts=0`, `ActiveState=active`. Stack traces show glib main-loop
  threads at abort.
- **The claim race, verbatim:**
  `Authorization denied to :1.188 to call method 'Claim' for device 'Elan MOC
  Sensors': Device was already claimed`. Timing: fprintd respawned 13:11:50,
  denial at 13:11:59 — something re-grabbed the claim within seconds of the
  respawn. The holder's subsequent `DeleteEnrolledFinger` rejection
  (`Not Authorized: net.reactivated.fprint.device.enroll`) was the user
  cancelling their own auth prompt — self-inflicted, not a bug.
- **`sudo systemctl restart fprintd` + the claim dropping freed the device** —
  the stale-claim mechanism is confirmed as the blocker.
- Linger is **off** (`Linger=no`; no `kinoite-linger.service` in the base
  image) — the lingering-session theory is dead.
- Full D-Bus client roster captured (`busctl list --no-legend` + PID→process
  mapping). Biometric-capable clients: **plasmalogin** (`:1.37`),
  **1password** (`:1.123/.127/.129/.136`, four live connections),
  **polkit-kde-auth** (`:1.187/.199`), fprintd itself (`:1.186`). No kwallet
  on the system bus.

## Verdict

Not a pipeline defect (audit unchanged). It is an interaction problem:
intermittent Elan MOC enumeration + recurring fprintd aborts + competing
D-Bus claimants. **Prime suspect for the competing claim (unconfirmed):**
1Password — this build writes the polkit `AUTH_SELF` rule specifically so
1Password can do fingerprint unlock, and 1Password is a live D-Bus client in
the user session.

## Confirmation protocol (pending)

1. Quit 1Password; exercise login-screen scan plus repeated in-session auth.
   Collisions stopping would confirm the suspect.
2. On the next collision: read the denied connection id from
   `journalctl -u fprintd`, map it to its process with the busctl/ps roster.

## Watch list (updated, replaces the first entry's)

1. **fprintd / libfprint package updates** (currently `1.94.5-5.fc44` /
   `1.94.100-1.fc44`) — both the ABRT and the claim logic live there.
2. **Identity of the second claimant** — if 1Password, the fix is
   pipeline-side (scope the polkit rule, disable the probe, or a drop-in).
3. Base-image updates remain relevant for the intermittent-enumeration half.
