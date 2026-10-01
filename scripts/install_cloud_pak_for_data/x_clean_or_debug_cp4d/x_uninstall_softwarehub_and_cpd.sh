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

#--- Set to false if it's a Helm managed cp4d instance (default after v5.4.0)
OLM_INSTALL=false
#---

echo "[INFO] Deleting ${COMPLETE_COMPONENT_LIST}  CR's in ${PROJECT_CPD_INST_OPERANDS}"
cpd-cli manage delete-cr \
    --cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS} \
    --components=${COMPLETE_COMPONENT_LIST} \
    --include_dependency=true \
    --verbose  || echo "[WARN] delete-cr failed (possibly no permissions or CRs already absent), continuing..."

#---
if [[ "${OLM_INSTALL}" == "true" ]]; then
    echo "[INFO] Deleting all OLM Artifacts in ${PROJECT_CPD_INST_OPERATORS}"
    cpd-cli manage delete-olm-artifacts \
        --cpd_operator_ns=${PROJECT_CPD_INST_OPERATORS} \
        --delete_all_components=true
fi

#---
echo "[INFO] Uninstalling {COMPLETE_COMPONENT_LIST} and their dependencies in ${PROJECT_CPD_INST_OPERATORS}"
cpd-cli manage uninstall-components \
    --instance_ns=${PROJECT_CPD_INST_OPERANDS} \
    --delete_all_components=true \
    --include_dependency=true

#---
IFS=',' read -rA entitlements <<< "${LICENSE_ENTITLEMENTS}"

for entitlement in "${entitlements[@]}"; do
    entitlement="${entitlement// /}"
    echo "[INFO] Removing entitlement: ${entitlement}"
    cpd-cli manage remove-entitlement \
        --cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS} \
        --entitlement=${entitlement} \
        --production=${PROD_LICENSE} \
        --restart_pods=false
done

#---
echo "[INFO] Uninstalling cpd-config-ac webhook from ${PROJECT_CPD_INST_OPERANDS}"
cpd-cli manage disable-cpd-config-ac \
    --cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS}

cpd-cli manage uninstall-cpd-config-ac \
    --cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS} \
    --verbose

#--- 
if [[ "${OLM_INSTALL}" == "false" ]]; then
echo "[INFO] Generating deletion list for all Cluster Scoped Resources in ${PROJECT_CPD_INST_OPERATORS}"
cpd-cli manage delete-cluster-scoped-resources \
    --operator_ns=${PROJECT_CPD_INST_OPERATORS} \
    --delete_all_components=true \
    --cleanup_all_instances=true \
    --include_dependency=true

echo "[INFO] Deleting all Cluster Scoped Resources in ${PROJECT_CPD_INST_OPERATORS}"
oc delete -f ${CPD_CLI_WORK_PATH}/cluster_scoped_resources_uninstall_list.yaml
fi

#---
cpd-cli manage restart-container

#---
cpd-cli manage clean-workspace