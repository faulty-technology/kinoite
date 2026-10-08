---
date: 2026-10-07
subject: Velero to B2 on nuc. Deploy, privilegedFsBackup fix, backup/delete/restore drill, k3s local-path delete bug
harness: none. A hand-applied drill workload (namespace backup-drill), velero CLI v1.18.4 and kubectl v1.36.4 from pinned containers on the laptop, Flux v2.9.6. Disk grow run by the operator on the NUC.
box: kinoite-nuc, k3s v1.36.5+k3s1, SELinux enforcing. Velero v1.18.4 (chart 12.2.0), velero-plugin-for-aws v1.14.4. B2 bucket faulty-technology-nuc-velero (us-west-002).
---

# Velero restore drill

Design and alternatives:
[decisions/2026-10-07-velero-to-b2](../decisions/2026-10-07-velero-to-b2.md).

## Disk grown first

The ISO install had left `nvme0n1p3` at 70G, with about 405 GiB unallocated
(`/var`: 70G, 65G free on 2026-10-06). The operator ran
`growpart /dev/nvme0n1 3` and `xfs_growfs /var`, online. After:
`nvme0n1p3 474.4G`, and `/var` 475G with 461G free.

## Deploy

homelab `5e32262` added `clusters/nuc/infrastructure/velero/`:

- the namespace,
- the `vmware-tanzu` HelmRepository,
- the HelmRelease,
- two SOPS-encrypted Secrets, `velero-b2-credentials` and
  `velero-repo-credentials`.

The operator put the secret values in with `sops set --value-stdin` from
1Password; they never reached this transcript.

Checks before deploying:

- **CRON_TZ.** Velero v1.18.4 parses schedules with `netresearch/go-cron`
  v0.15.0, which handles `CRON_TZ=`. The Velero image contains
  `usr/share/zoneinfo/America/New_York`.
- **Rendered chart.** The node-agent is privileged, and the
  BackupStorageLocation (BSL) has `checksumAlgorithm: ""`.
- **Schemas.** A server dry-run accepted the namespace, HelmRepository and
  HelmRelease.

At 16:43Z:

- HelmRelease Ready ("Helm install succeeded … velero@12.2.0").
- `velero` and `node-agent` 1/1 Running.
- BSL `default` **Available**, so the B2 key, endpoint and
  `checksumAlgorithm: ""` are accepted.
- Schedules `velero-daily` (`CRON_TZ=America/New_York 30 2 * * *`, ttl 336h)
  and `velero-weekly` (`… 0 3 * * 0`, ttl 2160h) Enabled.

**No backup ran when the schedules were created.** The first is the 02:30
daily, and `velero-repo-credentials` existed before any file-system backup.

## Drill workload and baseline (16:44:18Z)

Namespace `backup-drill` with a 1Gi local-path PVC, and an alpine Deployment
that writes:

- `/data/marker.txt`: 4096 random bytes, base64-encoded,
- `/data/drill.db`: a SQLite table of 1000 rows of random blobs.

Baseline:

    sha256 marker.txt  a9afa690ef7c2ce9835b8f36cfddb66b947bb0525f75642cdf8eceeca6614b0e
    count|sum(i)|row500 1000|500500|1B15C68AF1B24D034333B3E344136C69
    drill.db 53248 B, marker.txt 5536 B
    PV pvc-fa63e2f2-47a7-422b-b7ca-e60b8e2cb89c

## Finding 1 — volume backup "permission denied" without privilegedFsBackup

`velero backup create drill-1 --include-namespaces backup-drill`, 16:44:36Z:
**PartiallyFailed**. All 20 Kubernetes items were backed up. The volume was not:

    Failed to run kopia backup: Failed to upload the kopia snapshot for si
    default@default:snapshot-pod-volume/kopia/backup-drill/drill-…/drill-data: permission denied

- node-agent itself ran as `runAsUser: 0` and `privileged: true`. But the logs
  show the copy runs in a separate **data-path pod** ("Finish waiting data path
  pod").
- Velero v1.18.4 gates that pod's privilege on `privilegedFsBackup` in the
  node-agent config map (`pkg/types/node_agent.go`). The setting is passed to
  both the backup and the restore exposer (`nodeagent/server.go`).
- `journalctl -k --since 12:40` (EDT) on the NUC logged **no AVC**.
- The likely mechanism is per-pod SELinux MCS categories, the same one behind
  finding 3: an unprivileged pod can't read files labelled with another pod's
  categories. That mechanism is inferred, not observed.

Fix: homelab `cf3ac2a`.

- ConfigMap `velero-node-agent-config` contains `{"privilegedFsBackup": true}`.
- node-agent starts with `--node-agent-configmap=velero-node-agent-config`.
- Rolled out at 16:46:52Z.

## Backup — passed

`drill-2`, 16:47:17 → 16:47:31Z: **Completed**. PodVolumeBackup
`drill-2-xfsnm`: phase Completed, `totalBytes=58784 doneBytes=58784`
(53248 + 5536, exactly the two files), kopia snapshot
`7589d53850e0a05b7044b84badf5d397`.

## Delete

At 16:47:53Z the namespace `backup-drill` was deleted and was confirmed gone.
Its PV went **Released**. See finding 3.

## Restore — passed

`drill-2-restore`, 16:52:47 → 16:53:00Z: **Completed**. "kopia Restores:
Completed: backup-drill/…: data (size: 58784)". It provisioned a new PV,
`pvc-c50fe42f-e1f6-480e-b12d-783ed7840b45`, and the Deployment rolled out.

    sha256 marker.txt  a9afa690ef7c2ce9835b8f36cfddb66b947bb0525f75642cdf8eceeca6614b0e   (= baseline)
    count|sum(i)|row500 1000|500500|1B15C68AF1B24D034333B3E344136C69                        (= baseline)
    PRAGMA integrity_check  ok
    file mtimes preserved (16:44)

The only warning was "could not restore, ConfigMap:kube-root-ca.crt already
exists". That ConfigMap is created automatically in every namespace.

## Finding 3 — k3s local-path cannot delete volumes under SELinux

The released PV `pvc-fa63e2f2…` never went away.

- local-path-provisioner: "clean up volume … failed: … create process timeout
  after 120 seconds", retried repeatedly.
- The delete helper pod (`/script/teardown`: `set -eu; rm -rf "${VOL_DIR}"`,
  not privileged) exited 1 in the same second, with no output.

This is [k3s#14508](https://github.com/k3s-io/k3s/issues/14508). The helper
pods get random MCS categories, while the volume directory keeps the
categories of the pod that wrote it, so the delete helper's `rm` is denied.

The fix, [k3s#14740](https://github.com/k3s-io/k3s/pull/14740), merged to
`main` at 2026-10-07T16:34:44Z. It gives the helper
`seLinuxOptions.level: s0-s0:c0.c1023`. There is no release-1.36 backport yet.
k3s 1.36 patches have shipped about monthly (05-20, 06-24, 08-04, 08-27,
09-30), so the fix is most likely late October to early November.

Operator decision: wait for that release. Meanwhile, leaked PVs are cleaned up
by hand, and `backup-drill` is kept as the test case for the fix.

## What it means

- **Velero to B2 works end to end on this host.** A volume's bytes went
  offsite and came back identical, with SQLite intact.
- **On SELinux-enforcing k3s, the data-path pods must be privileged.**
  `privilegedFsBackup` covers both backup and restore.
- **Deleting a local-path volume leaks its directory** until k3s includes
  #14740.

Not yet verified:

- the first scheduled `velero-daily` (02:30 EDT 2026-10-08),
- a backup of a real app.
