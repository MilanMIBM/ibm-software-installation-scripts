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
    apps_domain="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
    [[ -n "${apps_domain}" ]] || mc_die "Could not read the cluster's apps domain - pass --dns-base."
    label="${NAME}-${NS}"
    (( ${#label} <= 63 )) || mc_die "'${label}' is longer than a DNS label allows (63) - pass a shorter --name or --dns-base."
    DNS_BASE="${label}.${apps_domain}"
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
mc_wait_ready cqlconnectivities.missioncontrol.datastax.com "${NAME}" "${NS}" 600 \
    || mc_die "CqlConnectivity ${NAME} not Ready after 10 minutes: oc describe cqlconnectivities.missioncontrol.datastax.com ${NAME} -n ${NS}"

# Ready flips before the router pods are up; wait for them and the metadata Route.
for (( i = 0; i < SIZE; i++ )); do
    for (( t = 0; t < 60; t++ )); do
        oc get deployment "${NAME}-cql-router-${i}" -n "${NS}" >/dev/null 2>&1 && break
        sleep 5
    done
    oc rollout status "deployment/${NAME}-cql-router-${i}" -n "${NS}" --timeout=600s >/dev/null \
        || mc_die "cql-router ${i} did not become available: oc get pods -n ${NS} | grep ${NAME}-cql-router"
done
for (( t = 0; t < 60; t++ )); do
    oc get route -n "${NS}" -o jsonpath='{.items[*].spec.host}' | tr ' ' '\n' | grep -qx "${METADATA_HOST}" && break
    sleep 5
done
oc get route -n "${NS}" -o jsonpath='{.items[*].spec.host}' | tr ' ' '\n' | grep -qx "${METADATA_HOST}" \
    || mc_die "No Route for ${METADATA_HOST} - check: oc get ingress,route -n ${NS}"
mc_info "Routers available, metadata Route: ${METADATA_HOST}"

# --- Secure Connect Bundle -----------------------------------------------------------
# Astra-format bundle built from the gateway's cert-manager secrets: client
# cert/key/CA (PEM, for Python/Node/C++/Go), keystore/truststore (JKS, for Java)
# and config.json pointing at the metadata service.
_work="$(mktemp -d)"
chmod 700 "${_work}"
trap 'rm -rf "${_work}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT
CLIENT_SECRET="${NAME}-client"
for (( t = 0; t < 30; t++ )); do
    oc get secret "${CLIENT_SECRET}" "${NAME}-pw" -n "${NS}" >/dev/null 2>&1 && break
    sleep 5
done
oc get secret "${CLIENT_SECRET}" "${NAME}-pw" -n "${NS}" >/dev/null 2>&1 \
    || mc_die "Gateway secrets ${CLIENT_SECRET} / ${NAME}-pw not found in ${NS}."
mkdir -p "${_work}/bundle"
mc_secret_value "${NS}" "${CLIENT_SECRET}" ca.crt         > "${_work}/bundle/ca.crt"
mc_secret_value "${NS}" "${CLIENT_SECRET}" tls.crt        > "${_work}/bundle/cert"
mc_secret_value "${NS}" "${CLIENT_SECRET}" tls.key        > "${_work}/bundle/key"
mc_secret_value "${NS}" "${CLIENT_SECRET}" keystore.jks   > "${_work}/bundle/identity.jks"
mc_secret_value "${NS}" "${CLIENT_SECRET}" truststore.jks > "${_work}/bundle/trustStore.jks"
STORE_PW="$(mc_secret_value "${NS}" "${NAME}-pw" keystore-pw)"

# Check the metadata service the way the drivers call it (mutual TLS; the
# drivers do not verify its host name, and its certificate is issued for the
# proxy host and router IDs). Its answer also gives the gateway's local DC.
META="$(python3 - "${_work}/bundle" "${METADATA_HOST}" <<'PY'
import json, ssl, sys, time, urllib.request
d, host = sys.argv[1], sys.argv[2]
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = False
ctx.load_verify_locations(f"{d}/ca.crt")
ctx.load_cert_chain(f"{d}/cert", f"{d}/key")
last = None
for _ in range(24):
    try:
        with urllib.request.urlopen(f"https://{host}:443/metadata", context=ctx, timeout=10) as r:
            print(json.dumps(json.load(r)))
            sys.exit(0)
    except Exception as e:
        last = e
        time.sleep(5)
sys.exit(f"metadata service at https://{host}:443/metadata not reachable: {last}")
PY
)" || mc_die "${META:-metadata service check failed}"
GW_LOCAL_DC="$(jq -r '.contact_info.local_dc // "dc1"' <<<"${META}")"
mc_info "Metadata service OK: proxy $(jq -r '.contact_info.sni_proxy_address' <<<"${META}"), $(jq -r '.contact_info.contact_points | length' <<<"${META}") router(s), local DC '${GW_LOCAL_DC}'"

MC_STORE_PW="${STORE_PW}" python3 - "${_work}/bundle" "${METADATA_HOST}" "${GW_LOCAL_DC}" "${SCB}" <<'PY'
import json, os, sys, zipfile
d, host, local_dc, out = sys.argv[1:5]
pw = os.environ["MC_STORE_PW"]
config = {
    "host": host, "port": 443, "localDC": local_dc,
    "caCertLocation": "./ca.crt", "certLocation": "./cert", "keyLocation": "./key",
    "keyStoreLocation": "./identity.jks", "keyStorePassword": pw,
    "trustStoreLocation": "./trustStore.jks", "trustStorePassword": pw,
}
os.makedirs(os.path.dirname(out), mode=0o700, exist_ok=True)
old = os.umask(0o077)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("config.json", json.dumps(config, indent=2))
    for f in ("ca.crt", "cert", "key", "identity.jks", "trustStore.jks"):
        z.write(os.path.join(d, f), f)
os.umask(old)
PY
mc_info "Secure Connect Bundle: ${SCB#${_CP4D_REPO_ROOT}/}"

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
cat <<EOF

Connect from outside the cluster (driver chooses contact points and TLS from the bundle;
do not also set contact points, port or SSL options):
  Python  Cluster(cloud={"secure_connect_bundle": "\$DATASTAX_HCD_SCB"},
                  auth_provider=PlainTextAuthProvider("\$DATASTAX_HCD_CQL_USER", "\$DATASTAX_HCD_CQL_PASSWORD"))
  Java    CqlSession.builder().withCloudSecureConnectBundle(Paths.get(scb)).withAuthCredentials(user, pass)
  cqlsh   cqlsh -b "\$DATASTAX_HCD_SCB" -u "\$DATASTAX_HCD_CQL_USER" -p "\$DATASTAX_HCD_CQL_PASSWORD"
The gateway presents its own datacenter '${GW_LOCAL_DC}'; inside OpenShift use
${INTERNAL_CP:-<cluster>-<dc>-service.${NS}.svc:9042} with local DC '${MC_DB_DC_NAME}' instead.
EOF
