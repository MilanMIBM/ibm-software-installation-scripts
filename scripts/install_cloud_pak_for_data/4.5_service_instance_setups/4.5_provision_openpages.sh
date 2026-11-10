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

for var in OC_LOGIN CPDM_OC_LOGIN CPD_USERNAME PROJECT_CPD_INST_OPERANDS STG_CLASS_FILE; do
    if [[ -z "${(P)var:-}" ]]; then
        echo "Error: ${var} is not set. Set it in ./cpd_vars.sh before running this script."
        exit 1
    fi
done

eval "${OC_LOGIN}"

# ------------------------------------------------------------------------------
# Hardware requirements (x86_64)
# ------------------------------------------------------------------------------
# Minimum resources for OpenPages with a Db2 database on IBM Software Hub:
#
#   vCPU                      Memory                    Storage
#   ------------------------  ------------------------  ---------------------------
#   Operator pods:  0.5 vCPU  Operator pods:  2 GB RAM  Persistent:  252 GB
#   Catalog pods:  0.01 vCPU  Catalog pods: 0.05 GB RAM Ephemeral:   10.9 GB
#   Operand:          6 vCPU  Operand:       20 GB RAM  Image:  up to 8.52 GB
#
# Notes:
#   - These are the minimums for the DEFAULT instance size with the integrated
#     Db2. The actual footprint depends on OPENPAGES_INSTANCE_SIZE (below), the
#     storage class in use, and whether the database is internal or external.
#   - OpenPages uses "Db2 as a service", which is distinct from the Db2 service
#     in the services catalog. It can optionally run on dedicated nodes - see
#     OPENPAGES_DEDICATED_NODE below.
#   - Using a database OUTSIDE of IBM Software Hub (OPENPAGES_EXTERNAL_DB=true)
#     lowers the minimum vCPU and memory requirements.
#
# Full x86_64 hardware requirements:
#   https://www.ibm.com/docs/en/software-hub/5.4.x?topic=requirements-x86-64-hardware
#
# ------------------------------------------------------------------------------
# Instance configuration
# ------------------------------------------------------------------------------

# OpenPages uses its own versioning scheme, mapped from the IBM Software Hub version.
# IBM Software Hub 5.4.0 -> OpenPages 10.0.0
# Override by exporting OPENPAGES_VERSION in ./cpd_vars.sh if you need a different value.
if [[ -z "${OPENPAGES_VERSION:-}" ]]; then
    case "${VERSION:-}" in
        5.4.0) OPENPAGES_VERSION="10.0.0" ;;
        *)
            echo "Error: no OpenPages instance version mapping for IBM Software Hub version '${VERSION:-<unset>}'."
            echo "       Set OPENPAGES_VERSION explicitly in ./cpd_vars.sh (e.g. export OPENPAGES_VERSION=\"10.0.0\")."
            exit 1
            ;;
    esac
fi
export OPENPAGES_VERSION

# Instance size - determines the resources allocated to the service instance.
# Valid values: small_mincpureq | xsmall | small | medium | large
#
#   Default sizes for OpenPages instances
#   -------------------------------------
#   small_mincpureq  Use this setting when you want to use minimal reserved CPU
#                    resources without removing the CPU pod setting.
#   xsmall (XS)      One application server and one database server.
#                    Use for nonproduction workloads only.
#   small            Two application servers and one database server.
#   medium           Two application servers and one database server.
#   large            Four application servers and one database server.
OPENPAGES_INSTANCE_SIZE="${OPENPAGES_INSTANCE_SIZE:-small}"
case "${OPENPAGES_INSTANCE_SIZE}" in
    small_mincpureq|xsmall|small|medium|large) ;;
    *)
        echo "Error: OPENPAGES_INSTANCE_SIZE='${OPENPAGES_INSTANCE_SIZE}' is not valid."
        echo "       Valid values: small_mincpureq, xsmall, small, medium, large"
        exit 1
        ;;
esac

# Integrate the instance with global search (advanced text search across all object types).
OPENPAGES_GLOBAL_SEARCH="${OPENPAGES_GLOBAL_SEARCH:-true}"

# Integrate the instance with Cognos Analytics.
# Note: provisioning restarts the Cognos Analytics instance when this is true.
# Defaults to true only when Cognos Analytics was flagged for install (PREP_CA), otherwise false.
OPENPAGES_COGNOS_INTEGRATION="${OPENPAGES_COGNOS_INTEGRATION:-${PREP_CA:-false}}"

# ------------------------------------------------------------------------------
# Database configuration
# ------------------------------------------------------------------------------

# Toggle for using an external (pre-existing) database instead of the automatically
# provisioned, integrated Db2. Can be set here or fed in from ./cpd_vars.sh.
OPENPAGES_EXTERNAL_DB="${OPENPAGES_EXTERNAL_DB:-false}"

