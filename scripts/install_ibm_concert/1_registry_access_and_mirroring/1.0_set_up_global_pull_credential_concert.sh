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
# 1.0 Global pull secret (OPTIONAL - off in the full wrapper by default)
# ------------------------------------------------------------------------------
# IBM's installer creates its own docker-registry secret in every product
# namespace from REG_USER/REG_PASS, so Concert does not need this. Use it when
# other workloads must pull Concert images, or as belt and braces.
#
# Calls the shared cpd-cli-free utility
#   src/utilities/redhat_openshift_utils/set_global_pull_secret.sh
# (the CP4D track keeps its own cpd-cli based 1.1 script unchanged).
# Entitled mode adds cp.icr.io/icr.io; mirrored/airgap add the private registry.
# Extra arguments are passed through (e.g. --dry-run, --no-distribute).
# ==============================================================================

_flags=(--config-dir "${CONCERT_CONFIG_DIR}" --secret-name "${IMAGE_PULL_SECRET:-concert-pull-secret}")
if [[ "${CONCERT_IMAGE_SOURCE}" == entitled ]]; then
    _flags+=(--skip-private)
else
    _flags+=(--skip-icr)
fi

"${_CP4D_REPO_ROOT}/src/utilities/redhat_openshift_utils/set_global_pull_secret.sh" "${_flags[@]}" "$@"
