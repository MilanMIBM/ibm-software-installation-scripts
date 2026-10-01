
#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# (legacy hardcoded sourcing - replaced by universal crawl below)
# source "${SCRIPT_DIR}/../../source_env_setup.sh"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

export CP_OPEN_DOWNLOAD=true # downloads the cases and images from cp.icr.io/cpopen rather than ibm's github.

PATCH_FLAG=()
if [[ -n "${PATCH_ID}" ]]; then
    PATCH_FLAG=(--patch_id=${PATCH_ID})
fi

# --- Case download for the components
eval "${CPDM_OC_LOGIN}"

COMPONENTS=${COMPLETE_COMPONENT_LIST}

cpd-cli manage case-download \
    --components=${COMPONENTS} \
    --release=${VERSION} \
    --scheduler_ns=${PROJECT_SCHEDULING_SERVICE} \
    --operator_ns=${PROJECT_CPD_INST_OPERATORS} \
    --cluster_resources=true \
    --from_oci=${CP_OPEN_DOWNLOAD} \
    "${PATCH_FLAG[@]}"
    
eval "${OC_LOGIN}"

oc apply -f "${CPD_CLI_WORK_PATH}/cluster_scoped_resources.yaml" \
    --server-side \
    --force-conflicts \
    --overwrite
