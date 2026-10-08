# Back up and restore the NUC's app data

Velero backs up every namespace except `kube-system` and `velero` to the B2
bucket `faulty-technology-nuc-velero` (`us-west-002`), including volume
contents (kopia). It runs a daily backup at 02:30, kept 14 days, and a Sunday
03:00 backup, kept 90 days. Times are America/New_York.

Configuration lives in homelab: `clusters/nuc/infrastructure/velero/`.

## Tools

Run these from the laptop.

    # velero v1.18.4
    velero() {
      podman run --rm -i --network host --userns=keep-id --user "$(id -u):$(id -g)" \
        -v "$HOME/.kube/nuc.yaml":/kubeconfig:ro,z -e KUBECONFIG=/kubeconfig \
        --entrypoint /velero \
        docker.io/velero/velero@sha256:87f95cccca5d4149e28ba44ffe1bd35ac298d9fc09aaccf9a02a4d432aeb89d9 \
        -n velero "$@"
    }
    # kubectl v1.36.4
    kubectl() {
      podman run --rm -i --network host --userns=keep-id --user "$(id -u):$(id -g)" \
        -v "$HOME/.kube/nuc.yaml":/kubeconfig:ro,z -e KUBECONFIG=/kubeconfig \
        registry.k8s.io/kubectl@sha256:484eff4657707d5ba697035d45b38fd00883c60c1b764f618af708db95cd3a2d "$@"
    }

## Check health

    velero backup-location get              # PHASE must be Available
    velero schedule get
    velero backup get                       # STATUS Completed; PartiallyFailed means a volume failed

To see what a backup actually holds:

    velero backup describe <backup> --details

Every volume must be listed under "Pod Volume Backups - kopia: Completed".

## Back up now

    velero backup create <name> --include-namespaces <ns> --wait

A volume is only backed up while a running pod mounts it. Don't scale the app
to 0 first.

## Restore one app

1. Pick a backup: `velero backup get`.
2. Remove the app's current namespace:

       kubectl delete namespace <ns>

   The restore recreates its PVCs. The old volumes are left behind until k3s
   includes [k3s#14740](https://github.com/k3s-io/k3s/pull/14740); see
   [Clean up a leaked volume](#clean-up-a-leaked-volume).
3. Restore:

       velero restore create --from-backup <backup> --include-namespaces <ns> --wait

4. Check:

       velero restore describe <restore> --details

   It must show `Phase: Completed` and the volume under "kopia Restores:
   Completed". Then open the app and check its data.

If the live database is damaged after a restore, use the app's own backup,
which was restored alongside it:

- Sonarr, Radarr and Prowlarr: System → Backup → Restore, from
  `/config/Backups/scheduled`.
- Plex: the dated `com.plexapp.plugins.library.db-YYYY-MM-DD` copies under
  `Plug-in Support/Databases`.

## Restore after losing the NUC

1. Reinstall the NUC, then grow the disk. See the README, "Installing
   kinoite-nuc".
2. Run `scripts/bootstrap.sh` in homelab. Flux brings Velero back from git,
   along with the SOPS Secrets (the B2 key and the repository password).
3. Wait for `velero backup-location get` to show Available. Velero then lists
   the backups already in B2 under `velero backup get`.
4. Restore each app as in [Restore one app](#restore-one-app). Skip step 2,
   since there is nothing to delete.

If homelab or the age key is lost too, the B2 key ID, application key and
repository password are in 1Password. Velero cannot read the backups without
the repository password.

## Clean up a leaked volume

This is needed until k3s ships #14740 and the pin in `profiles/nuc/k3s.sh` is
bumped.

    kubectl get pv | grep Released

On the NUC, for each leaked volume:

    sudo rm -rf /var/lib/rancher/k3s/storage/<pv-name>_<ns>_<pvc>
    kubectl delete pv <pv-name>
