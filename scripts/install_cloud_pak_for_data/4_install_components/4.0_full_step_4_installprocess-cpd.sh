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

# Temporary in-cluster watcher (deployed by 4.0_wxo_install_preverification.sh) that works
# around the expired Semeru FIPS profile in the docproc cache-init job, then deletes itself once
# the WatsonxOrchestrate CR is Completed. Only deployed when PREP_WXO=true and
# watsonx_orchestrate is in CPD_COMPONENTS; set to false to turn it off.
export WXO_DOCPROC_WATCHER="${WXO_DOCPROC_WATCHER:-false}"

h_steps_parse --strict "$@"

# Runs before the install: the prerequisite check is a pre-install check, and the watcher has to
# be up while install-components waits on the CR.
h_step wxo-preverify  "${PREP_WXO:-false}"        "4.0 watsonx Orchestrate install preverification (PREP_WXO)" \
    "${CURRENT_DIR}/4.0_wxo_install_preverification.sh"
h_step components     true                        "4.1 install components" \
    "${CURRENT_DIR}/4.1_install_components.sh"
h_step opensearch     "${PREP_OPENSEARCH:-false}" "4.1.1 watsonx.data OpenSearch (PREP_OPENSEARCH)" \
    "${CURRENT_DIR}/4.1.1_inst_wxd_opensearch.sh"
h_step profile        true                        "4.2 cpd profile" \
    "${CURRENT_DIR}/4.2_cpd_profile.sh"
h_steps_plan
h_step_on components && h_info "Watch live CR state in another terminal: scripts/install_cloud_pak_for_data/check_cr_status/x_cr_state_dashboard.sh"
h_steps_run
