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
# x Undo segment 3 (rollback of the cluster and install configuration)
# ------------------------------------------------------------------------------
#   - deletes our IDMS/ITMS and CatalogSources (label
#     app.kubernetes.io/managed-by=private-registry-mirroring)
#   - re-enables the default OperatorHub sources (when 3.4 disabled them)
#   - --include-ibm: also IBM's cloud-pak-for-data-mirror IDMS + ITMS (apply-icsp)
#   - --overrides: deletes every install's registry_overrides.sh (and
#     mc-values-registry.yaml), so the installs use their own settings again
#   Left alone: the global pull secret entry and the CA ConfigMap key (harmless;
#   remove by hand if wanted). Waits for the MachineConfigPools.
#
#   ./x_remove_mirror_config.sh [--current] [--include-ibm] [--overrides] [--yes]
# ==============================================================================

CURRENT=false IBM=false OVR=false YES=false
for _a in "$@"; do
    case "${_a}" in
        --current) CURRENT=true ;;
        --include-ibm) IBM=true ;;
        --overrides) OVR=true ;;
        --yes) YES=true ;;
        *) preg_die "Unknown argument: ${_a}" ;;
    esac
done

if ${OVR}; then
    for f in "${CONFIGS_ROOT}"/*/registry_overrides.sh(N) "${CONFIGS_ROOT}/datastax_mc_config/mc-values-registry.yaml"(N); do
        if ${YES}; then rm -f "${f}"; preg_info "removed ${f#${_CP4D_REPO_ROOT}/}"
        else preg_info "would remove ${f#${_CP4D_REPO_ROOT}/}"; fi
    done
fi

${CURRENT} || preg_cluster_login
sel="app.kubernetes.io/managed-by=${PREG_MANAGED_BY}"
objs=(${(f)"$(oc get imagedigestmirrorset,imagetagmirrorset -l "${sel}" -o name 2>/dev/null || true)"})
cats=(${(f)"$(oc get catalogsource -n openshift-marketplace -l "${sel}" -o name 2>/dev/null || true)"})
${IBM} && objs+=(${(f)"$(oc get imagedigestmirrorset/cloud-pak-for-data-mirror imagetagmirrorset/cloud-pak-for-data-mirror -o name 2>/dev/null || true)"})
disabled="$(oc get operatorhub cluster -o jsonpath='{.spec.disableAllDefaultSources}' 2>/dev/null || true)"

(( ${#objs} + ${#cats} )) || [[ "${disabled}" == true ]] || { preg_info "Nothing of ours on the cluster."; exit 0; }
(( ${#objs} )) && print -rl -- "${objs[@]}" | sed 's/^/  delete /'
(( ${#cats} )) && print -rl -- "${cats[@]}" | sed 's|^|  delete (openshift-marketplace) |'
[[ "${disabled}" == true ]] && print -r -- "  re-enable the default OperatorHub sources"
${YES} || { preg_info "List only - re-run with --yes."; exit 0; }

for o in $(oc get imagedigestmirrorset,imagetagmirrorset -l "${sel}" -o name 2>/dev/null); do oc delete "${o}"; done
oc delete catalogsource -n openshift-marketplace -l "${sel}" 2>/dev/null || true
${IBM} && oc delete imagedigestmirrorset/cloud-pak-for-data-mirror imagetagmirrorset/cloud-pak-for-data-mirror --ignore-not-found
[[ "${disabled}" == true ]] && oc patch operatorhub cluster --type=merge -p '{"spec":{"disableAllDefaultSources":false}}' >/dev/null
preg_wait_mcp_updated "${MIRROR_MCP_TIMEOUT:-3600}"
preg_info "Mirror configuration removed."
