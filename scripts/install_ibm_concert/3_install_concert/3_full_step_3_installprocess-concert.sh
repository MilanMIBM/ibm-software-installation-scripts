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
source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"

# ==============================================================================
# Step 3 - install IBM Concert (3.0 -> 3.4)
# ------------------------------------------------------------------------------
# Override any toggle at runtime, e.g.:  DO_PREVIEW=true ./3_full_step_3_installprocess-concert.sh
# ==============================================================================

DO_RENDER_PARAMS="${DO_RENDER_PARAMS:-true}"   # 3.0 params.ini + Workflows override values
DO_PREVIEW="${DO_PREVIEW:-false}"              # 3.1 IBM preview (experimental)
DO_SETUP="${DO_SETUP:-true}"                   # 3.2 IBM installer
DO_STATUS="${DO_STATUS:-true}"                 # 3.3 wait until ready
DO_DETAILS="${DO_DETAILS:-true}"               # 3.4 instance details

h_run_step "${DO_RENDER_PARAMS}" "3.0 render params.ini"    "${SCRIPT_DIR}/3.0_render_params_ini.sh"
h_run_step "${DO_PREVIEW}"       "3.1 preview (experimental)" "${SCRIPT_DIR}/3.1_preview_install.sh"
h_run_step "${DO_SETUP}"         "3.2 run IBM Concert setup" "${SCRIPT_DIR}/3.2_run_concert_setup.sh"
h_run_step "${DO_STATUS}"        "3.3 wait for Concert"      "${SCRIPT_DIR}/3.3_concert_status.sh" --wait=1800
h_run_step "${DO_DETAILS}"       "3.4 instance details"      "${SCRIPT_DIR}/3.4_get_instance_details.sh"
