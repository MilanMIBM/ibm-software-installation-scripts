#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: only configs/datastax_mc_config/datastax_mc_vars.sh is in scope ---
export ENV_TARGET="${ENV_TARGET:-datastax_mc}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/datastax_mc_helpers.sh"
mc_require_config

# ==============================================================================
# 0.1 Make sure a supported helm is available
# ------------------------------------------------------------------------------
# Mission Control supports Helm 3.14.0 - 3.18.x. A helm on PATH in that range is
# used; otherwise MC_HELM_VERSION is downloaded (sha256 verified) into
# datastax_mc_workspace/tools/ and used by every script here. Your own helm on
# PATH is never replaced.
# ==============================================================================

mc_ensure_helm
mc_info "helm for Mission Control: ${MC_HELM} ($(mc_helm_version_of "${MC_HELM}"))"
