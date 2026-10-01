#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# Re-exec under zsh if running under a different shell (e.g. bash)
if [ -z "${ZSH_VERSION:-}" ]; then exec /bin/zsh "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# ---
# WHY THIS SCRIPT EXISTS:
#   The <cluster>-dashboards-config ConfigMap holding opensearch_dashboards.yml is
#   OWNED by the OpenSearchCluster CR (see its ownerReferences / the "Owner" field
#   in the console). The opster operator regenerates that ConfigMap on every
#   reconcile, so editing it directly - by console, `oc edit`, or patch - is
#   reverted, usually within seconds.
#
#   The durable path is spec.dashboards.additionalConfig on the CR. The operator
#   merges those keys into the generated opensearch_dashboards.yml and rolls the
#   dashboards Deployment itself.
#
#   additionalConfig is map[string]string in the CRD, so values MUST be quoted
#   strings ("true", not true) or the patch is rejected by validation. The
#   operator renders them unquoted into the YAML, giving `explore.enabled: true`.
#
# NOTE: a merge patch is used rather than a JSON `add` op on purpose. `add` on
#   additionalConfig replaces the whole map and would wipe keys the operator or a
#   previous step placed there; merge semantics on map[string]string add keys
#   without clobbering their siblings.
# ---

for var in OC_LOGIN; do
    if [[ -z "${(P)var:-}" ]]; then
        echo "Error: ${var} is not set. Set it in ./cpd_vars.sh before running this script."
        exit 1
    fi
done

eval "${OC_LOGIN}"

# Switch to the operands project if the login landed elsewhere.
if [[ "$(oc project -q 2>/dev/null || true)" != "${PROJECT_CPD_INST_OPERANDS}" ]]; then
    echo "[INFO] Switching project to ${PROJECT_CPD_INST_OPERANDS}."
    oc project "${PROJECT_CPD_INST_OPERANDS}" >/dev/null
fi

# Set DRY_RUN=true to report what would change without patching anything.
DRY_RUN="${DRY_RUN:-false}"

# Wait for each dashboards Deployment to finish rolling after a patch.
WAIT_FOR_ROLLOUT="${WAIT_FOR_ROLLOUT:-true}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-5m}"

# Keys to merge into opensearch_dashboards.yml. Values are strings by CRD
# contract; override this list by exporting OSEARCH_DASHBOARDS_CONFIG as a JSON
# object before running, e.g.
#   OSEARCH_DASHBOARDS_CONFIG='{"explore.enabled":"true"}' ./5_u_patch_opensearch_dashboards_config.sh
OSEARCH_DASHBOARDS_CONFIG="${OSEARCH_DASHBOARDS_CONFIG:-$(cat <<'JSON'
{
  "explore.enabled": "true",
  "data_source.enabled": "true",
  "workspace.enabled": "true"
}
JSON
)}"

if ! print -r -- "${OSEARCH_DASHBOARDS_CONFIG}" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "[ERROR] OSEARCH_DASHBOARDS_CONFIG is not a valid JSON object."
    exit 1
fi

# Non-string values are silently dropped by the API server's validation on a
# map[string]string field, so fail loudly here instead.
if ! print -r -- "${OSEARCH_DASHBOARDS_CONFIG}" | jq -e 'all(.[]; type == "string")' >/dev/null 2>&1; then
    echo "[ERROR] All values in OSEARCH_DASHBOARDS_CONFIG must be strings (use \"true\", not true)."
    print -r -- "${OSEARCH_DASHBOARDS_CONFIG}" | jq -r 'to_entries[] | select(.value | type != "string") | "[ERROR]   \(.key): \(.value) is a \(.value | type)"'
    exit 1
fi

echo ""
echo "=== Keys to apply to opensearch_dashboards.yml ==="
print -r -- "${OSEARCH_DASHBOARDS_CONFIG}" | jq -r 'to_entries[] | "  \(.key): \(.value)"'

# ---
# Discover OpenSearch instances. Pass cluster names as arguments to target a
# subset; with no arguments every cluster in the operands project is patched.

