#!/bin/zsh
# Shared by scripts/install_cloud_pak_for_data/optional_install_swhub_control_center/.
# Source after env_bootstrap.sh, then call swhcc_activate before any cpd-cli command.

source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"
source "${_CP4D_REPO_ROOT}/scripts/operator_install_helpers.sh"

# What setup-control-center installs (CC_COMPONENT_LIST in apply_control_center.py).
SWHCC_COMPONENTS="ibm_swhcc,ibm_usage_metering,ibm_pg_operator,cpfs,zen"

# Point this process's cpd-cli at the premium image in its own container and
# workspace. cpd-cli reads all three from the environment and only ever touches the
# container named here, so the regular container and ~/cpd-cli/work are left alone.
swhcc_activate() {
    h_missing_vars CONTROL_CLUSTER_MODE CONTROL_OCP_URL CONTROL_OLM_UTILS_IMAGE CONTROL_OLM_UTILS_CONTAINER \
        CONTROL_CPD_CLI_WORKSPACE CONTROL_PROJECT_OPERATORS CONTROL_PROJECT_OPERANDS \
        CONTROL_STG_CLASS_BLOCK VERSION \
        || h_die "Not set: ${REPLY}. Check ${ENV_TARGET_FILE:-swhub_control_center_vars.sh}," \
                 "or write it with 0_swhub_control_center_generate_config.sh."
    export OLM_UTILS_IMAGE="${CONTROL_OLM_UTILS_IMAGE}"
    export OLM_UTILS_CONTAINER="${CONTROL_OLM_UTILS_CONTAINER}"
    export CPD_CLI_MANAGE_WORKSPACE="${CONTROL_CPD_CLI_WORKSPACE}"
    export CPD_CLI_WORK_PATH="${CONTROL_CPD_CLI_WORKSPACE}/work"
    mkdir -p "${CPD_CLI_WORK_PATH}"
    cp4d_olm_utils_is_premium \
        || h_die "CONTROL_OLM_UTILS_IMAGE must be an olm-utils-premium-v4 image: setup-control-center is a stub in the standard one."

    # Without this flag it installs the base release and re-applies older shared
    # CRDs over a patched instance.
    SWHCC_PATCH_FLAG=()
    if [[ -n "${PATCH_ID:-}" ]]; then
        SWHCC_PATCH_FLAG=(--patch_id=${PATCH_ID})
    else
        h_warn "PATCH_ID is empty: Control Center installs at the base ${VERSION} release."
    fi
}

# Log the local oc in to the Control Center cluster, unless it already is.
swhcc_oc_login() {
    local url="${CONTROL_OCP_URL%/}"
    if [[ "$(oc whoami --show-server 2>/dev/null)" == "${url}" ]] && oc whoami >/dev/null 2>&1; then
        h_info "oc already logged in to ${url} - skipping oc login"
    else
        eval "${CONTROL_OC_LOGIN}"
    fi
}

# Log the local oc and the side container in to the Control Center cluster, skipping
# whichever already has a valid session there.
swhcc_login() {
    local url="${CONTROL_OCP_URL%/}"
    swhcc_oc_login
    if [[ "$(podman inspect -f '{{.ImageName}}' "${OLM_UTILS_CONTAINER}" 2>/dev/null)" == "${OLM_UTILS_IMAGE}" ]] \
        && [[ "$(podman exec "${OLM_UTILS_CONTAINER}" oc whoami --show-server 2>/dev/null)" == "${url}" ]] \
        && podman exec "${OLM_UTILS_CONTAINER}" oc whoami >/dev/null 2>&1; then
        h_info "cpd-cli (${OLM_UTILS_CONTAINER}) already logged in to ${url} - skipping login-to-ocp"
    else
        eval "${CONTROL_CPDM_OC_LOGIN}"
    fi
}

# Pull the premium image if it is not local yet (it needs a cp.icr.io login).
swhcc_ensure_image() {
    podman image exists "${OLM_UTILS_IMAGE}" && return 0
    if [[ "${OLM_UTILS_IMAGE}" == cp.icr.io/* ]]; then
        [[ -n "${IBM_ENTITLEMENT_KEY:-}" ]] || h_die "IBM_ENTITLEMENT_KEY is needed to pull ${OLM_UTILS_IMAGE}."
        print -r -- "${IBM_ENTITLEMENT_KEY}" | podman login cp.icr.io --username cp --password-stdin
    fi
    h_info "Pulling ${OLM_UTILS_IMAGE}"
    podman pull --arch="${CONTROL_IMAGE_ARCH:-amd64}" "${OLM_UTILS_IMAGE}" \
        || h_die "Could not pull ${OLM_UTILS_IMAGE}. It needs an IBM Software Hub Premium entitlement and an existing tag."
}

# True when Control Center is already installed in its operands project.
swhcc_installed() {
    [[ -n "$(oc get ibmswhccs.swh.ibm.com -n "${CONTROL_PROJECT_OPERANDS}" -o name 2>/dev/null)" ]]
}
