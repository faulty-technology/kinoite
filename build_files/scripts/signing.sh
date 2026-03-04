#!/bin/bash
set -ouex pipefail

### Configure container signature policy for bootc update verification
mkdir -p /etc/pki/containers
cp /ctx/cosign.pub /etc/pki/containers/faulty-technology-kinoite.pub

cat > /etc/containers/policy.json << 'EOF'
{
  "default": [{"type": "reject"}],
  "transports": {
    "docker": {
      "ghcr.io/faulty-technology/kinoite": [
        {
          "type": "sigstoreSigned",
          "keyPath": "/etc/pki/containers/faulty-technology-kinoite.pub",
          "signedIdentity": {"type": "matchRepository"}
        }
      ],
      "": [{"type": "insecureAcceptAnything"}]
    },
    "docker-daemon": {"": [{"type": "insecureAcceptAnything"}]},
    "oci": {"": [{"type": "insecureAcceptAnything"}]},
    "oci-archive": {"": [{"type": "insecureAcceptAnything"}]},
    "containers-storage": {"": [{"type": "insecureAcceptAnything"}]}
  }
}
EOF

# Tell containers/image to look for cosign signatures stored as OCI artifacts
# in the same registry (the default without this is an old-style lookaside server)
cat > /etc/containers/registries.d/ghcr.io-faulty-technology-kinoite.yaml << 'EOF'
docker:
  ghcr.io/faulty-technology/kinoite:
    use-sigstore-attachments: true
EOF
