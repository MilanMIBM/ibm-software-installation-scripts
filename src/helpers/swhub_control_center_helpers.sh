#!/bin/zsh
# Shared by scripts/install_cloud_pak_for_data/optional_install_swhub_control_center/.
# Source after env_bootstrap.sh, then call swhcc_activate before any cpd-cli command.

source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"
source "${_CP4D_REPO_ROOT}/scripts/operator_install_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/swhub_control_center_image.sh"

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
    if [[ -n "${IR_IN_RUNNER:-}" ]]; then
        swhcc_activate_in_runner
        # A mirrored sidecar image may be pinned by digest (...-premium-v4@sha256:...).
        swhcc_image_is_premium "${OLM_UTILS_IMAGE}" \
            || h_die "The sidecar image ${OLM_UTILS_IMAGE} is not olm-utils-premium-v4: setup-control-center is a stub in the standard one."
    else
        export OLM_UTILS_IMAGE="${CONTROL_OLM_UTILS_IMAGE}"
        export OLM_UTILS_CONTAINER="${CONTROL_OLM_UTILS_CONTAINER}${MCM_CONTAINER_SUFFIX:-}"
        # Multi-cluster mode: inside the cluster's cpd-cli folder (plan 5.1).
        export CPD_CLI_MANAGE_WORKSPACE="${${MCM_CPD_CLI_WORKSPACE:+${MCM_CPD_CLI_WORKSPACE}/swhub-control-center}:-${CONTROL_CPD_CLI_WORKSPACE}}"
        export CPD_CLI_WORK_PATH="${CPD_CLI_MANAGE_WORKSPACE}/work"
        mkdir -p "${CPD_CLI_WORK_PATH}"
        cp4d_olm_utils_is_premium \
            || h_die "CONTROL_OLM_UTILS_IMAGE must be an olm-utils-premium-v4 image: setup-control-center is a stub in the standard one."
    fi

    # Without this flag it installs the base release and re-applies older shared
    # CRDs over a patched instance.
    SWHCC_PATCH_FLAG=()
    if [[ -n "${PATCH_ID:-}" ]]; then
        SWHCC_PATCH_FLAG=(--patch_id=${PATCH_ID})
    else
        h_warn "PATCH_ID is empty: Control Center installs at the base ${VERSION} release."
    fi
}

# In a runner pod (D4) the side container is the slot's premium sidecar, reached
# through the cpd-cli and podman shims (IR_EXEC_ROUTE). Everything is checked
# before the first cluster write, so a slot that can't do this stops at 1.0 with
# nothing changed. Called again in every step's process, so the main CP4D chain
# never routes.
swhcc_activate_in_runner() {
    local want
    [[ -n "${IR_SWHCC_IMAGE_SOURCE:-}" ]] \
        || h_die "This runner slot has no Control Center sidecar: launch the run again with Control Center on (INSTALL_SWHUB_CONTROL_CENTER=true, or its own chain)."
    want="$(swhcc_pod_image)"
    [[ "${IR_SWHCC_IMAGE_SOURCE}" == "${want}" ]] \
        || h_die "The slot's sidecar runs ${IR_SWHCC_IMAGE_SOURCE}, but this config asks for ${want}. Launch the run again so the slot picks it up."
    [[ "${IR_SWHCC_MODE:-${CONTROL_CLUSTER_MODE}}" == "${CONTROL_CLUSTER_MODE}" ]] \
        || h_die "The slot was set up for CONTROL_CLUSTER_MODE=${IR_SWHCC_MODE}, but this config says ${CONTROL_CLUSTER_MODE}. Launch the run again."
    export OLM_UTILS_IMAGE="${IR_SWHCC_IMAGE_SOURCE}"
    export OLM_UTILS_CONTAINER="${CONTROL_OLM_UTILS_CONTAINER}"
    # The sidecar's /tmp/work is this folder, so 1.0's oc apply of
    # cluster_scoped_resources.yaml and its offline copy see the files case-download wrote.
    export CPD_CLI_MANAGE_WORKSPACE="${IR_SWHCC_ROOT:-/work/swhcc}"
    export CPD_CLI_WORK_PATH="${CPD_CLI_MANAGE_WORKSPACE}/work"
    export IR_EXEC_ROUTE=swhcc IR_EXEC_CONTAINER_NAME="${OLM_UTILS_CONTAINER}"
    export IR_SWHCC_KUBECONFIG="${IR_SWHCC_KUBE_DIR:-/var/run/install-runner/swhcc-kube}/control.kubeconfig"
    mkdir -p "${CPD_CLI_WORK_PATH}"
    swhcc_probe_premium
}

# The image name only says premium; this reads the command itself, once per run.
# The standard image's setup-control-center is a stub that would only fail at 1.1,
# after prep has changed the cluster.
swhcc_probe_premium() {
    local marker="${IR_RUN_DIR:-${CPD_CLI_MANAGE_WORKSPACE}}/swhcc-probe.ok"
    [[ -e "${marker}" ]] && return 0
    podman exec "${OLM_UTILS_CONTAINER}" bash -c \
        'f="$(command -v setup-control-center)" && [ -n "${f}" ] && ! grep -q "part of IBM Software Hub Premium" "${f}"' \
        || h_die "The sidecar's setup-control-center is missing or the standard image's stub: ${IR_SWHCC_IMAGE_SOURCE} is not a working premium image."
    # Which build the moving tag gave (no file in the image names its BUILD_ID yet).
    h_info "Control Center sidecar: ${IR_SWHCC_IMAGE_SOURCE}, pinned at ${IR_SWHCC_IMAGE##*@}."
    touch "${marker}"
}

