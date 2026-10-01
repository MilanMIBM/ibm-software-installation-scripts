#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# Re-exec under zsh if running under a different shell (e.g. bash)
if [ -z "${ZSH_VERSION:-}" ]; then exec /bin/zsh "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# (legacy hardcoded sourcing - replaced by universal crawl below)
# source "${SCRIPT_DIR}/../source_env_setup.sh"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# ---

for var in CPDM_OC_LOGIN PROJECT_CPD_INST_OPERANDS PREP_WXO; do
    if [[ -z "${(P)var:-}" ]]; then
        echo "Error: ${var} is not set. Set it in ./cpd_vars.sh before running this script."
        exit 1
    fi
done

eval "${OC_LOGIN}"

echo "[INFO] Enabling access to watsonx Orchestrate images for the Agent Development Kit (ADK)..."

# Use IBM_ENTITLEMENT_KEY directly if set; otherwise extract from the cluster pull secret
if [[ -n "${IBM_ENTITLEMENT_KEY:-}" ]]; then
    echo "[INFO] Using IBM_ENTITLEMENT_KEY from environment."
else
    echo "[INFO] IBM_ENTITLEMENT_KEY is not set - extracting from the global pull secret..."
    IBM_ENTITLEMENT_KEY=$(oc get secret/pull-secret \
        -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' \
        | base64 -d | jq -r '.auths["cp.icr.io"].auth' | base64 -d | cut -d ':' -f2)
    if [[ -z "${IBM_ENTITLEMENT_KEY:-}" ]]; then
        echo "Error: Could not extract IBM_ENTITLEMENT_KEY from the global pull secret."
        exit 1
    fi
    echo "[INFO] Successfully extracted IBM_ENTITLEMENT_KEY from pull secret."
fi

echo "[INFO] Creating/updating secret wo-wxo-docker-proxy-env-secret in ${PROJECT_CPD_INST_OPERANDS}..."
oc create secret generic wo-wxo-docker-proxy-env-secret \
    -n "${PROJECT_CPD_INST_OPERANDS}" \
    --from-literal=IBM_CONTAINER_REGISTRY_API_KEY="${IBM_ENTITLEMENT_KEY}" \
    --dry-run=client -o yaml | oc apply -f -

echo "[INFO] Labelling secret wo-wxo-docker-proxy-env-secret..."
oc label secret wo-wxo-docker-proxy-env-secret \
    -n "${PROJECT_CPD_INST_OPERANDS}" \
    app.kubernetes.io/component=components-services \
    --overwrite

echo "[INFO] Done. watsonx Orchestrate ADK image access is configured."
