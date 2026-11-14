---
type: Run
date: 2026-11-14
subject: nuc boot. Unraid NFS mounts time out right after tailscale-online.target, while CSI NFS to the same server succeeds 16 s later
harness: none. The NUC's journal was read from Loki (`{service_namespace="nuc"}`, shipped by alloy.service) over the tailnet from the laptop.
box: kinoite-nuc (image with kinoite f5f66e3) → Unraid "NUCi7" 100.77.22.80
---

# Boot race: Unraid mounts vs the tailnet path

The mount units are `Wants=`/`After=` `tailscale-online.target`, with
`TimeoutSec=30` and `hard`. Unraid was up the whole time.

## Timeline (EST, from the NUC's journal)

Boot at 12:38, image before f5f66e3:

    12:38:52  tailscale-online.target reached
    12:38:52  both mounts: Mounted

Boot at 12:58, image with f5f66e3:

    12:58:44  boot
    12:59:01  tailscale-online.target reached; both mounts start
    12:59:31  both mounts: "Mounting timed out. Terminating." → failed
    12:59:47  k3s CSI: MountDevice succeeded for the rag PVCs on
              100.77.22.80:/mnt/user/k8s

The shares were then mounted again; the journal record of that step was not read.

## What it means

Reaching `tailscale-online.target` does not mean the path to Unraid carries
NFS traffic yet. One boot got there at once. The next had a path that wasn't
ready, for somewhere between 30 and 46 s after the target. Two boots are not
enough for a rate.

With the units as they were, a slow path left the mounts failed until
`kinoite-nfs-retry.timer` ran 5 minutes after boot. The fix is
`kinoite-nfs-wait.service`, which holds both mounts until 100.77.22.80:2049
accepts a TCP connection, for up to 90 s. It is unverified on the NUC.
