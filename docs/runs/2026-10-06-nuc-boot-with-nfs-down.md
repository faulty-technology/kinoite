---
date: 2026-10-06
subject: nuc reboot with Unraid NFS off. k3s comes up, mounts fail and stay failed
harness: none. Unraid Settings → NFS was turned off by the operator, then the NUC was rebooted. Afterwards journalctl, systemd-analyze and findmnt were read over SSH from the laptop.
box: kinoite-nuc (image latest.20261006163051, kinoite 9b0fb1e) → Unraid "NUCi7" 100.77.22.80
---

# Boot with NFS down

This closes the open item "k3s starting with Unraid unreachable" from
[2026-10-06-nuc-nfs-over-tailnet](2026-10-06-nuc-nfs-over-tailnet.md). The
mount units are `Wants=`/`After=` only, with `TimeoutSec=30` and `hard`.

## Timeline (EDT, from the NUC's journal)

    12:44:25  reboot requested
    12:44:27  media unmounted cleanly; fast unmount hangs (server gone, hard mount)
    12:44:57  fast: "Unmounting timed out. Terminating." (30 s)
    12:44:58  shutdown complete
    12:45:07  boot; sshd active at +5.2 s
    12:45:55  both mounts: "Mounting timed out. Terminating." → failed
              remote-fs.target reached at +44.96 s
    12:46:00  k3s.service active; multi-user.target at +52.6 s userspace
              (systemd-analyze: 1min 5.126s total)

`systemd-analyze critical-chain multi-user.target`:
`k3s.service @44.965s +7.649s` ← `remote-fs.target @44.962s`. k3s waited for
the mounts to fail and started anyway.

## Recovery

NFS was turned back on in Unraid. Both units stayed `failed` from 12:45:55
until the operator ran
`sudo systemctl start var-mnt-unraid-media.mount var-mnt-unraid-fast.mount` at
12:48:00. Both mounted that same second. At 12:48:10, `findmnt -t nfs4` listed
both and `100.77.22.80:2049` was open.

## What it means

- **k3s does not depend on the NAS.** An outage costs about 30 s on shutdown
  (the unmount timeout) and about 30 s on boot (the mount timeout).
- **Failed mounts are never retried.** After an outage that spans a NUC boot,
  the media paths stay unmounted until someone starts the units or the NUC
  reboots. Pods reading `hostPath` media are down for that whole time.

Not covered: an outage *while* the NUC is running with the mounts attached.
Under `hard`, I/O blocks until the server returns. That is the intended
behaviour, but untested.
