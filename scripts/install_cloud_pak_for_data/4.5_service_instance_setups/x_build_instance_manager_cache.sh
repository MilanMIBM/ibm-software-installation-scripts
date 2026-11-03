#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

# =============================================================================
# x_build_instance_manager_cache.sh - discovery cache of x_service_instance_manager.sh
# -----------------------------------------------------------------------------
# Discovers the installed add-ons that can create service instances, their forms
# (zen provisioning extensions, the parameters zen stored for existing instances,
# CRD schemas), StorageClass kinds and every storage field's need, and saves them in
# ${CONFIG_DIR}/instance_manager_cache/<api-host>--<namespace>/ so the manager opens
# at once. Only stale parts are rebuilt; a progress line is printed for every part.
#
# Optional: the manager builds the cache by itself when there is none yet or when
# the relevant cpd_vars values, install options or patch level changed. The cache
# holds no secrets (passwords in stored parameters are redacted).
#
# Usage:
#   ./x_build_instance_manager_cache.sh                         # build the stale parts
#   ./x_build_instance_manager_cache.sh --rebuild-cache         # rebuild every part
#   ./x_build_instance_manager_cache.sh --check-cache           # what is stale and why (writes nothing)
#   ./x_build_instance_manager_cache.sh --clear-cache           # remove this cluster's cache
#   ./x_build_instance_manager_cache.sh --include-subservices   # also warm the watsonx.data facts
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# Plain oc login only: CPDM_OC_LOGIN is `cpd-cli manage login-to-ocp`, which recreates the container.
eval "${OC_LOGIN}"

cd "${_CP4D_REPO_ROOT}"
export PYTHONPATH="${_CP4D_REPO_ROOT}/src${PYTHONPATH:+:${PYTHONPATH}}"

_mode="--build-cache"
for _a in "$@"; do
  case "${_a}" in --rebuild-cache|--check-cache|--clear-cache) _mode="" ;; esac
done
exec uv run --quiet python -m tui.instance_manager --provider cpd -n "${PROJECT_CPD_INST_OPERANDS}" ${_mode} "$@"
