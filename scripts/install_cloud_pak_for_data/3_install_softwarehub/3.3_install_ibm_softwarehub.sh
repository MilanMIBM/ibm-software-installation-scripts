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
eval "${CPDM_OC_LOGIN}"

# Split SOFTWARE_HUB into cluster-scoped and instance-scoped components
HAS_LICENSING=false
HAS_SCHEDULER=false
INSTANCE_COMPONENTS=()

IFS=',' read -rA _all_components <<< "${SOFTWARE_HUB}"
for _c in "${_all_components[@]}"; do
    case "${_c}" in
        ibm-licensing) HAS_LICENSING=true ;;
        scheduler)     HAS_SCHEDULER=true ;;
        *)             INSTANCE_COMPONENTS+=("${_c}") ;;
    esac
done

SKIP_COMPONENTS_FLAG=()
if [[ -n "${COMPONENTS_TO_SKIP:-}" ]]; then
    SKIP_COMPONENTS_FLAG=(--skip_components="${COMPONENTS_TO_SKIP}")
fi

PARAM_FILE_FLAG=()
if [[ -n "${INSTALL_OPTIONS}" ]]; then
    PARAM_FILE_FLAG=(--param-file="${CPD_CONFIG_PATH_CONTAINER}/${INSTALL_OPTIONS_FILE}")
fi

PATCH_FLAG=()
if [[ -n "${PATCH_ID:-}" ]]; then
    PATCH_FLAG=(--patch_id="${PATCH_ID}")
fi

# Install remaining instance-scoped components (e.g. cpfs, cpd_platform)
if (( ${#INSTANCE_COMPONENTS[@]} > 0 )); then
    for var in STG_CLASS_BLOCK STG_CLASS_FILE IMAGE_PULL_PREFIX IMAGE_PULL_SECRET; do
        if [[ -z "${(P)var:-}" ]]; then
            echo "Error: ${var} is not set. Set it in ./cpd_vars.sh before running this script."
            exit 1
        fi
    done
    INSTANCE_COMPONENTS_STR="${(j:,:)INSTANCE_COMPONENTS}"
    echo "[INFO] Running install-components for: ${INSTANCE_COMPONENTS_STR}"
    # Allow this step to fail without aborting the rest of the step-3 chain.
    # A non-zero exit here is commonly a benign "already installed" / helm
    # ownership collision when the components already exist on the cluster.
    # We capture the rc, warn, and continue instead of letting `set -e` kill us.
    set +e
    cpd-cli manage install-components \
        --license_acceptance=true \
        --components=${INSTANCE_COMPONENTS_STR} \
        --release=${VERSION} \
        --operator_ns=${PROJECT_CPD_INST_OPERATORS} \
        --instance_ns=${PROJECT_CPD_INST_OPERANDS} \
        --block_storage_class=${STG_CLASS_BLOCK} \
        --file_storage_class=${STG_CLASS_FILE} \
        --image_pull_prefix=${IMAGE_PULL_PREFIX} \
        --image_pull_secret=${IMAGE_PULL_SECRET} \
        "${PARAM_FILE_FLAG[@]}" \
        "${SKIP_COMPONENTS_FLAG[@]}" \
        --upgrade=${UPDATE} \
        ${PATCH_FLAG[@]+"${PATCH_FLAG[@]}"} 
    _ic_rc=$?
    set -e
    if (( _ic_rc != 0 )); then
        echo "[WARN] install-components exited ${_ic_rc} for: ${INSTANCE_COMPONENTS_STR}."
        echo "[WARN] This is often a benign 'already installed' / helm ownership collision."
        echo "[WARN] Check logs in ~/cpd-cli/work; continuing the step-3 chain regardless."
    fi
fi