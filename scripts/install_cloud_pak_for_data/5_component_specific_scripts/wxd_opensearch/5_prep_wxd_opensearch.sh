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

for var in OC_LOGIN PREP_OPENSEARCH; do
    if [[ -z "${(P)var:-}" ]]; then
        echo "Error: ${var} is not set. Set it in ./cpd_vars.sh before running this script."
        exit 1
    fi
done

eval "${OC_LOGIN}"

# ---
# Switch to the operands project if the login landed elsewhere. OC_LOGIN leaves
# the session on whatever project was last used, and several commands below rely
# on namespace-scoped context (notably the SCC access check).

if [[ "$(oc project -q 2>/dev/null || true)" != "${PROJECT_CPD_INST_OPERANDS}" ]]; then
    echo "[INFO] Switching project to ${PROJECT_CPD_INST_OPERANDS}."
    oc project "${PROJECT_CPD_INST_OPERANDS}" >/dev/null
else
    echo "[SKIP] Already on project ${PROJECT_CPD_INST_OPERANDS}."
fi

# ---
# Ensure wxd-opensearch-sa holds the privileged SCC.
# The OpenSearch node init container runs as UID 0; without this grant the
# StatefulSets sit at 0/N with FailedCreate ("unable to validate against any
# security context constraint") and no pods are ever created. The API then
# answers 401 via Traefik because there is no backend behind the route.

OSEARCH_SA="wxd-opensearch-sa"
OSEARCH_SCC="privileged"

echo ""
echo "=== Verifying ${OSEARCH_SCC} SCC for ${OSEARCH_SA} ==="

# -n is required: add-scc-to-user creates a namespaced RoleBinding, so the
# access check must be scoped to that namespace too. Without -n the check runs
# against whatever project the session is currently on and returns a false "no".
if oc auth can-i use "scc/${OSEARCH_SCC}" \
    --as="system:serviceaccount:${PROJECT_CPD_INST_OPERANDS}:${OSEARCH_SA}" \
    -n "${PROJECT_CPD_INST_OPERANDS}" &>/dev/null; then
    echo "[SKIP] ${OSEARCH_SA} already has the ${OSEARCH_SCC} SCC."
