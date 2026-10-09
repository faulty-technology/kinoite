---
date: 2026-10-08
subject: First scheduled velero-daily on nuc. 02:30 EDT, Completed, drill volume included
harness: none. velero CLI v1.18.4 and kubectl v1.36.4 from pinned containers on the laptop, read-only.
box: kinoite-nuc, Velero v1.18.4, schedule velero-daily "CRON_TZ=America/New_York 30 2 * * *", ttl 336h
---

# First scheduled daily backup

This closes "the first scheduled daily" from
[2026-10-07-nuc-velero-restore-drill](2026-10-07-nuc-velero-restore-drill.md).

    velero-daily-20261008063018   Completed   0 errors   0 warnings
    created 2026-10-08 06:30:18 UTC (= 02:30:18 EDT)   expires 13d   location default

- **Schedule timing.** It fired at local 02:30, so `CRON_TZ=America/New_York`
  works as intended.
- **The drill volume was included.** PodVolumeBackups:
  `backup-drill/data` Completed with 58784 bytes, the same as the manual
  drill backup.
- **Flux's own volumes were also backed up.** Those were `flux-system/data`
  (396028 bytes, the source-controller artifact cache) and several empty
  `temp`/`tmp` volumes. All of it is regenerated from git, so backing it up is
  harmless but useless.
- **Storage location.** Still `Available` at 2026-10-08 22:53 UTC.

Not verified: the weekly schedule, whose first run is Sunday 2026-10-11 03:00
EDT, and a real app's volume.
