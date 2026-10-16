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
# 1.4 Workflows FaaS: trust the Workflows registry route (only when FaaS is on)
# ------------------------------------------------------------------------------
# FaaS builds function images and pushes them to the Workflows route, so every
# node must accept it as an insecure registry (IBM docs, step 4).
#
# IBM's documented command (`oc patch ... --type=merge -p
# '{"spec":{"registrySources":{"insecureRegistries":["<route>"]}}}'`) REPLACES
# the whole list. This script appends the route to whatever is there instead,
# then waits for the MachineConfigPool rollout. --remove takes it out again
# (also done by x_uninstall_concert.sh).
# ==============================================================================

REMOVE=false
[[ "${1:-}" == --remove ]] && REMOVE=true

if ! ${REMOVE} && ! concert_product_enabled faas; then
    concert_info "Workflows FaaS is off - nothing to do."
    exit 0
fi

eval "${OC_LOGIN}"

ROUTE="$(concert_workflows_address)" || concert_die "Could not determine the Workflows route host (apps domain)."
current="$(oc get image.config.openshift.io cluster -o json | jq -c '.spec.registrySources.insecureRegistries // []')"

if ${REMOVE}; then
    jq -e --arg r "${ROUTE}" 'index($r)' <<<"${current}" >/dev/null || { concert_info "${ROUTE} is not listed - nothing to remove."; exit 0; }
    updated="$(jq -c --arg r "${ROUTE}" 'map(select(. != $r))' <<<"${current}")"
else
    if jq -e --arg r "${ROUTE}" 'index($r)' <<<"${current}" >/dev/null; then
        concert_info "${ROUTE} is already an insecure registry - nothing to do."
        exit 0
    fi
    allowed="$(oc get image.config.openshift.io cluster -o jsonpath='{.spec.registrySources.allowedRegistries}' 2>/dev/null || true)"
    [[ -n "${allowed}" ]] && concert_warn "image.config has allowedRegistries set - add ${ROUTE} there too, or FaaS pulls are blocked."
    updated="$(jq -c --arg r "${ROUTE}" '. + [$r]' <<<"${current}")"
fi

concert_info "insecureRegistries: ${current} -> ${updated}"
oc patch image.config.openshift.io cluster --type=merge \
    -p "{\"spec\":{\"registrySources\":{\"insecureRegistries\":${updated}}}}" >/dev/null
concert_wait_mcp_updated 3600
