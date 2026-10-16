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
# Rolling restart of Concert workloads
# ------------------------------------------------------------------------------
#   ./x_restart_concert_components.sh                      all selected products
#   ./x_restart_concert_components.sh concert workflows    only those products
# Products: hub concert dataapps workflows securecoder. The Hub restarts last
# (products re-register with it on start). Waits for each rollout.
# ==============================================================================

eval "${OC_LOGIN}"

products=("$@")
(( ${#products} )) || products=(${(f)"$(concert_selected_products)"})
# Hub last
if (( ${products[(Ie)hub]} )); then
    products=(${products:#hub} hub)
fi

for p in "${products[@]}"; do
    ns="$(concert_product_namespace "${p}")"
    [[ -n "${ns}" ]] || concert_die "Unknown product ${p}"
    oc get namespace "${ns}" >/dev/null 2>&1 || { concert_warn "${ns} does not exist - skipping ${p}."; continue; }
    concert_info "Restarting ${p} in ${ns}"
    for w in $(oc get deployments,statefulsets -n "${ns}" -o name 2>/dev/null); do
        oc rollout restart "${w}" -n "${ns}" >/dev/null
    done
    for w in $(oc get deployments,statefulsets -n "${ns}" -o name 2>/dev/null); do
        oc rollout status "${w}" -n "${ns}" --timeout=900s || concert_warn "${w} did not finish rolling out."
    done
done
concert_info "Restart complete - check with 3_install_concert/3.3_concert_status.sh"
