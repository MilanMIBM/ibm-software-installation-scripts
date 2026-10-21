#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: only configs/datastax_mc_config/datastax_mc_vars.sh is in scope ---
export ENV_TARGET="${ENV_TARGET:-datastax_mc}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/datastax_mc_helpers.sh"
mc_require_config

usage() {
    cat <<'EOF'
Create a Data API gateway (HTTP/JSON, for astrapy and other Data API clients)
in front of a Mission Control database datacenter, expose it with an OpenShift
Route, create keyspaces, and write the connection details.

  3.2_create_data_api.sh [options]

Options:
  --project NS        Project namespace (default: the only one with a database)
  --datacenter DC     CassandraDatacenter resource name (default: the only one
                      in the project), e.g. hcd-standolini
  --name NAME         DataApi name (default: the datacenter name, as the UI
                      does); its Service is <NAME>-data-api-cip
  --replicas N        Data API pods (default 1; DataStax: 2+ for production)
  --keyspace KS       Keyspace to create; repeatable (default: default_keyspace)
  --no-keyspace       Create no keyspace
  --no-route          In-cluster only (no OpenShift Route)
  --remove            Delete the Route and the DataApi instead (keyspaces stay)
  -h, --help          Show this help

Writes configs/datastax_mc_config/datastax_mc_dataapi_instance_details.sh with
the same DATASTAX_HCD_* names the CP4D DataStax scripts use (endpoint, user,
password, keyspace, token), plus the in-cluster endpoint. It describes the
gateway this script created or updated most recently. Safe to re-run.

Authentication: header  Token: Cassandra:<base64 user>:<base64 password>
(written as DATASTAX_HCD_TOKEN), or astrapy's UsernamePasswordTokenProvider.
EOF
}

PROJECT="" DC="" NAME="" REPLICAS=1 KEYSPACES=() NO_KS=false ROUTE=true REMOVE=false
while (( $# )); do
    case "$1" in
        --project)     PROJECT="${2:?--project needs a namespace}"; shift 2 ;;
        --datacenter)  DC="${2:?--datacenter needs a name}"; shift 2 ;;
        --name)        NAME="${2:?--name needs a value}"; shift 2 ;;
        --replicas)    REPLICAS="${2:?--replicas needs a number}"; shift 2 ;;
        --keyspace)    KEYSPACES+=("${2:?--keyspace needs a name}"); shift 2 ;;
        --no-keyspace) NO_KS=true; shift ;;
        --no-route)    ROUTE=false; shift ;;
        --remove)      REMOVE=true; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) mc_die "Unknown option: $1 (see --help)" ;;
    esac
done
[[ "${REPLICAS}" == <1-> ]] || mc_die "--replicas must be a positive number."
for ks in "${KEYSPACES[@]}"; do
    [[ "${ks}" =~ '^[A-Za-z][A-Za-z0-9_]{0,47}$' ]] || mc_die "Invalid keyspace name '${ks}' (letters, digits, _; max 48)."
