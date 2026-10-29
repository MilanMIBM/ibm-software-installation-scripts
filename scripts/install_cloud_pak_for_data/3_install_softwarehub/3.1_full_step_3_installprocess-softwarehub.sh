#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# (legacy hardcoded sourcing - replaced by universal crawl below)
# source "${SCRIPT_DIR}/../../source_env_setup.sh"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"
CURRENT_DIR="$(cd "$(dirname "$0")" && pwd)"

h_steps_parse --strict "$@"

# Optional: create ccs-cr only when ccs is listed as a component. Exact match on
# the comma-separated list, so e.g. "ccs_foo" does not trigger it.
_components=",${SOFTWARE_HUB:-},${CPD_COMPONENTS:-},"
[[ "${_components// /}" == *",ccs,"* ]] && DO_CCS_CR=true || DO_CCS_CR=false
unset _components
# Optional: Software Hub Control Center, only when ibm_swhcc is listed.
source "${_CP4D_REPO_ROOT}/scripts/operator_install_helpers.sh"
cp4d_has_component ibm_swhcc && DO_CONTROL_CENTER=true || DO_CONTROL_CENTER=false

# Each step only warns when it fails, so a benign "already installed" failure in
# one step still lets the rest proceed.
h_step --warn admin                true "3.2 set up cpd admin"            "${CURRENT_DIR}/3.2_set_up_cpd_admin.sh"
h_step --warn softwarehub          true "3.3 install IBM Software Hub"    "${CURRENT_DIR}/3.3_install_ibm_softwarehub.sh"
h_step --warn instance-creds       true "3.3.1 get instance credentials"  "${CURRENT_DIR}/3.3.1_get_instance_creds.sh"
h_step --warn admission-controller true "3.3.2 admission controller"      "${CURRENT_DIR}/3.3.2_softwarehub_admission_controller.sh"
h_step --warn entitlements         true "3.4 apply entitlements"          "${CURRENT_DIR}/3.4_apply_entitlements.sh"
h_step --warn ccs-cr               "${DO_CCS_CR}" "3.5 create ccs-cr if missing (ccs in SOFTWARE_HUB / CPD_COMPONENTS)" \
    "${CURRENT_DIR}/3.5_create_ccs_cr_if_missing.sh"
h_step --warn control-center       "${DO_CONTROL_CENTER}" "3.6 Software Hub Control Center (ibm_swhcc in COMPLETE_COMPONENT_LIST)" \
    "${CURRENT_DIR}/3.6_setup_software_hub_control_center.sh"
h_steps_plan
h_steps_run
