#!/bin/zsh
# Segment 0 hook: cpd (contract: _template.sh)
#   components  component and image-group IDs from src/helpers/cp4d_id_options_templates.py
#               (the same lists the CP4D notebook offers)
#   prefill     from configs/cp4d_config/cpd_vars.sh: components, image groups,
#               registry location/credentials, entitlement key
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done
if [[ -n "${PREG_NO_ENV:-}" ]]; then export _CP4D_REPO_ROOT="${_b}"; else source "${_b}/env_bootstrap.sh"; fi; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"

# A value still holding a template placeholder (<namespace>, <insert_...>) is unset.
real() { [[ -n "${1:-}" && "${1}" != *"<"*">"* ]]; }

case "${1:-}" in
    components)
        preg_python -I - "${_CP4D_REPO_ROOT}/src/helpers" <<'PY' >&3
import sys
sys.path.insert(0, sys.argv[1])
import cp4d_id_options_templates as t
names = {}
for d in t.cpd_enterprise_supported_components:
    if isinstance(d, dict):
        names[d.get("component_id")] = d.get("component_name", "")
base = ["ibm-licensing", "scheduler", "cpfs", "cpd_platform", "ccs", "zen"]
for c in base + [c for c in t.cp4d_component_id_options if c not in base]:
    desc = names.get(c, "")
    if c in base:
        desc = (desc + " " if desc else "") + "(Software Hub platform)"
    print(f"component\t{c}\t{desc}")
for g in t.image_group_ids:
    print(f"image_group\t{g}\t")
PY
        ;;
    prefill)
        [[ -n "${PREG_NO_ENV:-}" ]] && exit 0
        comps="${COMPLETE_COMPONENT_LIST:-${SOFTWARE_HUB:-}${CPD_COMPONENTS:+,${CPD_COMPONENTS}}}"
        # The template drops OpenSearch from CPD_COMPONENTS (4.1.1 installs it on
        # its own); it still has to be mirrored.
        if preg_is_true "${PREP_OPENSEARCH:-false}" && ! preg_in_list ibm_wxd_opensearch "${comps}"; then
            comps="${comps},ibm_wxd_opensearch"
        fi
        content="case,olm-utils,ibm-images,prereq-operators,extra-images"
        [[ -n "${IMAGE_GROUPS:-}" ]] && content="${content},image-groups"
        {
            [[ -n "${comps}" ]] && print -r -- "MIRROR_CPD_COMPONENTS"$'\t'"${comps}"
            print -r -- "MIRROR_CPD_CONTENT"$'\t'"${content}"
            [[ -n "${IMAGE_GROUPS:-}" ]] && print -r -- "MIRROR_CPD_IMAGE_GROUPS"$'\t'"${IMAGE_GROUPS}"
            real "${PRIVATE_REGISTRY_LOCATION:-}" && print -r -- "MIRROR_REGISTRY_ROOT"$'\t'"${PRIVATE_REGISTRY_LOCATION}"
            real "${PRIVATE_REGISTRY_PUSH_USER:-}" && print -r -- "MIRROR_REGISTRY_PUSH_USER"$'\t'"${PRIVATE_REGISTRY_PUSH_USER}"
            real "${PRIVATE_REGISTRY_PUSH_PASSWORD:-}" && print -r -- "MIRROR_REGISTRY_PUSH_PASSWORD"$'\t'"${PRIVATE_REGISTRY_PUSH_PASSWORD}"
            real "${IBM_ENTITLEMENT_KEY:-}" && print -r -- "MIRROR_IBM_ENTITLEMENT_KEY"$'\t'"${IBM_ENTITLEMENT_KEY}"
            :   # a false test on the last line would fail the group under set -e
        } >&3
        ;;
    *) preg_die "usage: $0 components|prefill" ;;
esac
exit 0
