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
export PREG_SKIP_REGISTRY_OVERRIDES=1   # the hook reads cpd_vars.sh itself, not 3.5's overrides

# ==============================================================================
# 4.2 Verify and record the patch (--phase=mirror|save|load, default MIRROR_PHASE)
# ------------------------------------------------------------------------------
#   mirror / load
#     - checks the delta in the registry by digest (--full: every image of the
#       patch, still only a skopeo probe per line - no cpd-cli list-images)
#     - version tags: <tag>-p<to> for moved tags, olm-utils
#       <release>.<to>[.<arch>] (cpd_vars.sh's OLM_UTILS_IMAGE form)
#     - records <to>: patches/current, <release>-p<to>/recorded.json,
#       history.log; native.jsonl and inventory.json move to <to>, so 2.0 / 2.4
#       work on the same patch
#     - 3.5 --only cpd (skip with --no-tap): registry_overrides.sh pins
#       OLM_UTILS_IMAGE to the patch's olm-utils tag and cpd-cli's container is
#       recreated from it - do not run while another cpd-cli job is running
#   save
#     - records the save, so the next save starts from <to>; carry the bundle in
#
#   ./4.2_verify_and_record_cpd_patch.sh [--phase=...] [--full] [--no-tap]
# ==============================================================================

preg_parse_phase_args "$@"
TAP=true HOOK_ARGS=()
for _a in "${PREG_ARGS[@]}"; do
    case "${_a}" in
        --full) HOOK_ARGS+=(--full) ;;
        --no-tap) TAP=false ;;
        *) preg_die "Unknown argument: ${_a}" ;;
    esac
done
preg_resolve_registry
PHASE="$(preg_resolve_phase "${PREG_PHASE_ARG}")"
export MIRROR_PHASE="${PHASE}"
preg_in_list cpd "${MIRROR_INSTALLS:-}" || preg_die "cpd is not in MIRROR_INSTALLS - nothing to update."
preg_run_hook 4_update_cpd_patch cpd record "--phase=${PHASE}" "${HOOK_ARGS[@]}" || preg_die "cpd: verifying / recording the patch failed"
if [[ "${PHASE}" != save ]] && ${TAP}; then
    zsh "${SCRIPT_DIR:h}/3_configure_cluster/3.5_point_installs_at_registry.sh" --only cpd
fi
