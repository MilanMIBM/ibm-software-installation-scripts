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

for var in OC_LOGIN CPDM_OC_LOGIN PREP_PA; do
    if [[ -z "${(P)var:-}" ]]; then
        echo "Error: ${var} is not set. Set it in ./cpd_vars.sh before running this script."
        exit 1
    fi
done

eval "${OC_LOGIN}"

#---
# export PLANNING_PAYLOAD_FILE="${SCRIPT_DIR}/planning-analytics-instance.json"
export PLANNING_PAYLOAD_FILE="${SERVICE_INSTANCE_FILE_DIR}/planning-analytics-instance.json"
CPD_PROFILE_NAME="${CPD_USERNAME}-profile"
#---
PA_INSTANCE_VERSION="5.3.3"
PA_INSTANCE_NAME="planninganalytics"
MYSQL_PV_SIZE=5 # recommended 20
COUCHDB_PV_SIZE=5 # recommended 20
MONGODB_PV_SIZE=5 # recommended 20
REDIS_PV_SIZE=5 # recommended 20
PA_INSTANCE_SIZE="small" # small_mincpureq, small, medium, large


# "persistence.class":"${STG_CLASS_BLOCK}" /or/ "${STG_CLASS_FILE}" and "tm1Service.storageClass":"${STG_CLASS_FILE}". 
PREP_PLANNINGANALYTICS='cat << EOF > ${PLANNING_PAYLOAD_FILE}
{
    "addon_type":"pa",
    "addon_version":"${PA_INSTANCE_VERSION}",
    "display_name":"${PA_INSTANCE_NAME}",
    "namespace":"${PROJECT_CPD_INST_OPERANDS}", 
    "create_arguments":{
        "description":"",
        "metadata":{
            "addon_version":"${PA_INSTANCE_VERSION}"
        },
        "resources":{},
        "parameters":{
            "paw_PA_INSTANCE_NAME":"${PA_INSTANCE_NAME}",
            "persistence.class":"${STG_CLASS_FILE}",
            "persistence.mysqlSize":"${MYSQL_PV_SIZE}Gi",
            "persistence.couchdbSize":"${COUCHDB_PV_SIZE}Gi",
            "persistence.mongoSize":"${MONGODB_PV_SIZE}Gi",
            "persistence.redisSize":"${REDIS_PV_SIZE}Gi",
            "scaleConfig":"${PA_INSTANCE_SIZE}",
            "common.tm1InternalType":true,
            "common.tm1Location":"http://pa-service-provider-api:1212",
            "tm1Service.storageClass":"${STG_CLASS_FILE}"
        }
    },
    "transient_fields":{}
}
EOF'

eval "${PREP_PLANNINGANALYTICS}"

eval "${CPDM_OC_LOGIN}"

cpd-cli service-instance create \
    --profile=${CPD_PROFILE_NAME} \
    --from-source=${PLANNING_PAYLOAD_FILE} \
    # --preview