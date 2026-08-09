#!/bin/bash
set -ouex pipefail

. "$(dirname "$0")/lib/common.sh"

### Nix package manager (multi-user daemon mode, modern CLI only)
# Fedora 44+ ships native nix RPMs. nix pulls in nix-core (the unified `nix`
# binary) and nix-system (/nix skeleton + nixbld sysusers); nix-daemon adds the
# multi-user daemon and its systemd units. nix-legacy (nix-env, nix-build, ...)
# is deliberately not installed — it's only a Recommends of nix, so weak deps
# are disabled to keep it out.
#
# /nix integration on a bootc image adapted from https://github.com/fu5ha/winter
dnf5 install -y --setopt=install_weak_deps=False nix nix-daemon
record_pkgs nix nix-daemon

# The image's /nix is read-only at runtime; bind-mount a persistent backing
# directory from /var over it. The backing dir must exist before nix.mount
# runs at local-fs.target time, and tmpfiles.d entries are only applied later
# (systemd-tmpfiles-setup runs After=local-fs.target) — hence a oneshot unit.
cat > /usr/lib/systemd/system/var-nix.service << 'EOF'
[Unit]
Description=Create backing directory for /nix bind mount
DefaultDependencies=no
After=systemd-remount-fs.service
Before=nix.mount
Before=local-fs.target
RequiresMountsFor=/var

[Service]
Type=oneshot
ExecStart=/usr/bin/install -d -m 0755 -o root -g root /var/nix
RemainAfterExit=yes

[Install]
RequiredBy=nix.mount
EOF

cat > /usr/lib/systemd/system/nix.mount << 'EOF'
[Unit]
Description=Bind mount /var/nix to /nix
Requires=var-nix.service
After=var-nix.service

[Mount]
What=/var/nix
Where=/nix
Type=none
Options=bind

[Install]
WantedBy=local-fs.target
EOF

# The nix RPMs create the /nix skeleton in the image, but the bind mount hides
# it at runtime — recreate it inside the mount. tmpfiles.d runs after mounts,
# so these land on the writable backing store.
cat > /usr/lib/tmpfiles.d/nix-mount-skeleton.conf << 'EOF'
d /nix/store             1775 root nixbld - -
d /nix/var/nix           0775 root nixbld - -
d /nix/var/log/nix/drvs  0775 root nixbld - -
EOF

# SELinux: Fedora's nix RPMs ship no policy, so /nix paths have no file
# context and resolve to default_t. User shells and the daemon run unconfined
# and don't care, but PID1 (init_t) labels the listening socket by looking the
# path up in the file-context database — no entry means it creates the socket
# as default_t and is denied by its own label choice (relabeling the dirs on
# disk doesn't help; the lookup is by path, not parent). The database entry
# must be added with semanage, whose state is machine-local (/var/lib/selinux)
# and can't ship in the image — so seed it from a oneshot at boot. PID1 picks
# up the policy commit without a reboot. Approach matches
# nix-community/nix-installers (daemon-socket -> var_run_t).
cat > /usr/lib/systemd/system/nix-selinux.service << 'EOF'
[Unit]
Description=SELinux file context for the Nix daemon socket
Before=nix-daemon.socket
ConditionSecurity=selinux

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'matchpathcon -n /nix/var/nix/daemon-socket/socket | grep -q var_run_t || { semanage fcontext -a -t var_run_t "/nix/var/nix/daemon-socket(/.*)?" && restorecon -iR /nix/var/nix/daemon-socket; }'
RemainAfterExit=yes

[Install]
RequiredBy=nix-daemon.socket
EOF

# Nix resolves $HOME strictly and Fedora Atomic homes live behind the
# /home -> /var/home symlink; hand it the real path.
cat > /etc/profile.d/00-nix-resolve-home.sh << 'EOF'
HOME=$(readlink -f "$HOME")
export HOME
EOF

# Modern CLI + flakes out of the box, no channels.
cat >> /etc/nix/nix.conf << 'EOF'
experimental-features = nix-command flakes
EOF
