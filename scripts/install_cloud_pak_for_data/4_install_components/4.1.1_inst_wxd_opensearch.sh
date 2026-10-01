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

export CP_OPEN_DOWNLOAD=true # downloads the cases and images from cp.icr.io/cpopen rather than ibm's github.

# ---

eval "${CPDM_OC_LOGIN}"

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

cpd-cli manage case-download \
    --components="ibm_wxd_opensearch" \
    --release=${VERSION} \
    --scheduler_ns=${PROJECT_SCHEDULING_SERVICE} \
    --operator_ns=${PROJECT_CPD_INST_OPERATORS} \
    --instance_ns=${PROJECT_CPD_INST_OPERANDS} \
    --cluster_resources=true \
    --from_oci=${CP_OPEN_DOWNLOAD}

eval "${OC_LOGIN}"

# Switch to the operands project if the login landed elsewhere. OC_LOGIN leaves
# the session on whatever project was last used, and the SCC access check below
# is namespace-scoped.
if [[ "$(oc project -q 2>/dev/null || true)" != "${PROJECT_CPD_INST_OPERANDS}" ]]; then
    echo "[INFO] Switching project to ${PROJECT_CPD_INST_OPERANDS}."
    oc project "${PROJECT_CPD_INST_OPERANDS}" >/dev/null
fi

oc apply -f "${CPD_CLI_WORK_PATH}/cluster_scoped_resources.yaml" \
    --server-side \
    --force-conflicts

# ibm_wxd_opensearch has (as of 18.05.2026) a known issue due to how its setup in the registry that it must be downloaded from 'cp.icr.io' rather than 'icr.io'.
cpd-cli manage install-components \
    --license_acceptance=true \
    --components="ibm_wxd_opensearch" \
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

# --- apply the necessary security context level
# The OpenSearch node init container runs as UID 0. Without this grant the
# StatefulSets never create pods (FailedCreate: "unable to validate against any
# security context constraint") and the instance silently never comes up.
OSEARCH_SA="wxd-opensearch-sa"
OSEARCH_SCC="privileged"

# -n is required: add-scc-to-user creates a namespaced RoleBinding, so the
# access check must be scoped to that namespace too. Without -n the check runs
# against whatever project the session is currently on and returns a false "no".
if oc auth can-i use "scc/${OSEARCH_SCC}" \
    --as="system:serviceaccount:${PROJECT_CPD_INST_OPERANDS}:${OSEARCH_SA}" \
    -n ${PROJECT_CPD_INST_OPERANDS} &>/dev/null; then
    echo "[SKIP] ${OSEARCH_SA} already has the ${OSEARCH_SCC} SCC."
else
    echo "[INFO] Granting ${OSEARCH_SCC} SCC to ${OSEARCH_SA}."
    oc adm policy add-scc-to-user "${OSEARCH_SCC}" -z "${OSEARCH_SA}" -n ${PROJECT_CPD_INST_OPERANDS}

    if ! oc auth can-i use "scc/${OSEARCH_SCC}" \
        --as="system:serviceaccount:${PROJECT_CPD_INST_OPERANDS}:${OSEARCH_SA}" \
        -n ${PROJECT_CPD_INST_OPERANDS} &>/dev/null; then
        echo "[ERROR] Failed to grant ${OSEARCH_SCC} SCC to ${OSEARCH_SA}."
        echo "[ERROR] OpenSearch pods cannot start without it. Not marking PREP_OPENSEARCH as complete."
        exit 1
    fi
    echo "[OK] Granted ${OSEARCH_SCC} SCC to ${OSEARCH_SA}."
fi

# --- mark opensearch as prepared in cpd_vars.sh
CPD_VARS_FILE="${SCRIPT_DIR}/../../cp4d_config/cpd_vars.sh"
if [[ -f "${CPD_VARS_FILE}" ]] && ! grep -q 'export PREP_OPENSEARCH=' "${CPD_VARS_FILE}"; then
    echo '' >> "${CPD_VARS_FILE}"
    echo 'export PREP_OPENSEARCH="true"' >> "${CPD_VARS_FILE}"
fi

# --- correct icr.io → cp.icr.io image references in opensearch CRs and Helm deployments
"${SCRIPT_DIR}/4.1.2_correct_wxd_opensearch_imgpull.sh"