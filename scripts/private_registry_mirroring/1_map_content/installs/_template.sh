#!/bin/zsh
# =============================================================================
# Segment 1 hook (mapping) - TEMPLATE (copy to <id>.sh for a new install)
# -----------------------------------------------------------------------------
#   <id>.sh map     required - print what to mirror (below)
#   <id>.sh check   optional - 1.1_check_sources.sh calls it when the install
#                   emitted native entries: check them with the install's own
#                   tool, exit non-zero on problems (no-op: exit 0)
#
# Called by 1_map_content/1.0_build_inventory.sh with ENV_TARGET=<the install's
# target> (its config loaded, registry_overrides.sh NOT applied, so image names
# are the original sources) and PREG_SKIP_REGISTRY_OVERRIDES=1.
#
# Print one JSON line per item on file descriptor 3 with the preg_emit_*
# helpers; stdout/stderr are free for messages:
#
#   preg_emit_image    <source ref> <component> [install|shared]
#   preg_emit_operator <catalog> <package> <channel|""> <component>   (always shared)
#   preg_emit_chart    <oci://… | https repo URL> <chart> <version> <component> [install|shared]
#   preg_emit_file     <url> <dest under <path>/files/> <component>
#   preg_emit_native   <handler> <summary> [extra JSON members]  (a download hook
#                      in segment 2 does the work, e.g. cpd-cli)
#
# Emit ONLY what MIRROR_<ID>_COMPONENTS and MIRROR_<ID>_CONTENT select: empty
# selections mean nothing (preg_has_component / preg_has_content).
# Use scope "shared" for generic items any install could reuse (base images,
# Red Hat operators); everything else stays under the install's own path.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"

ID="${MIRROR_INSTALL_ID:?run through 1.0_build_inventory.sh}"
case "${1:-}" in map) ;; check) exit 0 ;; *) preg_die "usage: $0 map|check" ;; esac
[[ -n "$(preg_install_selection "${ID}" COMPONENTS)" && -n "$(preg_install_selection "${ID}" CONTENT)" ]] || exit 0

if preg_has_content "${ID}" images && preg_has_component "${ID}" example; then
    preg_emit_image "docker.io/library/example:1.0" example
fi

exit 0
