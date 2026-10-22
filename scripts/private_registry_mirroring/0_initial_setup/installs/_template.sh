#!/bin/zsh
# =============================================================================
# Segment 0 hook - TEMPLATE (copy to <id>.sh for a new install)
# -----------------------------------------------------------------------------
# Called by 0.0_generate_mirror_config.sh:
#
#   <id>.sh components   catalog of what can be selected, written to fd 3 as
#                        "catalog<TAB>id<TAB>description" lines. Catalog
#                        "component" fills the install's component list in the
#                        config; other catalogs (e.g. "image_group") are
#                        available to <id>.sh.j2 as {{ catalogs.<name> }}.
#   <id>.sh prefill      values copied from the install's own config when the
#                        generator runs with --prefill-from-installs, written to
#                        fd 3 as "MIRROR_KEY<TAB>value" lines. Print nothing when
#                        the install's config does not exist.
#
# Runs with ENV_TARGET=<the install's target> (its config loaded) when that
# config exists, otherwise with PREG_NO_ENV=1 and no config at all.
# stdout/stderr are free for messages; only fd 3 is read.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done
if [[ -n "${PREG_NO_ENV:-}" ]]; then export _CP4D_REPO_ROOT="${_b}"; else source "${_b}/env_bootstrap.sh"; fi; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"

case "${1:-}" in
    components)
        print -r -- $'component\texample\tAn example component' >&3
        ;;
    prefill)
        [[ -n "${PREG_NO_ENV:-}" ]] && exit 0
        # print -r -- $'MIRROR_TEMPLATE_COMPONENTS\texample' >&3
        ;;
    *) preg_die "usage: $0 components|prefill" ;;
esac

exit 0
