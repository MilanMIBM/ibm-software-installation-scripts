#!/bin/zsh
# Segment 3 hook: concert (contract: _template.sh)
#   tap  configs/concert_config/registry_overrides.sh (guarded like concert_vars.sh):
#        CONCERT_IMAGE_SOURCE (mirrored | airgap), PRIVATE_REGISTRY_LOCATION=<pull
#        root>/concert, pull + push credentials, the derived CONCERT_REG_USER /
#        CONCERT_IMAGE_REGISTRY_PREFIX / CONCERT_REGISTRY_PASSWORD (concert_vars.sh
#        computes them before this file is sourced), CONCERT_MIRROR_VIA_SHARED=true
#        (Concert 1.2/1.3 step aside: operators + data-store images come from the
#        shared track), and - explicit redirect - the data-store and runner images
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"

PULL_PREFIX="${MIRROR_INSTALL_PULL_PREFIX:?no registry configured}"

case "${1:-}" in
tap)
    src="$(preg_install_conf concert INSTALL_IMAGE_SOURCE_PRIVATE)"
    [[ "${MIRROR_RESOLVED_IMAGE_SOURCE:-private}" == local ]] && src="$(preg_install_conf concert INSTALL_IMAGE_SOURCE_LOCAL)"
    body="$(preg_private_tmpdir)/body"
    : > "${body}"
    emit() { print -r -- "$1" >> "${body}"; }
    emit "export CONCERT_IMAGE_SOURCE=$(preg_q "${src}")"
    emit "export PRIVATE_REGISTRY_LOCATION=$(preg_q "${PULL_PREFIX}")"
    emit "export PRIVATE_REGISTRY_PULL_USER=$(preg_q "${MIRROR_REGISTRY_PULL_USER:-}")"
    emit "export PRIVATE_REGISTRY_PULL_PASSWORD=$(preg_q "${MIRROR_REGISTRY_PULL_PASSWORD:-}")"
    emit "export PRIVATE_REGISTRY_PUSH_USER=$(preg_q "${MIRROR_REGISTRY_PUSH_USER:-}")"
    emit "export PRIVATE_REGISTRY_PUSH_PASSWORD=$(preg_q "${MIRROR_REGISTRY_PUSH_PASSWORD:-}")"
    emit '# derived values concert_vars.sh computed before this file was sourced'
    emit 'export CONCERT_REG_USER="${PRIVATE_REGISTRY_PULL_USER}"'
    emit 'export CONCERT_IMAGE_REGISTRY_PREFIX="${PRIVATE_REGISTRY_LOCATION}/cp"'
    emit 'export CONCERT_REGISTRY_PASSWORD="${PRIVATE_REGISTRY_PULL_PASSWORD}"'
    emit "export CONCERT_MIRROR_VIA_SHARED=true"
    [[ -n "${MIRROR_REGISTRY_CA_FILE:-}" ]] && emit "export PRIVATE_REGISTRY_CA_FILE=$(preg_q "${MIRROR_REGISTRY_CA_FILE}")"
    if preg_redirect_explicit; then
        for v in CONCERT_DS_PG_IMAGE CONCERT_DS_MYSQL_IMAGE CONCERT_DS_REDIS_IMAGE CONCERT_DS_NEO4J_IMAGE CONCERT_RUNNER_BASE_IMAGE; do
            [[ -n "${(P)v:-}" ]] || continue
            if ref="$(preg_lookup_pull "${(P)v}")"; then emit "export ${v}=$(preg_q "${ref}")"; fi
        done
    fi
    preg_write_overrides concert "${body}"
    ;;
*) exit 0 ;;
esac

exit 0
