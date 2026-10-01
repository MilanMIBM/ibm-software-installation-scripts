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

for var in CPDM_OC_LOGIN PROJECT_CPD_INST_OPERANDS; do
    if [[ -z "${(P)var:-}" ]]; then
        echo "Error: ${var} is not set. Set it in ./cpd_vars.sh before running this script."
        exit 1
    fi
done

eval "${CPDM_OC_LOGIN}"

# ---
# Enable watsonx.data Premium UI features (enable_watsonx_platform) on a non-Premium deployment.
# Requires wxdaddon CR to exist (watsonx.data >= 2.2.2).

echo "[INFO] Checking wxdaddon CR in namespace ${PROJECT_CPD_INST_OPERANDS}..."

if ! oc get wxdaddon/wxdaddon -n "${PROJECT_CPD_INST_OPERANDS}" &>/dev/null; then
    echo "[ERROR] wxdaddon/wxdaddon not found in ${PROJECT_CPD_INST_OPERANDS}. Is watsonx.data >= 2.2.2 installed?"
    exit 1
fi

CURRENT_VALUE=$(oc get wxdaddon/wxdaddon -n "${PROJECT_CPD_INST_OPERANDS}" \
    -o jsonpath='{.spec.enable_watsonx_platform}' 2>/dev/null || true)

if [[ "${CURRENT_VALUE}" == "true" ]]; then
    echo "[SKIP] enable_watsonx_platform is already set to true. Nothing to do."
    exit 0
fi

echo "[INFO] Patching wxdaddon/wxdaddon to enable Premium UI features..."

oc patch wxdaddon/wxdaddon \
    --namespace="${PROJECT_CPD_INST_OPERANDS}" \
    --type=merge \
    -p '{"spec":{"enable_watsonx_platform":true}}'

echo "[OK] Patch applied."

# Verify
VERIFIED=$(oc get wxdaddon/wxdaddon -n "${PROJECT_CPD_INST_OPERANDS}" \
    -o jsonpath='{.spec.enable_watsonx_platform}' 2>/dev/null || true)

if [[ "${VERIFIED}" == "true" ]]; then
    echo "[OK] Verified: enable_watsonx_platform=true"
else
    echo "[WARN] Verification returned: '${VERIFIED}'. The patch may not have taken effect yet."
fi

# Monitor pod readiness - wait up to 10 minutes for any rolling restart to settle
echo ""
echo "[INFO] Monitoring wxd pods for rolling restart (up to 10 minutes)..."

TIMEOUT=600
INTERVAL=15
ELAPSED=0

while (( ELAPSED < TIMEOUT )); do
    NOT_READY=$(oc get pods -n "${PROJECT_CPD_INST_OPERANDS}" \
        --no-headers 2>/dev/null \
        | grep -v "Completed\|Evicted" \
        | awk '{print $2, $3}' \
        | grep -v "^[0-9]*/[0-9]* Running$\|^[0-9]*/[0-9]* Succeeded$" \
        | wc -l | tr -d ' ')

    if [[ "${NOT_READY}" -eq 0 ]]; then
        echo "[OK] All pods are Running/Completed."
        break
    fi

    echo "[INFO] ${NOT_READY} pod(s) not yet ready - waiting ${INTERVAL}s... (${ELAPSED}s elapsed)"
    sleep "${INTERVAL}"
    (( ELAPSED += INTERVAL ))
done

if (( ELAPSED >= TIMEOUT )); then
    echo "[WARN] Timed out after ${TIMEOUT}s. Some pods may still be restarting:"
    oc get pods -n "${PROJECT_CPD_INST_OPERANDS}" | grep -v "Running\|Completed\|Evicted" || true
fi

echo ""
echo "=== wxdaddon status ==="
oc get wxdaddon -n "${PROJECT_CPD_INST_OPERANDS}" -o yaml | grep enable_watsonx_platform || true
