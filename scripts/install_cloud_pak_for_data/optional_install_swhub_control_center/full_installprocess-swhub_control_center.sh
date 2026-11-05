#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"

# ==============================================================================
# Software Hub Control Center - full install
# ------------------------------------------------------------------------------
# Runs standalone, or as the last step of full_swhub_x_cpd_installprocess.sh when
# cpd_vars.sh has INSTALL_SWHUB_CONTROL_CENTER="true":
#   1.0 prep -> 1.0.1 shared components -> 1.1 install -> 1.2 status
#   -> 1.3 instance details -> 1.4 OAuth client -> cluster-admins
#   -> auto-detect instances
#
# Step 0 is NOT run here: configs/cp4d_config/swhub_control_center/
# swhub_control_center_vars.sh must exist. Write it with
# 0_swhub_control_center_generate_config.sh or the notebook.
#
# Step toggles - override any of them at runtime, e.g.:
#   DO_SWHCC_OAUTH=false ./full_installprocess-swhub_control_center.sh
# CONTROL_ADD_CLUSTER_ADMINS in the vars file (default true) turns on the
# cluster-admins step. AUTODETECT_IN_CLUSTER_SOFTWAREHUB_INSTANCES (default true) turns
# on the last step, which verifies the cluster and adds the instances.
# A failure in either only warns, and both can be re-run on their own.
#
# Or pick steps by name: --from <step> resumes there, --skip <step>[,...] leaves
# steps out, --list-steps shows the plan.
# ==============================================================================

h_steps_parse --strict "$@"

DO_SWHCC_PREP="${DO_SWHCC_PREP:-true}"                         # 1.0 prepare the cluster
DO_SWHCC_INSTALL="${DO_SWHCC_INSTALL:-true}"                   # 1.1 install Control Center
DO_SWHCC_STATUS="${DO_SWHCC_STATUS:-true}"                     # 1.2 report its health
DO_SWHCC_INSTANCE_DETAILS="${DO_SWHCC_INSTANCE_DETAILS:-true}" # 1.3 write instance details
DO_SWHCC_OAUTH="${DO_SWHCC_OAUTH:-true}"                       # 1.4 create the OAuth client

[[ "${CONTROL_CLUSTER_MODE:-same}" == different ]] && DO_SWHCC_SHARED=true || DO_SWHCC_SHARED=false
h_is_true "${AUTODETECT_IN_CLUSTER_SOFTWAREHUB_INSTANCES:-true}" && DO_SWHCC_AUTODETECT=true || DO_SWHCC_AUTODETECT=false
h_is_true "${CONTROL_ADD_CLUSTER_ADMINS:-true}" && DO_SWHCC_ADMINS=true || DO_SWHCC_ADMINS=false

echo "=============================================================================="
echo " Software Hub Control Center full install - project '${CONTROL_PROJECT_OPERANDS:-?}'"
echo "=============================================================================="
echo "[INFO] Release ${VERSION:-?}${PATCH_ID:+ patch ${PATCH_ID}}, side container ${CONTROL_OLM_UTILS_CONTAINER:-?} on ${CONTROL_OLM_UTILS_IMAGE:-?}"

# A failing status report only warns.
h_step         prep              "${DO_SWHCC_PREP}"             "1.0 control center prep" \
    "${SCRIPT_DIR}/1.0_swhub_control_center_prep.sh"
h_step         shared-components "${DO_SWHCC_SHARED}"           "1.0.1 shared cluster components (different cluster only)" \
    "${SCRIPT_DIR}/1.0.1_swhub_control_center_shared_components.sh"
h_step         install           "${DO_SWHCC_INSTALL}"          "1.1 control center install" \
    "${SCRIPT_DIR}/1.1_swhub_control_center_install.sh"
h_step --warn  status            "${DO_SWHCC_STATUS}"           "1.2 control center status" \
    "${SCRIPT_DIR}/1.2_swhub_control_center_status.sh"
h_step         instance-details  "${DO_SWHCC_INSTANCE_DETAILS}" "1.3 control center get instance details" \
    "${SCRIPT_DIR}/1.3_swhub_control_center_get_instance_details.sh"
h_step         oauth             "${DO_SWHCC_OAUTH}"            "1.4 control center OAuth client" \
    "${SCRIPT_DIR}/1.4_swhub_control_center_oauth_client.sh"
h_step --warn  cluster-admins    "${DO_SWHCC_ADMINS}"           "give OpenShift cluster-admins the Control Center admin role (CONTROL_ADD_CLUSTER_ADMINS)" \
    "${_CP4D_REPO_ROOT}/src/utilities/softwarehub_utils/softwarehub_control_center/toggle_cluster_admins.sh"
h_step --warn  autodetect-instances "${DO_SWHCC_AUTODETECT}"    "auto-detect and add the Software Hub instances (AUTODETECT_IN_CLUSTER_SOFTWAREHUB_INSTANCES)" \
    "${_CP4D_REPO_ROOT}/src/utilities/softwarehub_utils/softwarehub_control_center/autodetect_instances.sh"

h_steps_plan
h_steps_run

echo ""
echo "[INFO] Software Hub Control Center full install complete."
