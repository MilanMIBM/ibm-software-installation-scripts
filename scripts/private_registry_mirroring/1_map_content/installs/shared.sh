#!/bin/zsh
# Segment 1 hook: shared (contract: _template.sh)
#   MIRROR_SHARED_OPERATORS  package[:channel][@catalog], space-separated
#   MIRROR_SHARED_IMAGES     full image references, space-separated
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"

case "${1:-}" in map) ;; check) exit 0 ;; *) preg_die "usage: $0 map|check" ;; esac

for spec in ${=MIRROR_SHARED_OPERATORS:-}; do
    catalog="redhat-operators"
    [[ "${spec}" == *@* ]] && { catalog="${spec#*@}"; spec="${spec%%@*}"; }
    pkg="${spec%%:*}" channel=""
    [[ "${spec}" == *:* ]] && channel="${spec#*:}"
    preg_emit_operator "${catalog}" "${pkg}" "${channel}" "MIRROR_SHARED_OPERATORS"
done
for img in ${=MIRROR_SHARED_IMAGES:-}; do
    preg_emit_image "${img}" "MIRROR_SHARED_IMAGES" shared
done

exit 0
