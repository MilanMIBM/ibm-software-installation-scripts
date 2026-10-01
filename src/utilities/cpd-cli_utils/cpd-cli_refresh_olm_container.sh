#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# (legacy hardcoded sourcing - replaced by universal crawl below)
# source "${SCRIPT_DIR}/../scripts/source_env_setup.sh"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

#---

for var in OLM_UTILS_IMAGE CPD_CLI_WORK_PATH; do
    if [[ -z "${(P)var:-}" ]]; then
        echo "[ERROR] ${var} is not set. Set it in ./cpd_vars.sh before running this script."
        exit 1
    fi
done

CONTAINER_NAME="olm-utils-play-v4"

if [[ -d "${CPD_CLI_WORK_PATH}" ]]; then
    echo "[INFO] Cleaning cpd-cli workspace: ${CPD_CLI_WORK_PATH}"
    rm -rf "${CPD_CLI_WORK_PATH}"
    echo "[INFO] Workspace cleaned"
else
    echo "[INFO] Workspace already clean: ${CPD_CLI_WORK_PATH}"
fi

if podman ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "[INFO] Removing existing container: ${CONTAINER_NAME}"
    podman rm -f "${CONTAINER_NAME}"
else
    echo "[INFO] No existing container found: ${CONTAINER_NAME}"
fi

echo "[INFO] Pulling olm-utils image: ${OLM_UTILS_IMAGE}"
podman pull --arch="${IMAGE_ARCH:-amd64}" "${OLM_UTILS_IMAGE}"

echo "[INFO] Container and workspace cleaned. Run your cpd-cli manage command to start fresh."
echo "[INFO] Image pulled: ${OLM_UTILS_IMAGE}"
