---
date: 2026-10-06
subject: kinoite-nfs-retry.timer remounts NFS after a boot-time NAS outage, no operator action
harness: none. Unraid Settings → NFS was turned off by the operator, the NUC rebooted, and NFS was turned back on. The NUC's state and journal were then read over SSH from the laptop, with no manual mount start.
box: kinoite-nuc image latest.20261006165929 (kinoite 82b5a69) → Unraid "NUCi7" 100.77.22.80
---

# NFS retry timer

Fixes the "failed mounts are never retried" finding in
[2026-10-06-nuc-boot-with-nfs-down](2026-10-06-nuc-boot-with-nfs-down.md).

kinoite `82b5a69` (in `profiles/nuc/nfs.sh`) adds:

- `kinoite-nfs-retry.timer`: `OnBootSec=5min`, `OnUnitActiveSec=5min`.
- `kinoite-nfs-retry.service`: runs `/usr/libexec/kinoite-nfs-retry`, which
  `systemctl start`s each unit in `/usr/share/kinoite/nfs-units` whose state
  is **failed**. It leaves inactive (deliberately stopped) and active units
  alone.

Before shipping, the script was tested in the built image with a stand-in
`systemctl` reporting one unit failed, one active and one inactive. It started
only the failed one and exited 0.

## Timeline (EDT)

    13:43:12  NUC boots on latest.20261006165929, NFS off on Unraid
    13:44:01  both mounts: "Failed with result 'timeout'"
    13:44:14  timer enabled, next run 13:48:12; both mounts failed
    13:44:57  NFS back on: 100.77.22.80:2049 open; mounts still failed
    13:48:35  kinoite-nfs-retry: "retrying var-mnt-unraid-media.mount",
              "retrying var-mnt-unraid-fast.mount"; both "Mounted" the same
              second; service "Deactivated successfully"
    13:49:04  both units active; findmnt lists both nfs4 mounts; both
              directories readable

The journal for this boot shows no `sudo systemctl start var-mnt…`. The
remount was the timer alone. It fired 23 s after its scheduled 13:48:12
because of systemd's default `AccuracySec=1min`.

## What it means

After a NAS outage that spans a NUC boot, the media paths come back within
about 5 minutes of NFS returning, with nothing for the operator to do. The
worst case is one timer interval plus up to 1 min of timer slack.

Still not covered: an outage *while* the mounts are attached. Under `hard`,
I/O blocks until the server returns, and the units never fail, so the timer
doesn't come into it. That is untested.
