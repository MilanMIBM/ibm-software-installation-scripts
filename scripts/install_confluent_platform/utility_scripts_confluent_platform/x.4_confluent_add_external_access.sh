#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
: "${ENV_TARGET:=confluent}"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# ==============================================================================
# Confluent Platform - external Kafka access
# ------------------------------------------------------------------------------
# Makes the Kafka protocol reachable from outside the cluster, so the confluent
# CLI and any Kafka client can produce and consume from anywhere.
#
# Why this is not just a route:
#   The existing component routes are HTTP (edge-terminated). Kafka is a binary
#   protocol, so it needs raw TCP. It also needs PER-BROKER addressability: a
#   client is redirected to the specific partition leader, so one address for
#   the whole cluster cannot work (that is the NOT_LEADER_OR_FOLLOWER problem
#   already noted in 1.1_confluent_install.sh).
#
# How it works:
#   One TLS PASSTHROUGH route per broker. The OpenShift router does not decrypt;
#   it picks the backend from the TLS SNI hostname, which the Kafka client sends
#   during the handshake. So:
#
#     broker-0-kafka-<ns>.<domain>:443 -> broker-0
#     broker-1-kafka-<ns>.<domain>:443 -> broker-1
#     broker-2-kafka-<ns>.<domain>:443 -> broker-2
#
#   A new EXTERNAL listener advertises exactly those hostnames on port 443, so
#   leader redirects resolve correctly from anywhere.
#
#   This is a FOURTH listener. The existing PLAINTEXT / PLAINTEXT_HOST /
#   CONTROLLER listeners are untouched, so in-cluster traffic and the KRaft
#   quorum are unaffected.
#
# Security:
#   The EXTERNAL listener is SASL_SSL, not the SASL_PLAINTEXT used inside the
#   cluster: once the endpoint is internet-facing, unencrypted traffic is not
#   acceptable. This script generates a private CA and per-broker certificates
#   (the cluster has no cert-manager) and emits the CA for clients to trust.
#   Supply your own with --cert-path/--key-path if you have a real one.
#
# Requires CONFLUENT_SASL_ENABLED=true. An internet-facing listener without
# authentication is not something this script will create.
#
# DISRUPTIVE: every broker restarts. Topic data is preserved.
#
# Usage:
#   ./x.4_confluent_add_external_access.sh [--disable] [--rotate] [--yes]
#        [--dry-run] [--no-status] [--cert-path P --key-path P]
#
#   --disable    remove the routes and the EXTERNAL listener
#   --rotate     regenerate the CA and broker certificates
#   --cert-path  use an existing PEM certificate instead of generating one
#   --key-path   its private key (required with --cert-path)
#   --yes        skip the confirmation prompt
#   --dry-run    report what would change, change nothing
#   --no-status  skip the closing status report
# ==============================================================================

DISABLE=false
ROTATE=false
ASSUME_YES=true
DRY_RUN=false
RUN_STATUS=true
CERT_PATH=""
KEY_PATH=""

_need_value() { [[ -n "${2:-}" && "${2}" != --* ]] || { echo "[ERROR] $1 requires a value." >&2; exit 1; }; }

while (( $# > 0 )); do
    case "$1" in
        --disable)   DISABLE=true; shift ;;
        --rotate)    ROTATE=true; shift ;;
        --cert-path) _need_value "$1" "${2:-}"; CERT_PATH="$2"; shift 2 ;;
        --key-path)  _need_value "$1" "${2:-}"; KEY_PATH="$2"; shift 2 ;;
        --yes|-y)    ASSUME_YES=true; shift ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --no-status) RUN_STATUS=false; shift ;;
        -h|--help)   sed -n '16,62p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Try --help." >&2; exit 1 ;;
    esac
done

if [[ -n "${CERT_PATH}" && -z "${KEY_PATH}" ]] || [[ -z "${CERT_PATH}" && -n "${KEY_PATH}" ]]; then
    echo "[ERROR] --cert-path and --key-path must be given together." >&2
    exit 1
fi

INSTALL="${SCRIPT_DIR}/1.1_confluent_install.sh"
STATUS="${SCRIPT_DIR}/1.2_confluent_status.sh"
[[ -f "${INSTALL}" ]] || { echo "[ERROR] Not found: ${INSTALL}" >&2; exit 1; }

