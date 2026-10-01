#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# (legacy hardcoded sourcing - replaced by universal crawl below)
# source "${SCRIPT_DIR}/../source_env_setup.sh"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# ---
eval "${OC_LOGIN}"

# --- Cluster health check
cpd-cli health cluster

# --- Node health check
cpd-cli health nodes

# --- Network performance check
if [[ -n "${PRIVATE_REGISTRY_LOCATION:-}" ]]; then
    cpd-cli health network-performance \
        --image-prefix=${PRIVATE_REGISTRY_LOCATION}/cpopen/cpd \
        --image-tag=${VERSION}.${IMAGE_ARCH}
else
    cpd-cli health network-performance
fi
