#!/bin/zsh
# =============================================================================
# In-cluster install runner: CP4D hooks (contract in _template.sh)
# =============================================================================
set -euo pipefail
source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"

FULL_CHAIN="scripts/install_cloud_pak_for_data/0_x_full_quick_install_script/full_swhub_x_cpd_installprocess.sh"
SWHCC_CHAIN="scripts/install_cloud_pak_for_data/optional_install_swhub_control_center/full_installprocess-swhub_control_center.sh"
SWHCC_GENERATOR="scripts/install_cloud_pak_for_data/optional_install_swhub_control_center/0_swhub_control_center_generate_config.sh"

# True when this launch runs the Control Center sub-install, so the slot needs its
# premium sidecar. The full chain's own test (full_swhub_x_cpd_installprocess.sh),
# with the same defaults. No chain (x_install_runner.sh preflight) is the full chain.
wants_swhcc() {   # <chain>
    case "$1" in
        "${SWHCC_CHAIN}")      return 0 ;;
        "${FULL_CHAIN}"|"")    [[ "${DO_SWHUB_CONTROL_CENTER:-${INSTALL_SWHUB_CONTROL_CENTER:-false}}" == true ]] \
                                   && full_chain_runs_swhcc ;;
        *)                     return 1 ;;
    esac
}

# The standalone Control Center chain. It loads its own vars file, which may have no
# cpd_vars.sh behind it (written with --empty, for a Control Center cluster of its
# own): no CP4D storage classes, options file or olm-utils image. Its launch needs
# none of them; the CP4D chains still need all three.
is_swhcc_chain() { [[ "${1:-}" == "${SWHCC_CHAIN}" ]]; }

