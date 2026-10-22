#!/bin/zsh
# Segment 3 hook: cpd (contract: _template.sh)
#   cluster         cpd-cli manage apply-icsp --registry=<pull root>/cpd (IBM's
#                   cloud-pak-for-data-mirror IDMS + ITMS); --preview=true on dry runs
#   tap             configs/cp4d_config/registry_overrides.sh; podman login to the
#                   push host and cpd-cli manage restart-container (OLM_UTILS_IMAGE)
#   verify-cluster  nothing extra (3.6 probes cp.icr.io names through IBM's IDMS)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"

NATIVE="${MIRROR_INSTALL_WORKDIR:-}/native.jsonl"
has_ibm() { [[ -s "${NATIVE}" ]] && grep -q 'ibm-images' "${NATIVE}"; }
PULL_PREFIX="${MIRROR_INSTALL_PULL_PREFIX:?no registry configured}"
PUSH_PREFIX="${MIRROR_INSTALL_PUSH_PREFIX:?no registry configured}"

case "${1:-}" in
cluster)
    has_ibm || { preg_info "cpd: no IBM images mirrored - apply-icsp skipped"; exit 0; }
    command -v cpd-cli >/dev/null 2>&1 || preg_die "cpd-cli not on PATH"
    eval "${CPDM_OC_LOGIN:?CPDM_OC_LOGIN missing - generate configs/cp4d_config/cpd_vars.sh}" >/dev/null
    if preg_is_true "${MIRROR_CLUSTER_DRY_RUN:-false}"; then
        cpd-cli manage apply-icsp --registry="${PULL_PREFIX}" --preview=true >/dev/null
        preg_info "[dry-run] cpd-cli manage apply-icsp --registry=${PULL_PREFIX} would apply:"
        sed -n '/^kind:/,/^EOF/p' "${CPD_CLI_WORK_PATH:-${HOME}/cpd-cli/work}/preview.sh" 2>/dev/null | head -30 | sed 's/^/    /'
    else
        preg_info "cpd: cpd-cli manage apply-icsp --registry=${PULL_PREFIX}"
        cpd-cli manage apply-icsp --registry="${PULL_PREFIX}"
    fi
    ;;
tap)
    SRC="${MIRROR_RESOLVED_IMAGE_SOURCE:-private}"
    OLM_SFX="$(preg_olm_arch_suffix)"   # no arch unless one is specified
    OLM_REF="${PUSH_PREFIX}/cpopen/cpd/olm-utils-v4:\${VERSION}${OLM_SFX}"
    body="$(preg_private_tmpdir)/body"
    {
        print -r -- "export CPD_IMAGE_SOURCE=$(preg_q "${SRC}")"
        print -r -- "export PRIVATE_REGISTRY_LOCATION=$(preg_q "${PULL_PREFIX}")"
        print -r -- "export PRIVATE_REGISTRY_PULL_USER=$(preg_q "${MIRROR_REGISTRY_PULL_USER:-}")"
        print -r -- "export PRIVATE_REGISTRY_PULL_PASSWORD=$(preg_q "${MIRROR_REGISTRY_PULL_PASSWORD:-}")"
        print -r -- 'export IMAGE_PULL_PREFIX="${PRIVATE_REGISTRY_LOCATION}"'
        print -r -- 'export IMAGE_PULL_CREDENTIALS="$(printf %s "${PRIVATE_REGISTRY_PULL_USER}:${PRIVATE_REGISTRY_PULL_PASSWORD}" | base64 | tr -d "\n")"'
        print -r -- "# cpd-cli runs on this workstation: olm-utils comes from the PUSH side, with the CASE"
        print -r -- "# tag <release>[.<arch>] (the patch build's digest; there is no <release>.<patch> tag)."
        print -r -- "export OLM_UTILS_IMAGE=\"${OLM_REF}\""
        [[ "${SRC}" == local ]] && print -r -- "export CPD_CASE_SOURCE=offline"
        :
    } > "${body}"
    preg_write_overrides cpd "${body}"
    preg_is_true "${MIRROR_TAP_DRY_RUN:-false}" && exit 0

    # olm-utils from the registry: log podman in to the push host, recreate the
    # container - only when the image is really there (2.0 mirrored it).
    olm="${PUSH_PREFIX}/cpopen/cpd/olm-utils-v4:${VERSION:-}${OLM_SFX}"
    auth="$(preg_private_tmpdir)/auth.json"
    preg_write_authfile "${auth}" pull
    sed_host="$(preg_registry_host "${PUSH_PREFIX}")"
    if [[ -n "${VERSION:-}" ]] && skopeo inspect --raw --authfile "${auth}" ${(z)$(preg_skopeo_target_opts)} "docker://${olm}" >/dev/null 2>&1; then
        # podman login takes the same --cert-dir / --tls-verify options as skopeo
        print -r -- "${MIRROR_REGISTRY_PULL_PASSWORD}" | podman login -u "${MIRROR_REGISTRY_PULL_USER}" --password-stdin \
            ${(z)$(preg_skopeo_target_opts)} "${sed_host}" >/dev/null
        preg_info "cpd: podman logged in to ${sed_host}; recreating the olm-utils container from ${olm}"
        OLM_UTILS_IMAGE="${olm}" cpd-cli manage restart-container >/dev/null && preg_info "cpd: cpd-cli now runs olm-utils from the registry"
    else
        preg_warn "cpd: ${olm} not in the registry yet (mirror cpd_platform with 2.0) - cpd-cli keeps its current image for now."
    fi
    rm -f "${auth}"
    ;;
*) exit 0 ;;
esac

exit 0
