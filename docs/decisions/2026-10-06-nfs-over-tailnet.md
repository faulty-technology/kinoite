---
type: Decision
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

## Follow-up — k3s as a second NFS client (2026-10-31)

k3s now consumes the same Unraid exports as a **second NFS client**, via the
`csi-driver-nfs` CSI driver. Its node DaemonSet runs `hostNetwork: true`
(privileged, bidirectional mountPropagation), so its mounts also happen in the
node's network namespace — exactly like the host mounts above. Consequences:

- **Unraid sees the NUC tailnet IP for every client** (the host mounts and k3s
  alike), never a pod IP: csi-driver-nfs mounts in the host netns, and any
  pod-originated egress to `100.64.0.0/10` is SNAT'd to the node by flannel's
  default masquerade. A single per-share Unraid allow rule on the NUC tailnet IP
  covers all of them — no per-pod IPs, no CIDR lock-in, no subnet router needed.
- **Media is read-only.** The `arrdata` export is `ro`, and the host media mount
  (`/var/mnt/unraid/media`) is now mounted `ro` to match. k3s reads media through
  a static read-only PV; it never writes there.
- **k3s's writable data lives on a separate `k8s` share**, not `appdata`. The
  dedicated `k8s` share (same SSD pool as `appdata`, so it stays the fast tier)
  is exported `rw`; Unraid's live Docker app config in `appdata` is never touched
  by k3s. The host `appdata` mount (`/var/mnt/unraid/fast`) stays `rw` for
  direct/podman use, unrelated to k3s.
- Mount options add `proto=tcp` (Tailscale's 1280-byte MTU makes UDP NFS fragile);
  `rsize`/`wsize` left at defaults to avoid PMTU black-holing.
