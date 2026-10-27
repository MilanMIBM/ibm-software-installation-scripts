#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
# Shared Mission Control functions (datacenter lookup, CQL gateway); no MC config needed.
source "${_CP4D_REPO_ROOT}/src/helpers/datastax_mc_helpers.sh"

usage() {
    cat <<'EOF'
Create a Mission Control CQL gateway (CqlConnectivity) for the watsonx.data
DataStax HCD database, so Cassandra/CQL drivers outside the cluster can reach
it, and build its Secure Connect Bundle (SCB) - the same zip the Mission
Control UI offers for download. watsonx.data counterpart of the standalone
scripts/install_datastax_mc_standalone/3_post_install/3.3_create_cql_gateway.sh.

The gateway runs cql-router pods in the operands project and Mission Control
creates passthrough Routes for metadata.<dns-base> and for each router. A
driver given the SCB calls the metadata service over mutual TLS, then connects
to the OpenShift router on port 443 using each router's ID as the TLS SNI name.
Only the cluster's existing *.apps wildcard DNS is needed. The gateway carries
the datacenter's cloud pak annotations and the datastax-mc addOnId label, like
the DataApi from 5_0_prep_datastax_mc.sh. The routers run as Mission Control's
cass-dc-watcher service account, which only exists in the operators project,
so the script mirrors it into the operands project with a ClusterRoleBinding
to the same read-only ClusterRole; --remove deletes both once no gateway is left.

  5_2_prep_datastax_hcd_cql_gateway.sh [options]

Options:
  --datacenter DC     CassandraDatacenter resource name (default: the first in
                      PROJECT_CPD_INST_OPERANDS, as in 5_0), e.g. dc698
  --name NAME         Gateway name (default: <datacenter>-cql)
  --size N            cql-router replicas (default 1)
  --dns-base HOST     DNS base name (default: <name>-<project>.<apps domain>);
                      must resolve to the OpenShift router
  --scb FILE          Where to write the SCB (default:
                      configs/cp4d_config/scb/<project>-<name>-scb.zip)
  --remove            Delete the gateway, its SCB and its details instead
  -h, --help          Show this help

Writes the SCB path, gateway local DC and CQL credentials to
configs/cp4d_config/cpd_instance_details.sh (replacing this gateway's earlier
block). Apps inside OpenShift need no gateway: use DATASTAX_HCD_DC_ENDPOINT
from 5_0. Safe to re-run; each run rebuilds the SCB from the gateway's
current certificates.
EOF
}