eval "${OC_LOGIN}"

NS="${PROJECT_CONFLUENT_SERVER}"
: "${CONFLUENT_EXTERNAL_KAFKA_PORT:=9094}"
: "${CONFLUENT_EXTERNAL_TLS_SECRET:=confluent-kafka-tls}"
: "${CONFLUENT_EXTERNAL_CERT_VALIDITY_DAYS:=825}"
: "${CONFLUENT_BROKER_REPLICAS:=3}"
: "${CONFLUENT_SASL_ENABLED:=false}"
: "${CONFLUENT_SASL_MECHANISM:=SCRAM-SHA-512}"
: "${CONFLUENT_SASL_SECRET:=confluent-sasl}"
: "${CONFLUENT_SASL_CLIENTS:=app-client}"
: "${CONFLUENT_ROUTE_DOMAIN:=}"

oc get namespace "${NS}" &>/dev/null || { echo "[ERROR] Project '${NS}' does not exist." >&2; exit 1; }

_domain="${CONFLUENT_ROUTE_DOMAIN}"
if [[ -z "${_domain}" ]]; then
    _domain="$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
fi

# Route hostnames, one per broker. These are what the EXTERNAL listener
# advertises and what the client sends as SNI.
typeset -a _hosts _routes
_hosts=(); _routes=()
for _i in $(seq 0 $(( CONFLUENT_BROKER_REPLICAS - 1 ))); do
    _routes+=("broker-${_i}-kafka")
    _hosts+=("broker-${_i}-kafka-${NS}.${_domain}")
done

_current="$(oc get sts broker -n "${NS}" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="KAFKA_LISTENER_SECURITY_PROTOCOL_MAP")].value}' 2>/dev/null || true)"
case "${_current}" in
    *EXTERNAL*) _state="enabled" ;;
    *)          _state="not enabled - Kafka is cluster-internal only" ;;
esac

echo "=============================================================================="
echo " External Kafka access - project '${NS}'"
echo "=============================================================================="
echo "  current : ${_state}"
if $DISABLE; then
    echo "  target  : removed"
else
    echo "  target  : SASL_SSL EXTERNAL listener on per-broker passthrough routes"
    echo "  brokers : ${CONFLUENT_BROKER_REPLICAS}"
    for _h in "${_hosts[@]}"; do echo "            ${_h}:443"; done
fi
echo "  restarts: all ${CONFLUENT_BROKER_REPLICAS} brokers (topic data is kept)"
echo ""

# ------------------------------------------------------------------------------
# Preconditions
# ------------------------------------------------------------------------------
if ! $DISABLE && [[ "${CONFLUENT_SASL_ENABLED}" != "true" ]]; then
    echo "[ERROR] External access requires Kafka authentication, but CONFLUENT_SASL_ENABLED" >&2
    echo "[ERROR] is not 'true'. Exposing an unauthenticated broker to the internet is not" >&2
    echo "[ERROR] something this script will do. Run this first:" >&2
    echo "[ERROR]   ${SCRIPT_DIR}/x.2_confluent_add_sasl.sh" >&2
    exit 1
fi

if $DRY_RUN; then
    echo "[INFO] --dry-run: no changes made."
    exit 0
fi

if ! $ASSUME_YES; then
    if $DISABLE; then
        echo "External Kafka clients will lose access. In-cluster clients are unaffected."
    else
        echo "This exposes Kafka on the cluster's public ingress, protected by SASL over TLS."
    fi
    printf "Continue? [y/N] "
    read -r _reply
    case "${_reply}" in y|Y|yes|YES) ;; *) echo "[INFO] Aborted."; exit 0 ;; esac
    echo ""
fi

