#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: source confluent_vars.sh LAST so its cluster/storage values
# win over the CP4D ones defined in cpd_vars.sh. Override to point these
# scripts at a different config:  ENV_TARGET=<name|path> ./<script>.sh
: "${ENV_TARGET:=confluent}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# ==============================================================================
# Confluent Platform - collect instance details
# ------------------------------------------------------------------------------
# Discovers the live endpoints of the installed cp-all-in-one stack and writes
# them to cp4d_config/confluent_instance_details.sh, mirroring how
# 3.3.1_get_instance_creds.sh writes cpd_instance_details.sh.
#
# The generated file is picked up automatically on the next run of any script in
# this repo, because source_env_setup.sh sources every *.sh in cp4d_config/.
# ==============================================================================

eval "${OC_LOGIN}"

NS="${PROJECT_CONFLUENT_SERVER}"

if ! oc get namespace "${NS}" &>/dev/null; then
    echo "[ERROR] Project '${NS}' does not exist. Run the install scripts first." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# route_url <name> - external https URL for a route, empty if absent.
# ------------------------------------------------------------------------------
route_url() {
    local name="$1" host
    host="$(oc get route "${name}" -n "${NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    # The trailing 'return 0' matters: without it a missing route makes the
    # [[ ]] test the function's exit status, and under `set -e` the caller dies
    # mid-heredoc, silently truncating the generated file.
    [[ -n "${host}" ]] && echo "https://${host}"
    return 0
}

# ------------------------------------------------------------------------------
# svc_url <name> <port> - in-cluster URL, only if the service exists.
# ------------------------------------------------------------------------------
svc_url() {
    local name="$1" port="$2"
    # 'return 0' for the same reason as route_url: a component that was not
    # installed must yield an empty value, not a failing exit status.
    oc get service "${name}" -n "${NS}" &>/dev/null && echo "http://${name}.${NS}.svc.cluster.local:${port}"
    return 0
}

echo "[INFO] Collecting Confluent endpoints from project '${NS}'..."

# In-cluster bootstrap: what applications running on the cluster should use.
CONFLUENT_BOOTSTRAP_INTERNAL="broker.${NS}.svc.cluster.local:${CONFLUENT_BROKER_INTERNAL_PORT}"

CONFLUENT_SCHEMA_REGISTRY_INTERNAL_URL="$(svc_url schema-registry "${CONFLUENT_SCHEMA_REGISTRY_PORT}")"
CONFLUENT_CONNECT_INTERNAL_URL="$(svc_url connect "${CONFLUENT_CONNECT_PORT}")"
CONFLUENT_KSQLDB_INTERNAL_URL="$(svc_url ksqldb-server "${CONFLUENT_KSQLDB_PORT}")"
CONFLUENT_REST_PROXY_INTERNAL_URL="$(svc_url rest-proxy "${CONFLUENT_REST_PROXY_PORT}")"
CONFLUENT_CONTROL_CENTER_INTERNAL_URL="$(svc_url control-center "${CONFLUENT_CONTROL_CENTER_PORT}")"

CONFLUENT_SCHEMA_REGISTRY_URL="$(route_url schema-registry)"
CONFLUENT_CONNECT_URL="$(route_url connect)"
CONFLUENT_KSQLDB_URL="$(route_url ksqldb-server)"
CONFLUENT_REST_PROXY_URL="$(route_url rest-proxy)"
CONFLUENT_CONTROL_CENTER_URL="$(route_url control-center)"
CONFLUENT_MDS_URL="$(route_url mds)"

# External Kafka bootstrap: the per-broker passthrough routes created by
# x.4_confluent_add_external_access.sh, joined into one bootstrap string.
CONFLUENT_BOOTSTRAP_EXTERNAL=""
for _r in $(oc get routes -n "${NS}" -o name 2>/dev/null | grep -E 'route.*/broker-[0-9]+-kafka$' || true); do
    _h="$(oc get "${_r}" -n "${NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    [[ -n "${_h}" ]] && CONFLUENT_BOOTSTRAP_EXTERNAL+="${_h}:443,"
done
CONFLUENT_BOOTSTRAP_EXTERNAL="${CONFLUENT_BOOTSTRAP_EXTERNAL%,}"

# Cluster id as the running broker reports it, falling back to the configured
# value when the broker is not up yet.
CONFLUENT_RUNNING_CLUSTER_ID="$(oc get statefulset broker -n "${NS}" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="CLUSTER_ID")].value}' 2>/dev/null || true)"
CONFLUENT_RUNNING_CLUSTER_ID="${CONFLUENT_RUNNING_CLUSTER_ID:-${CONFLUENT_CLUSTER_ID}}"

# Resolve the deployed version from the broker image tag, so the file records
# what is actually running rather than what "latest" meant at install time.
_broker_image="$(oc get statefulset broker -n "${NS}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
CONFLUENT_DEPLOYED_VERSION="${_broker_image##*:}"

# Basic-auth credentials for the web UIs, read back from the secret created by
# 1.0_confluent_prep.sh. Empty when authentication is disabled.
: "${CONFLUENT_AUTH_SECRET:=confluent-auth}"
CONFLUENT_AUTH_USER="$(oc get secret "${CONFLUENT_AUTH_SECRET}" -n "${NS}" -o jsonpath='{.data.username}' 2>/dev/null | base64 --decode || true)"
CONFLUENT_AUTH_PASS="$(oc get secret "${CONFLUENT_AUTH_SECRET}" -n "${NS}" -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode || true)"

# MDS super-user credentials, read back from whichever user store is deployed.
# These are what "confluent login" uses. Empty until x.4_confluent_add_mds.sh
# has been run.
: "${CONFLUENT_MDS_SUPER_USER:=mds-admin}"
: "${CONFLUENT_LDAP_SECRET:=confluent-ldap}"
: "${CONFLUENT_KEYCLOAK_SECRET:=confluent-keycloak}"
CONFLUENT_MDS_USER=""
CONFLUENT_MDS_PASS=""
for _s in "${CONFLUENT_LDAP_SECRET}" "${CONFLUENT_KEYCLOAK_SECRET}"; do
    _p="$(oc get secret "${_s}" -n "${NS}" -o jsonpath="{.data.${CONFLUENT_MDS_SUPER_USER}}" 2>/dev/null | base64 --decode 2>/dev/null || true)"
    if [[ -n "${_p}" ]]; then
        CONFLUENT_MDS_USER="${CONFLUENT_MDS_SUPER_USER}"
        CONFLUENT_MDS_PASS="${_p}"
        break
    fi
done

# SASL/SCRAM client credentials for the Kafka wire protocol, minted by
# x.2_confluent_add_sasl.sh. Emitted as NAME=PASSWORD pairs, one per line, so a
# caller can pick the client it needs without a second oc call.
: "${CONFLUENT_SASL_SECRET:=confluent-sasl}"
: "${CONFLUENT_SASL_ADMIN_USER:=confluent-admin}"
CONFLUENT_SASL_CLIENT_CREDS=""
_sasl_users=()
if oc get secret "${CONFLUENT_SASL_SECRET}" -n "${NS}" &>/dev/null; then
    for _k in $(oc get secret "${CONFLUENT_SASL_SECRET}" -n "${NS}" -o jsonpath='{.data}' 2>/dev/null \
                | python3 -c 'import sys,json; print(" ".join(json.load(sys.stdin).keys()))' 2>/dev/null || true); do
        _v="$(oc get secret "${CONFLUENT_SASL_SECRET}" -n "${NS}" -o jsonpath="{.data.${_k}}" 2>/dev/null | base64 --decode || true)"
        [[ -n "${_v}" ]] && CONFLUENT_SASL_CLIENT_CREDS+="${_k}=${_v}"$'\n' && _sasl_users+=("${_k}")
    done
fi

REPO_ROOT="$(cd "${SCRIPT_DIR}" && while [[ ! -f pyproject.toml ]]; do cd ..; done && pwd)"
VARS_FILE="${REPO_ROOT}/cp4d_config/confluent_instance_details.sh"

cat > "${VARS_FILE}" <<EOF
# Written by $(basename $0) on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Live endpoints of the Confluent Platform stack in project '${NS}'.
# Regenerate with: src/scripts/confluent_install/$(basename $0)

export CONFLUENT_NAMESPACE="${NS}"
export CONFLUENT_DEPLOYED_VERSION="${CONFLUENT_DEPLOYED_VERSION}"
export CONFLUENT_RUNNING_CLUSTER_ID="${CONFLUENT_RUNNING_CLUSTER_ID}"

# --- Web UI basic auth (Control Center, Prometheus, Alertmanager) -------------
# Empty when CONFLUENT_AUTH_ENABLED=false.
export CONFLUENT_AUTH_USER="${CONFLUENT_AUTH_USER}"
export CONFLUENT_AUTH_PASS="${CONFLUENT_AUTH_PASS}"

# --- In-cluster (use these from workloads running on the cluster) -------------
export CONFLUENT_BOOTSTRAP_INTERNAL="${CONFLUENT_BOOTSTRAP_INTERNAL}"
export CONFLUENT_SCHEMA_REGISTRY_INTERNAL_URL="${CONFLUENT_SCHEMA_REGISTRY_INTERNAL_URL}"
export CONFLUENT_CONNECT_INTERNAL_URL="${CONFLUENT_CONNECT_INTERNAL_URL}"
export CONFLUENT_KSQLDB_INTERNAL_URL="${CONFLUENT_KSQLDB_INTERNAL_URL}"
export CONFLUENT_REST_PROXY_INTERNAL_URL="${CONFLUENT_REST_PROXY_INTERNAL_URL}"
export CONFLUENT_CONTROL_CENTER_INTERNAL_URL="${CONFLUENT_CONTROL_CENTER_INTERNAL_URL}"

# --- External routes (empty when CONFLUENT_CREATE_ROUTES is false) ------------
export CONFLUENT_SCHEMA_REGISTRY_URL="${CONFLUENT_SCHEMA_REGISTRY_URL}"
export CONFLUENT_CONNECT_URL="${CONFLUENT_CONNECT_URL}"
export CONFLUENT_KSQLDB_URL="${CONFLUENT_KSQLDB_URL}"
export CONFLUENT_REST_PROXY_URL="${CONFLUENT_REST_PROXY_URL}"
export CONFLUENT_CONTROL_CENTER_URL="${CONFLUENT_CONTROL_CENTER_URL}"

# --- Metadata Service (MDS) --------------------------------------------------
# Empty unless x.4_confluent_add_mds.sh has been run. This is the URL the
# confluent CLI logs in against:  confluent login --url "\$CONFLUENT_MDS_URL"
export CONFLUENT_MDS_URL="${CONFLUENT_MDS_URL}"
export CONFLUENT_MDS_USER="${CONFLUENT_MDS_USER}"
export CONFLUENT_MDS_PASS="${CONFLUENT_MDS_PASS}"

# The confluent CLI reads these directly, so a non-interactive login is just:
#   confluent login   (no flags needed once this file is sourced)
export CONFLUENT_PLATFORM_MDS_URL="${CONFLUENT_MDS_URL}"
export CONFLUENT_PLATFORM_USERNAME="${CONFLUENT_MDS_USER}"
export CONFLUENT_PLATFORM_PASSWORD="${CONFLUENT_MDS_PASS}"

# --- External Kafka bootstrap ------------------------------------------------
# Empty unless x.4_confluent_add_external_access.sh has been run. Use with
# cp4d_config/confluent_external_client.properties (SASL_SSL).
export CONFLUENT_BOOTSTRAP_EXTERNAL="${CONFLUENT_BOOTSTRAP_EXTERNAL}"

# --- Kafka SASL/SCRAM client credentials -------------------------------------
# Empty unless x.2_confluent_add_sasl.sh has been run. One NAME=PASSWORD per
# line, including the platform admin user. Read one with:
#   echo "\$CONFLUENT_SASL_CLIENT_CREDS" | grep '^app-client=' | cut -d= -f2-
export CONFLUENT_SASL_CLIENT_CREDS="${CONFLUENT_SASL_CLIENT_CREDS}"
EOF

echo ""
cat "${VARS_FILE}"
echo ""
echo "[INFO] Confluent instance details written to ${VARS_FILE##*/}"

# ------------------------------------------------------------------------------
# Kafka client properties for the SASL-enabled cluster
# ------------------------------------------------------------------------------
# Written here as well as by x.2_confluent_add_sasl.sh, because SASL can now be
# turned on without that script running at all: CONFLUENT_MDS_ENABLED=true
# implies SASL, and the installer enables it directly. Regenerating the file
# from the live secret on every details run keeps it in step with the cluster
# whichever path enabled SASL, and refreshes it after a credential rotation.
#
# Unlike the env-var file above, this is a real Kafka properties file: it is
# passed to the CLI tools with --command-config, so the values are live rather
# than commented out.
: "${CONFLUENT_WRITE_SASL_PROPERTIES:=true}"
: "${CONFLUENT_SASL_MECHANISM:=SCRAM-SHA-512}"

if [[ "${CONFLUENT_WRITE_SASL_PROPERTIES}" != "true" ]]; then
    echo "[INFO] Skipping the SASL client properties file (CONFLUENT_WRITE_SASL_PROPERTIES=false)."
elif (( ${#_sasl_users[@]} == 0 )); then
    echo "[INFO] No SASL credentials in '${CONFLUENT_SASL_SECRET}'; skipping the client properties file."
else
    SASL_FILE="${REPO_ROOT}/cp4d_config/confluent_sasl_clients.properties"

    # The admin user is the default the file is configured for; every other
    # client is listed underneath as a ready-to-paste jaas line.
    _admin_pw="$(oc get secret "${CONFLUENT_SASL_SECRET}" -n "${NS}" \
        -o jsonpath="{.data.${CONFLUENT_SASL_ADMIN_USER}}" 2>/dev/null | base64 --decode || true)"
    _default_user="${CONFLUENT_SASL_ADMIN_USER}"
    _default_pw="${_admin_pw}"
    # Fall back to the first client in the secret when the configured admin user
    # is not one of its keys, so the file is never written with empty values.
    if [[ -z "${_default_pw}" ]]; then
        _default_user="${_sasl_users[1]}"
        _default_pw="$(oc get secret "${CONFLUENT_SASL_SECRET}" -n "${NS}" \
            -o jsonpath="{.data.${_default_user}}" 2>/dev/null | base64 --decode || true)"
    fi

    {
        echo "# Written by $(basename $0) on $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        echo "# Kafka client properties for the SASL cluster in '${NS}'."
        echo "#"
        echo "# Configured for '${_default_user}'. Use with the Kafka CLI tools:"
        echo "#   kafka-topics --bootstrap-server ${CONFLUENT_BOOTSTRAP_INTERNAL} \\"
        echo "#     --command-config cp4d_config/${SASL_FILE##*/} --list"
        echo "#"
        echo "# Regenerate with: src/scripts/confluent_install/$(basename $0)"
        echo "# Suppress with:   CONFLUENT_WRITE_SASL_PROPERTIES=false"
        echo ""
        echo "bootstrap.servers=${CONFLUENT_BOOTSTRAP_INTERNAL}"
        echo "security.protocol=SASL_PLAINTEXT"
        echo "sasl.mechanism=${CONFLUENT_SASL_MECHANISM}"
        echo "sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\"${_default_user}\" password=\"${_default_pw}\";"
        echo ""
        echo "# ---- other clients: swap the jaas line above for one of these ----"
        for _u in "${_sasl_users[@]}"; do
            [[ "${_u}" == "${_default_user}" ]] && continue
            _p="$(oc get secret "${CONFLUENT_SASL_SECRET}" -n "${NS}" \
                -o jsonpath="{.data.${_u}}" 2>/dev/null | base64 --decode || true)"
            [[ -z "${_p}" ]] && continue
            echo "# ${_u}"
            echo "# sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\"${_u}\" password=\"${_p}\";"
        done

        # watsonx.data "Add component - Apache Kafka" needs the EXTERNAL
        # listener: its form has no plaintext option, so it always opens TLS and
        # the SASL_PLAINTEXT listener above cannot answer it. The fields are
        # spelled out because they are typed into a UI, not read by a client.
        echo ""
        echo "# =============================================================================="
        echo "# watsonx.data - Add component > Apache Kafka"
        echo "# =============================================================================="
        if [[ -z "${CONFLUENT_BOOTSTRAP_EXTERNAL}" ]]; then
            echo "# Not available: the EXTERNAL listener is not deployed."
            echo "# Run x.4_confluent_add_external_access.sh, then regenerate this file."
        else
            echo "#"
            echo "# Hostname / Port  - one row per broker, all on port 443 (the router's"
            echo "#                    port, not the container's). Add rows with '+' so"
            echo "#                    partition-leader redirects resolve."
            for _hp in ${(s:,:)CONFLUENT_BOOTSTRAP_EXTERNAL}; do
                echo "#                    ${_hp%:*}    ${_hp##*:}"
            done
            echo "#"
            echo "# SASL connection  - ON"
            echo "# SASL mechanism   - ${CONFLUENT_SASL_MECHANISM}"
            echo "# Username         - ${_default_user}"
            echo "# API key/Password - ${_default_pw}"
            echo "#"
            echo "# Upload certificate - cp4d_config/confluent_kafka_ca.crt"
            echo "#                      (the private CA; the brokers' certificate is not"
            echo "#                       signed by a public authority)"
        fi
    } > "${SASL_FILE}"
    # Mode 600: this file holds live passwords in plain text.
    chmod 600 "${SASL_FILE}"

    echo "[INFO] SASL client properties written to ${SASL_FILE##*/} (mode 600, user '${_default_user}')."
fi