DC="" NAME="" SIZE=1 DNS_BASE="" SCB="" REMOVE=false
while (( $# )); do
    case "$1" in
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

for var in OC_LOGIN PROJECT_CPD_INST_OPERATORS PROJECT_CPD_INST_OPERANDS; do
    if [[ -z "${(P)var:-}" ]]; then
        echo "Error: ${var} is not set. Set it in ./cpd_vars.sh before running this script."
        exit 1
    fi
done

eval "${OC_LOGIN}"

NS="${PROJECT_CPD_INST_OPERANDS}"
# Same primary datacenter as 5_0_prep_datastax_mc.sh: the first one in the project.
DC="${DC:-$(oc get cassandradatacenters.cassandra.datastax.com -n "${NS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)}"
mc_resolve_datacenter "${NS}" "${DC}"
NAME="${NAME:-${MC_DB_DC}-cql}"
SCB="${SCB:-${_CP4D_REPO_ROOT}/configs/cp4d_config/scb/${NS}-${NAME}-scb.zip}"
VARS_FILE="${_CP4D_REPO_ROOT}/configs/cp4d_config/cpd_instance_details.sh"
_BLOCK_BEGIN="# >>> cql-gateway ${NS}/${NAME}"
_BLOCK_END="# <<< cql-gateway ${NS}/${NAME}"

# Drop this gateway's block from cpd_instance_details.sh (rewritten in place to keep its permissions).
_strip_details_block() {
    [[ -f "${VARS_FILE}" ]] || return 0
    local tmp="${VARS_FILE}.tmp.$$"
    awk -v b="${_BLOCK_BEGIN}" -v e="${_BLOCK_END}" '$0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }' \
        "${VARS_FILE}" > "${tmp}"
    cat "${tmp}" > "${VARS_FILE}"
    rm -f "${tmp}"
}

# --- cql-router service account ------------------------------------------------------
# The router pods run as <release>-cass-dc-watcher-<operators project>, which Mission
# Control only creates in its own (operators) project. With the database in the separate
# operands project, mirror it there and bind the same read-only ClusterRole (get/watch on
# CassandraDatacenters). The router watches at cluster scope, so it needs a
# ClusterRoleBinding; a RoleBinding in the operands project is not enough.
_SA_MARKER="app.kubernetes.io/created-by=5_2_prep_datastax_hcd_cql_gateway"
_ensure_router_service_account() {
    local ops="${PROJECT_CPD_INST_OPERATORS}" sa role crb existed
    sa="$(oc get serviceaccounts -n "${ops}" -o name | sed 's|^serviceaccount/||' | grep -- "-cass-dc-watcher-${ops}\$" | head -n1 || true)"
    if [[ -z "${sa}" ]]; then
        mc_warn "No *-cass-dc-watcher-${ops} service account in ${ops} - not mirroring it; the cql-router pods may not start."
        return 0
    fi
    role="$(oc get clusterrolebindings -o json | jq -r --arg ns "${ops}" --arg sa "${sa}" \
        '[.items[] | select(any(.subjects[]?; .kind == "ServiceAccount" and .namespace == $ns and .name == $sa)) | .roleRef.name][0] // empty')"
    [[ -n "${role}" ]] || mc_die "No ClusterRoleBinding found for ${ops}/${sa} - cannot mirror its permissions."
    crb="${sa}-${NS}"
    existed="$(oc get clusterrolebinding "${crb}" --ignore-not-found -o name)"

    oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${sa}
  namespace: ${NS}
  labels:
    ${_SA_MARKER%%=*}: ${_SA_MARKER#*=}
    icpdsupport/addOnId: datastax-mc
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${crb}
  labels:
    ${_SA_MARKER%%=*}: ${_SA_MARKER#*=}
    icpdsupport/addOnId: datastax-mc
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${role}
subjects:
  - kind: ServiceAccount
    name: ${sa}
    namespace: ${NS}
EOF
    mc_info "cql-router service account ${NS}/${sa} ready (ClusterRoleBinding ${crb} -> ${role})."

    # Routers from an earlier run that failed for want of the account or binding: restart them now.
    if [[ -z "${existed}" ]] && oc get deployment -n "${NS}" -l "missioncontrol.datastax.com/cql-connectivity=${NAME}" -o name | grep -q .; then
        oc rollout restart deployment -n "${NS}" -l "missioncontrol.datastax.com/cql-connectivity=${NAME}" >/dev/null
        mc_info "Restarted existing cql-router deployments of ${NAME}."
    fi
}

if ${REMOVE}; then
    oc delete cqlconnectivities.missioncontrol.datastax.com "${NAME}" -n "${NS}" --ignore-not-found
    rm -f "${SCB}"
    _strip_details_block
    # The mirrored service account is shared by every gateway in the project.
    if [[ -z "$(oc get cqlconnectivities.missioncontrol.datastax.com -n "${NS}" -o name)" ]]; then
        for _crb in $(oc get clusterrolebinding -l "${_SA_MARKER}" -o json \
                | jq -r --arg ns "${NS}" '.items[] | select(any(.subjects[]?; .namespace == $ns)) | .metadata.name'); do
            oc delete clusterrolebinding "${_crb}" --ignore-not-found
        done
        oc delete serviceaccount -n "${NS}" -l "${_SA_MARKER}" --ignore-not-found
    fi
    mc_info "CQL gateway ${NS}/${NAME} removed."
    exit 0
fi
_ensure_router_service_account

if [[ -z "${DNS_BASE}" ]]; then
    mc_cql_gateway_dns_base "${NAME}" "${NS}"
    DNS_BASE="${REPLY}"
fi
METADATA_HOST="metadata.${DNS_BASE}"

# --- CqlConnectivity ---------------------------------------------------------------
# Carry the datacenter's cloud pak (licensing) annotations and the CP4D labels the
# DataApi gets in 5_0, so the cql-router pods are accounted for like the rest of HCD.
COMMON_ANNOTATIONS="$(oc get cassandradatacenters.cassandra.datastax.com "${MC_DB_DC}" -n "${NS}" -o json | jq -c '.spec.additionalAnnotations // {}')"
jq -n --arg name "${NAME}" --arg ns "${NS}" --arg dc "${MC_DB_DC}" --arg dns "${DNS_BASE}" \
      --argjson size "${SIZE}" --argjson annotations "${COMMON_ANNOTATIONS}" '{
    apiVersion: "missioncontrol.datastax.com/v1alpha1",
    kind: "CqlConnectivity",
    metadata: {name: $name, namespace: $ns},
    spec: {
        cassandraDatacenterRef: {name: $dc},
        metadata: {
            commonAnnotations: $annotations,
            commonLabels: {
                "icpdsupport/addOnId": "datastax-mc",
                "velero.io/exclude-from-backup": "true",
                "icpdsupport/ignore-on-nd-backup": "true",
                "icpdsupport/empty-on-nd-backup": "true"
            }
        },
        ingress: {size: $size, dnsBaseName: $dns}
    }
}' | oc apply -f - >/dev/null
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

q() { print -r -- "${(qq)1}"; }
_strip_details_block
mkdir -p "${VARS_FILE:h}"
(umask 077; cat >> "${VARS_FILE}" <<EOF
${_BLOCK_BEGIN}
# Written by $(basename $0) on $(date -u +%Y-%m-%dT%H:%M:%SZ)
#--- DataStax HyperConvergedDatabase (HCD) - CQL gateway (cluster ${MC_DB_CLUSTER}, datacenter ${MC_DB_DC_NAME})
# From outside the cluster: the gateway's Secure Connect Bundle + username/password.
export DATASTAX_HCD_SCB=$(q "${SCB}")
export DATASTAX_HCD_CQL_GATEWAY_LOCAL_DC=$(q "${GW_LOCAL_DC}")
export DATASTAX_HCD_CQL_METADATA_URL=$(q "https://${METADATA_HOST}:443/metadata")
export DATASTAX_HCD_CQL_USER=$(q "${CQL_USER}")
export DATASTAX_HCD_CQL_PASSWORD=$(q "${CQL_PASS}")
${_BLOCK_END}
EOF
)
mc_info "CQL gateway details written to ${VARS_FILE##*/}"
mc_cql_gateway_usage
cat <<EOF
The gateway presents its own datacenter '${GW_LOCAL_DC}'; inside OpenShift use
DATASTAX_HCD_DC_ENDPOINT (from 5_0_prep_datastax_mc.sh) with local DC '${MC_DB_DC_NAME}' instead.
EOF
