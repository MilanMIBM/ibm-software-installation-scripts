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

#---
ALL_COMPONENTS=false
ALL_SOFTWAREHUB_INSTANCES=false
INCLUDE_DEPENDENCIES=true
FILTER_ON=false
#---

COMPONENT_LIST=(
    "analyticsengine"
    "factsheet"
    "watsonx_data"
    "informix_cp4d"
    "ibm_wxd_opensearch"
)

# COMPONENT_LIST_STRING=$(IFS=,; echo "${COMPONENT_LIST[*]}")
COMPONENT_LIST_STRING="cpfs,cpd_platform,ccs,${CPD_COMPONENTS}" # swap out with the above version for local variant of the components list.

FILTER_FIELDS=(
    "cr_kind"
    "cr_name"
    "cr_status"
    "creation_timestamp"
    "error_history"
    "expected_version"
    "reconciled_version"
    "operator_info"
    "progress"
    "progress_message"
    "namespace"
)

FILTER_FIELDS_STRING=$(IFS=,; echo "${FILTER_FIELDS[*]}")

FILTER_ON_FLAG=()
if [[ "${FILTER_ON}" == "true" ]]; then
    FILTER_ON_FLAG=(--filter=${FILTER_FIELDS_STRING})
fi

echo "[INFO] Getting the custom resource status for ${COMPONENT_LIST_STRING} components in ${PROJECT_CPD_INST_OPERANDS}"
cpd-cli manage get-cr-status \
    --cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS} \
    --components=${COMPONENT_LIST_STRING} \
    --include_dependency=${INCLUDE_DEPENDENCIES} \
    "${FILTER_ON_FLAG[@]}" \
    # --cluster_component_ns=${PROJECT_SCHEDULING_SERVICE} \ # If you want to check on the scheduling service or other cluster wide components.