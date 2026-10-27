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
Create a Mission Control CQL gateway (CqlConnectivity) so Cassandra/CQL drivers
outside the cluster can reach a database datacenter, and build its Secure
Connect Bundle (SCB) - the same zip the UI offers for download.

How it works on OpenShift (Ingress type): Mission Control runs cql-router pods
and creates passthrough Routes for metadata.<dns-base> and for each router. A
driver given the SCB calls the metadata service over mutual TLS, then connects
to the OpenShift router on port 443 using each router's ID as the TLS SNI name.
Only the cluster's existing *.apps wildcard DNS is needed.

  3.3_create_cql_gateway.sh [options]

Options:
  --project NS        Project namespace (default: the only one with a database)
  --datacenter DC     CassandraDatacenter resource name (default: the only one
                      in the project), e.g. hcd-standolini
  --name NAME         Gateway name (default: <datacenter>-cql)
  --size N            cql-router replicas (default 1)
  --dns-base HOST     DNS base name (default: <name>-<project>.<apps domain>);
                      must resolve to the OpenShift router
  --scb FILE          Where to write the SCB (default:
                      configs/datastax_mc_config/scb/<project>-<name>-scb.zip)
  --remove            Delete the gateway and its SCB instead
  -h, --help          Show this help

Writes configs/datastax_mc_config/datastax_mc_cql_instance_details.sh with the
SCB path, credentials and local DCs, plus the in-cluster contact point for
apps running inside OpenShift (no gateway needed there). Safe to re-run; each
run rebuilds the SCB from the gateway's current certificates.
EOF
}

PROJECT="" DC="" NAME="" SIZE=1 DNS_BASE="" SCB="" REMOVE=false
while (( $# )); do
    case "$1" in
        --project)    PROJECT="${2:?--project needs a namespace}"; shift 2 ;;
        --datacenter) DC="${2:?--datacenter needs a name}"; shift 2 ;;
        --name)       NAME="${2:?--name needs a value}"; shift 2 ;;
        --size)       SIZE="${2:?--size needs a number}"; shift 2 ;;
        --dns-base)   DNS_BASE="${2:?--dns-base needs a host name}"; shift 2 ;;
        --scb)        SCB="${2:?--scb needs a file path}"; shift 2 ;;
        --remove)     REMOVE=true; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) mc_die "Unknown option: $1 (see --help)" ;;
    esac
done
[[ "${SIZE}" == <1-> ]] || mc_die "--size must be a positive number."

eval "${OC_LOGIN}"
mc_resolve_datacenter "${PROJECT}" "${DC}"
NS="${MC_DB_PROJECT}"
NAME="${NAME:-${MC_DB_DC}-cql}"
SCB="${SCB:-${MC_CONFIG_DIR}/scb/${NS}-${NAME}-scb.zip}"
DETAILS="${MC_CONFIG_DIR}/datastax_mc_cql_instance_details.sh"

if ${REMOVE}; then
    oc delete cqlconnectivities.missioncontrol.datastax.com "${NAME}" -n "${NS}" --ignore-not-found
    rm -f "${SCB}"
    if [[ -f "${DETAILS}" ]] && grep -q "cql-gateway ${NS}/${NAME}\$" "${DETAILS}"; then
        rm -f "${DETAILS}"
    fi
    mc_info "CQL gateway ${NS}/${NAME} removed."
    exit 0
fi

if [[ -z "${DNS_BASE}" ]]; then
    mc_cql_gateway_dns_base "${NAME}" "${NS}"
    DNS_BASE="${REPLY}"
fi
METADATA_HOST="metadata.${DNS_BASE}"

# --- CqlConnectivity ---------------------------------------------------------------
oc apply -f - >/dev/null <<EOF
apiVersion: missioncontrol.datastax.com/v1alpha1
kind: CqlConnectivity
metadata:
  name: ${NAME}
  namespace: ${NS}
spec:
  cassandraDatacenterRef:
    name: ${MC_DB_DC}
  ingress:
    size: ${SIZE}
    dnsBaseName: ${DNS_BASE}
EOF
mc_info "CQL gateway ${NS}/${NAME} applied (${SIZE} router(s), ${DNS_BASE}); waiting for it..."
mc_cql_gateway_wait "${NS}" "${NAME}" "${SIZE}" "${METADATA_HOST}"

# --- Secure Connect Bundle -----------------------------------------------------------
_work="$(mktemp -d)"
chmod 700 "${_work}"
trap 'rm -rf "${_work}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT
mc_cql_gateway_scb "${NS}" "${NAME}" "${METADATA_HOST}" "${SCB}" "${_work}"
GW_LOCAL_DC="${REPLY}"

# --- Details -------------------------------------------------------------------------------
CQL_USER="$(mc_secret_value "${NS}" "${MC_DB_SUPERUSER_SECRET}" username)"
CQL_PASS="$(mc_secret_value "${NS}" "${MC_DB_SUPERUSER_SECRET}" password)"
INTERNAL_SVC="${MC_DB_CLUSTER}-${MC_DB_DC}-service"
if oc get service "${INTERNAL_SVC}" -n "${NS}" >/dev/null 2>&1; then
    INTERNAL_CP="${INTERNAL_SVC}.${NS}.svc:9042"
else
    INTERNAL_CP=""
    mc_warn "In-cluster service ${INTERNAL_SVC} not found - DATASTAX_HCD_CQL_INTERNAL_CONTACT_POINT left empty."
fi

q() { print -r -- "${(qq)1}"; }
(umask 077; cat > "${DETAILS}" <<EOF
# Written by $(basename $0) on $(date -u +%Y-%m-%dT%H:%M:%SZ) for cql-gateway ${NS}/${NAME}
[[ "\${ENV_TARGET:-}" == datastax_mc || "\${ENV_TARGET:-}" == *datastax_mc_vars.sh ]] || return 0
#--- DataStax HCD - CQL (cluster ${MC_DB_CLUSTER}, datacenter ${MC_DB_DC_NAME})
# From outside the cluster: the gateway's Secure Connect Bundle + username/password.
export DATASTAX_HCD_SCB=$(q "${SCB}")
export DATASTAX_HCD_CQL_GATEWAY_LOCAL_DC=$(q "${GW_LOCAL_DC}")
export DATASTAX_HCD_CQL_METADATA_URL=$(q "https://${METADATA_HOST}:443/metadata")
export DATASTAX_HCD_CQL_USER=$(q "${CQL_USER}")
export DATASTAX_HCD_CQL_PASSWORD=$(q "${CQL_PASS}")
# From inside the cluster: straight to the database service, no gateway.
export DATASTAX_HCD_CQL_INTERNAL_CONTACT_POINT=$(q "${INTERNAL_CP}")
export DATASTAX_HCD_CQL_INTERNAL_LOCAL_DC=$(q "${MC_DB_DC_NAME}")
EOF
)
mc_info "Wrote ${DETAILS#${_CP4D_REPO_ROOT}/}"
mc_cql_gateway_usage
cat <<EOF
The gateway presents its own datacenter '${GW_LOCAL_DC}'; inside OpenShift use
${INTERNAL_CP:-<cluster>-<dc>-service.${NS}.svc:9042} with local DC '${MC_DB_DC_NAME}' instead.
EOF