if [[ $# -gt 0 ]]; then
    SERVICE_IDS=("$@")
else
    SERVICE_IDS=(${(f)"$(oc get opensearchclusters -n "${PROJECT_CPD_INST_OPERANDS}" \
        --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)"})
fi

if [[ ${#SERVICE_IDS[@]} -eq 0 ]]; then
    echo ""
    echo "[WARN] No OpenSearch service instances found in ${PROJECT_CPD_INST_OPERANDS}. Nothing to do."
    exit 0
fi

echo ""
echo "[INFO] Target OpenSearch instances: ${SERVICE_IDS[*]}"

PATCHED=0
SKIPPED=0
FAILED=0

for CLUSTER_NAME in "${SERVICE_IDS[@]}"; do
    [[ -z "${CLUSTER_NAME}" ]] && continue

    echo ""
    echo "=== Patching dashboards config for: ${CLUSTER_NAME} ==="

    if ! oc get opensearchcluster "${CLUSTER_NAME}" -n "${PROJECT_CPD_INST_OPERANDS}" &>/dev/null; then
        echo "[ERROR] OpenSearchCluster ${CLUSTER_NAME} not found in ${PROJECT_CPD_INST_OPERANDS}."
        (( FAILED += 1 ))
        continue
    fi

    # If something upstream owns this CR, our patch is reverted on the owner's
    # next reconcile. Warn rather than abort - the patch still takes effect and
    # is useful for a live cluster, it just may not survive.
    OWNER=$(oc get opensearchcluster "${CLUSTER_NAME}" -n "${PROJECT_CPD_INST_OPERANDS}" \
        -o jsonpath='{.metadata.ownerReferences[*].kind}/{.metadata.ownerReferences[*].name}' 2>/dev/null || true)
    if [[ -n "${OWNER}" && "${OWNER}" != "/" ]]; then
        echo "[WARN] ${CLUSTER_NAME} is owned by ${OWNER}."
        echo "[WARN] A controller reconcile may revert this patch; set the keys at the source for a permanent change."
    fi

    CURRENT=$(oc get opensearchcluster "${CLUSTER_NAME}" -n "${PROJECT_CPD_INST_OPERANDS}" \
        -o jsonpath='{.spec.dashboards.additionalConfig}' 2>/dev/null || true)
    [[ -z "${CURRENT}" ]] && CURRENT="{}"

    # Already-correct clusters are left alone so re-runs do not churn the
    # dashboards Deployment.
    if print -r -- "${CURRENT}" | jq -e --argjson want "${OSEARCH_DASHBOARDS_CONFIG}" \
        'to_entries | from_entries as $have | $want | to_entries | all(.[]; $have[.key] == .value)' >/dev/null 2>&1; then
        echo "[SKIP] ${CLUSTER_NAME} already has all requested keys."
        (( SKIPPED += 1 ))
        continue
    fi

    print -r -- "${CURRENT}" | jq -r --argjson want "${OSEARCH_DASHBOARDS_CONFIG}" \
        '. as $have | $want | to_entries[] | select($have[.key] != .value) | "[INFO] \(.key): \($have[.key] // "<unset>") -> \(.value)"'

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "[INFO] DRY_RUN=true - ${CLUSTER_NAME} not patched."
        continue
    fi

    PATCH=$(jq -nc --argjson cfg "${OSEARCH_DASHBOARDS_CONFIG}" \
        '{spec: {dashboards: {additionalConfig: $cfg}}}')

    if oc patch opensearchcluster "${CLUSTER_NAME}" -n "${PROJECT_CPD_INST_OPERANDS}" \
        --type=merge -p "${PATCH}" >/dev/null; then
        echo "[OK] Patched spec.dashboards.additionalConfig on ${CLUSTER_NAME}."
        (( PATCHED += 1 ))
    else
        echo "[ERROR] Failed to patch ${CLUSTER_NAME}."
        (( FAILED += 1 ))
        continue
    fi

    # The operator rewrites the ConfigMap and rolls the Deployment. Waiting here
    # surfaces a bad key as a failed rollout rather than a silent crashloop.
    if [[ "${WAIT_FOR_ROLLOUT}" == "true" ]]; then
        DASHBOARDS_DEPLOY="${CLUSTER_NAME}-dashboards"
        if oc get deploy "${DASHBOARDS_DEPLOY}" -n "${PROJECT_CPD_INST_OPERANDS}" &>/dev/null; then
            echo "[INFO] Waiting for ${DASHBOARDS_DEPLOY} to roll out (timeout ${ROLLOUT_TIMEOUT})."
            if oc rollout status "deploy/${DASHBOARDS_DEPLOY}" -n "${PROJECT_CPD_INST_OPERANDS}" \
                --timeout="${ROLLOUT_TIMEOUT}" 2>/dev/null; then
                echo "[OK] ${DASHBOARDS_DEPLOY} rolled out."
            else
                echo "[WARN] ${DASHBOARDS_DEPLOY} did not report ready within ${ROLLOUT_TIMEOUT}."
                echo "[WARN] Check the dashboards container logs - an unsupported key or a plugin"
                echo "[WARN] missing from the shipped image will crashloop the pod:"
                echo "[WARN]   oc logs -n ${PROJECT_CPD_INST_OPERANDS} deploy/${DASHBOARDS_DEPLOY} --tail=50"
            fi
        else
            echo "[WARN] Deployment ${DASHBOARDS_DEPLOY} not found; skipping rollout wait."
        fi
    fi

    # Show what the operator actually rendered into the ConfigMap.
    CM="${CLUSTER_NAME}-dashboards-config"
    if oc get cm "${CM}" -n "${PROJECT_CPD_INST_OPERANDS}" &>/dev/null; then
        echo ""
        echo "--- ${CM} / opensearch_dashboards.yml ---"
        oc get cm "${CM}" -n "${PROJECT_CPD_INST_OPERANDS}" \
            -o jsonpath='{.data.opensearch_dashboards\.yml}' 2>/dev/null | sed 's/^/    /'
        echo ""
    fi
done

# ---

echo ""
echo "=== Summary ==="
echo "[INFO] Patched: ${PATCHED}   Already current: ${SKIPPED}   Failed: ${FAILED}"

if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[INFO] DRY_RUN=true - no changes were made."
fi

if [[ ${FAILED} -gt 0 ]]; then
    exit 1
fi
