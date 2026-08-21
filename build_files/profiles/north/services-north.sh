#!/bin/bash
set -ouex pipefail

# north-only service enablement (shared services are handled by services.sh).

### Sunshine streaming host
# Sunshine ships a systemd *user* unit; enable it globally so it starts for the
# logged-in user. sunshine.sh drops in the ExecStartPre that seeds the capture
# settings and the global_prep_cmd that resizes the persistent virtual monitor;
# pairing and wiring the prep commands stay per-user first-login steps (see README).
#
# The virtual display is created on demand by the seeded global_prep_cmd (`ensure`)
# and destroyed by its `undo` (`down`), NOT at login — sunshine-virtual-monitor.service
# is shipped disabled as of 2026-08-18 because krfb holds a render node and pinned a GPU
# awake full time. See sunshine.sh. A crash mid-stream skips `undo`, so ExecStopPost runs
# `down` as the net: it re-enables outputs an --exclusive stream disabled, restores the
# previous primary, and drops the monitor.
#
# Use the canonical unit name. pvermeer's package also ships a sunshine.service
# compat symlink, but upstream only declares it as an [Install] Alias= — which
# doesn't exist until the real unit is enabled, so enabling the alias fails.
systemctl --global enable app-dev.lizardbyte.app.Sunshine.service

### SELinux boolean for containerized GPU compute
# Enabled even though the lemonade Quadlet is deliberately not — without it, ROCm dies
# with an HSA abort that looks nothing like a permission error. Guarded and idempotent,
# so it's a no-op on every boot after the first. See lemonade.sh.
systemctl enable lemonade-selinux.service

### Linger for rootless user services
# Both LLM stacks (lemonade.container, vllm.container) are rootless user units. Without
# linger, systemd tears the user manager down at logout and takes a running server with
# it — including a server started over SSH, the moment that SSH session ends. That is a
# genuine trap on a headless-ish box: the model unloads mid-request for no visible reason.
#
# `loginctl enable-linger` records this as a file under /var/lib/systemd/linger/<user>.
# /var is machine-local state on a bootc system, NOT part of the image, so this cannot be
# baked as a file — it has to be (re)asserted at boot, which is what the oneshot below
# does. That also makes it survive a wipe-and-rebase, which a manual `loginctl` call would
# not.
#
# Deliberately does NOT auto-start anything: neither lemonade.container nor vllm.container
# has an [Install] section, so a lingering user manager still starts no LLM at boot. This
# only keeps a HAND-STARTED one alive past logout.
#
# Defined here rather than in lemonade.sh/vllm.sh because it serves both and belongs to
# neither. Enumerates users instead of hardcoding a name so it keeps working whatever the
# account is called after a reinstall.
install -D -m 0755 /dev/stdin /usr/libexec/kinoite-enable-linger << 'EOF'
#!/bin/bash
# Enable systemd linger for every regular login user. Idempotent; safe to re-run at boot.
set -euo pipefail

while IFS=: read -r name _ uid _ _ home shell; do
    # Regular human accounts only: skip system users and nobody (65534).
    if [ "$uid" -lt 1000 ] || [ "$uid" -ge 60000 ]; then
        continue
    fi
    case "$shell" in
        */nologin | */false | "") continue ;;
    esac
    if [ ! -d "$home" ]; then
        continue
    fi
    if [ -e "/var/lib/systemd/linger/$name" ]; then
        continue
    fi
    # Non-fatal: one bad account must not fail the unit for the others.
    loginctl enable-linger "$name" || echo "kinoite-enable-linger: failed for $name" >&2
done < /etc/passwd
EOF
bash -n /usr/libexec/kinoite-enable-linger

cat > /usr/lib/systemd/system/kinoite-linger.service << 'EOF'
[Unit]
Description=Enable systemd linger for regular login users
Documentation=file:///usr/share/kinoite/vllm.md
After=systemd-logind.service
Wants=systemd-logind.service

[Service]
Type=oneshot
ExecStart=/usr/libexec/kinoite-enable-linger
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl enable kinoite-linger.service
