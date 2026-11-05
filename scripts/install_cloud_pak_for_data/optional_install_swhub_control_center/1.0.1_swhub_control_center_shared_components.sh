#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/swhub_control_center_helpers.sh"

# ==============================================================================
# Software Hub Control Center - shared cluster components
# ------------------------------------------------------------------------------
# Only for a Control Center on a different cluster from its instances: installs the
# License Service and the scheduling service there. A shared cluster already has them.
# ==============================================================================

swhcc_activate
if [[ "${CONTROL_CLUSTER_MODE}" != different ]]; then
    h_info "CONTROL_CLUSTER_MODE=${CONTROL_CLUSTER_MODE} - the shared components are already on this cluster, skipping."
    exit 0
fi
h_missing_vars CONTROL_PROJECT_LICENSE_SERVICE CONTROL_PROJECT_SCHEDULING_SERVICE \
    || h_die "Not set: ${REPLY}. Check ${ENV_TARGET_FILE}."

swhcc_login

cpd-cli manage apply-cluster-components \
    --release=${VERSION} \
    --license_acceptance=true \
    --licensing_ns=${CONTROL_PROJECT_LICENSE_SERVICE} \
    "${SWHCC_PATCH_FLAG[@]}"

cpd-cli manage apply-scheduler \
    --release=${VERSION} \
    --license_acceptance=true \
    --scheduler_ns=${CONTROL_PROJECT_SCHEDULING_SERVICE} \
    "${SWHCC_PATCH_FLAG[@]}"
