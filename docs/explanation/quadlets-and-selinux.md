# Rootless Quadlets and SELinux confinement

Two constraints that cost a week between them, both of which fail silently.

## Rootless Quadlets must ship in `/etc`, not `/usr`

`podman-systemd.unit(5)` lists `/usr/share/containers/systemd/users/` as a
search path but podman 5.8.4 does not use it. The generator searches only:

    /run/user/$UID/containers/systemd
    ~/.config/containers/systemd
    /etc/containers/systemd/users
    /etc/containers/systemd/users/$UID

A unit under `/usr/share/...` is silently ignored — no error, the unit simply
does not exist. Recheck after a podman bump:

    QUADLET_UNIT_DIRS=/usr/share/containers/systemd/users \
      /usr/lib/systemd/user-generators/podman-user-generator --user --dryrun

## ROCm's blocker was one missing SELinux permission

`container-selinux` grants container domains `hsa_device_t:chr_file` everything
*except* `map`, and ROCm mmaps the node.

Every model load aborted ~25 ms in with `Memory critical error by agent node-0 …
Reason: Memory in use` → exit 134. Node 0 is the **CPU** agent, which is why
every llama.cpp-level knob missed it. The only AVC in the whole trace was
`denied { map } tclass=chr_file tcontext=…:hsa_device_t`.

Three things fix it and one does not: `container_use_devices=on` (the baked
fix), `SecurityLabelDisable=true`, and `--ipc=host` all pass;
`SeccompProfile=unconfined` never mattered.

**The baked boolean alone is verified sufficient** — a model loads and generates
under `Enforcing` with zero AVCs and none of the other overrides present. That
went untested for a while because a leftover user drop-in
(`~/.config/containers/systemd/lemonade.container.d/`) from the original bisect
was still applying `SecurityLabelDisable=true` and `--ipc=host`, silently
masking it.

**Check for stray user drop-ins before trusting any container-confinement
result.**

Two traps from the same bisect: `Ulimit=memlock` as a Quadlet key is not the
`PodmanArgs` form and was inert throughout — not part of the fix. And any bisect
must pin `llamacpp.rocm_args` first, since a leftover `-sm row` made six
consecutive tests fail for an unrelated reason.

Don't re-chase: `ctx_size` capping, `-mg 0 -sm none`, `--load-mode mmap` alone,
`ROCR_VISIBLE_DEVICES`. This is **not** the iGPU warmup segfault
(lemonade#1921 / llamacpp-rocm#96), and the iGPU is not implicated.

Still open: narrowing `container_use_devices` to a CIL module granting only
`container_domain → hsa_device_t:chr_file map`.
