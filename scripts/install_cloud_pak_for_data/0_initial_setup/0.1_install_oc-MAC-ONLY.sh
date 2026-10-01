#!/bin/zsh
# OpenShift CLI (oc) Auto-Installer for macOS
# Usage: chmod +x install_oc.sh && ./install_oc.sh

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

INSTALL_DIR="/usr/local/bin"

# Determine architecture
ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64)  PLATFORM="mac" ;;
  arm64)   PLATFORM="mac-arm64" ;;
  *)       echo "Unsupported architecture: ${ARCH}"; exit 1 ;;
esac

DOWNLOAD_URL="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-${PLATFORM}.tar.gz"

echo "=== OpenShift CLI (oc) Installer for macOS (${ARCH}) ==="

# Download
echo "[1/4] Downloading openshift-client-${PLATFORM}.tar.gz..."
curl -fSL -o /tmp/openshift-client.tar.gz "${DOWNLOAD_URL}"

# Extract
echo "[2/4] Extracting..."
tar -xzf /tmp/openshift-client.tar.gz -C /tmp oc kubectl
rm -f /tmp/openshift-client.tar.gz

# Install
echo "[3/4] Installing to ${INSTALL_DIR} (requires sudo)..."
sudo mv /tmp/oc "${INSTALL_DIR}/oc"
sudo mv /tmp/kubectl "${INSTALL_DIR}/kubectl"
sudo chmod +x "${INSTALL_DIR}/oc" "${INSTALL_DIR}/kubectl"

# Remove quarantine
echo "[4/4] Removing macOS quarantine flags..."
xattr -rd com.apple.quarantine "${INSTALL_DIR}/oc" 2>/dev/null || true
xattr -rd com.apple.quarantine "${INSTALL_DIR}/kubectl" 2>/dev/null || true

echo ""
echo "=== Installation complete ==="
oc version --client
echo ""
echo "Log in to a cluster with:"
echo "  oc login <cluster-url> --token=<token>"