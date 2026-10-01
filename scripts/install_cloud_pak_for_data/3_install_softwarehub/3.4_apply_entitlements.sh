#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# (legacy hardcoded sourcing - replaced by universal crawl below)
# source "${SCRIPT_DIR}/../source_env_setup.sh"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# ---
for var in LICENSE_ENTITLEMENTS PROD_LICENSE PROJECT_CPD_INST_OPERANDS; do
    if [[ -z "${(P)var:-}" ]]; then
        echo "Error: ${var} is not set. Set it in ./cpd_vars.sh before running this script."
        exit 1
    fi
done

PROD_APPLICABLE=(
    "cpd-enterprise"
    "cognos-analytics"
    "planning-analytics"
    "data-lineage"
    "data-lineage-reserved"
    "data-integration-unstructured-data"
    "data-product-hub"
    "watsonx-ai"
    "watsonx-data"
    "watsonx-gov-mm"
    "watsonx-gov-rc"
    "watsonx-orchestrate"
)

eval "${CPDM_OC_LOGIN}"

IFS=',' read -rA entitlements <<< "${LICENSE_ENTITLEMENTS}"

for entitlement in "${entitlements[@]}"; do
    entitlement="${entitlement// /}"
    production=${PROD_LICENSE}
    if (( ${PROD_APPLICABLE[(Ie)${entitlement}]} == 0 )); then
        production=false
    fi
    echo "[INFO] Applying entitlement: ${entitlement} (production=${production})"
    cpd-cli manage apply-entitlement \
        --instance_ns=${PROJECT_CPD_INST_OPERANDS} \
        --entitlement=${entitlement} \
        --production=${production}
done