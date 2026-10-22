#!/bin/zsh
# Segment 2 hook: concert (contract: _template.sh)
#
# Runs Concert's own scripts/install_ibm_concert/1_registry_access_and_mirroring/
# 1.1_mirror_concert_images.sh (oc image mirror from the installer's images.lst,
# IBM's cp/<suffix> layout, its own save/load) against the push side of
# <root>/concert, through a one-off PREG_RUN_OVERRIDES_FILE - concert_vars.sh is
# not touched:
#   mirror  CONCERT_IMAGE_SOURCE=mirrored, PRIVATE_REGISTRY_LOCATION=<push root>/concert
#   save    CONCERT_IMAGE_SOURCE=airgap --phase=save, CONCERT_AIRGAP_DIR=<bundle>/concert/airgap
#   load    CONCERT_IMAGE_SOURCE=airgap --phase=load (same dir)
# Needs Concert's installer archive (0_initial_setup/0.1_fetch_concert_installer.sh).
# Concert 1.2/1.3 are not run: their operators and data-store images are part of
# the shared track (2.1 / 2.2).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"

VERB="${1:-}"; shift || true
NATIVE="${MIRROR_INSTALL_WORKDIR:?run through 2.0}/native.jsonl"
[[ -s "${NATIVE}" ]] || exit 0
STEP="${_CP4D_REPO_ROOT}/scripts/install_ibm_concert/1_registry_access_and_mirroring/1.1_mirror_concert_images.sh"

case "${VERB}" in
download)
    preg_parse_phase_args "$@"
    PHASE="${PREG_PHASE_ARG:-${MIRROR_PHASE:-mirror}}"
    TARGET="${MIRROR_INSTALL_PUSH_PREFIX:?no registry configured}"
    run_dir="$(preg_private_tmpdir)"
    ovr="${run_dir}/concert-push-overrides.sh"
    q() { print -r -- "${(qq)1}"; }
    {
        print -r -- "# one-off overrides for ${STEP:t} (written by the mirroring track)"
        if [[ "${PHASE}" == mirror ]]; then
            print -r -- "export CONCERT_IMAGE_SOURCE=mirrored"
        else
            print -r -- "export CONCERT_IMAGE_SOURCE=airgap"
            print -r -- "export CONCERT_AIRGAP_DIR=$(q "$(preg_bundle_dir)/concert/airgap")"
        fi
        print -r -- "export PRIVATE_REGISTRY_LOCATION=$(q "${TARGET}")"
        print -r -- "export PRIVATE_REGISTRY_PUSH_USER=$(q "${MIRROR_REGISTRY_PUSH_USER:-}")"
        print -r -- "export PRIVATE_REGISTRY_PUSH_PASSWORD=$(q "${MIRROR_REGISTRY_PUSH_PASSWORD:-}")"
        [[ -n "${MIRROR_IBM_ENTITLEMENT_KEY:-}" ]] && print -r -- "export IBM_ENTITLEMENT_KEY=$(q "${MIRROR_IBM_ENTITLEMENT_KEY}")"
        print -r -- "export CONCERT_MIRROR_SELECTED_ONLY=true"
        [[ -n "$(preg_oc_insecure)" ]] && print -r -- "export CONCERT_MIRROR_INSECURE=true"
        :
    } > "${ovr}"
    chmod 600 "${ovr}"
    args=()
    [[ "${PHASE}" != mirror ]] && args=(--phase="${PHASE}")
    preg_info "concert: ${STEP:t} ${args[*]} -> ${TARGET}/cp/..."
    rc=0
    PREG_RUN_OVERRIDES_FILE="${ovr}" ENV_TARGET=concert zsh "${STEP}" "${args[@]}" || rc=$?
    rm -rf "${run_dir}"
    (( rc == 0 )) || preg_die "concert: ${STEP:t} failed (rc ${rc})"
    ;;
verify-registry)
    preg_info "concert: 1.1 verifies a probe image itself after mirroring/loading."
    ;;
*) preg_die "usage: $0 download --phase=... | verify-registry" ;;
esac

exit 0