# Log the local oc in to the Control Center cluster, unless it already is.
swhcc_oc_login() {
    [[ -n "${IR_IN_RUNNER:-}" ]] && { swhcc_oc_login_in_runner; return; }
    local url="${CONTROL_OCP_URL%/}"
    if [[ "$(oc whoami --show-server 2>/dev/null)" == "${url}" ]] && oc whoami >/dev/null 2>&1; then
        h_info "oc already logged in to ${url} - skipping oc login"
    else
        eval "${CONTROL_OC_LOGIN}"
    fi
}

# In a pod, both oc and the sidecar use IR_SWHCC_KUBECONFIG, never the supervisor's
# or the chain's file: a login here can't move the status record (X17), and
# `eval "${OC_LOGIN}"` switches back to the chain's file. Same mode copies the
# chain's file (its tokenFile, no secret) and never logs in, so the supervisor's
# fallback to kubernetes.default.svc can't force a login to the public URL.
# Different mode logs in once into that file; there is no TTY to answer oc's
# certificate question, so a TLS flag is always given.
# Some steps (cluster-admins, the indicator's zen-core-api lookup) log in without
# swhcc_activate, so the file's path comes from the slot's env when nothing set it.
swhcc_oc_login_in_runner() {
    local kc="${IR_SWHCC_KUBECONFIG:-}" url="${CONTROL_OCP_URL%/}" tls=""
    if [[ -z "${kc}" ]]; then
        [[ -n "${IR_SWHCC_KUBE_DIR:-}" ]] \
            || h_die "This runner slot has no Control Center sidecar: launch the run again with Control Center on (INSTALL_SWHUB_CONTROL_CENTER=true, or its own chain)."
        kc="${IR_SWHCC_KUBE_DIR}/control.kubeconfig"
    fi
    export IR_SWHCC_KUBECONFIG="${kc}"
    if [[ "${CONTROL_CLUSTER_MODE}" == same ]]; then
        if [[ ! -s "${kc}" ]]; then
            [[ -r "${IR_CHAIN_KUBECONFIG:-}" ]] || h_die "No chain kubeconfig in this pod (IR_CHAIN_KUBECONFIG)."
            ( umask 077; cp -f "${IR_CHAIN_KUBECONFIG}" "${kc}" )
        fi
        export KUBECONFIG="${kc}" K8S_AUTH_KUBECONFIG="${kc}"
        oc whoami >/dev/null || h_die "The pod's session does not work for Control Center (${kc})."
        return 0
    fi
    export KUBECONFIG="${kc}" K8S_AUTH_KUBECONFIG="${kc}"
    if [[ -s "${kc}" && "$(oc whoami --show-server 2>/dev/null)" == "${url}" ]] && oc whoami >/dev/null 2>&1; then
        h_info "oc already logged in to ${url} - skipping oc login"
        return 0
    fi
    if [[ "${CONTROL_SERVER_ARGUMENTS:-}" != *(--certificate-authority|--insecure-skip-tls-verify)* ]]; then
        if [[ -n "${CONTROL_OCP_CA_FILE:-}" && -r "${CONTROL_OCP_CA_FILE}" ]]; then
            tls="--certificate-authority=${CONTROL_OCP_CA_FILE}"
        else
            h_warn "No readable CONTROL_OCP_CA_FILE: logging in to ${url} without checking its certificate."
            tls="--insecure-skip-tls-verify=true"
        fi
    fi
    ( umask 077; eval "${CONTROL_OC_LOGIN} ${tls}" ) || h_die "Could not log in to the Control Center cluster ${url}."
    chmod 600 "${kc}" 2>/dev/null || true
}

# Log the local oc and the side container in to the Control Center cluster, skipping
# whichever already has a valid session there.
swhcc_login() {
    [[ -n "${IR_IN_RUNNER:-}" ]] && { swhcc_login_in_runner; return; }
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

# The sidecar has no login of its own: it reads the same kubeconfig file through
# the request env. This proves it sees the same session as the oc here.
swhcc_login_in_runner() {
    local here there
    swhcc_oc_login
    here="$(oc whoami --show-server 2>/dev/null)"
    there="$(podman exec "${OLM_UTILS_CONTAINER}" oc whoami --show-server 2>/dev/null)" || there=""
    [[ -n "${here}" && "${there%/}" == "${here%/}" ]] \
        || h_die "The Control Center sidecar sees ${there:-no session}, not ${here:-this pod's session}."
    h_info "cpd-cli (Control Center sidecar) uses the session for ${here}."
}

# The Control Center cluster, then back to the Software Hub cluster. One cluster in
# same mode, so nothing to switch there. Around calls that reach Control Center's
# own pods (zen-core-api) from a script otherwise on the Software Hub cluster.
swhcc_use_control() {
    [[ "${CONTROL_CLUSTER_MODE:-same}" == different ]] || return 0
    swhcc_oc_login
}
swhcc_use_swh() {
    [[ "${CONTROL_CLUSTER_MODE:-same}" == different ]] || return 0
    [[ -n "${OC_LOGIN:-}" ]] && eval "${OC_LOGIN}"
    return 0
}

# Pull the premium image if it is not local yet (it needs a cp.icr.io login).
# In a pod the slot pulled it already (the sidecar runs it).
swhcc_ensure_image() {
    [[ -n "${IR_IN_RUNNER:-}" ]] && return 0
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