# ------------------------------------------------------------------------------
# Disable
# ------------------------------------------------------------------------------
if $DISABLE; then
    echo "------------------------------------------------------------------------------"
    echo " Step 1/2: remove the routes"
    echo "------------------------------------------------------------------------------"
    for _r in "${_routes[@]}"; do
        oc delete route "${_r}" -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true
        echo "[INFO] Removed route '${_r}'."
    done

    echo ""
    echo "------------------------------------------------------------------------------"
    echo " Step 2/2: remove the EXTERNAL listener"
    echo "------------------------------------------------------------------------------"
    export CONFLUENT_EXTERNAL_KAFKA_ENABLED="false"
    "${INSTALL}"

    echo ""
    echo "[INFO] External access removed. The TLS secret '${CONFLUENT_EXTERNAL_TLS_SECRET}' is kept"
    echo "[INFO] so re-enabling reuses the same CA. Delete it to discard the certificates."

    if [[ "${RUN_STATUS}" == "true" && -f "${STATUS}" ]]; then
        echo ""
        "${STATUS}" || echo "[WARN] Status reported one or more components not ready (see above)."
    fi
    exit 0
fi

# ------------------------------------------------------------------------------
# Step 1 - certificates
# ------------------------------------------------------------------------------
echo "------------------------------------------------------------------------------"
echo " Step 1/4: TLS certificates"
echo "------------------------------------------------------------------------------"

_have_ks="$(oc get secret "${CONFLUENT_EXTERNAL_TLS_SECRET}" -n "${NS}" -o jsonpath='{.data.keystore\.jks}' 2>/dev/null || true)"

if [[ -n "${_have_ks}" && "${ROTATE}" != "true" && -z "${CERT_PATH}" ]]; then
    echo "[INFO] Reusing the existing certificates in '${CONFLUENT_EXTERNAL_TLS_SECRET}' (--rotate to replace)."
else
    _tmp="$(mktemp -d)"
    trap 'rm -rf "${_tmp}"' EXIT

    # One certificate carrying every broker hostname as a SAN. The router picks
    # the backend by SNI, and the broker only has to prove it owns the name the
    # client asked for, so a single shared cert is sufficient and much simpler
    # than one keystore per pod.
    _san=""
    for _h in "${_hosts[@]}"; do _san+="DNS:${_h},"; done
    _san+="DNS:broker,DNS:broker-headless,DNS:localhost"

    _store_pw="$(LC_ALL=C head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)"

    if [[ -n "${CERT_PATH}" ]]; then
        [[ -f "${CERT_PATH}" ]] || { echo "[ERROR] No such file: ${CERT_PATH}" >&2; exit 1; }
        [[ -f "${KEY_PATH}"  ]] || { echo "[ERROR] No such file: ${KEY_PATH}" >&2; exit 1; }
        echo "[INFO] Using the supplied certificate."
        cp "${CERT_PATH}" "${_tmp}/server.crt"
        cp "${KEY_PATH}"  "${_tmp}/server.key"
        # Without a separate CA the cert itself is what clients must trust.
        cp "${CERT_PATH}" "${_tmp}/ca.crt"
    else
        echo "[INFO] Generating a private CA and a broker certificate..."
        openssl req -new -x509 -nodes -days "${CONFLUENT_EXTERNAL_CERT_VALIDITY_DAYS}" \
            -subj "/CN=Confluent Kafka CA (${NS})/O=cp4d-installation-scripts" \
            -keyout "${_tmp}/ca.key" -out "${_tmp}/ca.crt" 2>/dev/null

        # X.509 caps a CN at 64 characters and a route hostname on a long
        # cluster domain overruns that, so the CN is a fixed short label. It is
        # not used for validation: every real hostname is in the SAN list below,
        # which is what TLS clients actually check.
        openssl req -new -nodes \
            -subj "/CN=confluent-kafka-broker/O=cp4d-installation-scripts" \
            -keyout "${_tmp}/server.key" -out "${_tmp}/server.csr" 2>/dev/null

        printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "${_san}" > "${_tmp}/ext.cnf"
        openssl x509 -req -in "${_tmp}/server.csr" \
            -CA "${_tmp}/ca.crt" -CAkey "${_tmp}/ca.key" -CAcreateserial \
            -out "${_tmp}/server.crt" -days "${CONFLUENT_EXTERNAL_CERT_VALIDITY_DAYS}" \
            -extfile "${_tmp}/ext.cnf" 2>/dev/null
    fi

    # Kafka wants JKS. Build a PKCS12 with openssl, then let keytool convert it
    # inside a broker pod, so no local JDK is required.
    openssl pkcs12 -export \
        -in "${_tmp}/server.crt" -inkey "${_tmp}/server.key" \
        -certfile "${_tmp}/ca.crt" -name broker \
        -out "${_tmp}/keystore.p12" -passout "pass:${_store_pw}" 2>/dev/null

    oc create secret generic "${CONFLUENT_EXTERNAL_TLS_SECRET}" \
        --from-file=keystore.p12="${_tmp}/keystore.p12" \
        --from-file=ca.crt="${_tmp}/ca.crt" \
        --from-literal=storePassword="${_store_pw}" \
        -n "${NS}" --dry-run=client -o yaml | oc apply -f - >/dev/null

    # Convert to JKS and add the truststore, using keytool from the broker image.
    echo "[INFO] Building the Java keystore and truststore..."
    _pod="$(oc get pod -n "${NS}" -l app=broker -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo broker-0)"
    oc exec "${_pod}" -n "${NS}" -- bash -c "
        set -e
        cd /tmp && rm -rf mkjks && mkdir mkjks && cd mkjks
        cat > keystore.p12.b64 <<'P12'
