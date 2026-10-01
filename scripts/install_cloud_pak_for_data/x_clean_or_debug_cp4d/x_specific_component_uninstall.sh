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
DELETE_ALL_COMPONENTS=false
DELETE_ALL_SOFTWAREHUB_INSTANCES=false
DELETE_DEPENDENCIES=true
#---

COMPONENTS_TO_DELETE=(
    "ibm_databand"
)

COMPONENTS_TO_DELETE_STRING=$(IFS=,; echo "${COMPONENTS_TO_DELETE[*]}")

echo "[INFO] Deleting ${COMPONENTS_TO_DELETE}  CR's in ${PROJECT_CPD_INST_OPERANDS}"
cpd-cli manage delete-cr \
    --cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS} \
    --components=${COMPONENTS_TO_DELETE_STRING} \
    --include_dependency=${DELETE_DEPENDENCIES} || echo "[WARN] delete-cr failed (possibly no permissions or CRs already absent), continuing..."

cpd-cli manage uninstall-components \
    --instance_ns=${PROJECT_CPD_INST_OPERANDS} \
    --components=${COMPONENTS_TO_DELETE_STRING} \
    --include_dependency=${DELETE_DEPENDENCIES} \
    --delete_all_components=${DELETE_ALL_COMPONENTS}

cpd-cli manage delete-cluster-scoped-resources \
    --operator_ns=${PROJECT_CPD_INST_OPERATORS} \
    --delete_all_components=${DELETE_ALL_COMPONENTS} \
    --cleanup_all_instances=${DELETE_ALL_SOFTWAREHUB_INSTANCES} \
    --include_dependency=${DELETE_DEPENDENCIES} \
    --components=${COMPONENTS_TO_DELETE_STRING}

echo "[INFO] Deleting all Specified Cluster Scoped Resources in ${PROJECT_CPD_INST_OPERATORS}"
oc delete -f ${CPD_CLI_WORK_PATH}/cluster_scoped_resources_uninstall_list.yaml