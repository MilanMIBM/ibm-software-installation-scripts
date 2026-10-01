#!/bin/zsh
# cpd-cli Auto-Installer for macOS
# Usage: chmod +x install_cpd_cli.sh && ./install_cpd_cli.sh [SE|EE]
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

CPD_CLI_VERSION="14.3.1"
EDITION="${1:-EE}"  # Pass "SE" as first arg for Standard Edition, defaults to Enterprise

PACKAGE_NAME="cpd-cli-darwin-${EDITION}-${CPD_CLI_VERSION}.tgz"
DOWNLOAD_URL="https://github.com/IBM/cpd-cli/releases/download/v${CPD_CLI_VERSION}/${PACKAGE_NAME}"
INSTALL_DIR="/Users/$(whoami)/cpd-cli"

echo "=== cpd-cli ${CPD_CLI_VERSION} Installer for macOS (${EDITION}) ==="

# Download
echo "[1/4] Downloading ${PACKAGE_NAME}..."
curl -fSL -o "/tmp/${PACKAGE_NAME}" "${DOWNLOAD_URL}"

# Extract
echo "[2/4] Extracting to ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"
tar -xzf "/tmp/${PACKAGE_NAME}" -C "${INSTALL_DIR}" --strip-components=1
rm -f "/tmp/${PACKAGE_NAME}"

# Trust components via xattr (removes quarantine flag, no manual right-click needed)
echo "[3/4] Removing macOS quarantine flags..."
CPD_COMPONENTS=(
  "cpd-cli"
  "plugins/lib/darwin/config"
  "plugins/lib/darwin/cpdbr"
  "plugins/lib/darwin/cpdbr-oadp"
  "plugins/lib/darwin/cpdctl"
  "plugins/lib/darwin/cpdtool"
  "plugins/lib/darwin/health"
  "plugins/lib/darwin/manage"
  "plugins/lib/darwin/platform-diag"
  "plugins/lib/darwin/platform-mgmt"
)
for component in "${CPD_COMPONENTS[@]}"; do
  target="${INSTALL_DIR}/${component}"
  if [[ -f "${target}" ]]; then
    xattr -rd com.apple.quarantine "${target}" 2>/dev/null || true
    chmod +x "${target}"
  fi
done

# Add to PATH
echo "[4/4] Configuring PATH..."
EXPORT_LINE="export PATH=\"${INSTALL_DIR}:\$PATH\""

SHELL_RC=""
if [[ -f "${HOME}/.zshrc" ]]; then
  SHELL_RC="${HOME}/.zshrc"
elif [[ -f "${HOME}/.bash_profile" ]]; then
  SHELL_RC="${HOME}/.bash_profile"
else
  SHELL_RC="${HOME}/.zshrc"
  touch "${SHELL_RC}"
fi

if ! grep -qF "cpd-cli" "${SHELL_RC}"; then
  echo "" >> "${SHELL_RC}"
  echo "# IBM cpd-cli" >> "${SHELL_RC}"
  echo "${EXPORT_LINE}" >> "${SHELL_RC}"
  echo "Added cpd-cli to PATH in ${SHELL_RC}"
else
  echo "PATH entry already exists in ${SHELL_RC}, skipping."
fi

# Optional: set workspace env var
WORKSPACE_LINE="export CPD_CLI_MANAGE_WORKSPACE=\"${INSTALL_DIR}\""
if ! grep -qF "CPD_CLI_MANAGE_WORKSPACE" "${SHELL_RC}"; then
  echo "${WORKSPACE_LINE}" >> "${SHELL_RC}"
fi

# Source and verify
export PATH="${INSTALL_DIR}:$PATH"
echo ""
echo "=== Installation complete ==="
echo "Installed to: ${INSTALL_DIR}"
echo "Run 'source ${SHELL_RC}' or open a new terminal, then verify with:"
echo "  cpd-cli version"