#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"

# Credentials: saved to configs/cp4d_config/managed-service-instances/<type>/<instance>-instance_details.sh
# and, while this is true, also as a secret in the Software Hub internal vault, shared with
# SERVICE_INSTANCE_VAULT_MEMBERS (default cpadmin). Default: SERVICE_INSTANCE_VAULT_STORE from cpd_vars.sh, else true.
STORE_CREDENTIALS_IN_VAULT="${SERVICE_INSTANCE_VAULT_STORE:-true}"

# ---

for var in OC_LOGIN; do
    if [[ -z "${(P)var:-}" ]]; then
        echo "Error: ${var} is not set. Set it in ./cpd_vars.sh before running this script."
        exit 1
    fi
done

export CPD_PROFILE_NAME="${CPD_PROFILE_NAME:-${CPD_USERNAME}-profile}"
eval "${OC_LOGIN}"
DB2_USERNAME="${DB2_USERNAME:-db2admin}"
export DB2_Version="${DB2_VERSION:-12.1.3.0-cn3-${IMAGE_ARCH}}"
DB2_CPU_LIMIT="2" # 2vCPUs also can be defined as "2000m"
DB2_MEMORY_LIMIT="8Gi" # 8GB
export DB2_PROFILE="${DB2_PROFILE:-general}"
export DB2_STORAGE_CLAIM="${DB2_STORAGE_CLAIM:-30}"
for volume in DATA ACTIVELOGS TEMPTS META BACKUP ARCHIVELOGS; do
    storage_var="DB2_${volume}_STORAGE_GI"
    export "${storage_var}=${(P)storage_var:-${DB2_STORAGE_CLAIM}}"
done
python3 "${_CP4D_REPO_ROOT}/src/helpers/db2_provisioning.py" --validate
DB2_4K_DEVICE_SUPPORT=ON # ON / OFF

DB2_ID=$((RANDOM % 9000000 + 1000000)) # Random 7 digit id suffix
export DB2_INSTANCE_NAME="${DB2_INSTANCE_NAME:-db2oltp-1${DB2_ID}}"
python3 "${_CP4D_REPO_ROOT}/src/helpers/db2_provisioning.py" --validate
export DB2_PAYLOAD_FILE="${SERVICE_INSTANCE_FILE_DIR}/${DB2_INSTANCE_NAME}.json"
[[ ! -e "${DB2_PAYLOAD_FILE}" ]] || { print -u2 -- "Payload already exists; choose a new DB2_INSTANCE_NAME"; exit 1; }

python3 "${_CP4D_REPO_ROOT}/src/helpers/db2_provisioning.py" --check-name "${DB2_INSTANCE_NAME}" --profile "${CPD_PROFILE_NAME}"
existing_instance="$(oc get db2uinstance "${DB2_INSTANCE_NAME}" -n "${PROJECT_CPD_INST_OPERANDS}" --ignore-not-found -o name)"
[[ -z "${existing_instance}" ]] || { print -u2 -- "Db2 instance already exists; choose a new DB2_INSTANCE_NAME"; exit 1; }

# --- Instance password: DB2_PASSWORD as given (export it, or set it in
# ./cpd_vars.sh), else a generated one. It is saved to this instance's details
# file, configs/cp4d_config/managed-service-instances/db2oltp/<instance>-instance_details.sh
# (gitignored, readable by this user only, the same file the instance manager TUI
# writes), before the instance is created, so it is never lost. Its variables are
# prefixed DB2OLTP_<INSTANCE>_ so a later run never picks them up as DB2_PASSWORD.
if [[ -n "${DB2_PASSWORD:-}" ]]; then
    echo "[INFO] Using DB2_PASSWORD from the environment / config."
else
    DB2_PASSWORD="$(h_random_password 24)"
    echo "[INFO] Generated a password for ${DB2_INSTANCE_NAME} (set DB2_PASSWORD to choose one)."
fi
h_instance_var_prefix db2oltp "${DB2_INSTANCE_NAME}"
DB2_VAR_PREFIX="${REPLY}"
h_write_instance_details db2oltp "${DB2_INSTANCE_NAME}" "${PROJECT_CPD_INST_OPERANDS}" \
    "${DB2_VAR_PREFIX}_INSTANCE_NAME=${DB2_INSTANCE_NAME}" \
    "${DB2_VAR_PREFIX}_USERNAME=${DB2_USERNAME}" \
    "${DB2_VAR_PREFIX}_PASSWORD=${DB2_PASSWORD}"
DB2_CREDENTIALS_FILE="${REPLY}"
echo "[INFO] Credentials saved to ${DB2_CREDENTIALS_FILE#${_CP4D_REPO_ROOT}/} (${DB2_VAR_PREFIX}_*)"

# The builder receives credentials through the environment, never shell interpolation.
export DB2_PASSWORD DB2_CPU_LIMIT DB2_MEMORY_LIMIT DB2_4K_DEVICE_SUPPORT
python3 "${_CP4D_REPO_ROOT}/src/helpers/db2_provisioning.py" --output "${DB2_PAYLOAD_FILE}"

python3 "${_CP4D_REPO_ROOT}/src/helpers/db2_provisioning.py" --submit "${DB2_PAYLOAD_FILE}" --profile "${CPD_PROFILE_NAME}"

# --- Observe the progress in provisioning of Db2

echo "Waiting for ${DB2_INSTANCE_NAME} to reach Ready state..."
python3 "${_CP4D_REPO_ROOT}/src/helpers/db2_provisioning.py" --wait "${DB2_INSTANCE_NAME}" --namespace "${PROJECT_CPD_INST_OPERANDS}" --profile "${CPD_PROFILE_NAME}"

cpd-cli service-instance status "${DB2_INSTANCE_NAME}" --profile="${CPD_PROFILE_NAME}" --service-type=db2oltp
