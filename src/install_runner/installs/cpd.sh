#!/bin/zsh
# =============================================================================
# In-cluster install runner: CP4D hooks (contract in _template.sh)
# =============================================================================
set -euo pipefail
source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"

case "${1:-}" in
    preflight)
        rc=0
        # The registry slot and its locks don't exist yet: a private registry would
        # need 3.x run from the pod with a config it doesn't have.
        if [[ "${CPD_IMAGE_SOURCE:-entitled}" != entitled ]]; then
            h_error "CPD_IMAGE_SOURCE=${CPD_IMAGE_SOURCE}: the in-cluster runner supports entitled only for now."
            rc=1
        fi
        for sc in "${STG_CLASS_BLOCK:-}" "${STG_CLASS_FILE:-}"; do
            [[ -n "${sc}" ]] || { h_error "STG_CLASS_BLOCK and STG_CLASS_FILE must be set."; rc=1; continue; }
            oc get storageclass "${sc}" >/dev/null 2>&1 \
                || { h_error "Storage class ${sc} does not exist on this cluster."; rc=1; }
        done
        # 4.1 reads the options file through the config copy in the work dir.
        if [[ -n "${INSTALL_OPTIONS_FILE:-}" && ! -f "${CONFIG_DIR}/${INSTALL_OPTIONS_FILE}" ]]; then
            h_error "INSTALL_OPTIONS_FILE=${INSTALL_OPTIONS_FILE} is not in ${CONFIG_DIR}."
            rc=1
        fi
        exit "${rc}"
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
