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

eval "${CPDM_OC_LOGIN}"

COMPONENT_LIST=(
    "ccs"
    "analyticsengine"
    "factsheet"
)

COMPONENT_LIST_STRING=$(IFS=,; echo "${COMPONENT_LIST[*]}") # Swap with option below to do it for all service related components
# COMPONENT_LIST_STRING="${CPD_COMPONENTS}"

echo "[INFO] Restarting components: ${COMPONENT_LIST_STRING} in ${PROJECT_CPD_INST_OPERANDS}"
cpd-cli manage restart \
    --components=${COMPONENT_LIST_STRING} \
    --cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS} \
    --verbose