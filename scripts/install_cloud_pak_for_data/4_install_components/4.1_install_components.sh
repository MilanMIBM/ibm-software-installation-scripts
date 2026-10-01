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

for var in CPD_COMPONENTS VERSION PROJECT_CPD_INST_OPERATORS PROJECT_CPD_INST_OPERANDS STG_CLASS_BLOCK STG_CLASS_FILE IMAGE_PULL_PREFIX IMAGE_PULL_SECRET; do
    if [[ -z "${(P)var:-}" ]]; then
        echo "Error: ${var} is not set. Set it in ./cpd_vars.sh before running this script."
        exit 1
    fi
done

eval "${CPDM_OC_LOGIN}"

SKIP_COMPONENTS_FLAG=()
if [[ -n "${COMPONENTS_TO_SKIP:-}" ]]; then
    SKIP_COMPONENTS_FLAG=(--skip_components="${COMPONENTS_TO_SKIP}")
fi

PARAM_FILE_FLAG=()
if [[ -n "${INSTALL_OPTIONS:-}" ]]; then
    PARAM_FILE_FLAG=(--param-file="${CPD_CONFIG_PATH_CONTAINER}/${INSTALL_OPTIONS_FILE}")
fi

PATCH_FLAG=()
if [[ -n "${PATCH_ID:-}" ]]; then
    PATCH_FLAG=(--patch_id="${PATCH_ID}")
fi

COMPONENTS=${COMPLETE_COMPONENT_LIST}

# --- Databand needs a customer-provided postgres secret before its chart can install ---
DATABAND_COMPONENTS=(ibm-databand watsonx_data_premium watsonx_dataintegration)
for component in ${(s:,:)COMPONENTS}; do
    if (( ${DATABAND_COMPONENTS[(Ie)${component}]} )); then
        echo "[INFO] ${component} is in COMPONENTS - provisioning databand postgres first"
        "${SCRIPT_DIR}/../4.5_service_instance_setups/4.5_provision_databand_postgres.sh"
        break
    fi
done

install_components() {
    cpd-cli manage install-components \
        --license_acceptance=true \
        --components="$1" \
        --release=${VERSION} \
        --operator_ns=${PROJECT_CPD_INST_OPERATORS} \
        --instance_ns=${PROJECT_CPD_INST_OPERANDS} \
        --block_storage_class=${STG_CLASS_BLOCK} \
        --file_storage_class=${STG_CLASS_FILE} \
        --image_pull_prefix=${IMAGE_PULL_PREFIX} \
        --image_pull_secret=${IMAGE_PULL_SECRET} \
        --upgrade=${UPDATE} \
        ${PARAM_FILE_FLAG[@]+"${PARAM_FILE_FLAG[@]}"} \
        ${SKIP_COMPONENTS_FLAG[@]+"${SKIP_COMPONENTS_FLAG[@]}"} \
        ${PATCH_FLAG[@]+"${PATCH_FLAG[@]}"}
}

manta_secrets_exist() {
    oc get secret manta-credentials manta-keys -n ${PROJECT_CPD_INST_OPERANDS} >/dev/null 2>&1
}

# --- mantaflow prevalidation requires the manta-credentials/manta-keys secrets that wkc creates ---
# If mantaflow is requested and those secrets don't exist yet, strip it from the main install
# and install it on its own afterwards. A mantaflow failure only warns, so later steps still run.
DEFER_MANTAFLOW=false
if (( ${${(s:,:)COMPONENTS}[(Ie)mantaflow]} )) && ! manta_secrets_exist; then
    DEFER_MANTAFLOW=true
    COMPONENTS=${(j:,:)${(@)${(s:,:)COMPONENTS}:#mantaflow}}
    echo "[INFO] mantaflow requested but manta secrets not present yet - installing it after the other components"
fi

if [[ -n "${COMPONENTS}" ]]; then
    install_components "${COMPONENTS}"
fi

if [[ "${DEFER_MANTAFLOW}" == "true" ]]; then
    echo "[INFO] Waiting up to 15m for manta-credentials and manta-keys secrets in ${PROJECT_CPD_INST_OPERANDS}..."
    for _ in {1..90}; do
        manta_secrets_exist && break
        sleep 10
    done
    if ! manta_secrets_exist; then
        echo "[WARN] manta-credentials/manta-keys secrets not found (they are created by wkc) - skipping mantaflow."
        echo "[WARN] Once wkc is installed, re-run this script to install mantaflow."
    elif install_components mantaflow; then
        echo "[INFO] mantaflow installed"
    else
        echo "[WARN] mantaflow install failed - other components are unaffected. Re-run this script to retry."
    fi
fi
