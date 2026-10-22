#!/bin/zsh
# =============================================================================
# Segment 3 hook (tapping into the registry) - TEMPLATE (copy to <id>.sh)
# -----------------------------------------------------------------------------
# All verbs optional; unknown verbs must exit 0.
#
#   <id>.sh cluster         install-specific cluster objects, run by 3.3 before
#                           the generic mirror sets (cpd: IBM's apply-icsp).
#                           MIRROR_CLUSTER_DRY_RUN=true: change nothing, show it.
#   <id>.sh tap             point the install at the registry (3.5): build the
#                           overrides body and call
#                               preg_write_overrides <id> <body file>
#                           (it adds the header and the ENV_TARGET guard, honours
#                           MIRROR_TAP_DRY_RUN). Look up where an ORIGINAL image
#                           landed with preg_lookup_pull <source> (pull side).
#                           Cluster-facing references use the PULL root
#                           (${MIRROR_INSTALL_PULL_PREFIX}); things this
#                           workstation pulls itself (Helm charts, olm-utils) the
#                           PUSH root (${MIRROR_INSTALL_PUSH_PREFIX}).
#                           Honour MIRROR_CLUSTER_REDIRECT: explicit image
#                           settings only when preg_redirect_explicit.
#   <id>.sh verify-cluster  3.6: check the running install (e.g. every pod image
#                           under <pull root>/<path>/ or <pull root>/shared/).
#
# Runs with the install's config loaded (registry_overrides.sh skipped during
# tap, so the original image names are visible).
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"

case "${1:-}" in
    tap)
        body="$(preg_private_tmpdir)/body"
        {
            print -r -- "export EXAMPLE_IMAGE=$(preg_q "$(preg_lookup_pull docker.io/library/example:1.0 || true)")"
        } > "${body}"
        preg_write_overrides "${MIRROR_INSTALL_ID}" "${body}"
        ;;
    *) exit 0 ;;
esac

exit 0
