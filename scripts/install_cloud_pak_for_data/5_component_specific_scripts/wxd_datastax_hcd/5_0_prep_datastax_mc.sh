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

for var in OC_LOGIN PROJECT_CPD_INST_OPERANDS PREP_DATASTAX; do
    if [[ -z "${(P)var:-}" ]]; then
        echo "Error: ${var} is not set. Set it in ./cpd_vars.sh before running this script."
        exit 1
    fi
done

eval "${OC_LOGIN}"

# When PREPARE_TLS=true, after the HCD DataAPI route is created this script also
# exports the certificates needed to securely connect to the HCD services from
# outside the cluster, saving them to cp4d_config/certs/<dc_name>/:
#   - dataapi-route-ca.crt : CA that verifies the edge-terminated DataAPI HTTPS route
#   - cql-ca.crt           : CassandraDatacenter server CA for native CQL (9042) TLS
PREPARE_TLS="${PREPARE_TLS:-false}"

#--------------------------------
##### Datastax HCD uses block storage
#--------------------------------

# --- prepares prepares nonroot-v2 security context to the service
oc adm policy add-scc-to-user nonroot-v2 -z datastax-mc -n ${PROJECT_CPD_INST_OPERANDS}
# --- extracts DataStax Mission Control login credentials
oc extract secret/datastax-mc-embedded-ui-dex-admin-credentials -n ${PROJECT_CPD_INST_OPERATORS} --to=-

# --- prepares route to the service so that it can be accessed

PREP_DATASTAX_ROUTE="cat <<EOF | oc apply --namespace ${PROJECT_CPD_INST_OPERATORS} -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: datastax-mc-ui
spec:
  tls:
    termination: passthrough
  to:
    kind: Service
    name: datastax-mc-ui
    weight: 100
EOF"
eval "${PREP_DATASTAX_ROUTE}"

# eval "${PREP_DATASTAX_ANNOTATION}" VVV same as below

for _NS in "${PROJECT_CPD_INST_OPERATORS}" "${PROJECT_CPD_INST_OPERANDS}"; do
    _CURRENT_LABEL="$(oc get ns "${_NS}" -o jsonpath='{.metadata.labels.mission-control\.datastax\.com/is-project}' 2>/dev/null || true)"
    if [[ "${_CURRENT_LABEL}" != "true" ]]; then
        oc label ns "${_NS}" mission-control.datastax.com/is-project=true
    fi
    _CURRENT_ANNOTATION="$(oc get ns "${_NS}" -o jsonpath='{.metadata.annotations.mission-control\.datastax\.com/project-name}' 2>/dev/null || true)"
    if [[ "${_CURRENT_ANNOTATION}" != "${_NS}" ]]; then
        oc annotate ns "${_NS}" mission-control.datastax.com/project-name="${_NS}"
    fi
done

# Discover all CassandraDatacenter instance names in the operands namespace
DC_NAMES=($(oc get cassandradatacenters.cassandra.datastax.com -n "${PROJECT_CPD_INST_OPERANDS}" -o jsonpath='{.items[*].metadata.name}'))