$(base64 < "${_tmp}/keystore.p12")
P12
        cat > ca.crt <<'CA'
$(cat "${_tmp}/ca.crt")
CA
        base64 -d keystore.p12.b64 > keystore.p12
        keytool -importkeystore -noprompt \
            -srckeystore keystore.p12 -srcstoretype PKCS12 -srcstorepass '${_store_pw}' \
            -destkeystore keystore.jks -deststoretype JKS -deststorepass '${_store_pw}' >/dev/null 2>&1
        keytool -importcert -noprompt -alias ca -file ca.crt \
            -keystore truststore.jks -storepass '${_store_pw}' >/dev/null 2>&1
        base64 keystore.jks > keystore.jks.b64
        base64 truststore.jks > truststore.jks.b64
    "

    oc exec "${_pod}" -n "${NS}" -- cat /tmp/mkjks/keystore.jks.b64   | base64 -d > "${_tmp}/keystore.jks"
    oc exec "${_pod}" -n "${NS}" -- cat /tmp/mkjks/truststore.jks.b64 | base64 -d > "${_tmp}/truststore.jks"
    oc exec "${_pod}" -n "${NS}" -- rm -rf /tmp/mkjks >/dev/null 2>&1 || true

    oc create secret generic "${CONFLUENT_EXTERNAL_TLS_SECRET}" \
        --from-file=keystore.jks="${_tmp}/keystore.jks" \
        --from-file=truststore.jks="${_tmp}/truststore.jks" \
        --from-file=ca.crt="${_tmp}/ca.crt" \
        --from-literal=storePassword="${_store_pw}" \
        -n "${NS}" --dry-run=client -o yaml | oc apply -f - >/dev/null

    # Keep the CA next to the client properties so clients can trust it.
    REPO_ROOT="$(cd "${SCRIPT_DIR}" && while [[ ! -f pyproject.toml ]]; do cd ..; done && pwd)"
    cp "${_tmp}/ca.crt" "${REPO_ROOT}/cp4d_config/confluent_kafka_ca.crt"
    chmod 644 "${REPO_ROOT}/cp4d_config/confluent_kafka_ca.crt"

    rm -rf "${_tmp}"; trap - EXIT
    echo "[INFO] Certificates stored in secret '${CONFLUENT_EXTERNAL_TLS_SECRET}'."
fi

# ------------------------------------------------------------------------------
# Step 2 - routes
# ------------------------------------------------------------------------------
echo ""
echo "------------------------------------------------------------------------------"
echo " Step 2/4: per-broker passthrough routes"
echo "------------------------------------------------------------------------------"

# Each route targets ONE pod, selected by the statefulset-pod-name label that
# the StatefulSet controller sets automatically. A per-pod Service is needed
# because a Route can only point at a Service, and the shared 'broker' Service
# load-balances across all pods.
for _i in $(seq 0 $(( CONFLUENT_BROKER_REPLICAS - 1 ))); do
    _svc="broker-${_i}-external"
    _rt="${_routes[$(( _i + 1 ))]}"
    _host="${_hosts[$(( _i + 1 ))]}"

    oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${_svc}
  namespace: ${NS}
  labels: { app: broker, app.kubernetes.io/part-of: confluent }
