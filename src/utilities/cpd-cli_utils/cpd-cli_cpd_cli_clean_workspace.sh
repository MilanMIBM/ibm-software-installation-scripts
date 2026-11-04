#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

#---
# clean-workspace reads the work dir from the existing olm-utils container; if
# the container is gone (e.g. after cpd-cli_refresh_olm_container.sh) it aborts
# with "The work directory was not found." -> recreate the container first.
_container="${OLM_UTILS_CONTAINER:-olm-utils-play-v4}"
_runtime="${DOCKER_EXE:-podman}"
if ! "${_runtime}" container inspect "${_container}" >/dev/null 2>&1; then
    echo "[INFO] Container ${_container} not found; creating it via cpd-cli manage restart-container"
    cpd-cli manage restart-container
fi

cpd-cli manage clean-workspace