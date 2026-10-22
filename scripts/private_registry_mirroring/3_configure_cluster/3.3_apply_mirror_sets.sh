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
# 3.3 Image mirror sets (IDMS + ITMS)
# ------------------------------------------------------------------------------
#   1. installs/<id>.sh cluster  - install-specific objects first
#      (cpd: cpd-cli manage apply-icsp --registry=<pull root>/cpd -> IBM's
#      cloud-pak-for-data-mirror IDMS + ITMS)
#   2. ours, generated from 1.0's targets: one IDMS + ITMS per registry path,
#      named mirror-<path> (labels app.kubernetes.io/managed-by=private-registry-mirroring,
#      private-registry-mirroring/path=<path>), one entry per source repository
#      -> <pull root>/<path>/<repository>; for cpd also IBM's documented
#      registry.redhat.io -> <pull root>/cpd (MIRROR_CPD_REDHAT_HOST_MIRROR)
#      MIRROR_CLUSTER_REDIRECT=explicit: only mirror-cpd and mirror-shared
#   Policy: NeverContactSource for local (air-gapped), the default otherwise.
#   3. waits for the MachineConfigPools when anything changed.
# Operator catalogs (and their mirror sets) are 3.4.
#
#   ./3.3_apply_mirror_sets.sh [--current] [--dry-run] [--no-wait] [--prune]
#     --prune  delete our mirror-* objects whose path is no longer in the inventory
# ==============================================================================

CURRENT=false DRY=false WAIT=true PRUNE=false
for _a in "$@"; do
    case "${_a}" in
        --current) CURRENT=true ;;
        --dry-run) DRY=true ;;
        --no-wait) WAIT=false ;;
        --prune) PRUNE=true ;;
        *) preg_die "Unknown argument: ${_a}" ;;
    esac
done
preg_resolve_registry
WS="${MIRROR_WORKSPACE}"
PULL="$(preg_pull_root)"
POLICY="$(preg_policy)"
${CURRENT} || preg_cluster_login
export MIRROR_CLUSTER_DRY_RUN="${DRY}"

# --- 1. install-specific cluster objects -----------------------------------------------
for id in "${(@f)$(preg_installs)}"; do
    [[ -n "${id}" ]] || continue
    preg_run_hook 3_configure_cluster "${id}" cluster || preg_die "${id}: cluster hook failed"
done

# --- 2. our mirror sets ----------------------------------------------------------------
OUT="${WS}/cluster/mirror-sets"
rm -rf "${OUT}"; mkdir -p "${OUT}"
extra=()
CPD_PATH="$(preg_install_path cpd)"
if preg_in_list cpd "${MIRROR_INSTALLS:-}" && preg_is_true "${MIRROR_CPD_REDHAT_HOST_MIRROR:-true}"; then
    extra+=(--extra "${CPD_PATH}=registry.redhat.io=${CPD_PATH}")
fi
preg_engine mirror-sets --workspace "${WS}" --root "${PULL}" --policy "${POLICY}" --out "${OUT}" "${extra[@]}" >/dev/null
if ! preg_redirect_mirror_sets; then
    # explicit: installs other than CP4D carry their own image settings (3.5)
    for f in "${OUT}"/mirror-*.yaml(N); do
        [[ "${f:t}" == (mirror-${CPD_PATH}.yaml|mirror-$(preg_install_path shared).yaml) ]] || rm -f "${f}"
    done
fi

changed=false
files=("${OUT}"/mirror-*.yaml(N))
if (( ${#files} == 0 )); then
    preg_info "No images mapped - no mirror sets of ours to apply."
fi
for f in "${files[@]}"; do
    n="$(grep -c '^  - mirrors:' "${f}")"
    if ${DRY}; then
        preg_info "[dry-run] ${f:t}: IDMS + ITMS, $(( n / 2 )) source(s) each (policy ${POLICY})"
        sed -n '1,/^---$/p' "${f}" | sed 's/^/    /' | head -40
        continue
    fi
    if ! oc diff -f "${f}" >/dev/null 2>&1; then
        oc apply -f "${f}" >/dev/null
        changed=true
        preg_info "applied ${f:t%.yaml} (IDMS + ITMS, $(( n / 2 )) source(s) each)"
    else
        preg_info "unchanged ${f:t%.yaml}"
    fi
done

# --- stale objects of ours ---------------------------------------------------------------
want=(${files:t:r})
for kind in imagedigestmirrorset imagetagmirrorset; do
    for name in $(oc get "${kind}" -l "app.kubernetes.io/managed-by=${PREG_MANAGED_BY}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        [[ "${name}" == mirror-shared-operators* ]] && continue      # 3.4's
        (( ${want[(Ie)${name}]} )) && continue
        if ${PRUNE} && ! ${DRY}; then
            oc delete "${kind}" "${name}" >/dev/null && preg_info "deleted stale ${kind}/${name}"
            changed=true
        else
            preg_warn "stale ${kind}/${name} (not in the inventory) - --prune deletes it"
        fi
    done
done

if ${changed} && ${WAIT} && ! ${DRY}; then
    preg_wait_mcp_updated "${MIRROR_MCP_TIMEOUT:-3600}"
fi
