#!/bin/bash
set -ouex pipefail

### Configure container signature policy for bootc update verification
# IMAGE_NAME is passed from each Containerfile (ARG -> env) so every image
# verifies against its own GHCR repo path with the shared cosign key.
IMAGE_NAME="${IMAGE_NAME:-kinoite}"
IMAGE_REPO="ghcr.io/faulty-technology/${IMAGE_NAME}"
PUBKEY="/etc/pki/containers/faulty-technology-${IMAGE_NAME}.pub"

mkdir -p /etc/pki/containers
cp /ctx/cosign.pub "$PUBKEY"

cat > /etc/containers/policy.json << EOF
{
  "default": [{"type": "reject"}],
  "transports": {
    "docker": {
      "${IMAGE_REPO}": [
        {
          "type": "sigstoreSigned",
          "keyPath": "${PUBKEY}",
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
cat > "/etc/containers/registries.d/ghcr.io-faulty-technology-${IMAGE_NAME}.yaml" << EOF
docker:
  ${IMAGE_REPO}:
    use-sigstore-attachments: true
EOF