else
    echo "[INFO] ${OSEARCH_SA} is missing the ${OSEARCH_SCC} SCC. Applying it now."
    oc adm policy add-scc-to-user "${OSEARCH_SCC}" -z "${OSEARCH_SA}" -n "${PROJECT_CPD_INST_OPERANDS}"

    if oc auth can-i use "scc/${OSEARCH_SCC}" \
        --as="system:serviceaccount:${PROJECT_CPD_INST_OPERANDS}:${OSEARCH_SA}" \
        -n "${PROJECT_CPD_INST_OPERANDS}" &>/dev/null; then
        echo "[OK] Granted ${OSEARCH_SCC} SCC to ${OSEARCH_SA}."

        # StatefulSets blocked by the missing SCC retry on a backoff that can be
        # several minutes long. Nudge any that have no ready replicas.
        # Note: .status.readyReplicas is omitted entirely (not 0) when no pods
        # exist, so compare desired .spec.replicas against readyReplicas here
        # rather than filtering on readyReplicas==0 with jsonpath.
        for STS in $(oc get sts -n "${PROJECT_CPD_INST_OPERANDS}" -o json 2>/dev/null \
            | jq -r '.items[]
                     | select(.metadata.name | startswith("opensearch"))
                     | select((.status.readyReplicas // 0) < (.spec.replicas // 0))
                     | .metadata.name' || true); do
            echo "[INFO] Restarting stalled StatefulSet ${STS}."
            oc rollout restart "sts/${STS}" -n "${PROJECT_CPD_INST_OPERANDS}" || true
        done
    else
        echo "[ERROR] Failed to grant ${OSEARCH_SCC} SCC to ${OSEARCH_SA}."
        echo "[ERROR] OpenSearch pods cannot start without it. Resolve this before continuing."
        exit 1
    fi
fi

#--------------------------------
##### Opensearch uses block storage
#--------------------------------

oc get opensearchclusters -n "${PROJECT_CPD_INST_OPERANDS}"

oc get pods -n "${PROJECT_CPD_INST_OPERANDS}" | grep opensearch || true

# ---
# Expose OpenSearch service instances with passthrough routes and update Traefik TLS cert

SERVICE_IDS=(${(f)"$(oc get opensearchclusters -n "${PROJECT_CPD_INST_OPERANDS}" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null)"})

if [[ ${#SERVICE_IDS[@]} -eq 0 ]]; then
    echo "[WARN] No OpenSearch service instances found in ${PROJECT_CPD_INST_OPERANDS}. Skipping route creation."
else
    # Identify the Traefik ingress TLS certificate name once (shared across all instances)
    TRAEFIK_CERT=$(oc -n "${PROJECT_CPD_INST_OPERATORS}" get certificate --no-headers 2>/dev/null | grep traefik-ingress-tls | awk '{print $1}' | head -n1)
    if [[ -z "${TRAEFIK_CERT:-}" ]]; then
        echo "[WARN] Could not locate a traefik-ingress-tls certificate in ${PROJECT_CPD_INST_OPERATORS}. TLS patching will be skipped."
    fi

    for SERVICE_ID in "${SERVICE_IDS[@]}"; do
        echo ""
        echo "=== Exposing OpenSearch service: ${SERVICE_ID} ==="

        # Create passthrough route for OpenSearch backend (port 9200)
        if oc get route "${SERVICE_ID}-backend" -n "${PROJECT_CPD_INST_OPERATORS}" &>/dev/null; then
            echo "[SKIP] Route ${SERVICE_ID}-backend already exists."
        else
            oc create route passthrough "${SERVICE_ID}-backend" \
                --service=ibm-wxd-opensearch-traefik \
                --port=9200 \
                -n "${PROJECT_CPD_INST_OPERATORS}" \
                --wildcard-policy=None
            echo "[OK] Created route ${SERVICE_ID}-backend (port 9200)."
        fi

        # Create passthrough route for OpenSearch Dashboards (port 5601)
        if oc get route "${SERVICE_ID}-dashboards" -n "${PROJECT_CPD_INST_OPERATORS}" &>/dev/null; then
            echo "[SKIP] Route ${SERVICE_ID}-dashboards already exists."
        else
            oc create route passthrough "${SERVICE_ID}-dashboards" \
                --service=ibm-wxd-opensearch-traefik \
                --port=5601 \
                -n "${PROJECT_CPD_INST_OPERATORS}" \
                --wildcard-policy=None
            echo "[OK] Created route ${SERVICE_ID}-dashboards (port 5601)."
        fi

        # Obtain the backend route hostname and patch the Traefik TLS cert to include it
        if [[ -n "${TRAEFIK_CERT:-}" ]]; then
            BACKEND_HOST=$(oc get route "${SERVICE_ID}-backend" -n "${PROJECT_CPD_INST_OPERATORS}" --no-headers -o custom-columns=HOST:.spec.host 2>/dev/null || true)
            DASHBOARDS_HOST=$(oc get route "${SERVICE_ID}-dashboards" -n "${PROJECT_CPD_INST_OPERATORS}" --no-headers -o custom-columns=HOST:.spec.host 2>/dev/null || true)

            for HOSTNAME in "${BACKEND_HOST}" "${DASHBOARDS_HOST}"; do
                [[ -z "${HOSTNAME:-}" ]] && continue
                echo "[INFO] Patching Traefik cert ${TRAEFIK_CERT} to add dnsName: ${HOSTNAME}"
                oc -n "${PROJECT_CPD_INST_OPERATORS}" patch certificate "${TRAEFIK_CERT}" \
                    --type='json' \
                    -p="[{\"op\":\"add\",\"path\":\"/spec/dnsNames/-\",\"value\":\"${HOSTNAME}\"}]"
            done
        fi
    done

    # Delete orphaned backend/dashboards routes with no matching OpenSearch instance
    EXISTING_ROUTES=(${(f)"$(oc get routes -n "${PROJECT_CPD_INST_OPERATORS}" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep -E '\-(backend|dashboards)$')"} )
    for ROUTE in "${EXISTING_ROUTES[@]}"; do
        [[ -z "${ROUTE:-}" ]] && continue
        INSTANCE="${ROUTE%-backend}"
        INSTANCE="${INSTANCE%-dashboards}"
        if [[ ! " ${SERVICE_IDS[@]} " =~ " ${INSTANCE} " ]]; then
            echo "[INFO] Deleting orphaned route ${ROUTE} (instance ${INSTANCE} no longer exists)."
            oc delete route "${ROUTE}" -n "${PROJECT_CPD_INST_OPERATORS}"
        fi
    done

    echo ""
    echo "=== Routes in ${PROJECT_CPD_INST_OPERATORS} ==="
    oc get routes -n "${PROJECT_CPD_INST_OPERATORS}"
fi

# ---
# Apply annotations and labels to each OpenSearch instance (dashboards, nodePools, PVCs)

if [[ ${#SERVICE_IDS[@]} -eq 0 ]]; then
    echo "[WARN] No OpenSearch service instances found. Skipping annotations/labels patch."
else
    for CLUSTER_NAME in "${SERVICE_IDS[@]}"; do
        echo ""
        echo "=== Applying annotations/labels to OpenSearch instance: ${CLUSTER_NAME} ==="

        ANNOTATIONS=$(oc get opensearchcluster "${CLUSTER_NAME}" -n "${PROJECT_CPD_INST_OPERANDS}" -o jsonpath='{.spec.general.annotations}')
        LABELS=$(oc get opensearchcluster "${CLUSTER_NAME}" -n "${PROJECT_CPD_INST_OPERANDS}" -o jsonpath='{.spec.nodePools[0].labels}')

        NODE_POOL_COUNT=$(oc get opensearchcluster "${CLUSTER_NAME}" -n "${PROJECT_CPD_INST_OPERANDS}" -o jsonpath='{.spec.nodePools}' | jq '. | length')

        NODEPOOL_PATCHES=""
        for i in $(seq 0 $(( NODE_POOL_COUNT - 1 ))); do
            NODEPOOL_PATCHES+=",{\"op\":\"add\",\"path\":\"/spec/nodePools/${i}/annotations\",\"value\":${ANNOTATIONS}}"
        done

        oc patch opensearchcluster "${CLUSTER_NAME}" -n "${PROJECT_CPD_INST_OPERANDS}" \
            --type='json' -p="[
  {\"op\":\"add\",\"path\":\"/spec/dashboards/annotations\",\"value\":${ANNOTATIONS}},
  {\"op\":\"add\",\"path\":\"/spec/dashboards/labels\",\"value\":${LABELS}}
  ${NODEPOOL_PATCHES}
]"
        echo "[OK] Patched dashboards and nodePools for ${CLUSTER_NAME}."

        for PVC in $(oc get pvc -n "${PROJECT_CPD_INST_OPERANDS}" -l "opster.io/opensearch-cluster=${CLUSTER_NAME}" -o jsonpath='{.items[*].metadata.name}'); do
            oc patch pvc "${PVC}" -n "${PROJECT_CPD_INST_OPERANDS}" \
                --type='merge' -p "{\"metadata\":{\"annotations\":${ANNOTATIONS},\"labels\":${LABELS}}}"
            echo "[OK] Patched PVC ${PVC}."
        done
    done
fi


# ---
# Grant kubeadmin and cpadmin the all_access role in each OpenSearch instance
# Fixes: "OpenSearch roles could not be retrieved" in CP4D UI

OSEARCH_ROLE_MAPPING_USERS=("kubeadmin" "cpadmin")

_OSEARCH_ensure_role_mapping() {
    local url="$1" user="$2" pass="$3" principal="$4"

    # The PATCH "add" op below appends unconditionally, so re-running this script
    # would keep adding duplicate entries. Skip if the principal is already there.
    local current
    current=$(curl -sk -u "${user}:${pass}" \
        "${url}/_plugins/_security/api/rolesmapping/all_access" 2>/dev/null || true)
    if echo "${current}" | jq -e --arg p "${principal}" \
        '(.all_access.backend_roles // []) | index($p)' &>/dev/null; then
        echo "[SKIP] ${principal} already mapped to all_access."
        return
    fi

    local http_code
    http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
        -u "${user}:${pass}" \
        -X PATCH "${url}/_plugins/_security/api/rolesmapping/all_access" \
        -H 'Content-Type: application/json' \
        -d "[{\"op\":\"add\",\"path\":\"/backend_roles/-\",\"value\":\"${principal}\"}]")

    if [[ "${http_code}" == "200" ]]; then
        echo "[OK] ${principal} mapped to all_access (PATCH)."
        return
    fi

    if [[ "${http_code}" == "401" || "${http_code}" == "403" ]]; then
        echo "[ERROR] Authentication failed (HTTP ${http_code}) for ${principal}."
        echo "[ERROR] The route authenticates via CP4D AMS - check credentials in secret ${CPD_OSEARCH_ADMIN_SECRET:-platform-auth-idp-credentials}."
        return
    fi

    echo "[INFO] PATCH returned ${http_code} for ${principal}. Attempting PUT."
    local raw_existing existing merged
    raw_existing=$(curl -sk -u "${user}:${pass}" \
        "${url}/_plugins/_security/api/rolesmapping/all_access")
    if ! echo "${raw_existing}" | jq empty 2>/dev/null; then
        echo "[ERROR] GET rolesmapping returned non-JSON response. Cannot proceed with PUT for ${principal}."
        return
    fi
    existing=$(echo "${raw_existing}" | jq '.all_access.backend_roles // []')
    merged=$(echo "${existing}" | jq --arg p "${principal}" '. + [$p] | unique')
    http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
        -u "${user}:${pass}" \
        -X PUT "${url}/_plugins/_security/api/rolesmapping/all_access" \
        -H 'Content-Type: application/json' \
        -d "{\"backend_roles\":${merged}}")
    if [[ "${http_code}" == "200" ]]; then
        echo "[OK] ${principal} mapped to all_access (PUT)."
    else
        echo "[ERROR] Failed to map ${principal} to all_access (HTTP ${http_code})."
    fi
}

if [[ ${#SERVICE_IDS[@]} -eq 0 ]]; then
    echo "[WARN] No OpenSearch service instances found. Skipping role mapping."
else
    for CLUSTER_NAME in "${SERVICE_IDS[@]}"; do
        echo ""
        echo "=== Granting all_access role mapping in OpenSearch instance: ${CLUSTER_NAME} ==="

        OSEARCH_ADMIN_SECRET="${CLUSTER_NAME}-user-secret"
        OSEARCH_ADMIN_USER=$(oc get secret "${OSEARCH_ADMIN_SECRET}" -n "${PROJECT_CPD_INST_OPERANDS}" \
            -o jsonpath='{.data.username}' 2>/dev/null | base64 -d || true)
        OSEARCH_ADMIN_PASS=$(oc get secret "${OSEARCH_ADMIN_SECRET}" -n "${PROJECT_CPD_INST_OPERANDS}" \
            -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)

        if [[ -z "${OSEARCH_ADMIN_USER:-}" || -z "${OSEARCH_ADMIN_PASS:-}" ]]; then
            echo "[WARN] Could not retrieve admin credentials from secret ${OSEARCH_ADMIN_SECRET}. Skipping ${CLUSTER_NAME}."
            continue
        fi

        # The backend route does not terminate at OpenSearch: it passes through
        # Traefik, whose ForwardAuth middleware delegates to the CP4D AMS service
        # (/lakehouse/api/v3/auth/authenticate). AMS validates CP4D platform
        # identities, not OpenSearch's internal user database, so the
        # <cluster>-user-secret credentials above are rejected with a 401 there.
        # Use the CP4D IAM admin credentials for anything going over the route.
        # Note: platform-auth-idp-credentials is the correct source - the
        # admin-user-details secret holds a different password that AMS rejects.
        CPD_OSEARCH_ADMIN_SECRET="platform-auth-idp-credentials"
        CPD_OSEARCH_ADMIN_USER=$(oc get secret "${CPD_OSEARCH_ADMIN_SECRET}" -n "${PROJECT_CPD_INST_OPERANDS}" \
            -o jsonpath='{.data.admin_username}' 2>/dev/null | base64 -d || true)
        CPD_OSEARCH_ADMIN_PASS=$(oc get secret "${CPD_OSEARCH_ADMIN_SECRET}" -n "${PROJECT_CPD_INST_OPERANDS}" \
            -o jsonpath='{.data.admin_password}' 2>/dev/null | base64 -d || true)

        if [[ -z "${CPD_OSEARCH_ADMIN_USER:-}" || -z "${CPD_OSEARCH_ADMIN_PASS:-}" ]]; then
            echo "[WARN] Could not retrieve CP4D admin credentials from secret ${CPD_OSEARCH_ADMIN_SECRET}. Skipping ${CLUSTER_NAME}."
            continue
        fi

        OSEARCH_HOST=$(oc get route "${CLUSTER_NAME}-backend" -n "${PROJECT_CPD_INST_OPERATORS}" \
            --no-headers -o custom-columns=HOST:.spec.host 2>/dev/null || true)

        if [[ -z "${OSEARCH_HOST:-}" ]]; then
            echo "[WARN] Could not resolve backend route for ${CLUSTER_NAME}. Skipping role mapping."
            continue
        fi

        OSEARCH_URL="https://${OSEARCH_HOST}"

        for PRINCIPAL in "${OSEARCH_ROLE_MAPPING_USERS[@]}"; do
            _OSEARCH_ensure_role_mapping "${OSEARCH_URL}" "${CPD_OSEARCH_ADMIN_USER}" "${CPD_OSEARCH_ADMIN_PASS}" "${PRINCIPAL}"
        done
    done
fi

# --- write OpenSearch credentials to cpd_instance_details.sh ---
REPO_ROOT="$(cd "${SCRIPT_DIR}" && while [[ ! -f pyproject.toml ]]; do cd ..; done && pwd)"
VARS_FILE="${REPO_ROOT}/cp4d_config/cpd_instance_details.sh"


if [[ ${#SERVICE_IDS[@]} -gt 0 ]]; then
    _PRIMARY_CLUSTER="${SERVICE_IDS[1]}"
    OSEARCH_URL="https://$(oc get route "${_PRIMARY_CLUSTER}-backend" -n "${PROJECT_CPD_INST_OPERATORS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    OSEARCH_DASHBOARDS_URL="https://$(oc get route "${_PRIMARY_CLUSTER}-dashboards" -n "${PROJECT_CPD_INST_OPERATORS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"

    # User credentials (<cluster>-user-secret, type basic-auth)
    _OSEARCH_USER_SECRET="${_PRIMARY_CLUSTER}-user-secret"
    OSEARCH_USERNAME="$(oc get secret "${_OSEARCH_USER_SECRET}" -n "${PROJECT_CPD_INST_OPERANDS}" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d || true)"
    OSEARCH_PASSWORD="$(oc get secret "${_OSEARCH_USER_SECRET}" -n "${PROJECT_CPD_INST_OPERANDS}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"

    # Admin credentials (<cluster>-admin-password, type Opaque)
    _OSEARCH_ADMIN_SECRET="${_PRIMARY_CLUSTER}-admin-password"
    OSEARCH_ADMIN_USERNAME="$(oc get secret "${_OSEARCH_ADMIN_SECRET}" -n "${PROJECT_CPD_INST_OPERANDS}" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d || true)"
    OSEARCH_ADMIN_PASSWORD="$(oc get secret "${_OSEARCH_ADMIN_SECRET}" -n "${PROJECT_CPD_INST_OPERANDS}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"

    if [[ -z "${OSEARCH_ADMIN_USERNAME:-}" || -z "${OSEARCH_ADMIN_PASSWORD:-}" ]]; then
        echo "[WARN] Could not retrieve admin credentials from secret ${_OSEARCH_ADMIN_SECRET}. OSEARCH_ADMIN_* vars will be empty."
    fi

    # CP4D IAM credentials - required for requests over the backend/dashboards
    # routes, which authenticate via Traefik ForwardAuth against CP4D AMS rather
    # than against OpenSearch's internal user database. The OSEARCH_* creds above
    # only work against the pods directly (e.g. via oc exec).
    _CPD_OSEARCH_ADMIN_SECRET="platform-auth-idp-credentials"
    CPD_OSEARCH_ADMIN_USER="$(oc get secret "${_CPD_OSEARCH_ADMIN_SECRET}" -n "${PROJECT_CPD_INST_OPERANDS}" -o jsonpath='{.data.admin_username}' 2>/dev/null | base64 -d || true)"
    CPD_OSEARCH_ADMIN_PASS="$(oc get secret "${_CPD_OSEARCH_ADMIN_SECRET}" -n "${PROJECT_CPD_INST_OPERANDS}" -o jsonpath='{.data.admin_password}' 2>/dev/null | base64 -d || true)"

    if [[ -z "${CPD_OSEARCH_ADMIN_USER:-}" || -z "${CPD_OSEARCH_ADMIN_PASS:-}" ]]; then
        echo "[WARN] Could not retrieve CP4D admin credentials from secret ${_CPD_OSEARCH_ADMIN_SECRET}. CPD_OSEARCH_ADMIN_* vars will be empty."
    fi

    OSEARCH_BLOCK="
# Written by $(basename $0) on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
export OSEARCH_URL=\"${OSEARCH_URL}\"
export OSEARCH_DASHBOARDS_URL=\"${OSEARCH_DASHBOARDS_URL}\"
export OSEARCH_USERNAME=\"${OSEARCH_USERNAME}\"
export OSEARCH_PASSWORD=\"${OSEARCH_PASSWORD}\"
export OSEARCH_ADMIN_USERNAME=\"${OSEARCH_ADMIN_USERNAME}\"
export OSEARCH_ADMIN_PASSWORD=\"${OSEARCH_ADMIN_PASSWORD}\"
# CP4D IAM credentials - use these for requests over OSEARCH_URL / OSEARCH_DASHBOARDS_URL
export CPD_OSEARCH_ADMIN_USER=\"${CPD_OSEARCH_ADMIN_USER}\"
export CPD_OSEARCH_ADMIN_PASS=\"${CPD_OSEARCH_ADMIN_PASS}\""

    if [[ -f "${VARS_FILE}" ]]; then
        echo "${OSEARCH_BLOCK}" >> "${VARS_FILE}"
        echo "[INFO] OpenSearch credentials appended to ${VARS_FILE##*/}"
    else
        mkdir -p "$(dirname "${VARS_FILE}")"
        echo "${OSEARCH_BLOCK}" > "${VARS_FILE}"
        echo "[INFO] OpenSearch credentials written to ${VARS_FILE##*/}"
    fi
else
    echo "[WARN] No OpenSearch instances found - skipping credential write to ${VARS_FILE##*/}."
fi