# False when the full chain's arguments (IR_HOOK_ARGS, one per line) leave the
# swhub-control-center step out: --skip it, or --only / --<step> without it. It is
# the last step, so --from never does. Arguments that do not parse keep it (the
# chain stops on them in the pod anyway).
full_chain_runs_swhcc() {
    [[ -n "${IR_HOOK_ARGS:-}" ]] || return 0
    local -a args=("${(@f)IR_HOOK_ARGS}")
    local verdict
    verdict="$(
        h_steps_parse --strict "${args[@]}" >/dev/null 2>&1
        local -a only=("${H_STEPS_ONLY[@]}" "${H_STEPS_PICK[@]}")
        if (( ${H_STEPS_SKIP[(Ie)swhub-control-center]} )); then print out
        elif (( ${#only} )) && (( ! ${only[(Ie)swhub-control-center]} )); then print out
        fi
    )" || true
    [[ "${verdict}" != out ]]
}

# The sidecar's image, from the vars file's values (SWHCC_RV).
swhcc_image_from_values() {
    CONTROL_OLM_UTILS_IMAGE="${SWHCC_RV[CONTROL_OLM_UTILS_IMAGE]:-}" CONTROL_IMAGE_ARCH="${SWHCC_RV[CONTROL_IMAGE_ARCH]:-}" \
        IMAGE_ARCH="${SWHCC_RV[IMAGE_ARCH]:-}" swhcc_pod_image
}

# Control Center in the pod (D4). Reads the vars file in a child shell, so this
# check sees what the pod will load. Errors stop the launch; warnings say what will
# need a person or may go wrong.
swhcc_preflight() {
    local vars image mode login rc=0 have_login=false
    source "${_CP4D_REPO_ROOT}/src/helpers/swhub_control_center_image.sh"
    source "${_CP4D_REPO_ROOT}/scripts/operator_install_helpers.sh"
    vars="$(swhcc_runner_vars_file)"
    if ! swhcc_runner_values "${vars}"; then
        h_error "This launch runs Control Center, but ${vars#${_CP4D_REPO_ROOT}/} is missing; the pod's sidecar is built from it. Write it first: ${SWHCC_GENERATOR} --from-cpd"
        return 1
    fi
    image="$(swhcc_image_from_values)"
    mode="${SWHCC_RV[CONTROL_CLUSTER_MODE]:-same}"
    login="${SWHCC_RV[CONTROL_OC_LOGIN]:-}"

    if [[ "${image}" == cp.icr.io/* && -z "${SWHCC_RV[IBM_ENTITLEMENT_KEY]:-}" ]]; then
        h_error "IBM_ENTITLEMENT_KEY is empty: the cluster can't pull the Control Center image ${image}."
        rc=1
    fi
    if [[ -z "${SWHCC_RV[PATCH_ID]:-}" ]]; then
        h_error "PATCH_ID is empty: Control Center would install at the base release. Set it to the instances' patch."
        rc=1
    fi
    if ! swhcc_image_is_premium "${image}"; then
        h_error "The Control Center image ${image:-(none)} is not olm-utils-premium-v4: setup-control-center is a stub in the standard image."
        rc=1
    fi
    if [[ "${mode}" == different ]]; then
        [[ "${login}" == *--token=[^[:space:]]* ]] && have_login=true
        [[ "${login}" == *--username=[^[:space:]]* && "${login}" == *--password=[^[:space:]]* ]] && have_login=true
        if [[ "${have_login}" != true ]]; then
            h_error "CONTROL_OC_LOGIN has no token or username and password: the pod can't log in to ${SWHCC_RV[CONTROL_OCP_URL]:-the Control Center cluster}."
            rc=1
        fi
        if [[ -z "${SWHCC_RV[CONTROL_OCP_CA_FILE]:-}" && "${SWHCC_RV[CONTROL_SERVER_ARGUMENTS]:-}" != *(--certificate-authority|--insecure-skip-tls-verify)* ]]; then
            h_warn "No CONTROL_OCP_CA_FILE: the pod logs in to the Control Center cluster with --insecure-skip-tls-verify."
        fi
    fi

    if h_is_true "${SWHCC_RV[AUTODETECT_IN_CLUSTER_SOFTWAREHUB_INSTANCES]:-true}"; then
        if [[ ( -z "${SWHCC_RV[OCP_USERNAME]:-}" || -z "${SWHCC_RV[OCP_PASSWORD]:-}" ) \
              && ( -z "${SWHCC_RV[CONTROL_OCP_USERNAME]:-}" || -z "${SWHCC_RV[CONTROL_OCP_PASSWORD]:-}" ) ]]; then
            h_warn "Token-only login: verifying the cluster in Control Center needs a browser. Watch x_install_runner.sh status for the page to open."
        fi
        if h_is_true "${SWHCC_RV[CONTROL_OTHER_WORKLOADS_INDICATOR]:-true}" && [[ -z "${SWHCC_RV[CONTROL_ROUTE_PUBLIC_IP]:-}" ]]; then
            h_warn "If routes resolve to a private address inside the cluster, the pod skips registering the other workloads indicator (it can't look up the public IP). Set CONTROL_ROUTE_PUBLIC_IP, or register it locally after collect."
        fi
    fi
    if h_is_true "${SWHCC_RV[CONTROL_AUTODETECT_ROTATE_API_KEYS]:-false}"; then
        h_warn "CONTROL_AUTODETECT_ROTATE_API_KEYS=true revokes instance API keys again each time autodetect re-runs (a resume does that)."
    fi
    if [[ -z "${INSTALL_RUNNER_SWHCC_IMAGE:-}" ]]; then
        h_warn "The premium tag ${image##*:} moves with IBM's patches. The launch pins the build it points to now, by digest."
    fi
    if [[ -z "${OCP_URL:-}" ]]; then
        h_warn "OCP_URL is empty: the pod will use https://kubernetes.default.svc, which Control Center may not reach."
    fi
    return "${rc}"
}

case "${1:-}" in
    preflight)
        rc=0
        # The registry slot and its locks don't exist yet: a private registry would
        # need 3.x run from the pod with a config it doesn't have.
        if [[ "${CPD_IMAGE_SOURCE:-entitled}" != entitled ]]; then
            h_error "CPD_IMAGE_SOURCE=${CPD_IMAGE_SOURCE}: the in-cluster runner supports entitled only for now."
            rc=1
        fi
        chain="${IR_HOOK_CHAIN:-${2:-}}"
        for sc in "${STG_CLASS_BLOCK:-}" "${STG_CLASS_FILE:-}"; do
            if [[ -z "${sc}" ]]; then
                # The Control Center chain only checks the ones its vars file has.
                is_swhcc_chain "${chain}" && continue
                h_error "STG_CLASS_BLOCK and STG_CLASS_FILE must be set."; rc=1; continue
            fi
            oc get storageclass "${sc}" >/dev/null 2>&1 \
                || { h_error "Storage class ${sc} does not exist on this cluster."; rc=1; }
        done
        # 4.1 reads the options file through the config copy in the work dir, so it
        # must be in the folder staged as configs/cp4d_config (the cluster's own under a
        # pin). IR_STAGED_CONFIG_DIR is that folder; without it, the loaded one. The
        # Control Center chain runs no 4.1.
        staged="${IR_STAGED_CONFIG_DIR:-${CONFIG_DIR:-}}"
        if ! is_swhcc_chain "${chain}" && [[ -n "${INSTALL_OPTIONS_FILE:-}" && ! -f "${staged}/${INSTALL_OPTIONS_FILE}" ]]; then
            h_error "INSTALL_OPTIONS_FILE=${INSTALL_OPTIONS_FILE} is not in ${staged}, the folder the runner stages."
            rc=1
        fi
        if wants_swhcc "${IR_HOOK_CHAIN:-${2:-}}"; then
            swhcc_preflight || rc=1
        fi
        exit "${rc}"
        ;;
    runner-inputs)
        # What the runner pod needs that the Control Center chain's vars file may not
        # have (written with --empty): the standard olm-utils image of its release as
        # the runner's base, and the cluster's default storage class for its volume.
        # Nothing for the CP4D chains: OLM_UTILS_IMAGE and STG_CLASS_BLOCK stay required.
        is_swhcc_chain "${IR_HOOK_CHAIN:-${2:-}}" || exit 0
        if [[ -z "${OLM_UTILS_IMAGE:-}" && -n "${VERSION:-}" ]]; then
            print -r -- "base_image=icr.io/cpopen/cpd/olm-utils-v4:${VERSION}${PATCH_ID:+.${PATCH_ID}}"
        fi
        [[ -n "${STG_CLASS_BLOCK:-}" ]] || print -r -- "storage_class=default"
        ;;
    sidecars)
        # "swhcc<TAB><premium image by tag><TAB><same|different>" when the launch runs
        # Control Center; nothing otherwise.
        wants_swhcc "${2:-${IR_HOOK_CHAIN:-}}" || exit 0
        source "${_CP4D_REPO_ROOT}/src/helpers/swhub_control_center_image.sh"
        if swhcc_runner_values "$(swhcc_runner_vars_file)"; then
            print -r -- "swhcc"$'\t'"$(swhcc_image_from_values)"$'\t'"${SWHCC_RV[CONTROL_CLUSTER_MODE]:-same}"
        else
            print -r -- "swhcc"$'\t'$'\t'"same"
        fi
        ;;
    post-collect)
        # 4.2 made the cpd-cli profile in the pod. This rebuilds it here from the
        # collected details; it uses OC_LOGIN only, never `cpd-cli manage`.
        repair="${_CP4D_REPO_ROOT}/scripts/install_cloud_pak_for_data/4.5_service_instance_setups/x_repair_cpd_cli_profile.sh"
        if command -v cpd-cli >/dev/null 2>&1; then
            "${repair}" || h_warn "Could not rebuild the local cpd-cli profile. Run ${repair:t} when CPD_APIKEY is set."
        else
            h_warn "cpd-cli is not on PATH here: skipping the local profile."
        fi
        ;;
esac
