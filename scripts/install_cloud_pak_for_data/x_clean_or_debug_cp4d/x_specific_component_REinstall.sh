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

SKIP_COMPONENTS_FLAG=()
if [[ -n "${COMPONENTS_TO_SKIP:-}" ]]; then
    SKIP_COMPONENTS_FLAG=(--skip_components="${COMPONENTS_TO_SKIP}")
fi

PARAM_FILE_FLAG=()
if [[ -n "${INSTALL_OPTIONS}" ]]; then
    PARAM_FILE_FLAG=(--param-file="${CPD_CONFIG_PATH_CONTAINER}/${INSTALL_OPTIONS_FILE}")
fi

PATCH_FLAG=()
if [[ -n "${PATCH_ID:-}" ]]; then
    PATCH_FLAG=(--patch_id="${PATCH_ID}")
fi

COMPONENTS_TO_REINSTALL=(
    "ccs"
    "analyticsengine"
    "factsheet"
    "watsonx_data"
    "informix_cp4d"
    "ibm_wxd_opensearch"
)

# COMPONENTS_TO_REINSTALL_STRING=$(IFS=,; echo "${COMPONENTS_TO_REINSTALL[*]}")
COMPONENTS_TO_REINSTALL_STRING="${COMPLETE_COMPONENT_LIST}"

## Uninstall the products

echo "[INFO] Deleting ${COMPONENTS_TO_REINSTALL}  CR's in ${PROJECT_CPD_INST_OPERANDS}"
cpd-cli manage delete-cr \
    --cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS} \
    --components=${COMPONENTS_TO_REINSTALL_STRING} \
    ${PATCH_FLAG[@]+"${PATCH_FLAG[@]}"} \
    --include_dependency=${DELETE_DEPENDENCIES} || echo "[WARN] delete-cr failed (possibly no permissions or CRs already absent), continuing..."

echo "[INFO] Uninstalling components ${COMPONENTS_TO_REINSTALL} in ${PROJECT_CPD_INST_OPERANDS}"
cpd-cli manage uninstall-components \
    --instance_ns=${PROJECT_CPD_INST_OPERANDS} \
    --components=${COMPONENTS_TO_REINSTALL_STRING} \
    --include_dependency=${DELETE_DEPENDENCIES} \
    --delete_all_components=${DELETE_ALL_COMPONENTS} \

echo "[INFO] Deleting cluster scoped resources for ${COMPONENTS_TO_REINSTALL} in ${PROJECT_CPD_INST_OPERANDS}"
cpd-cli manage delete-cluster-scoped-resources \
    --operator_ns=${PROJECT_CPD_INST_OPERATORS} \
    --delete_all_components=${DELETE_ALL_COMPONENTS} \
    --cleanup_all_instances=${DELETE_ALL_SOFTWAREHUB_INSTANCES} \
    --include_dependency=${DELETE_DEPENDENCIES} \
    --components=${COMPONENTS_TO_REINSTALL_STRING}

echo "[INFO] Deleting all Cluster Scoped Resources in ${PROJECT_CPD_INST_OPERATORS}"
oc delete -f ${CPD_CLI_WORK_PATH}/cluster_scoped_resources_uninstall_list.yaml

# ### Reinstall the products

echo "[INFO] Reapplying cluster scoped resources for ${COMPONENTS_TO_REINSTALL} in ${PROJECT_CPD_INST_OPERANDS}"
oc apply -f "${CPD_CLI_WORK_PATH}/cluster_scoped_resources.yaml" \
    --server-side \
    --force-conflicts

echo "[INFO] Reauthorizing instance topology for ${COMPONENTS_TO_REINSTALL} in ${PROJECT_CPD_INST_OPERANDS}"
cpd-cli manage authorize-instance-topology \
    --cpd_operator_ns=${PROJECT_CPD_INST_OPERATORS} \
    --cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS}


echo "[INFO] Reinstalling components ${COMPONENTS_TO_REINSTALL} in ${PROJECT_CPD_INST_OPERANDS}"
cpd-cli manage install-components \
    --license_acceptance=true \
    --components=${COMPONENTS_TO_REINSTALL_STRING} \
    --release=${VERSION} \
    --operator_ns=${PROJECT_CPD_INST_OPERATORS} \
    --instance_ns=${PROJECT_CPD_INST_OPERANDS} \
    --block_storage_class=${STG_CLASS_BLOCK} \
    --file_storage_class=${STG_CLASS_FILE} \
    --image_pull_prefix=${IMAGE_PULL_PREFIX} \
    --image_pull_secret=${IMAGE_PULL_SECRET} \
    "${PARAM_FILE_FLAG[@]}" \
    "${SKIP_COMPONENTS_FLAG[@]}" \
    --upgrade=${UPDATE} \
    ${PATCH_FLAG[@]+"${PATCH_FLAG[@]}"} 