#!/bin/zsh
# =============================================================================
# Segment 2 hook (downloading / mirroring) - TEMPLATE (copy to <id>.sh)
# -----------------------------------------------------------------------------
# Optional: only installs whose map hook printed "native" entries need one.
#
#   <id>.sh download --phase=mirror|save|load
#       Move the install's native content with its own tooling:
#         mirror  internet + registry on this machine: straight to
#                 ${MIRROR_INSTALL_PUSH_PREFIX}
#         save    internet side of a stop-over: into $(preg_bundle_dir)/<path>/
#         load    inside: from the bundle into ${MIRROR_INSTALL_PUSH_PREFIX}
#       The native entries are in ${MIRROR_INSTALL_WORKDIR}/native.jsonl.
#   <id>.sh verify-registry
#       Check the native content in the registry (2.4). Exit non-zero on problems.
#
# Runs with the install's config loaded. Exported by the core:
#   MIRROR_INSTALL_ID / _PATH / _WORKDIR / _PULL_PREFIX / _PUSH_PREFIX,
#   MIRROR_RESOLVED_IMAGE_SOURCE, MIRROR_RESOLVED_PUSH_ROOT, MIRROR_PHASE,
#   and every MIRROR_* setting of the mirror config.
# To run one of the install's OWN scripts against the push side, write its
# settings to a 0600 file and run it with PREG_RUN_OVERRIDES_FILE=<file>
# (sourced after its config by scripts/source_env_setup.sh).
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"

case "${1:-}" in
    download)        preg_parse_phase_args "${@:2}"; preg_info "nothing native for ${MIRROR_INSTALL_ID} (${PREG_PHASE_ARG})" ;;
    verify-registry) exit 0 ;;
    *) preg_die "usage: $0 download --phase=... | verify-registry" ;;
esac

exit 0
