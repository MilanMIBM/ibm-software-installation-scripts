#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# (legacy hardcoded sourcing - replaced by universal crawl below)
# source "${SCRIPT_DIR}/../source_env_setup.sh"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/version_resolver.sh"

# ---
eval "${CPDM_OC_LOGIN}"

# The --cpd_config_ac_image override is only needed when the cluster pulls from a
# private container registry. With the IBM Entitled Registry the cpd-cli resolves
# the image itself (without the flag it falls back to rsi-webhook-deployment's image
# or a DOCKER_REGISTRY/... placeholder, so a private registry needs it).
#
# The image tag comes from the zen CASE that 2.0.2 downloaded, so it follows
# VERSION / PATCH_ID without a lookup table:
#   zen CASE version  patch-<VERSION>-<PATCH_ID>.yaml (patch_components_meta.zen),
#                     else release-<VERSION>.yml from the olm-utils container
#   tag               the <arch> IMAGE row for zen-rsi-adm-controller in that CASE's
#                     images CSV, e.g. 6.10.8-45-amd64 (the tag mirror-images pushes)
# Read by cpd_release_meta.py (vr_cpd_image_tag); the lookup this script did
# before is the fallback (legacy_zen_ac_tag in src/helpers/legacy_version_resolution.sh).
# CPD_CONFIG_AC_IMAGE (full image reference) skips the lookup.
AC_REPO="cpopen/cpfs/zen-rsi-adm-controller"

resolve_ac_image() {
  local tag
  tag="$(vr_try "zen-rsi-adm-controller tag" \
    vr_cpd_image_tag ibm-zen zen "^${AC_REPO}\$" "${IMAGE_ARCH:-amd64}" \
    -- legacy_zen_ac_tag "${AC_REPO}")" || return 1
  print -r -- "${IMAGE_PULL_PREFIX}/${AC_REPO}:${tag}"
}

if [[ -n "${PRIVATE_REGISTRY_LOCATION:-}" ]]; then
  AC_IMAGE="${CPD_CONFIG_AC_IMAGE:-}"
  [[ -n "${AC_IMAGE}" ]] || AC_IMAGE="$(resolve_ac_image)" || exit 1

  echo "[INFO] Private registry detected, using ${AC_IMAGE}"
  cpd-cli manage install-cpd-config-ac \
    --cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS} \
    --cpd_config_ac_image=${AC_IMAGE}
else
  echo "[INFO] IBM Entitled Registry detected, letting cpd-cli resolve the controller image"
  cpd-cli manage install-cpd-config-ac \
    --cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS}
fi

cpd-cli manage enable-cpd-config-ac \
  --cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS}
