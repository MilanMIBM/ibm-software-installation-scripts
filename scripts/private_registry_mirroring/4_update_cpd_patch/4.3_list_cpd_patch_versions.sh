#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: the mirror config only (MIRROR_CONFIG_FILE selects another file) ---
export ENV_TARGET="${MIRROR_CONFIG_FILE:-registry_mirror}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"
preg_require_config
export PREG_SKIP_REGISTRY_OVERRIDES=1

# ==============================================================================
# 4.3 List the CP4D patch versions (read-only, workspace only)
# ------------------------------------------------------------------------------
# The patch <root>/cpd is recorded at, the last save, a pending plan, every
# planned / recorded patch (mapping lines, delta) and the recent history.
#
#   ./4.3_list_cpd_patch_versions.sh
# ==============================================================================

(( $# == 0 )) || preg_die "Unknown argument: $1"
preg_in_list cpd "${MIRROR_INSTALLS:-}" || preg_die "cpd is not in MIRROR_INSTALLS."
preg_resolve_registry
preg_run_hook 4_update_cpd_patch cpd list
