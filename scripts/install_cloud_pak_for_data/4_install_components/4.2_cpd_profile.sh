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


CPD_URL="${CPD_URL}"
CPD_USERNAME="${CPD_USERNAME}"
CPD_APIKEY="${CPD_APIKEY}"

CPD_PROFILE_NAME="${CPD_USERNAME}-profile"

eval "${CPDM_OC_LOGIN}"

# oc get routes --namespace=cpd-operands
echo "Preparing user ${CPD_USERNAME} with ${CPD_APIKEY} in ${CPD_URL} as profile - ${CPD_PROFILE_NAME}"
cpd-cli config users set "${CPD_USERNAME}" \
    --apikey="${CPD_APIKEY}"  \
    --username="${CPD_USERNAME}" 

cpd-cli config profiles set "${CPD_PROFILE_NAME}" \
    --user="${CPD_USERNAME}" \
    --url="${CPD_URL}" 
# in this context user is actually 

cpd-cli config users list
cpd-cli config profiles list