#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/scripts/operator_install_helpers.sh"

# IBM Software Hub Control Center (ibm_swhcc). install-components skips it as a
# shared cluster component; setup-control-center installs it (once per cluster)
# into its own operator / operand projects, created by 2.0.1.
if ! SWHCC_OPERATORS_NS="$(cp4d_swhcc_operator_ns)"; then
    echo "[INFO] ibm_swhcc not in COMPLETE_COMPONENT_LIST; skipping Software Hub Control Center."
    exit 0
fi
SWHCC_OPERANDS_NS="$(cp4d_swhcc_operand_ns)"

# setup-control-center is a Software Hub Premium command: in the standard
# olm-utils-v4 image it only prints a notice and exits 1.
if ! cp4d_olm_utils_is_premium; then
    echo "[ERROR] setup-control-center needs the IBM Software Hub Premium olm-utils image, but"
    echo "[ERROR] OLM_UTILS_IMAGE is '${OLM_UTILS_IMAGE:-unset}'. In ./cpd_vars.sh set e.g."
    echo "[ERROR]   export OLM_UTILS_IMAGE=\"cp.icr.io/cp/cpd/olm-utils-premium-v4:<tag>\""
    echo "[ERROR] (entitled registry; list tags with skopeo list-tags), run"
    echo "[ERROR] cpd-cli manage restart-container, then re-run this script."
    exit 1
fi

for var in VERSION STG_CLASS_BLOCK IMAGE_PULL_PREFIX IMAGE_PULL_SECRET; do
    if [[ -z "${(P)var:-}" ]]; then
        echo "Error: ${var} is not set. Set it in ./cpd_vars.sh before running this script."
        exit 1
    fi
done

eval "${CPDM_OC_LOGIN}"

# setup-control-center requires authorize-instance-topology on its projects first
# (AUTHORIZE_INSTANCE_TOPOLOGY=false skips it, as in 2.1).
if [[ "${AUTHORIZE_INSTANCE_TOPOLOGY:-true}" == true ]]; then
    cpd-cli manage authorize-instance-topology \
        --operator_ns=${SWHCC_OPERATORS_NS} \
        --instance_ns=${SWHCC_OPERANDS_NS} \
        --verbose
else
    echo "[INFO] AUTHORIZE_INSTANCE_TOPOLOGY=false - skipping authorize-instance-topology."
fi

echo "[INFO] Running setup-control-center (operators ${SWHCC_OPERATORS_NS}, operands ${SWHCC_OPERANDS_NS})"
cpd-cli manage setup-control-center \
    --license_acceptance=true \
    --release=${VERSION} \
    --operator_ns=${SWHCC_OPERATORS_NS} \
    --operand_ns=${SWHCC_OPERANDS_NS} \
    --block_storage_class=${STG_CLASS_BLOCK} \
    --image_pull_prefix=${IMAGE_PULL_PREFIX} \
    --image_pull_secret=${IMAGE_PULL_SECRET} \
    --upgrade=${UPDATE:-false}