# --- Settings used when OPENPAGES_EXTERNAL_DB=true
# Database provider of the external database: Db2 | Oracle
OPENPAGES_DATABASE_PROVIDER="${OPENPAGES_DATABASE_PROVIDER:-Db2}"
# Name of the secret (in the instance project) that holds the external database credentials.
OPENPAGES_DATABASE_SECRET_NAME="${OPENPAGES_DATABASE_SECRET_NAME:-}"

# --- Settings used when OPENPAGES_EXTERNAL_DB=false (integrated Db2)
# Run the database on a dedicated node.
OPENPAGES_DEDICATED_NODE="${OPENPAGES_DEDICATED_NODE:-false}"
# Node label to pin the database to a specific node. Leave empty for any available node.
OPENPAGES_NODE_LABEL="${OPENPAGES_NODE_LABEL:-}"
# Run the automatically provisioned Db2 with the restricted-v2 SCC.
# Only supported when provisioning into a tethered project that carries the required
# openshift.io/sa.scc.* annotations - keep false when using the operands project.
OPENPAGES_RESTRICTED_V2_SCC="${OPENPAGES_RESTRICTED_V2_SCC:-false}"

# Project to create the instance in. Only one OpenPages instance can exist per project.
# Set to ${PROJECT_CPD_INSTANCE_TETHERED} in ./cpd_vars.sh to use a tethered project instead.
OPENPAGES_INSTANCE_PROJECT="${OPENPAGES_INSTANCE_PROJECT:-${PROJECT_CPD_INST_OPERANDS}}"

# Storage classes - Portworx uses its own dedicated storage classes for Db2.
if [[ "${OPENSHIFT_TYPE:-}" == "portworx" ]]; then
    OPENPAGES_DB_DATA_STG_CLASS="portworx-db2-rwo-sc"
    OPENPAGES_DB_META_STG_CLASS="portworx-db2-rwx-sc"
    OPENPAGES_DB_BACKUP_STG_CLASS="portworx-db2-rwx-sc"
    OPENPAGES_APP_STG_CLASS="portworx-shared-gp3"
else
    OPENPAGES_DB_DATA_STG_CLASS="${STG_CLASS_BLOCK}"
    OPENPAGES_DB_META_STG_CLASS="${STG_CLASS_FILE}"
    OPENPAGES_DB_BACKUP_STG_CLASS="${STG_CLASS_FILE}"
    OPENPAGES_APP_STG_CLASS="${STG_CLASS_FILE}"
fi

# --- Validate the configuration that the chosen database mode depends on.

if [[ "${OPENPAGES_EXTERNAL_DB}" == "true" ]]; then
    case "${OPENPAGES_DATABASE_PROVIDER}" in
        Db2|Oracle) ;;
        *)
            echo "Error: OPENPAGES_DATABASE_PROVIDER='${OPENPAGES_DATABASE_PROVIDER}' is not valid."
            echo "       Valid values when using an external database: Db2, Oracle"
            exit 1
            ;;
    esac

    if [[ -z "${OPENPAGES_DATABASE_SECRET_NAME}" ]]; then
        echo "Error: OPENPAGES_EXTERNAL_DB is true but OPENPAGES_DATABASE_SECRET_NAME is not set."
        echo "       Set it in ./cpd_vars.sh to the name of the secret holding the external database credentials."
        exit 1
    fi

    if ! oc get secret "${OPENPAGES_DATABASE_SECRET_NAME}" -n "${OPENPAGES_INSTANCE_PROJECT}" >/dev/null 2>&1; then
        echo "Error: secret '${OPENPAGES_DATABASE_SECRET_NAME}' was not found in project '${OPENPAGES_INSTANCE_PROJECT}'."
        echo "       Create the external database credentials secret before running this script."
        exit 1
    fi
else
    if [[ -z "${STG_CLASS_BLOCK:-}" && "${OPENSHIFT_TYPE:-}" != "portworx" ]]; then
        echo "Error: STG_CLASS_BLOCK is not set but is required for the automatically provisioned Db2."
        echo "       Set it in ./cpd_vars.sh, or set OPENPAGES_EXTERNAL_DB=true to use an external database."
        exit 1
    fi
fi

OPENPAGES_ID=$((RANDOM % 9000000 + 1000000)) # Random 7 digit id suffix
export OPENPAGES_PAYLOAD_FILE="${SERVICE_INSTANCE_FILE_DIR}/openpages-instance.json"
export OPENPAGES_INSTANCE_NAME="${OPENPAGES_INSTANCE_NAME:-openpages-1${OPENPAGES_ID}}"

export CPD_PROFILE_NAME="${CPD_USERNAME}-profile"

