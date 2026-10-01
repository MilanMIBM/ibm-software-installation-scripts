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

for var in CPDM_OC_LOGIN PREP_INFORMIX; do
    if [[ -z "${(P)var:-}" ]]; then
        echo "Error: ${var} is not set. Set it in ./cpd_vars.sh before running this script."
        exit 1
    fi
done

eval "${CPDM_OC_LOGIN}"

USE_INFORMIX_SCC_PROFILE=false

if [[ "${USE_INFORMIX_SCC_PROFILE}" == "true" ]]; then
    INFORMIX_SCC="cpd-cli manage apply-scc --cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS} --components=informix"
    echo "[INFO] Applying cpd-cli informix SCC profile."
else
    INFORMIX_SCC="oc adm policy add-scc-to-user restricted-v2 -z informix -n ${PROJECT_CPD_INST_OPERANDS}"
    echo "[INFO] Applying restricted-v2 scc profile."
fi

eval "${INFORMIX_SCC}"

# --- Patch Informix workloads with fsGroup: 1000 (CephFS PVC permissions fix) ---

### ibm-informix-cp4d-operator-controller-manager (Deployment) - 'allowPrivilegeEscalation: false' needs to be changed to 'allowPrivilegeEscalation: true'

patch_informix_fsgroup() {
    local ns="${PROJECT_CPD_INST_OPERANDS}"
    local patch='{"spec":{"template":{"spec":{"securityContext":{"runAsNonRoot":true,"fsGroup":1000}}}}}'

    echo "[INFO] Patching Informix StatefulSets and Deployments in namespace '${ns}' with fsGroup: 1000"

    for sts in $(oc get statefulset -n "${ns}" -l icpdsupport/addOnId=informix -o name 2>/dev/null); do
        echo "[INFO] Patching ${sts}"
        oc patch "${sts}" -n "${ns}" --type='merge' -p "${patch}"
    done

    # for deploy in $(oc get deployment -n "${ns}" -l icpdsupport/addOnId=informix -o name 2>/dev/null); do
    #     echo "[INFO] Patching ${deploy}"
    #     oc patch "${deploy}" -n "${ns}" --type='merge' -p "${patch}"
    # done

    echo "[INFO] Informix fsGroup patching complete"
}

patch_informix_fsgroup