---
date: 2026-10-06
subject: Unraid NFS mounts on nuc over the tailnet. Export rule, NFS rebind, boot ordering
harness: none — commands run by hand. bash /dev/tcp probes and findmnt/systemctl over SSH from the laptop; a manual mount test run by the operator on the NUC.
box: kinoite-nuc (NUC12WSKi7) → Unraid "NUCi7" (tailnet 100.77.22.80, LAN 192.168.200.46)
---

# NFS over the tailnet

Why the tailnet and not the LAN:
[decisions/2026-10-06-nfs-over-tailnet](../decisions/2026-10-06-nfs-over-tailnet.md).

## Identifying the server

The tailnet device `NUCi7` (`100.77.22.80`, `tag:server`) is the Unraid box.
Its web UI title is `NUCi7/Login`. A `tailscale ping` from the NUC went
direct, via `192.168.200.46`, in 1 ms.

## Port 2049 refused on the tailnet

TCP probes from the NUC, 2026-10-04/06:

    192.168.200.46:2049  open        100.77.22.80:2049  Connection refused (~12 ms)
    192.168.200.46:111   open        100.77.22.80:111   open

The refusal was immediate, the same as for an unused port (2050), and rpcbind
answered on the tailnet. So this was nfsd not listening on the tailnet
address, rather than a Tailscale ACL drop.

1. **Export rule.** The shares are Private. The operator appended
   `100.109.124.15(sec=sys,rw,no_subtree_check,all_squash,anonuid=99,anongid=100)`
   to the rules of `arrdata` and `appdata`. Re-probed at 16:14:02Z: 2049 still
   refused. The rule is required for the mount, but it isn't what was refusing
   the port.
2. **NFS rebind.** `tailscale1` was already in Settings → Network Settings →
   Include listening interfaces. The operator toggled Settings → NFS off and on.
   Re-probed at 16:16:23Z: `100.77.22.80:2049 open`.

Cause: since 6.12, Unraid services bind to the specific IPs of their listening
interfaces when they start
([unraid/webgui#1567](https://github.com/unraid/webgui/issues/1567)). The
Tailscale plugin was installed while Unraid was running, after nfsd had
started, so `tailscale1`'s address didn't exist when nfsd bound.

## Manual mount test

The operator ran this on the NUC with
`mount -t nfs -o nfsvers=4.2 100.77.22.80:/mnt/user/<share>`:

    100.77.22.80:/mnt/user/arrdata nfs4 rw,relatime,vers=4.2,rsize=1048576,wsize=1048576,namlen=255,hard,...
    100.77.22.80:/mnt/user/appdata nfs4 rw,relatime,vers=4.2,rsize=1048576,wsize=1048576,namlen=255,hard,...

A test file written as root on each share came out `nobody:users 99:100`, so
`all_squash` maps every write to the ownership the apps will run as. The file
was then removed.

## Baked and booted

kinoite `9b0fb1e` set `UNRAID_HOST=100.77.22.80`,
`MEDIA_EXPORT=/mnt/user/arrdata` and `FAST_EXPORT=/mnt/user/appdata`. The mount
units order after `tailscale-online.target`. The same commit added the
America/New_York timezone in `host.sh`.

The NUC booted 2026-10-06 12:35:26 EDT into
`kinoite-nuc:latest.20261006163051` (`sha256:a15007ed…`).

    100.77.22.80:/mnt/user/appdata /var/mnt/unraid/fast  rw,noatime,vers=4.2,rsize=1048576,wsize=1048576,hard,...
    100.77.22.80:/mnt/user/arrdata /var/mnt/unraid/media rw,noatime,vers=4.2,rsize=1048576,wsize=1048576,hard,...

Activation times, seconds after boot (`ActiveEnterTimestampMonotonic`):

    tailscaled.service             5.72
    tailscale-wait-online.service 15.05
    var-mnt-unraid-media.mount    15.37
    var-mnt-unraid-fast.mount     15.39
    k3s.service                   23.04

`tailscaled` reported ready 9.3 s before the tailnet address existed. Mounts
ordered on `tailscaled.service` alone would have fired that early.

After the boot:

- Time zone: `America/New_York (EDT, -0400)`.
- Next update run: `Sun 2026-10-11 04:00:00 EDT`.
- Cluster: node Ready, `flux-system=True`, `intel-gpu-plugin=True`, GPU
  plugin Running, `gpu.intel.com/i915=4`.

## Not verified

- **k3s starting with Unraid unreachable.** The units are `Wants=`, not
  `Requires=`, but that hasn't been exercised.
- **NFS listening on the tailnet after an Unraid reboot.** The array is
  started by hand, normally well after the Tailscale plugin is up. It is
  untested.
- **A pod reading through these mounts.** That comes with the first app.
