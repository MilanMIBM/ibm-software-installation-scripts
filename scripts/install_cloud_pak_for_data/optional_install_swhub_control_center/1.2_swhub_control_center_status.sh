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
# Software Hub Control Center - status
# ------------------------------------------------------------------------------
# The checks from IBM's install topic. In the operators report the PVC and stateful
# set checks are expected to be skipped: that project holds neither.
# ==============================================================================

swhcc_activate
swhcc_login

cpd-cli manage get-cr-status \
    --instance_ns=${CONTROL_PROJECT_OPERANDS}

cpd-cli health operators \
    --operator_ns=${CONTROL_PROJECT_OPERATORS} \
    --control_plane_ns=${CONTROL_PROJECT_OPERANDS}

cpd-cli health operands \
    --control_plane_ns=${CONTROL_PROJECT_OPERANDS}
