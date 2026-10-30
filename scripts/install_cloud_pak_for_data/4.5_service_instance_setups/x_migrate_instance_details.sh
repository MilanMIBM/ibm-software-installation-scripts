#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

# =============================================================================
# x_migrate_instance_details.sh - move service-instance details to per-instance files
# -----------------------------------------------------------------------------
# The service-instance scripts (4.5_*, 5_*) and the instance manager TUI now write
# one file per instance:
#   configs/cp4d_config/managed-service-instances/<type>/<instance>-instance_details.sh
# (sourced by every script through env_bootstrap.sh, newest last). Older runs appended
# their results to cpd_instance_details.sh, and Db2 wrote service_instances/*-credentials.txt.
# This moves those leftovers with the same variable names; platform values (CPD_URL,
# CPD_APIKEY, ...) stay in cpd_instance_details.sh. Values are never printed.
#
# Usage:
#   ./x_migrate_instance_details.sh            # show what would move (dry run)
#   ./x_migrate_instance_details.sh --apply    # move it (keeps a 0600 backup of cpd_instance_details.sh)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

cd "${_CP4D_REPO_ROOT}"
export PYTHONPATH="${_CP4D_REPO_ROOT}/src${PYTHONPATH:+:${PYTHONPATH}}"
exec uv run --quiet python -m tui.instance_manager.ops.migrate_details "$@"
