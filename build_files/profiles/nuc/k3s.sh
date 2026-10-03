#!/bin/bash
set -ouex pipefail

. "$(cd "$(dirname "$0")/../../scripts" && pwd)/lib/common.sh"

### k3s SELinux policy
# Rancher's "coreos" build is the one get.k3s.io picks for rpm-ostree Fedora.
# Repo file written inline so the gpgkey points at the pinned, vendored key.
verify_and_import_key "rancher-k3s" "Rancher k3s" \
    "https://rpm.rancher.io/public.key" \
    C8CFF216455126E9B9C918BE925EA29AE257814A \
    BA7AB9AE441379936597613BAA7E9EC8FE21FDCF

register_repo_file /etc/yum.repos.d/rancher-k3s-common.repo
cat > /etc/yum.repos.d/rancher-k3s-common.repo << 'REPO'
[rancher-k3s-common-stable]
name=Rancher K3s Common (stable)
baseurl=https://rpm.rancher.io/k3s/stable/common/coreos/noarch
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-rancher-k3s
REPO

install_pkgs k3s-selinux

### k3s binary
# sha256 comes from the release's own sha256sum-amd64.txt — bump version and hash
# together, one minor version at a time (Kubernetes does not support skipping minors).
# /usr/bin, not get.k3s.io's /usr/local/bin, which is /var on an ostree system.
K3S_VERSION="v1.36.5+k3s1"
K3S_SHA256="d73847bcd3c5fccef0115b372e2f9a91f3032dc84bbf71518a4617565294d313"

curl -fsSL --retry 6 --retry-delay 5 --retry-all-errors --connect-timeout 15 --max-time 600 \
    -o /tmp/k3s \
    "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION//+/%2B}/k3s"

echo "${K3S_SHA256}  /tmp/k3s" | sha256sum -c -

install -m 0755 /tmp/k3s /usr/bin/k3s
rm -f /tmp/k3s
for tool in kubectl crictl ctr; do
    ln -sf k3s "/usr/bin/${tool}"
done

# k3s-selinux labels /usr/s?bin/k3s container_runtime_exec_t, so the relocated
# binary is covered by policy; ostree applies it at deploy.

### Unit
# Adapted from the unit get.k3s.io writes. Ordered after the NFS mounts and tailscaled
# but not requiring them: a NAS outage must not keep the game server down.
cat > /usr/lib/systemd/system/k3s.service << 'UNIT'
[Unit]
Description=Lightweight Kubernetes
Documentation=https://k3s.io
Wants=network-online.target
After=network-online.target tailscaled.service remote-fs.target

[Service]
Type=notify
EnvironmentFile=-/etc/default/%N
EnvironmentFile=-/etc/sysconfig/%N
KillMode=process
Delegate=yes
User=root
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0
Restart=always
RestartSec=5s
ExecStartPre=-/sbin/modprobe br_netfilter
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/bin/k3s server

[Install]
WantedBy=multi-user.target
UNIT

### Baked config
# config.yaml.d so /etc/rancher/k3s/config.yaml stays free for machine-local
# settings (e.g. the full MagicDNS name in tls-san — k3s appends list values).
# Traefik and ServiceLB stay on: ServiceLB is what puts game-server UDP ports on
# the node IP.
mkdir -p /etc/rancher/k3s/config.yaml.d
cat > /etc/rancher/k3s/config.yaml.d/10-image.yaml << 'CONF'
selinux: true
write-kubeconfig-mode: "0640"
tls-san:
  - nuc
CONF
