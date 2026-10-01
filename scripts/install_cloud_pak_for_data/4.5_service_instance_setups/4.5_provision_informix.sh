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


USE_SINGLE_STORAGE_INSTANCE=false
#--- Configuration
INSTANCE_NAME="informix-server"
INSTANCE_VERSION="10.1.0"
INSTANCE_REPLICAS=1 # Min 1, Max 10 replicas
REPLICA_CPU=4 # Min 1, Max 16 CPUs
REPLICA_MEMORY=12 # Min 1, Max 64 GB
SHARED_STORAGE_SIZE=40
SHARED_STORAGE_UNIT="Gi"
DATA_STORAGE_SIZE=40
DATA_STORAGE_UNIT="Gi"
BACKUP_STORAGE_SIZE=40
BACKUP_STORAGE_UNIT="Gi"
# ---
# export INFORMIX_PAYLOAD_FILE="${SCRIPT_DIR}/informix-instance.json"
export INFORMIX_PAYLOAD_FILE="${SERVICE_INSTANCE_FILE_DIR}/informix-instance.json"
CPD_PROFILE_NAME="${CPD_USERNAME}-profile"
# ---
for var in CPDM_OC_LOGIN PREP_INFORMIX; do
    if [[ -z "${(P)var:-}" ]]; then
        echo "Error: ${var} is not set. Set it in ./cpd_vars.sh before running this script."
        exit 1
    fi
done

eval "${CPDM_OC_LOGIN}"

# --- Prepare service instance config ---


if [[ "${USE_SINGLE_STORAGE_INSTANCE}" == "true" ]]; then
    # Option 1 - Shared storage
    cat << EOF > ${INFORMIX_PAYLOAD_FILE}
{
    "display_name": "${INSTANCE_NAME}",
    "namespace": "${PROJECT_CPD_INST_OPERANDS}",
    "addon_type": "informix",
    "addon_version": "${INSTANCE_VERSION}",
    "create_arguments": {
        "description": "Informix DB",
        "metadata": {
            "ifxreplicas": ${INSTANCE_REPLICAS},
            "corespernode": ${REPLICA_CPU},
            "memorypernode": ${REPLICA_MEMORY},
            "singlepvcoption": true,
            "sharedstorageoptions": "new_claim",
            "sharedstorageclass": "${STG_CLASS_FILE}",
            "sharedsize": ${SHARED_STORAGE_SIZE},
            "sharedunit": "${SHARED_STORAGE_UNIT}",
            "datastorageoptions": "new_claim",
            "backupstorageoptions": "new_claim"
        }
    }
}
EOF
else
    # Option 2 - Split storage
    cat << EOF > ${INFORMIX_PAYLOAD_FILE}
{
    "display_name": "${INSTANCE_NAME}",
    "namespace": "${PROJECT_CPD_INST_OPERANDS}",
    "addon_type": "informix",
    "addon_version": "${INSTANCE_VERSION}",
    "create_arguments": {
        "description": "Informix DB",
        "metadata": {
            "ifxreplicas": ${INSTANCE_REPLICAS},
            "corespernode": ${REPLICA_CPU},
            "memorypernode": ${REPLICA_MEMORY},
            "singlepvcoption": false,
            "sharedstorageoptions": "new_claim",
            "sharedstorageclass": "${STG_CLASS_FILE}",
            "sharedsize": ${SHARED_STORAGE_SIZE},
            "sharedunit": "${SHARED_STORAGE_UNIT}",
            "datastorageoptions": "new_claim",
            "datastorageclass": "${STG_CLASS_FILE}",
            "datasize": ${DATA_STORAGE_SIZE},
            "dataunit": "${DATA_STORAGE_UNIT}",
            "backupstorageoptions": "new_claim",
            "backupstorageclass": "${STG_CLASS_FILE}",
            "backupsize": ${BACKUP_STORAGE_SIZE},
            "backupunit": "${BACKUP_STORAGE_UNIT}"
        }
    }
}
EOF
fi

echo "Payload saved to: ${INFORMIX_PAYLOAD_FILE}"
#--- Provision command
echo "Service creation from ${INFORMIX_PAYLOAD_FILE} with profile ${CPD_PROFILE_NAME}"
cpd-cli service-instance create \
    --profile=${CPD_PROFILE_NAME} \
    --from-source=${INFORMIX_PAYLOAD_FILE} \
    --verbose