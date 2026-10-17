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
# Uninstall Concert Optimize (Turbonomic)
# ------------------------------------------------------------------------------
#   ./x_uninstall_optimize.sh [--delete-namespace] [--delete-crd] [--yes]
# Reverses 5_install_optimize:
#   - detaches Optimize from the Hub (IBM's manage-product.sh --action=remove,
#     Hub restart) - skipped with a warning when the runner is unavailable
#   - deletes the Xl (the t8c-operator uninstalls the Helm release), then the
#     operator, the route and the TLS/CA secrets, and the anyuid grant
# Turbonomic's volumes (database, Kafka, rsyslog, ...) are kept - 5.2/5.4 mark
# them helm.sh/resource-policy: keep, so a reinstall reuses them (Prometheus'
# 8 Gi volume is the exception: its chart ignores the annotation).
# --delete-namespace also deletes the namespace and with it those volumes -
# that destroys all Optimize data.
# --delete-crd also deletes the cluster-wide Xl CRD (refused while any Xl
# exists anywhere).
# ==============================================================================

DELETE_NS=false
DELETE_CRD=false
YES=false
for _arg in "$@"; do
    case "${_arg}" in
        --delete-namespace) DELETE_NS=true ;;
        --delete-crd)       DELETE_CRD=true ;;
        --yes|-y)           YES=true ;;
        *) concert_die "Unknown argument: ${_arg}" ;;
    esac
done

eval "${OC_LOGIN}"
NS="$(concert_optimize_namespace)"
CRD="xls.charts.helm.k8s.io"
oc get namespace "${NS}" >/dev/null 2>&1 || { concert_info "Namespace ${NS} not found - nothing to uninstall."; exit 0; }

concert_warn "This removes Concert Optimize (Turbonomic) from ${NS} on $(oc whoami --show-server)$(${DELETE_NS} && print -r -- ' and DELETES the namespace with all Turbonomic data')."
if ! ${YES}; then
    read -r "reply?Type 'uninstall' to continue: "
    [[ "${reply}" == uninstall ]] || concert_die "Aborted."
fi

# --- Hub --------------------------------------------------------------------------
if concert_remote_hub_enabled || [[ -n "$(concert_hub_product_url turbonomic)" ]]; then
    concert_info "Detaching Optimize from the Hub"
    concert_hub_manage_product remove turbonomic \
        || concert_warn "Could not detach Optimize - remove it later: concert-hub/bin/manage-product.sh --action=remove --product-id=turbonomic"
else
    concert_info "The local Hub has no Optimize entry - nothing to detach."
fi

# --- Turbonomic -------------------------------------------------------------------
if oc get xl "${CONCERT_OPTIMIZE_XL}" -n "${NS}" >/dev/null 2>&1; then
    oc delete xl "${CONCERT_OPTIMIZE_XL}" -n "${NS}" --wait=false >/dev/null
    _xl_gone() { ! oc get xl "${CONCERT_OPTIMIZE_XL}" -n "${NS}" >/dev/null 2>&1; }
    concert_wait_for 900 "the t8c-operator to remove the Turbonomic release" _xl_gone \
        || concert_warn "Xl ${NS}/${CONCERT_OPTIMIZE_XL} is still there (finalizer) - check oc logs deploy/t8c-operator -n ${NS}."
fi

oc delete route "${CONCERT_OPTIMIZE_ROUTE}" -n "${NS}" --ignore-not-found >/dev/null
oc delete secret "${CONCERT_OPTIMIZE_TLS_SECRET}" "${CONCERT_OPTIMIZE_CA_SECRET}" -n "${NS}" --ignore-not-found >/dev/null
oc delete deployment t8c-operator -n "${NS}" --ignore-not-found >/dev/null
oc delete networkpolicy t8c-operator-egress -n "${NS}" --ignore-not-found >/dev/null
oc delete rolebinding,role,serviceaccount t8c-operator -n "${NS}" --ignore-not-found >/dev/null
oc adm policy remove-scc-from-group anyuid "system:serviceaccounts:${NS}" >/dev/null 2>&1 || true
concert_info "Operator, route and secrets removed from ${NS}; Turbonomic's volumes are kept."

if ${DELETE_NS}; then
    oc delete namespace "${NS}" --ignore-not-found --wait=false >/dev/null
    concert_info "Namespace ${NS} deletion started (its volumes go with it)."
fi

if ${DELETE_CRD}; then
    if [[ -n "$(oc get xl -A --no-headers 2>/dev/null || true)" ]]; then
        concert_warn "Other Xl resources still exist - keeping CRD ${CRD}."
    else
        oc delete crd "${CRD}" --ignore-not-found >/dev/null
        concert_info "CRD ${CRD} deleted."
    fi
fi
concert_info "Optimize uninstall finished. Set CONCERT_INSTALL_OPTIMIZE=false in the config to keep it off."
