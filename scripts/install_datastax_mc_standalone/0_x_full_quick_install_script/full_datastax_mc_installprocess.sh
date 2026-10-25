#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# --- Config target: only configs/datastax_mc_config/datastax_mc_vars.sh is in scope ---
export ENV_TARGET="${ENV_TARGET:-datastax_mc}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/datastax_mc_helpers.sh"
mc_require_config

# This script lives in scripts/install_datastax_mc_standalone/0_x_full_quick_install_script/,
# so the numbered step folders are one level up.
SCRIPTS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CP4D_ROOT="${_CP4D_REPO_ROOT}/scripts/install_cloud_pak_for_data"

# ---------------------------------------------------------------------------
# Step toggles - true runs a step, false skips it. Override at runtime, e.g.:
#   DO_CERT_MANAGER=false DO_PREFLIGHT=false ./full_datastax_mc_installprocess.sh
# The config itself comes first, from
#   0_initial_setup/0.0_generate_datastax_mc_config.sh --empty | --from-cpd
# ---------------------------------------------------------------------------
DO_INSTALL_OC="${DO_INSTALL_OC:-false}"              # 0.0 oc for macOS (CP4D script, reused)
DO_FETCH_HELM="${DO_FETCH_HELM:-true}"               # 0.1 helm 3.14 - 3.18
DO_CERT_MANAGER="${DO_CERT_MANAGER:-true}"           # 1.0 cert-manager operator (+ owner refs)
DO_PREFLIGHT="${DO_PREFLIGHT:-true}"                 # 1.1 preflight (read-only)
DO_NAMESPACE="${DO_NAMESPACE:-true}"                 # 1.2 namespace + pull secrets
DO_LABEL_NODES="${DO_LABEL_NODES:-true}"             # 1.3 platform node labels
DO_SCC="${DO_SCC:-true}"                             # 1.4 SCC grants
DO_INSTALL="${DO_INSTALL:-true}"                     # 2.1 render values + helm upgrade --install
DO_ROUTE="${DO_ROUTE:-true}"                         # 2.2 UI Route (control plane only)
DO_WAIT="${DO_WAIT:-true}"                           # 2.3 wait for all pods
DO_DETAILS="${DO_DETAILS:-true}"                     # 2.4 instance details file
DO_NETWORKPOLICY="${DO_NETWORKPOLICY:-false}"        # 3.0 internode NetworkPolicy (needs projects)

h_run_step "${DO_INSTALL_OC}" "0.0 install oc (macOS, CP4D script)" \
    "${CP4D_ROOT}/0_initial_setup/0.1_install_oc-MAC-ONLY.sh"
h_run_step "${DO_FETCH_HELM}" "0.1 helm for Mission Control" \
    "${SCRIPTS_ROOT}/0_initial_setup/0.1_fetch_helm.sh"

h_run_step "${DO_CERT_MANAGER}" "1.0 cert-manager operator" \
    "${SCRIPTS_ROOT}/1_prepare_cluster/1.0_install_cert_manager.sh"
h_run_step "${DO_PREFLIGHT}" "1.1 preflight" \
    "${SCRIPTS_ROOT}/1_prepare_cluster/1.1_cluster_preflight.sh"
h_run_step "${DO_NAMESPACE}" "1.2 namespace and pull secrets" \
    "${SCRIPTS_ROOT}/1_prepare_cluster/1.2_create_namespace_and_pull_secret.sh"
h_run_step "${DO_LABEL_NODES}" "1.3 platform node labels" \
    "${SCRIPTS_ROOT}/1_prepare_cluster/1.3_label_platform_nodes.sh"
h_run_step "${DO_SCC}" "1.4 SCC (${MC_SCC_MODE})" \
    "${SCRIPTS_ROOT}/1_prepare_cluster/1.4_configure_scc.sh"

h_run_step "${DO_INSTALL}" "2.1 install Mission Control ${MC_VERSION} (${MC_PLANE} plane)" \
    "${SCRIPTS_ROOT}/2_install_mission_control/2.1_install_mission_control.sh"
h_run_step "${DO_ROUTE}" "2.2 UI Route" \
    "${SCRIPTS_ROOT}/2_install_mission_control/2.2_create_ui_route.sh"
h_run_step "${DO_WAIT}" "2.3 wait for Mission Control" \
    "${SCRIPTS_ROOT}/2_install_mission_control/2.3_mission_control_status.sh" --wait
h_run_step "${DO_DETAILS}" "2.4 instance details" \
    "${SCRIPTS_ROOT}/2_install_mission_control/2.4_get_instance_details.sh"

h_run_step "${DO_NETWORKPOLICY}" "3.0 internode NetworkPolicy" \
    "${SCRIPTS_ROOT}/3_post_install/3.0_apply_internode_networkpolicy.sh"
