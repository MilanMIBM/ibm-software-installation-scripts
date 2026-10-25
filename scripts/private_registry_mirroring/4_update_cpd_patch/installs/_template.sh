#!/bin/zsh
# =============================================================================
# Segment 4 hook (product patch / version updates) - TEMPLATE (copy to <id>.sh)
# -----------------------------------------------------------------------------
# Optional: only cpd has one so far (cpd.sh). The 4.x scripts call it with a verb:
#
#   <id>.sh plan   --phase=mirror|save|load [--to N] [--from N] [--all] [--estimate]
#                  [--bundle DIR] [--quick]
#       Work out what moving the registry path to another version must copy,
#       without pushing; leave it for copy / record (a pending plan).
#   <id>.sh copy   --phase=...
#       Copy only that delta: to the registry, into a bundle (save), or from it (load).
#   <id>.sh record --phase=... [--full]
#       Verify, add version tags, record the new version (exit non-zero on problems).
#   <id>.sh list
#       Recorded / planned versions (read-only).
#
# Runs with the install's config loaded. Exported by the core:
#   MIRROR_INSTALL_ID / _PATH / _WORKDIR / _PULL_PREFIX / _PUSH_PREFIX,
#   MIRROR_RESOLVED_IMAGE_SOURCE, MIRROR_RESOLVED_PUSH_ROOT, MIRROR_PHASE,
#   and every MIRROR_* setting of the mirror config.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"

case "${1:-}" in
    plan|copy|record) preg_info "no version updates for ${MIRROR_INSTALL_ID}" ;;
    list) exit 0 ;;
    *) preg_die "usage: $0 plan|copy|record|list [--phase=...]" ;;
esac

exit 0
