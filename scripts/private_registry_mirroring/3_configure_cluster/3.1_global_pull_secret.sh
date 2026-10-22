#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: the mirror config only (MIRROR_CONFIG_FILE selects another file) ---
export ENV_TARGET="${MIRROR_CONFIG_FILE:-registry_mirror}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"
preg_require_config

# ==============================================================================
# 3.1 Registry credentials in the cluster-wide pull secret
# ------------------------------------------------------------------------------
# Adds the pull root's HOST (one entry covers every install path below it) with
# MIRROR_REGISTRY_PULL_USER / _PASSWORD to openshift-config/pull-secret, using
# the repo's cpd-cli-free src/utilities/redhat_openshift_utils/set_global_pull_secret.sh
# (merges; never replaces). The MCO rolls it out to every node (no reboot on
# recent OpenShift). A copy is saved in configs/registry_mirror_config/.
#
#   ./3.1_global_pull_secret.sh [--current] [--dry-run] [--with-icr]
#     --with-icr  also (re)add cp.icr.io / icr.io with MIRROR_IBM_ENTITLEMENT_KEY
#                 (private mode, when the cluster may still reach IBM directly)
# ==============================================================================

CURRENT=false DRY=() ICR=(--skip-icr)
for _a in "$@"; do
    case "${_a}" in
        --current) CURRENT=true ;;
        --dry-run) DRY=(--dry-run) ;;
        --with-icr) ICR=() ;;
        *) preg_die "Unknown argument: ${_a}" ;;
    esac
done
preg_resolve_registry
preg_require_vars MIRROR_REGISTRY_PULL_USER MIRROR_REGISTRY_PULL_PASSWORD
${CURRENT} || preg_cluster_login
HOST="$(preg_registry_host "$(preg_pull_root)")"

RUN="$(preg_private_tmpdir)"
trap 'rm -rf "${RUN}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT
OVR="${RUN}/pull-secret-overrides.sh"
{
    print -r -- "export OC_LOGIN=:"                     # already logged in above
    print -r -- "export PRIVATE_REGISTRY_LOCATION=$(preg_q "${HOST}")"
    print -r -- "export PRIVATE_REGISTRY_PULL_USER=$(preg_q "${MIRROR_REGISTRY_PULL_USER}")"
    print -r -- "export PRIVATE_REGISTRY_PULL_PASSWORD=$(preg_q "${MIRROR_REGISTRY_PULL_PASSWORD}")"
    print -r -- "export IBM_ENTITLEMENT_KEY=$(preg_q "${MIRROR_IBM_ENTITLEMENT_KEY:-}")"
} > "${OVR}"
chmod 600 "${OVR}"

preg_info "Adding ${HOST} to openshift-config/pull-secret${DRY:+ (dry-run)}"
PREG_RUN_OVERRIDES_FILE="${OVR}" ENV_TARGET="${MIRROR_CONFIG_FILE_PATH}" \
    zsh "${_CP4D_REPO_ROOT}/src/utilities/redhat_openshift_utils/set_global_pull_secret.sh" \
    --config-dir "${REGISTRY_MIRROR_CONFIG_DIR}" --no-distribute "${ICR[@]}" "${DRY[@]}"
