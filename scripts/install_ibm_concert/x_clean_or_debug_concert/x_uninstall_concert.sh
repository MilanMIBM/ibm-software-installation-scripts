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
# Uninstall IBM Concert products
# ------------------------------------------------------------------------------
#   ./x_uninstall_concert.sh [--product=<p>]... [--delete-namespaces] [--yes]
# Products: workflows dataapps concert hub (default: every selected product,
# removed in that order). Runs IBM's bin/uninstall-products-on-k8s --force in
# the runner, then reverts what these scripts changed cluster-wide:
#   - the FaaS insecure-registry entry (1.4 --remove; MachineConfigPool rollout)
# --delete-namespaces also deletes the product namespaces (and with them the
# external data store secrets). Data stores themselves are NOT touched - see
# x_uninstall_datastores.sh. Istio/Service Mesh stay (they may be shared).
# Reinstalling a product later reconnects to the same external stores.
# ==============================================================================

products=()
DELETE_NS=false
YES=false
for _arg in "$@"; do
    case "${_arg}" in
        --product=*)         products+=("${_arg#*=}") ;;
        --delete-namespaces) DELETE_NS=true ;;
        --yes|-y)            YES=true ;;
        *) concert_die "Unknown argument: ${_arg}" ;;
    esac
done
if (( ${#products} == 0 )); then
    for p in workflows dataapps concert hub; do concert_product_enabled "${p}" && products+=("${p}"); done
fi
(( ${#products} )) || concert_die "Nothing to uninstall."

eval "${OC_LOGIN}"
concert_warn "This removes: ${products[*]} from $(oc whoami --show-server)$(${DELETE_NS} && print -r -- ' and deletes their namespaces')."
if ! ${YES}; then
    read -r "reply?Type 'uninstall' to continue: "
    [[ "${reply}" == uninstall ]] || concert_die "Aborted."
fi

for p in "${products[@]}"; do
    ns="$(concert_product_namespace "${p}")"
    [[ -n "${ns}" ]] || concert_die "Unknown product ${p} (workflows|dataapps|concert|hub)"
    if ! oc get namespace "${ns}" >/dev/null 2>&1; then
        concert_info "${p}: namespace ${ns} not found - skipping."
        continue
    fi
    args=("--product=${p}" "--product_ns=${ns}" --force)
    concert_local_hub_enabled && args+=("--hub_ns=${PROJECT_CONCERT_HUB}")
    files=()
    [[ -f "${CONCERT_CONFIG_DIR}/params.ini" ]] && files=(--file "${CONCERT_CONFIG_DIR}/params.ini")
    concert_info "Uninstalling ${p} from ${ns}"
    concert_run --name "uninstall-${p}" --timeout 3600 "${files[@]}" -- \
        bin/uninstall-products-on-k8s "${args[@]}" || concert_warn "IBM's uninstall reported an error for ${p}."
done

if (( ${products[(Ie)workflows]} )); then
    "${_CP4D_REPO_ROOT}/scripts/install_ibm_concert/1_registry_access_and_mirroring/1.4_set_up_faas_insecure_registry.sh" --remove || true
fi

if ${DELETE_NS}; then
    for p in "${products[@]}"; do
        ns="$(concert_product_namespace "${p}")"
        [[ "${p}" == workflows ]] && oc delete namespace "${PROJECT_CONCERT_WORKFLOWS_FAAS}" --ignore-not-found --wait=false
        oc delete namespace "${ns}" --ignore-not-found --wait=false
    done
    concert_info "Namespace deletion started (finalizers may take a few minutes)."
fi
concert_info "Uninstall finished."
