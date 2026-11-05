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
# Software Hub Control Center - install
# ------------------------------------------------------------------------------
# Applies the project permissions, then runs setup-control-center in the side
# container. Needs 1.0_swhub_control_center_prep.sh first: the charts come from the
# CASE packages it downloads. UPDATE=true upgrades an existing install.
# ==============================================================================

swhcc_activate
h_missing_vars IMAGE_PULL_PREFIX IMAGE_PULL_SECRET || h_die "Not set: ${REPLY}. Check ${ENV_TARGET_FILE}."
swhcc_login

if swhcc_installed && [[ "${UPDATE:-false}" != true ]]; then
    h_info "Control Center is already installed in '${CONTROL_PROJECT_OPERANDS}' - nothing to do (UPDATE=true upgrades it)."
    exit 0
fi

# setup-control-center requires authorize-instance-topology on its projects first
# (AUTHORIZE_INSTANCE_TOPOLOGY=false skips it, as in 2.1).
if [[ "${AUTHORIZE_INSTANCE_TOPOLOGY:-true}" == true ]]; then
    cpd-cli manage authorize-instance-topology \
        --operator_ns=${CONTROL_PROJECT_OPERATORS} \
        --instance_ns=${CONTROL_PROJECT_OPERANDS}
else
    h_info "AUTHORIZE_INSTANCE_TOPOLOGY=false - skipping authorize-instance-topology."
fi

# Keep --upgrade last: setup-control-center resets it on every later argument.
h_info "Running setup-control-center (operators ${CONTROL_PROJECT_OPERATORS}, operands ${CONTROL_PROJECT_OPERANDS})"
cpd-cli manage setup-control-center \
    --license_acceptance=true \
    --release=${VERSION} \
    --operator_ns=${CONTROL_PROJECT_OPERATORS} \
    --operand_ns=${CONTROL_PROJECT_OPERANDS} \
    --block_storage_class=${CONTROL_STG_CLASS_BLOCK} \
    --image_pull_prefix=${IMAGE_PULL_PREFIX} \
    --image_pull_secret=${IMAGE_PULL_SECRET} \
    "${SWHCC_PATCH_FLAG[@]}" \
    --upgrade=${UPDATE:-false}