echo "Provisioning OpenPages instance '${OPENPAGES_INSTANCE_NAME}' (version ${OPENPAGES_VERSION}, size ${OPENPAGES_INSTANCE_SIZE})"
echo "  Project:  ${OPENPAGES_INSTANCE_PROJECT}"
echo "  Database: $([[ "${OPENPAGES_EXTERNAL_DB}" == "true" ]] && echo "external (${OPENPAGES_DATABASE_PROVIDER}, secret ${OPENPAGES_DATABASE_SECRET_NAME})" || echo "internal (Db2, auto-provisioned)")"

# --- Build the CPD service-instance payload (zen-data/v3/service_instances schema)

python3 - <<PYEOF
import json

external_db = "${OPENPAGES_EXTERNAL_DB}".lower() == "true"

if external_db:
    metadata = {
        "databaseType": "external",
        "database": "${OPENPAGES_DATABASE_PROVIDER}",
        "dbSecretName": "${OPENPAGES_DATABASE_SECRET_NAME}",
        "blockStorageClass": "",
        "fileStorageClass": "${STG_CLASS_FILE}",
        "enableGlobalSearch": "${OPENPAGES_GLOBAL_SEARCH}".lower() == "true",
        "enableIntegrationWithCognos": "${OPENPAGES_COGNOS_INTEGRATION}".lower() == "true",
        "scaleConfig": "${OPENPAGES_INSTANCE_SIZE}"
    }
else:
    metadata = {
        "databaseType": "internal",
        "database": "Db2",
        "enableRestrictedV2SCCForDb2": "${OPENPAGES_RESTRICTED_V2_SCC}".lower() == "true",
        "dedicatedDbNodes": "${OPENPAGES_DEDICATED_NODE}".lower() == "true",
        "dbNodeLabelValue": "${OPENPAGES_NODE_LABEL}",
        "dbDataStorageClass": "${OPENPAGES_DB_DATA_STG_CLASS}",
        "dbMetaStorageClass": "${OPENPAGES_DB_META_STG_CLASS}",
        "dbBackupStorageClass": "${OPENPAGES_DB_BACKUP_STG_CLASS}",
        "appStorageClass": "${OPENPAGES_APP_STG_CLASS}",
        "enableGlobalSearch": "${OPENPAGES_GLOBAL_SEARCH}".lower() == "true",
        "enableIntegrationWithCognos": "${OPENPAGES_COGNOS_INTEGRATION}".lower() == "true",
        "scaleConfig": "${OPENPAGES_INSTANCE_SIZE}"
    }

payload = {
    "display_name": "${OPENPAGES_INSTANCE_NAME}",
    "namespace": "${OPENPAGES_INSTANCE_PROJECT}",
    "addon_version": "${OPENPAGES_VERSION}",
    "addon_type": "openpages",
    "create_arguments": {
        "metadata": metadata
    }
}

with open("${OPENPAGES_PAYLOAD_FILE}", "w") as f:
    json.dump(payload, f, indent=2)
PYEOF

# --- Log into the cluster and create the resource.

eval "${OC_LOGIN}"
eval "${CPDM_OC_LOGIN}"

cpd-cli service-instance create \
    --profile=${CPD_PROFILE_NAME} \
    --from-source=${OPENPAGES_PAYLOAD_FILE} \
    --verbose

# --- Observe the progress in provisioning of OpenPages

echo "Waiting for ${OPENPAGES_INSTANCE_NAME} to reach PROVISIONED state..."
sleep 120

# Provisioning an OpenPages instance (with the integrated Db2) commonly takes well over an hour.
OPENPAGES_WAIT_TIMEOUT_SECONDS="${OPENPAGES_WAIT_TIMEOUT_SECONDS:-7200}"
OPENPAGES_POLL_INTERVAL_SECONDS="${OPENPAGES_POLL_INTERVAL_SECONDS:-60}"
_waited=0

while (( _waited < OPENPAGES_WAIT_TIMEOUT_SECONDS )); do
    _status="$(cpd-cli service-instance status "${OPENPAGES_INSTANCE_NAME}" \
        --profile=${CPD_PROFILE_NAME} \
        --output=json 2>/dev/null || true)"

    case "${_status}" in
        *PROVISIONED*)
            echo "${OPENPAGES_INSTANCE_NAME} is PROVISIONED."
            break
            ;;
        *FAILED*)
            echo "${OPENPAGES_INSTANCE_NAME} provisioning FAILED."
            echo "Review the logs of the zen-core-api and zen-watcher pods in ${PROJECT_CPD_INST_OPERANDS} for the cause."
            break
            ;;
        *)
            echo "  still provisioning (${_waited}s elapsed)..."
            ;;
    esac

    sleep "${OPENPAGES_POLL_INTERVAL_SECONDS}"
    _waited=$(( _waited + OPENPAGES_POLL_INTERVAL_SECONDS ))
done

cpd-cli service-instance status "${OPENPAGES_INSTANCE_NAME}" \
    --profile=${CPD_PROFILE_NAME} \
    --output=json
