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
# 5.5 Attach Optimize to the Hub (IBM: "Installing capabilities" - attach)
# ------------------------------------------------------------------------------
# IBM's concert-hub/bin/manage-product.sh --action=add --product-id=turbonomic
# in the runner, then a Hub restart, so Optimize shows in the platform
# navigation. The Hub ships the turbonomic product entry ("Optimize", nav at
# /api/v3/solis/nav); manage-product.sh records the instance URL in the Hub's
# solis-account-instances-cm and the browser URL as a Keycloak redirect URI.
#
# URLs follow what IBM's installer does for Concert, Data Apps and Workflows:
#   local Hub   instance = https://concert-gateway.<ns>.svc.cluster.local:443
#               (in-cluster), Keycloak entrypoint = the optimize route
#   remote Hub  instance = entrypoint = the optimize route; runs on the Hub's
#               cluster (CONCERT_REMOTE_HUB_OC_LOGIN, which needs 0.2 once)
#
#   ./5.5_attach_optimize_to_hub.sh [--force]   --force re-attaches (and
#                                               restarts the Hub) even when the
#                                               local Hub already has the URL
# ==============================================================================

FORCE=false
for _arg in "$@"; do
    case "${_arg}" in
        --force) FORCE=true ;;
        *) concert_die "Unknown argument: ${_arg}" ;;
    esac
done

concert_product_enabled optimize || { concert_info "Optimize is not selected - nothing to do."; exit 0; }

eval "${OC_LOGIN}"
NS="$(concert_optimize_namespace)"
HOST="$(oc get route "${CONCERT_OPTIMIZE_ROUTE}" -n "${NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
[[ -n "${HOST}" ]] || concert_die "No route ${NS}/${CONCERT_OPTIMIZE_ROUTE} - run 5.4_enable_concert_gateway.sh first."
EXTERNAL="https://${HOST}"

if concert_remote_hub_enabled; then
    INSTANCE="${EXTERNAL}:443"
    concert_info "Attaching Optimize (${INSTANCE}) to the remote Hub ${CONCERT_REMOTE_HUB_URL}"
else
    INSTANCE="https://concert-gateway.${NS}.svc.cluster.local:443"
    current="$(concert_hub_product_url turbonomic)"
    if [[ "${current}" == "${INSTANCE}" ]] && ! ${FORCE}; then
        concert_info "The Hub already has Optimize at ${INSTANCE} - nothing to do (--force re-attaches)."
        exit 0
    fi
    concert_info "Attaching Optimize (${INSTANCE}) to the Hub in ${PROJECT_CONCERT_HUB}"
fi

concert_hub_manage_product add turbonomic "${INSTANCE}" "${EXTERNAL}" \
    || concert_die "manage-product.sh failed - see the runner log above."

concert_info "Optimize attached. The Hub restarted; it shows in the platform navigation in a few minutes."
concert_info "Next: 5.6_optimize_status.sh"