spec:
  selector:
    app: broker
    statefulset.kubernetes.io/pod-name: broker-${_i}
  ports:
    - name: external
      port: ${CONFLUENT_EXTERNAL_KAFKA_PORT}
      targetPort: ${CONFLUENT_EXTERNAL_KAFKA_PORT}
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${_rt}
  namespace: ${NS}
  labels: { app.kubernetes.io/part-of: confluent }
spec:
  host: ${_host}
  to: { kind: Service, name: ${_svc} }
  port: { targetPort: external }
  tls:
    # Passthrough: the router must not decrypt. It selects this backend by the
    # TLS SNI hostname the Kafka client sends, and the broker terminates TLS.
    termination: passthrough
EOF
    echo "[INFO] Route ${_rt} -> broker-${_i} (${_host}:443)"
done

# ------------------------------------------------------------------------------
# Step 3 - reconfigure and restart the platform
# ------------------------------------------------------------------------------
echo ""
echo "------------------------------------------------------------------------------"
echo " Step 3/4: add the EXTERNAL listener"
echo "------------------------------------------------------------------------------"

export CONFLUENT_EXTERNAL_KAFKA_ENABLED="true"
"${INSTALL}"

# ------------------------------------------------------------------------------
# Step 4 - client configuration
# ------------------------------------------------------------------------------
echo ""
echo "------------------------------------------------------------------------------"
echo " Step 4/4: client configuration"
echo "------------------------------------------------------------------------------"

REPO_ROOT="$(cd "${SCRIPT_DIR}" && while [[ ! -f pyproject.toml ]]; do cd ..; done && pwd)"
OUT="${REPO_ROOT}/cp4d_config/confluent_external_client.properties"
CA_OUT="${REPO_ROOT}/cp4d_config/confluent_kafka_ca.crt"

_bootstrap=""
for _h in "${_hosts[@]}"; do _bootstrap+="${_h}:443,"; done
_bootstrap="${_bootstrap%,}"

_first_client="${CONFLUENT_SASL_CLIENTS%%,*}"
_first_pw="$(oc get secret "${CONFLUENT_SASL_SECRET}" -n "${NS}" \
    -o jsonpath="{.data.${_first_client}}" 2>/dev/null | base64 --decode || true)"

{
    echo "# Written by $(basename $0) on $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "# Kafka client properties for EXTERNAL access to the cluster in '${NS}'."
    echo "#"
    echo "#   kafka-topics --bootstrap-server ${_hosts[1]}:443 \\"
    echo "#     --command-config cp4d_config/confluent_external_client.properties --list"
    echo ""
    echo "bootstrap.servers=${_bootstrap}"
    echo "security.protocol=SASL_SSL"
    echo "sasl.mechanism=${CONFLUENT_SASL_MECHANISM}"
    echo "ssl.truststore.type=PEM"
    echo "ssl.truststore.location=${CA_OUT}"
    if [[ -n "${_first_pw}" ]]; then
        echo "sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\"${_first_client}\" password=\"${_first_pw}\";"
    else
        echo "# sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\"<user>\" password=\"<password>\";"
    fi
} > "${OUT}"
chmod 600 "${OUT}"

echo "[INFO] Client properties written to ${OUT##*/} (mode 600)."
echo "[INFO] CA certificate at ${CA_OUT##*/}."
echo ""
echo "  bootstrap.servers=${_bootstrap}"
echo "  security.protocol=SASL_SSL"
echo ""
echo "  Test it from here:"
echo "    kafka-topics --bootstrap-server ${_hosts[1]}:443 \\"
echo "      --command-config ${OUT#${REPO_ROOT}/} --list"
echo ""
echo "  Remove external access:  $(basename $0) --disable"

if [[ "${RUN_STATUS}" == "true" && -f "${STATUS}" ]]; then
    echo ""
    "${STATUS}" || echo "[WARN] Status reported one or more components not ready (see above)."
fi
