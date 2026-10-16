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
# 4.3 Hub <-> products on other clusters (Hub mode "auto", plan decision D5)
# ------------------------------------------------------------------------------
#   access-key   On a cluster that RUNS the Hub: print a new access key for a
#                product cluster (its CONCERT_REMOTE_HUB_ACCESS_KEY).
#   register     On a cluster whose products use a REMOTE Hub: add this
#                cluster's product instances to that Hub with IBM's
#                manage-product.sh (IBM's documented post-install step). The
#                runner Job runs on the Hub cluster (CONCERT_REMOTE_HUB_OC_LOGIN),
#                which therefore needs 0.2 once:
#                  CONCERT_TARGET_OC_LOGIN="$CONCERT_REMOTE_HUB_OC_LOGIN" ../0_initial_setup/0.2_prepare_installer_runner.sh
#
#   ./4.3_hub_remote_products.sh access-key
#   ./4.3_hub_remote_products.sh register [--product=concert|dataapps|workflows ...]
# ==============================================================================

ACTION="${1:-}"
shift || true

case "${ACTION}" in
access-key)
    concert_product_enabled hub || concert_die "This cluster does not run the Hub (remote Hub configured)."
    eval "${OC_LOGIN}"
    concert_warn "The key below grants access to this Hub - hand it over securely."
    concert_run --name access-key --timeout 600 -- concert-hub/bin/access-key "--namespace=${PROJECT_CONCERT_HUB}" --generate
    ;;
register)
    concert_remote_hub_enabled || concert_die "No remote Hub configured (CONCERT_HUB_MODE=auto with CONCERT_REMOTE_HUB_URL + key)."
    concert_require_vars CONCERT_REMOTE_HUB_OC_LOGIN
    products=()
    for _arg in "$@"; do
        case "${_arg}" in
            --product=*) products+=("${_arg#*=}") ;;
            *) concert_die "Unknown argument: ${_arg}" ;;
        esac
    done
    if (( ${#products} == 0 )); then
        for p in concert dataapps workflows; do concert_product_enabled "${p}" && products+=("${p}"); done
    fi

    # Instance URLs come from this (the product) cluster's routes.
    eval "${OC_LOGIN}"
    typeset -A url
    for p in "${products[@]}"; do
        case "${p}" in
            concert)   r="$(oc get route concert  -n "${PROJECT_CONCERT}"           -o jsonpath='{.spec.host}' 2>/dev/null || true)" ;;
            dataapps)  r="$(oc get route dataapps -n "${PROJECT_CONCERT_DATAAPPS}"  -o jsonpath='{.spec.host}' 2>/dev/null || true)" ;;
            workflows) r="$(oc get route solis-gw -n "${PROJECT_CONCERT_WORKFLOWS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)" ;;
            *) concert_die "Unknown product ${p}" ;;
        esac
        [[ -n "${r}" ]] || concert_die "No route for ${p} on this cluster - install it first."
        url[${p}]="https://${r}:443"
    done

    # Switch to the Hub cluster for the runner Job.
    eval "${CONCERT_REMOTE_HUB_OC_LOGIN}"
    for p in "${products[@]}"; do
        concert_info "Registering ${p} (${url[${p}]}) with the Hub in ${CONCERT_REMOTE_HUB_NAMESPACE:-ibm-platform-hub}"
        # --kc-entrypoint-url: the Keycloak client's rootUrl, as IBM's own
        # installer sets it when it registers a product with a local Hub.
        concert_run --name "register-${p}" --timeout 900 -- concert-hub/bin/manage-product.sh \
            --action=add --deployment-type=k8s "--namespace=${CONCERT_REMOTE_HUB_NAMESPACE:-ibm-platform-hub}" \
            "--product-id=${p}" "--instance-url=${url[${p}]}" "--kc-entrypoint-url=${url[${p}]%:443}" --restart-hub=true
    done
    eval "${OC_LOGIN}"
    ;;
*)
    concert_die "Usage: $0 access-key | register [--product=<id>]..."
    ;;
esac