if [[ ${#DC_NAMES[@]} -eq 0 ]]; then
    echo "Error: No CassandraDatacenter instances found in namespace ${PROJECT_CPD_INST_OPERANDS}."
    exit 1
fi

echo "Found CassandraDatacenter instances: ${DC_NAMES[*]}"

for DC_NAME in "${DC_NAMES[@]}"; do
    echo "--- Processing DC: ${DC_NAME} ---"

    PREP_COMMON_DC_ANNOTATIONS="oc get cassandradatacenters.cassandra.datastax.com ${DC_NAME} -n ${PROJECT_CPD_INST_OPERANDS} -o json | jq '.spec.additionalAnnotations'"
    COMMON_ANNOTATIONS=$(eval "${PREP_COMMON_DC_ANNOTATIONS}")
    echo ${COMMON_ANNOTATIONS}

    DATAAPI_READY="$(oc get dataapi.missioncontrol.datastax.com "${DC_NAME}" -n "${PROJECT_CPD_INST_OPERANDS}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    if [[ "${DATAAPI_READY}" == "True" ]]; then
        echo "[INFO] DataApi '${DC_NAME}' already exists and is Ready - skipping creation."
    else
        PREP_DATASTAX_API="cat <<EOF | oc apply -f -
{
    \"apiVersion\": \"missioncontrol.datastax.com/v1alpha1\",
    \"kind\": \"DataApi\",
    \"metadata\": {
        \"name\": \"${DC_NAME}\",
        \"namespace\": \"${PROJECT_CPD_INST_OPERANDS}\"
    },
    \"spec\": {
        \"cassandraDatacenterRef\": {
            \"name\": \"${DC_NAME}\"
        },
        \"metadata\": {
            \"commonAnnotations\": ${COMMON_ANNOTATIONS},
            \"commonLabels\": {
                \"icpdsupport/addOnId\": \"datastax-mc\",
                \"velero.io/exclude-from-backup\": \"true\",
                \"icpdsupport/ignore-on-nd-backup\": \"true\",
                \"icpdsupport/empty-on-nd-backup\": \"true\"
            }
        },
        \"replicas\": 1,
        \"resources\": {
            \"limits\": {
                \"cpu\": 4,
                \"memory\": \"8G\",
                \"ephemeral-storage\": \"4Gi\"
            },
            \"requests\": {
                \"cpu\": 2,
                \"memory\": \"4G\",
                \"ephemeral-storage\": \"2Gi\"
            }
        },
        \"services\": {
            \"clusterIP\": {
                \"port\": 8080
            }
        }
    }
}
EOF"
        eval "${PREP_DATASTAX_API}"
    fi
    DCNAME_SUPERUSER=$(eval "oc extract secret/datastax${DC_NAME//[^0-9]/}-superuser -n ${PROJECT_CPD_INST_OPERANDS}  --to=-")
    echo ${DCNAME_SUPERUSER}
done


oc get cassandradatacenters.cassandra.datastax.com -n "${PROJECT_CPD_INST_OPERANDS}"

# --- write DataStax MC credentials to cpd_instance_details.sh ---
REPO_ROOT="$(cd "${SCRIPT_DIR}" && while [[ ! -f pyproject.toml ]]; do cd ..; done && pwd)"
VARS_FILE="${REPO_ROOT}/cp4d_config/cpd_instance_details.sh"
CERTS_ROOT="${REPO_ROOT}/cp4d_config/certs"

DATASTAX_URL="https://$(oc get route datastax-mc-ui -n ${PROJECT_CPD_INST_OPERATORS} -o jsonpath='{.spec.host}')"

_UI_SECRET="datastax-mc-embedded-ui-dex-admin-credentials"
DATASTAX_USERNAME="" DATASTAX_PASSWORD=""
for (( _attempt=1; _attempt<=5; _attempt++ )); do
    DATASTAX_USERNAME="$(oc get secret "${_UI_SECRET}" -n "${PROJECT_CPD_INST_OPERATORS}" -o jsonpath='{.data.username}' 2>/dev/null | base64 --decode || true)"
    DATASTAX_PASSWORD="$(oc get secret "${_UI_SECRET}" -n "${PROJECT_CPD_INST_OPERATORS}" -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode || true)"
    [[ -n "${DATASTAX_USERNAME}" && -n "${DATASTAX_PASSWORD}" ]] && break
    _delay=$(( _attempt * 10 ))
    echo "[WARN] Secret '${_UI_SECRET}' is missing username/password, retrying in ${_delay}s (attempt ${_attempt}/5)..." >&2
    sleep "${_delay}"
done
[[ -z "${DATASTAX_USERNAME}" || -z "${DATASTAX_PASSWORD}" ]] && echo "[WARN] Secret '${_UI_SECRET}' could not be fully retrieved after 5 retries." >&2

