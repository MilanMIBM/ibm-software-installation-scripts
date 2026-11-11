#!/bin/zsh
# =============================================================================
# swhub_control_center_image.sh - the premium image a runner pod's sidecar uses
# -----------------------------------------------------------------------------
# Sourced by swhub_control_center_helpers.sh (inside the pod) and by
# src/install_runner/installs/cpd.sh (on the workstation), so both sides name the
# same image. Design: .claude/plans/multi-cluster-management/in-cluster-install-addon/
# d4-control-center-in-pod-design.md, section 3.
# =============================================================================

# The premium olm-utils image for a Control Center sidecar. Locally the side
# container runs on CONTROL_IMAGE_ARCH, but in a pod it runs on the install
# cluster's nodes, so the tag's arch suffix becomes IMAGE_ARCH. In different mode
# the two can differ. INSTALL_RUNNER_SWHCC_IMAGE (a mirrored premium image) wins.
swhcc_pod_image() {
    if [[ -n "${INSTALL_RUNNER_SWHCC_IMAGE:-}" ]]; then
        print -r -- "${INSTALL_RUNNER_SWHCC_IMAGE}"
        return 0
    fi
    local image="${CONTROL_OLM_UTILS_IMAGE:-}" from="${CONTROL_IMAGE_ARCH:-}" to="${IMAGE_ARCH:-${CONTROL_IMAGE_ARCH:-}}"
    if [[ -n "${from}" && -n "${to}" && "${image}" == *".${from}" ]]; then
        image="${image%.${from}}.${to}"
    fi
    print -r -- "${image}"
}

# cp4d_olm_utils_is_premium for a sidecar image, which may also be pinned by
# digest (a mirrored INSTALL_RUNNER_SWHCC_IMAGE). The repository must still be
# named olm-utils-premium-v4; in the pod swhcc_probe_premium then reads the command.
swhcc_image_is_premium() {   # <image>
    [[ "$1" == */olm-utils-premium-v4[:@]* ]]
}

# The Control Center vars file a runner launch reads: the loaded one for the
# Control Center chain, else the one next to the staged CP4D config.
swhcc_runner_vars_file() {
    if [[ "${ENV_TARGET_FILE:-}" == */swhub_control_center_vars.sh ]]; then
        print -r -- "${ENV_TARGET_FILE}"
    else
        print -r -- "${IR_STAGED_CONFIG_DIR:-${CONFIG_DIR:-}}/swhub_control_center/swhub_control_center_vars.sh"
    fi
}

# Values a runner launch needs, read from the vars file in a child zsh (as
# 0_swhub_control_center_generate_config.sh reads cpd_vars.sh), so nothing it sets
# leaks into this shell. Fills the associative array SWHCC_RV. Secrets travel over
# the pipe only, never as arguments.
SWHCC_RUNNER_NAMES=(CONTROL_CLUSTER_MODE CONTROL_OLM_UTILS_IMAGE CONTROL_IMAGE_ARCH IMAGE_ARCH PATCH_ID
    IBM_ENTITLEMENT_KEY CPD_IMAGE_SOURCE CONTROL_OCP_URL CONTROL_OC_LOGIN CONTROL_SERVER_ARGUMENTS
    CONTROL_OCP_CA_FILE AUTODETECT_IN_CLUSTER_SOFTWAREHUB_INSTANCES OCP_USERNAME OCP_PASSWORD
    CONTROL_OCP_USERNAME CONTROL_OCP_PASSWORD CONTROL_AUTODETECT_ROTATE_API_KEYS
    CONTROL_OTHER_WORKLOADS_INDICATOR CONTROL_ROUTE_PUBLIC_IP OCP_URL)
swhcc_runner_values() {   # <vars file> -> SWHCC_RV
    typeset -gA SWHCC_RV=()
    local pair
    [[ -f "$1" ]] || return 1
    while IFS= read -r -d '' pair; do
        SWHCC_RV[${pair%%=*}]="${pair#*=}"
    done < <(zsh -c 'source "$1" >/dev/null 2>&1; shift; for n in "$@"; do print -rN -- "${n}=${(P)n:-}"; done' \
                 _ "$1" "${SWHCC_RUNNER_NAMES[@]}")
    return 0
}
