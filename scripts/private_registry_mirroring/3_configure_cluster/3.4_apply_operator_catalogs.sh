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
# 3.4 Operator catalogs (shared) - from 2.2's oc-mirror cluster-resources
# ------------------------------------------------------------------------------
#   - oc-mirror's generic names (idms-operator-0, itms-generic-0, cs-*) become
#     mirror-shared-operators[-n] and, with the default sources disabled,
#     redhat-operators / certified-operators / community-operators - so every
#     existing "source: redhat-operators" Subscription resolves unchanged
#   - push root -> pull root in every reference (ICR: <region>.icr.io pushed,
#     private.<region>.icr.io pulled)
#   - MIRROR_DISABLE_DEFAULT_CATALOGS (auto = local): operatorhub/cluster
#     disableAllDefaultSources=true BEFORE the renamed catalogs are created
#   - the OLM v1 ClusterCatalog is skipped unless MIRROR_APPLY_CLUSTERCATALOG=true
#   - waits for the CatalogSources (READY) and the MachineConfigPools
#
#   ./3.4_apply_operator_catalogs.sh [--current] [--dry-run] [--no-wait]
# ==============================================================================

CURRENT=false DRY=false WAIT=true
for _a in "$@"; do
    case "${_a}" in
        --current) CURRENT=true ;;
        --dry-run) DRY=true ;;
        --no-wait) WAIT=false ;;
        *) preg_die "Unknown argument: ${_a}" ;;
    esac
done
preg_resolve_registry
WS="${MIRROR_WORKSPACE}"
SHARED="$(preg_install_path shared)"
RES="$(cat "${WS}/${SHARED}/last-cluster-resources" 2>/dev/null || true)"
if [[ -z "${RES}" || "${RES}" == none ]]; then
    preg_info "No operator catalogs mirrored (2.2) - nothing to apply."
    exit 0
fi
[[ -d "${RES}" ]] || preg_die "oc-mirror cluster resources not found: ${RES} (run 2.2 first)"

DISABLE="$(preg_auto_bool "${MIRROR_DISABLE_DEFAULT_CATALOGS:-auto}")"
OUT="${WS}/cluster/catalogs"
args=(--in "${RES}" --out "${OUT}" --policy "$(preg_policy)" --rewrite "$(preg_push_root)=$(preg_pull_root)")
[[ "${DISABLE}" == true ]] && args+=(--rename-defaults)
preg_is_true "${MIRROR_APPLY_CLUSTERCATALOG:-false}" && args+=(--clustercatalog)
preg_engine catalog-resources "${args[@]}" >/dev/null
files=("${OUT}"/*.yaml(N))
(( ${#files} )) || preg_die "No resources produced from ${RES}"

if ${DRY}; then
    [[ "${DISABLE}" == true ]] && preg_info "[dry-run] would set operatorhub/cluster spec.disableAllDefaultSources=true"
    for f in "${files[@]}"; do
        preg_info "[dry-run] ${f:t}"
        sed 's/^/    /' "${f}" | head -30
    done
    exit 0
fi

${CURRENT} || preg_cluster_login
if [[ "${DISABLE}" == true ]]; then
    cur="$(oc get operatorhub cluster -o jsonpath='{.spec.disableAllDefaultSources}' 2>/dev/null || true)"
    if [[ "${cur}" != true ]]; then
        preg_warn "Disabling the default OperatorHub sources (the mirrored catalogs take over their names)."
        oc patch operatorhub cluster --type=merge -p '{"spec":{"disableAllDefaultSources":true}}' >/dev/null
        sleep 10   # let OLM remove the default CatalogSources before ours take their names
    fi
fi

changed=false catalogs=()
for f in "${files[@]}"; do
    kind="$(awk '/^kind:/ {print $2; exit}' "${f}")"
    name="$(awk '/^  name:/ {print $2; exit}' "${f}")"
    if [[ "${kind}" == (ImageDigestMirrorSet|ImageTagMirrorSet) ]] && ! oc diff -f "${f}" >/dev/null 2>&1; then
        changed=true
    fi
    oc apply -f "${f}" >/dev/null
    preg_info "applied ${kind}/${name}"
    [[ "${kind}" == CatalogSource ]] && catalogs+=("${name}")
done

if ${WAIT}; then
    for c in "${catalogs[@]}"; do
        preg_wait_for 900 "CatalogSource ${c} READY" \
            zsh -c "[[ \"\$(oc get catalogsource '${c}' -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}')\" == READY ]]"
    done
    ${changed} && preg_wait_mcp_updated "${MIRROR_MCP_TIMEOUT:-3600}"
fi
preg_info "Operator catalogs applied: ${catalogs[*]:-none}"