_SUPERUSER_SECRET="datastax${DC_NAMES[1]//[^0-9]/}-superuser"
DATASTAX_HCD_API_USER="" DATASTAX_HCD_API_PASSWORD=""
for (( _attempt=1; _attempt<=5; _attempt++ )); do
    DATASTAX_HCD_API_USER="$(oc get secret "${_SUPERUSER_SECRET}" -n "${PROJECT_CPD_INST_OPERANDS}" -o jsonpath='{.data.username}' 2>/dev/null | base64 --decode || true)"
    DATASTAX_HCD_API_PASSWORD="$(oc get secret "${_SUPERUSER_SECRET}" -n "${PROJECT_CPD_INST_OPERANDS}" -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode || true)"
    [[ -n "${DATASTAX_HCD_API_USER}" && -n "${DATASTAX_HCD_API_PASSWORD}" ]] && break
    _delay=$(( _attempt * 10 ))
    echo "[WARN] Secret '${_SUPERUSER_SECRET}' is missing username/password, retrying in ${_delay}s (attempt ${_attempt}/5)..." >&2
    sleep "${_delay}"
done
[[ -z "${DATASTAX_HCD_API_USER}" || -z "${DATASTAX_HCD_API_PASSWORD}" ]] && echo "[WARN] Secret '${_SUPERUSER_SECRET}' could not be fully retrieved after 5 retries." >&2

# Derive the DataApi URL from the primary DC - expose via OCP Route for external access
_PRIMARY_DC="${DC_NAMES[1]}"
DATASTAX_HCD_PORT="$(oc get dataapi.missioncontrol.datastax.com "${_PRIMARY_DC}" -n "${PROJECT_CPD_INST_OPERANDS}" -o jsonpath='{.spec.services.clusterIP.port}' 2>/dev/null || echo "8080")"

# Derive the DataApi clusterIP service name: <dc>-data-api-cip
DATASTAX_HCD_SVC="${_PRIMARY_DC}-data-api-cip"

_DATAAPI_ROUTE_NAME="${_PRIMARY_DC}-dataapi"
_DATAAPI_ROUTE_EXISTS="$(oc get route "${_DATAAPI_ROUTE_NAME}" -n "${PROJECT_CPD_INST_OPERANDS}" --ignore-not-found -o jsonpath='{.metadata.name}' 2>/dev/null || true)"
if [[ -z "${_DATAAPI_ROUTE_EXISTS}" ]]; then
    oc create route edge "${_DATAAPI_ROUTE_NAME}" \
        --service="${DATASTAX_HCD_SVC}" \
        --port=http \
        --insecure-policy=Redirect \
        -n "${PROJECT_CPD_INST_OPERANDS}"
fi
DATASTAX_HCD_URL="https://$(oc get route "${_DATAAPI_ROUTE_NAME}" -n "${PROJECT_CPD_INST_OPERANDS}" -o jsonpath='{.spec.host}')"

