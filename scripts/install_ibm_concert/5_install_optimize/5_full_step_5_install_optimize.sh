#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: only configs/concert_config/concert_vars.sh is in scope ---
export ENV_TARGET="${ENV_TARGET:-concert}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/concert_helpers.sh"
concert_require_config

# ==============================================================================
# Step 5 - install Concert Optimize / Turbonomic (5.1 -> 5.6, then 3.4)
# ------------------------------------------------------------------------------
# Needs the Hub (step 3, or a remote Hub) and the runner (0.2) for 5.5.
# Override any toggle at runtime, e.g.:  DO_ATTACH=false ./5_full_step_5_install_optimize.sh
# or pick steps by name: --from <step>, --skip <step>[,...], --list-steps.
# ==============================================================================

h_steps_parse --strict "$@"

concert_product_enabled optimize || { concert_info "Optimize is not selected (CONCERT_INSTALL_OPTIMIZE) - nothing to do."; exit 0; }

DO_OPERATOR="${DO_OPERATOR:-true}"       # 5.1 t8c-operator (pinned to CONCERT_OPTIMIZE_VERSION)
DO_DEPLOY="${DO_DEPLOY:-true}"           # 5.2 plain Turbonomic (skipped once in Concert mode)
DO_INITIALIZE="${DO_INITIALIZE:-true}"   # 5.3 administrator + license
DO_GATEWAY="${DO_GATEWAY:-true}"         # 5.4 Concert mode, TLS, route
DO_ATTACH="${DO_ATTACH:-true}"           # 5.5 attach to the Hub (restarts the Hub)
DO_STATUS="${DO_STATUS:-true}"           # 5.6 wait until ready
DO_DETAILS="${DO_DETAILS:-true}"         # 3.4 refresh concert_instance_details.sh (adds the Optimize URL)

h_step operator   "${DO_OPERATOR}"   "5.1 Turbonomic operator"        "${SCRIPT_DIR}/5.1_install_turbonomic_operator.sh"
h_step deploy     "${DO_DEPLOY}"     "5.2 deploy Turbonomic"          "${SCRIPT_DIR}/5.2_deploy_turbonomic.sh"
h_step initialize "${DO_INITIALIZE}" "5.3 administrator and license"  "${SCRIPT_DIR}/5.3_initialize_turbonomic.sh"
h_step gateway    "${DO_GATEWAY}"    "5.4 Concert mode + route"       "${SCRIPT_DIR}/5.4_enable_concert_gateway.sh"
h_step attach     "${DO_ATTACH}"     "5.5 attach Optimize to the Hub" "${SCRIPT_DIR}/5.5_attach_optimize_to_hub.sh"
h_step status     "${DO_STATUS}"     "5.6 wait for Optimize"          "${SCRIPT_DIR}/5.6_optimize_status.sh" --wait=1800
h_step details    "${DO_DETAILS}"    "3.4 instance details"           "${SCRIPT_DIR}/../3_install_concert/3.4_get_instance_details.sh"
h_steps_plan
h_steps_run
