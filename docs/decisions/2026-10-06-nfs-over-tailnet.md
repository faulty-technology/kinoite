---
date: 2026-10-06
subject: the NUC mounts Unraid NFS over the tailnet (100.x), not the LAN
---

# NFS over the tailnet

## Decision

`nfs.sh` mounts Unraid at its Tailscale IP, `100.77.22.80`, ordered after
`tailscale-online.target`. Access is governed by a Tailscale ACL rule (NUC →
Unraid, tcp:2049) plus a per-host Unraid export rule for the NUC's tailnet IP.
The address is an IP rather than a MagicDNS name, so a mount never waits on DNS
at boot.

## Why

Access control lives in one place, the tailnet policy, and traffic is
encrypted. The mounts also keep working if either box moves off the
`192.168.200.0/24` LAN.

## Alternatives rejected

- **LAN address (`192.168.200.46`).** This was the original design. It skips
  WireGuard overhead, but access then depends on the Unraid export rule and
  LAN topology alone. Tailscale went direct between the two boxes (1 ms, via
  the LAN), so the overhead is CPU, not an extra hop.

## Cost

- **Boot depends on Tailscale.** If Tailscale is down, the mounts fail. k3s is
  ordered after them but doesn't require them.
- **Unraid's nfsd must start after `tailscale1` has its address.** Unraid binds
  services to interface IPs when they start
  ([runs/2026-10-06-nuc-nfs-over-tailnet.md](../runs/2026-10-06-nuc-nfs-over-tailnet.md)).
  With manual array start this holds in practice. If NFS is ever unreachable on
  the tailnet, toggle Settings → NFS off and on.
- **WireGuard encryption** costs CPU on both ends for media traffic. This is
  unmeasured.
