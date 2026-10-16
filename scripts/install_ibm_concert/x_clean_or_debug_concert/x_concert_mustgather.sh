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
# IBM support must-gather
# ------------------------------------------------------------------------------
# Runs IBM's bin/support-mustgather.sh in the runner (it collects from the
# cluster with the runner's credentials). The output lands on the runner
# volume as mustgather-output-<timestamp>; x_fetch_installer_logs.sh then
# copies it here (cluster runner). Attach it to the IBM support case.
# ==============================================================================

eval "${OC_LOGIN}"
concert_run --name mustgather --timeout 3600 -- bin/support-mustgather.sh

if [[ "${CONCERT_RUNNER:-cluster}" == cluster ]]; then
    "${SCRIPT_DIR}/x_fetch_installer_logs.sh"
fi
