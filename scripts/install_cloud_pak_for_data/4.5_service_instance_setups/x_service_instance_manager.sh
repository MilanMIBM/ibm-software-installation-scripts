#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

# =============================================================================
# x_service_instance_manager.sh - service instances of the CP4D install in cpd_vars.sh
# -----------------------------------------------------------------------------
# Lists the installed add-ons that can create service instances and every existing
# instance (zen record, backing CR or both) with its state. Each type's options are
# discovered from the cluster: the zen provisioning form, the parameters zen stored
# for existing instances, the CRs and their CRDs. Nothing per service is hardcoded.
# Storage-class fields are classified file / block from the PVCs their values feed.
#
# Uses `cpd-cli service-instance` (talks to zen directly; never `cpd-cli manage`,
# which would recreate the olm-utils container). The cpd-cli profile is checked
# first; x_repair_cpd_cli_profile.sh fixes a stale one.
#
# Usage:
#   ./x_service_instance_manager.sh --once                 # types, instances, states
#   ./x_service_instance_manager.sh --explain edb          # discovered fields + where each came from
#   ./x_service_instance_manager.sh --storage-report       # StorageClass kinds + every field's need
#   ./x_service_instance_manager.sh --save-auto-repair on  # repair a broken profile automatically (this cluster)
#   ./x_service_instance_manager.sh --help                 # every option
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# Plain oc login only: CPDM_OC_LOGIN is `cpd-cli manage login-to-ocp`, which recreates the container.
eval "${OC_LOGIN}"

cd "${_CP4D_REPO_ROOT}"
export PYTHONPATH="${_CP4D_REPO_ROOT}/src${PYTHONPATH:+:${PYTHONPATH}}"
# STG_CLASS_FILE / STG_CLASS_BLOCK / CPD_USERNAME / CONFIG_DIR come from the env.
exec uv run --quiet python -m tui.instance_manager --provider cpd -n "${PROJECT_CPD_INST_OPERANDS}" "$@"
