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
#                     or release-<VERSION>.yml in the olm-utils container (no patch)
#   tag               the <arch> IMAGE row for zen-rsi-adm-controller in that CASE's
#                     images CSV, e.g. 6.10.8-45-amd64 (the tag mirror-images pushes)
# CPD_CONFIG_AC_IMAGE (full image reference) skips the lookup.
AC_REPO="cpopen/cpfs/zen-rsi-adm-controller"

# Prints case_version of the first "zen:" block in a YAML stream on stdin.
zen_case_version() {
  awk '
    /^[[:space:]]*zen:[[:space:]]*$/ { match($0, /^[[:space:]]*/); zi = RLENGTH; z = 1; next }
    z && NF {
      match($0, /^[[:space:]]*/)
      if (RLENGTH <= zi) exit
      if ($1 == "case_version:") { gsub(/["'\'']/, "", $2); print $2; exit }
    }'
}

resolve_ac_image() {
  local work="${CPD_CLI_WORK_PATH:-${HOME}/cpd-cli/work}" zen="" src csv tag
  if [[ -n "${PATCH_ID:-}" ]]; then
    src="${work}/offline/patch/patch-${VERSION}-${PATCH_ID}.yaml"
    [[ -f "${src}" ]] && zen="$(zen_case_version < "${src}")"
  else
    src="release-${VERSION}.yml in ${OLM_UTILS_CONTAINER:-olm-utils-play-v4}"
    zen="$(podman exec "${OLM_UTILS_CONTAINER:-olm-utils-play-v4}" \
      cat "/opt/ansible/ansible-play/config-vars/release-${VERSION}.yml" 2>/dev/null | zen_case_version || true)"
  fi
  if [[ -z "${zen}" ]]; then
    echo "[ERROR] No zen case_version found in ${src} - run 2.0.2 (case-download) first, or set CPD_CONFIG_AC_IMAGE" >&2
    return 1
  fi

  for csv in "${work}/offline/${VERSION}/.ibm-pak/data/cases/ibm-zen/${zen}/"ibm-zen-${zen}*-images.csv(N); do
    tag="$(awk -F, -v r="${AC_REPO}" -v a="${IMAGE_ARCH:-amd64}" \
      '$2 == r && $5 == "IMAGE" && $7 == a { print $3; exit }' "${csv}")"
    [[ -n "${tag}" ]] && break
  done
  if [[ -z "${tag}" ]]; then
    echo "[ERROR] No ${AC_REPO} ${IMAGE_ARCH:-amd64} image in the ibm-zen ${zen} CASE (${work}/offline/${VERSION}/.ibm-pak/data/cases/ibm-zen/${zen}) - run 2.0.2 first, or set CPD_CONFIG_AC_IMAGE" >&2
    return 1
  fi
  echo "[INFO] zen CASE ${zen} (from ${src:t}) -> ${AC_REPO}:${tag}" >&2
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
