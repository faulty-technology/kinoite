---
date: 2026-10-11
subject: First automatic bootc update (Sun 04:00 EDT) and first weekly Velero backup on nuc
harness: none. journalctl, rpm-ostree status and findmnt over SSH, plus velero CLI v1.18.4 and kubectl v1.36.4 from pinned containers on the laptop. All read-only, at 12:48 EDT.
box: kinoite-nuc. bootc-fetch-apply-updates with UPDATE_POLICY=apply (OnCalendar "Sun *-*-* 04:00:00", RandomizedDelaySec=0, America/New_York)
---

# First automatic update and first weekly backup

## Automatic update (EDT)

    04:00:04  bootc-fetch-apply-updates.timer fired (no random delay)
    04:00:30  bootc: "Queued for next boot … kinoite-nuc:latest
              Version: latest.20261010155255  Digest: sha256:634f2952…"
              "Total new layers: 66 Size: 1.2 GB / Added layers: 25 Size: 676.2 MB"
    04:00:30  bootc-fetch-apply-updates.service: killed, status=15/TERM,
              "Failed with result 'signal'"
    04:01:25  booted

`rpm-ostree status` afterwards:

- The booted deployment is `ostree-image-signed:docker://…kinoite-nuc:latest`,
  `latest.20261010155255`.
- The previous deployment, `latest.20261006165929`, is kept for rollback.

The "Failed with result 'signal'" is `--apply` rebooting the machine while its
own unit is still active, so systemd stops the unit at shutdown. The update
had already been queued and the new image booted. Expect this state every
week; it isn't a fault.

## State after the reboot (12:48 EDT)

- Both NFS mounts are up, and k3s is active.
- Node `nuc` is Ready.
- The Kustomizations `flux-system` and `intel-gpu-plugin` are Ready, and the
  `velero` HelmRelease is Ready.
- `intel-gpu-plugin` is Running (it restarted with the boot), and
  `gpu.intel.com/i915=4`. So the `k3s_device_plugin` SELinux module carried
  over into the new image.
- `velero` and `node-agent` are Running, and the BSL is Available.
- `backup-drill` is Running.

## Backups

- `velero-weekly-20261011070022`: created 07:00:22 UTC (03:00 EDT),
  **Completed**, 0 errors, 0 warnings, expires in 89 days.
- `velero-daily-20261009063020`, `…20261010063021` and `…20261011063022`:
  all Completed at 02:30 EDT with 0 errors. That's four consecutive dailies,
  counting 2026-10-08.
- The kopia repository maintenance jobs for `backup-drill` and `flux-system`
  ran about hourly and all Completed.

Not covered here: removing `flux-system` from the schedules. That homelab
change was not yet pushed at the time of this check.