# --- PREPARE_TLS: export certs for secure external connections to the HCD services ---
DATASTAX_HCD_ROUTE_CA="" DATASTAX_HCD_CQL_CA=""
if [[ "${PREPARE_TLS}" == "true" ]]; then
    echo "=== PREPARE_TLS: exporting HCD certificates for ${_PRIMARY_DC} ==="
    _CERT_DIR="${CERTS_ROOT}/${_PRIMARY_DC}"
    mkdir -p "${_CERT_DIR}"

    # 1) DataAPI route CA: the DataAPI route is edge-terminated, so it is served by
    #    the cluster default ingress certificate. Capture the CA that verifies it.
    _ROUTE_CA=""
    # Prefer the cluster CA cert published into the operands namespace.
    _ROUTE_CA="$(oc get secret ibmcloud-cluster-ca-cert -n "${PROJECT_CPD_INST_OPERANDS}" -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 --decode || true)"
    # Fall back to the ingress operator's router CA.
    if [[ -z "${_ROUTE_CA:-}" ]]; then
        _ROUTE_CA="$(oc get secret router-ca -n openshift-ingress-operator -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 --decode || true)"
    fi
    if [[ -n "${_ROUTE_CA:-}" ]]; then
        DATASTAX_HCD_ROUTE_CA="${_CERT_DIR}/dataapi-route-ca.crt"
        print -r -- "${_ROUTE_CA}" > "${DATASTAX_HCD_ROUTE_CA}"
        chmod 600 "${DATASTAX_HCD_ROUTE_CA}"
        echo "  [OK] DataAPI route CA saved to ${DATASTAX_HCD_ROUTE_CA}"
    else
        echo "  [WARN] Could not retrieve a route CA certificate; the DataAPI endpoint may use a publicly-trusted cert."
    fi

    # 2) CQL server CA: cass-operator generates a per-datacenter CA used for the
    #    native CQL (9042) endpoint. Secret/key names vary by version, so try the
    #    known candidates in priority order.
    _CQL_CA=""
    for _cand in \
        "${_PRIMARY_DC}-ca-keystore:cert" \
        "${_PRIMARY_DC}-ca-keystore:ca.crt" \
        "${_PRIMARY_DC}-server-ca:ca.crt" \
        "${_PRIMARY_DC}-server-ca:tls.crt" \
        "datastax${_PRIMARY_DC//[^0-9]/}-ca-keystore:cert" \
        "datastax${_PRIMARY_DC//[^0-9]/}-server-ca:ca.crt"; do
        _sec="${_cand%%:*}"; _key="${_cand##*:}"
        oc get secret "${_sec}" -n "${PROJECT_CPD_INST_OPERANDS}" &>/dev/null || continue
        _CQL_CA="$(oc get secret "${_sec}" -n "${PROJECT_CPD_INST_OPERANDS}" -o jsonpath="{.data.${_key//./\\.}}" 2>/dev/null | base64 --decode || true)"
        if [[ -n "${_CQL_CA:-}" ]]; then
            echo "  [INFO] CQL CA sourced from secret '${_sec}' key '${_key}'."
            break
        fi
    done
    if [[ -n "${_CQL_CA:-}" ]]; then
        DATASTAX_HCD_CQL_CA="${_CERT_DIR}/cql-ca.crt"
        print -r -- "${_CQL_CA}" > "${DATASTAX_HCD_CQL_CA}"
        chmod 600 "${DATASTAX_HCD_CQL_CA}"
        echo "  [OK] CQL server CA saved to ${DATASTAX_HCD_CQL_CA}"
    else
        echo "  [WARN] No CassandraDatacenter CQL CA secret found for '${_PRIMARY_DC}'; skipping CQL cert export."
    fi
fi

DATASTAX_BLOCK="
# Written by $(basename $0) on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
#--- DataStax Mission Control - DataAPI
export DATASTAX_MC_URL=\"${DATASTAX_URL}\"
export DATASTAX_MC_USERNAME=\"${DATASTAX_USERNAME}\"
export DATASTAX_MC_LOGIN_USERNAME=\"${DATASTAX_USERNAME}@local\"
export DATASTAX_MC_PASSWORD=\"${DATASTAX_PASSWORD}\"
#--- DataStax HyperConvergedDatabase (HCD) - DataAPI
export DATASTAX_HCD_ENDPOINT=\"${DATASTAX_HCD_URL}\"
export DATASTAX_HCD_API_USER=\"${DATASTAX_HCD_API_USER}\"
export DATASTAX_HCD_API_PASSWORD=\"${DATASTAX_HCD_API_PASSWORD}\"
export DATASTAX_HCD_KEYSPACE=\"default_keyspace\"
export DATASTAX_HCD_ROUTE_CA=\"${DATASTAX_HCD_ROUTE_CA}\"
export DATASTAX_HCD_CQL_CA=\"${DATASTAX_HCD_CQL_CA}\""

if [[ -f "${VARS_FILE}" ]]; then
    echo "${DATASTAX_BLOCK}" >> "${VARS_FILE}"
    echo "[INFO] DataStax MC credentials appended to ${VARS_FILE##*/}"
else
    mkdir -p "$(dirname "${VARS_FILE}")"
    echo "${DATASTAX_BLOCK}" > "${VARS_FILE}"
    echo "[INFO] DataStax MC credentials written to ${VARS_FILE##*/}"
fi