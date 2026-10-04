---
date: 2026-10-04
subject: Intel GPU device plugin on nuc via Flux. SELinux connectto fix, bypath=none, workload gets /dev/dri
harness: none — commands run by hand. From the laptop: flux-cli v2.9.6 and kubectl v1.36.4 pinned containers (as in runs/2026-10-04-nuc-flux-github-app). On the NUC: journalctl -k, semodule. Policy was queried with sesearch in a throwaway kinoite-nuc container.
box: kinoite-nuc (NUC12WSKi7, i7-1260P, Iris Xe, i915), k3s v1.36.5+k3s1, SELinux enforcing
---

# Intel GPU device plugin on nuc

## What was deployed

homelab `3df205d` added `clusters/nuc/infrastructure/intel-gpu-plugin/`. It has
three parts:

- A `GitRepository` for intel/intel-device-plugins-for-kubernetes at tag
  `v0.37.1`, which resolves to commit `6e5cf25a`. It fetches only
  `deployments/gpu_plugin`.
- A Flux `Kustomization` that deploys that path into namespace `intel-gpu`. It
  patches the container args to `-shared-dev-num=4`.
- The `intel-gpu` Namespace.

That uses Intel's upstream kustomize base directly. There is no operator and no
cert-manager.

## Finding 1 — SELinux denies registration on k3s

Deployed at 15:50Z. The plugin pod crash-looped with this error:

    Failed to serve gpu.intel.com/i915: ... dial unix /var/lib/kubelet/device-plugins/kubelet.sock: connect: permission denied

Flux reported `Kustomization/intel-gpu-plugin` **Ready** throughout, so
Kustomization Ready does not prove the workload is healthy.

`ausearch` returned nothing because auditd is inactive on fedora-bootc.
Denials go to the kernel journal instead:

    avc: denied { connectto } comm="intel_gpu_devic" path="/var/lib/kubelet/device-plugins/kubelet.sock"
      scontext=system_u:system_r:container_device_plugin_t:s0:c221,c872
      tcontext=system_u:system_r:container_runtime_t:s0 tclass=unix_stream_socket permissive=0

Socket labels on the NUC, from `ls -lZ`: `kubelet.sock` and
`gpu.intel.com-i915.sock` are both `container_file_t`.

Why: upstream container-selinux allows `container_device_plugin_t` to connect
only to `kubelet_t`, via
`stream_connect_pattern(container_device_plugin_t, container_var_lib_t, kubelet_var_lib_t, kubelet_t)`.
k3s's embedded kubelet runs as `container_runtime_t`. k3s-selinux has no
device-plugin rules. The compiled policy in the image already allows
`container_device_plugin_t` to write a `container_file_t` sock_file, so the
connect is the only gap.

Permissive test. The domain was made permissive with
`semodule -i` of `(typepermissive container_device_plugin_t)` for about 120 s,
and the pod was restarted inside that window at 16:00:12Z. Result: plugin
`1/1 Running` and node allocatable `gpu.intel.com/i915: "4"`. The kernel
journal logged **no** AVCs during the window. That can't separate "nothing else
needed" from kernel rate-limiting of audit printk without auditd, so the result
was settled by the enforcing test below. The module was removed afterwards
(`semodule -l | grep -c dp-permissive` printed 0). `ostree admin config-diff`
then showed only `selinux/targeted/active/commit_num` modified, which was reset
to the `/usr/etc` copy.

Fix: kinoite `88633de`. `profiles/nuc/k3s.sh` installs the CIL module
`k3s_device_plugin`:

    (allow container_device_plugin_t container_runtime_t (unix_stream_socket (connectto)))

`sesearch` on the built image's `policy.35` shows the rule compiled in.

Enforcing test. NUC booted 17:46:28Z into
`kinoite-nuc:latest.20261004170142` (digest `sha256:ca928512…`), from the CI
build of `88633de`. Results:

- `semodule -l`: `k3s`, `k3s_device_plugin`.
- Kernel journal for this boot: no `container_device_plugin_t` AVCs.
- The plugin pod restarted with the boot and was `1/1 Running`.
- Node allocatable: `gpu.intel.com/i915: "4"`.

## Finding 2 — default by-path mounting breaks pods on this host

A busybox test pod with `limits: gpu.intel.com/i915: 1` failed in
CreateContainerError with:

    failed to generate spec: failed to mkdir "/dev/dri/by-path/pci-0000:00:02.0-platform-simple-framebuffer.0-card": file exists

The plugin's default `-bypath=single` passes `/dev/dri/by-path` symlinks into
the pod as device files. The NUC's by-path directory includes a
simple-framebuffer link at the same PCI address, and containerd cannot create
it. Intel's README documents `-bypath=none` ("aligned with Docker privileged
mode"). by-path links only matter for telling GPUs apart in multi-GPU setups.

Fix: homelab `5d7a6c3`, args `["-shared-dev-num=4", "-bypath=none"]`. Rolled
out 17:50:53Z.

Test pod again, 17:51:09Z:

    crw-rw----  root 39   226,   1  card1
    crw-rw-rw-  root 105  226, 128  renderD128
    label=system_u:system_r:container_t:s0:c473,c880
    RENDER_RW_OK
    OPEN_OK

## What it means

Any pod can request `gpu.intel.com/i915: 1`, up to 4 at once. It gets the
iGPU's card and render nodes while staying confined as `container_t`.

Not verified here: hardware video decode or encode (VA-API/QSV) from inside a
pod. Opening the render node is necessary for that, but not sufficient. The
first Plex or Unmanic transcode proves it.
