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


#--- Configuration
EDB_ID=$((RANDOM % 90000 + 10000)) # Random 5 digit id suffix
INSTANCE_NAME="edb-postgres-${EDB_ID}"
INSTANCE_DESCRIPTION="EDB Postgres DB"
ADDON_VERSION="5.4.0"
INSTANCE_VERSION=18.3   # Pick one: 13.23, 14.20, 15.15, 16.11, 17.7, 18.1 (based on SWHub version; 18.3 for 5.4.0)
EDB_TYPE="enterprise"   # "standard" or "enterprise"
INSTANCE_STORAGE=20
INSTANCE_STORAGE_UNIT="Gi"   # Gi, Ti, or Pi
INSTANCE_REPLICAS=1  # Min 1, Max 50 (use 3 for HA)
REPLICA_CPU=2        # Min 1, Max 16
REPLICA_MEMORY=6     # Min 1, Max 64 GB

# Custom secrets: adds superuserSecret and bootstrap.initdb.secret to the cluster spec
CUSTOM_SECRETS=false
SUPERUSER_SECRET_NAME="edb-superuser-secret"   # spec.superuserSecret.name
BOOTSTRAP_SECRET_NAME="edb-bootstrap-secret"   # spec.bootstrap.initdb.secret.name

# Custom TLS: adds certificates block (clientCASecret, serverCASecret, replicationTLSSecret, serverTLSSecret)
CUSTOM_TLS=false
TLS_CLIENT_CA_SECRET="edb-client-ca"
TLS_SERVER_CA_SECRET="edb-server-ca"
TLS_SERVER_TLS_SECRET="edb-server-tls"
TLS_REPLICATION_SECRET="edb-replication-tls"
# ---
export EDB_PAYLOAD_FILE="${SERVICE_INSTANCE_FILE_DIR}/edb-cpd-instance.json"
CPD_PROFILE_NAME="${CPD_USERNAME}-profile"
# ---
for var in CPDM_OC_LOGIN PREP_EDB; do
    if [[ -z "${(P)var:-}" ]]; then
        echo "Error: ${var} is not set. Set it in ./cpd_vars.sh before running this script."
        exit 1
    fi
done

eval "${CPDM_OC_LOGIN}"

# --- Build optional JSON fragments ---
CUSTOM_SECRETS_FRAGMENT=""
if [[ "${CUSTOM_SECRETS}" == "true" ]]; then
    CUSTOM_SECRETS_FRAGMENT=",
            \"customCredential\": \"true\",
            \"superuserSecretName\": \"${SUPERUSER_SECRET_NAME}\",
            \"bootstrapSecretName\": \"${BOOTSTRAP_SECRET_NAME}\""
fi

CUSTOM_TLS_FRAGMENT=""
if [[ "${CUSTOM_TLS}" == "true" ]]; then
    CUSTOM_TLS_FRAGMENT=",
            \"clientCASecret\": \"${TLS_CLIENT_CA_SECRET}\",
            \"serverCASecret\": \"${TLS_SERVER_CA_SECRET}\",
            \"serverTLSSecret\": \"${TLS_SERVER_TLS_SECRET}\",
            \"replicationTLSSecret\": \"${TLS_REPLICATION_SECRET}\""
fi

# --- Prepare service instance config --- # always uses File Storage classes
cat << EOF > ${EDB_PAYLOAD_FILE}
{
    "addon_type": "edb",
    "display_name": "${INSTANCE_NAME}",
    "namespace": "${PROJECT_CPD_INST_OPERANDS}",
    "addon_version": "${ADDON_VERSION}",
    "create_arguments": {
        "description": "${INSTANCE_DESCRIPTION}",
        "parameters": {
            "customCredential": "false",
            "version": ${INSTANCE_VERSION},
            "edbtype": "${EDB_TYPE}",
            "compatibilityWithOracle": "true",
            "storageClass": "${STG_CLASS_FILE}",
            "ssize": ${INSTANCE_STORAGE},
            "sunit": "${INSTANCE_STORAGE_UNIT}",
            "members": ${INSTANCE_REPLICAS},
            "corespernode": ${REPLICA_CPU},
            "memorypernode": ${REPLICA_MEMORY}${CUSTOM_SECRETS_FRAGMENT}${CUSTOM_TLS_FRAGMENT}
        }
    }
}
EOF

echo "Payload saved to: ${EDB_PAYLOAD_FILE}"
#--- Provision command
echo "Service creation from ${EDB_PAYLOAD_FILE} with profile ${CPD_PROFILE_NAME}"
cpd-cli service-instance create \
    --profile=${CPD_PROFILE_NAME} \
    --from-source=${EDB_PAYLOAD_FILE} \
    --verbose

#--- Validate provisioning
echo "Checking service instance status..."
cpd-cli service-instance status ${INSTANCE_NAME} \
    --profile=${CPD_PROFILE_NAME} \
    --output=json