done
${NO_KS} || (( ${#KEYSPACES} )) || KEYSPACES=(default_keyspace)

eval "${OC_LOGIN}"
mc_resolve_datacenter "${PROJECT}" "${DC}"
NS="${MC_DB_PROJECT}"
NAME="${NAME:-${MC_DB_DC}}"
SVC="${NAME}-data-api-cip"
ROUTE_NAME="${NAME}-data-api"
DETAILS="${MC_CONFIG_DIR}/datastax_mc_dataapi_instance_details.sh"

if ${REMOVE}; then
    oc delete route "${ROUTE_NAME}" -n "${NS}" --ignore-not-found >/dev/null
    oc delete dataapis.missioncontrol.datastax.com "${NAME}" -n "${NS}" --ignore-not-found
    if [[ -f "${DETAILS}" ]] && grep -q "data-api ${NS}/${NAME}\$" "${DETAILS}"; then
        rm -f "${DETAILS}"
    fi
    mc_info "Data API ${NS}/${NAME} removed (keyspaces and data are kept)."
    exit 0
fi

# --- DataApi -------------------------------------------------------------------------
oc apply -f - >/dev/null <<EOF
apiVersion: missioncontrol.datastax.com/v1alpha1
kind: DataApi
metadata:
  name: ${NAME}
  namespace: ${NS}
spec:
  cassandraDatacenterRef:
    name: ${MC_DB_DC}
  replicas: ${REPLICAS}
  services:
    clusterIP:
      port: 8080
EOF
mc_info "DataApi ${NS}/${NAME} applied (${REPLICAS} replica(s)); waiting for it to be Ready..."
mc_wait_ready dataapis.missioncontrol.datastax.com "${NAME}" "${NS}" 600 \
    || mc_die "DataApi ${NAME} not Ready after 10 minutes: oc describe dataapis.missioncontrol.datastax.com ${NAME} -n ${NS}"

INTERNAL="http://${SVC}.${NS}.svc:8080"
ENDPOINT="${INTERNAL}"
CA_FILE=""
if ${ROUTE}; then
    oc get route "${ROUTE_NAME}" -n "${NS}" >/dev/null 2>&1 \
        || oc create route edge "${ROUTE_NAME}" --service="${SVC}" --port=http --insecure-policy=Redirect -n "${NS}" >/dev/null
    ENDPOINT="https://$(oc get route "${ROUTE_NAME}" -n "${NS}" -o jsonpath='{.spec.host}')"
fi

# --- Credentials and readiness through the endpoint ----------------------------------
API_USER="$(mc_secret_value "${NS}" "${MC_DB_SUPERUSER_SECRET}" username)"
API_PASS="$(mc_secret_value "${NS}" "${MC_DB_SUPERUSER_SECRET}" password)"
# tr: GNU base64 wraps long values over several lines
TOKEN="Cassandra:$(print -rn -- "${API_USER}" | base64 | tr -d '\n'):$(print -rn -- "${API_PASS}" | base64 | tr -d '\n')"

CURL=(curl -s -m 15)
if ${ROUTE}; then
    # Routes on the default ingress certificate: trust it explicitly when the
    # system CAs do not (self-signed cluster ingress), and save that CA.
    if ! curl -s -o /dev/null -m 10 "${ENDPOINT}" 2>/dev/null; then
        CA_FILE="${MC_CONFIG_DIR}/certs/${NS}-${NAME}-route-ca.crt"
        mkdir -p "${CA_FILE:h}"
        (umask 077; oc get secret router-ca -n openshift-ingress-operator -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 --decode > "${CA_FILE}" || true)
        [[ -s "${CA_FILE}" ]] || mc_die "The Route's certificate is not trusted and the cluster router CA could not be read."
        CURL+=(--cacert "${CA_FILE}")
        mc_info "Route certificate is not publicly trusted - saved its CA to ${CA_FILE#${_CP4D_REPO_ROOT}/}"
    fi
else
    mc_warn "--no-route: ${INTERNAL} is reachable from inside the cluster only; keyspaces are created through a temporary port-forward."
    oc port-forward -n "${NS}" "svc/${SVC}" 18181:8080 >/dev/null 2>&1 &
    _pf=$!
    trap 'kill ${_pf} 2>/dev/null; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT
    ENDPOINT_LOCAL="http://127.0.0.1:18181"
    sleep 3
fi
CALL_URL="${ENDPOINT_LOCAL:-${ENDPOINT}}/v1"

data_api() {
    "${CURL[@]}" "${CALL_URL}" -H "Token: ${TOKEN}" -H 'Content-Type: application/json' -d "$1"
}

for (( i = 0; i < 24; i++ )); do
    resp="$(data_api '{"findKeyspaces":{}}' || true)"
    [[ "${resp}" == *'"keyspaces"'* ]] && break
    sleep 5
done
[[ "${resp}" == *'"keyspaces"'* ]] || mc_die "Data API did not answer findKeyspaces at ${CALL_URL}: ${resp:-no response}"
mc_info "Data API answering at ${ENDPOINT}"

for ks in "${KEYSPACES[@]}"; do
    if jq -e --arg k "${ks}" '.status.keyspaces | index($k)' <<<"${resp}" >/dev/null; then
        mc_info "Keyspace ${ks} already exists."
        continue
    fi
    out="$(data_api "{\"createKeyspace\":{\"name\":\"${ks}\"}}")"
    jq -e '.status.ok == 1' <<<"${out}" >/dev/null || mc_die "createKeyspace ${ks} failed: ${out}"
    mc_info "Keyspace ${ks} created."
done

# --- Details -----------------------------------------------------------------------------
q() { print -r -- "${(qq)1}"; }
(umask 077; cat > "${DETAILS}" <<EOF
# Written by $(basename $0) on $(date -u +%Y-%m-%dT%H:%M:%SZ) for data-api ${NS}/${NAME}
[[ "\${ENV_TARGET:-}" == datastax_mc || "\${ENV_TARGET:-}" == *datastax_mc_vars.sh ]] || return 0
#--- DataStax HCD - Data API (cluster ${MC_DB_CLUSTER}, datacenter ${MC_DB_DC_NAME})
export DATASTAX_HCD_ENDPOINT=$(q "${ENDPOINT}")
export DATASTAX_HCD_INTERNAL_ENDPOINT=$(q "${INTERNAL}")
export DATASTAX_HCD_API_USER=$(q "${API_USER}")
export DATASTAX_HCD_API_PASSWORD=$(q "${API_PASS}")
export DATASTAX_HCD_TOKEN=$(q "${TOKEN}")
export DATASTAX_HCD_KEYSPACE=$(q "${KEYSPACES[1]:-default_keyspace}")
export DATASTAX_HCD_ROUTE_CA=$(q "${CA_FILE}")
EOF
)
mc_info "Wrote ${DETAILS#${_CP4D_REPO_ROOT}/}"
mc_info "Try it: source s_env.sh datastax_mc && curl -s \"\${DATASTAX_HCD_ENDPOINT}/v1\" -H \"Token: \${DATASTAX_HCD_TOKEN}\" -H 'Content-Type: application/json' -d '{\"findKeyspaces\":{}}'"
