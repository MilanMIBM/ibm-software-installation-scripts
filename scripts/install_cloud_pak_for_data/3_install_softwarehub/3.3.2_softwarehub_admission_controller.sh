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

# The --cpd_config_ac_image override (and therefore ZEN_VERSION) is only needed when
# the cluster pulls from a private container registry. With the IBM Entitled Registry
# the cpd-cli resolves the image itself.
if [[ -n "${PRIVATE_REGISTRY_LOCATION:-}" ]]; then
  # ZEN_VERSION mapping (see "Installing the IBM Software Hub configuration admission
  # controller webhook"): 5.4.0 varies by patch level, 5.3.1 -> 6.4.0, 5.3.0 -> 6.3.0
  case "${VERSION}" in
    5.4.0)
      case "${PATCH_ID:-}" in
        "")    export ZEN_VERSION="6.10.0" ;;  # no patch applied
        1|2)   export ZEN_VERSION="6.10.1" ;;
        3|4)   export ZEN_VERSION="6.10.3" ;;
        5|6)   export ZEN_VERSION="6.10.5" ;;
        *)     echo "[ERROR] Unknown PATCH_ID=${PATCH_ID} for VERSION=${VERSION}, cannot determine ZEN_VERSION"; exit 1 ;;
      esac
      ;;
    5.3.1) export ZEN_VERSION="6.4.0" ;;
    5.3.0) export ZEN_VERSION="6.3.0" ;;
    *) echo "[ERROR] Unknown VERSION=${VERSION}, cannot determine ZEN_VERSION"; exit 1 ;;
  esac

  echo "[INFO] Private registry detected, using zen-rsi-adm-controller:${ZEN_VERSION}-${IMAGE_ARCH}"
  cpd-cli manage install-cpd-config-ac \
    --cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS} \
    --cpd_config_ac_image=${IMAGE_PULL_PREFIX}/cpopen/cpfs/zen-rsi-adm-controller:${ZEN_VERSION}-${IMAGE_ARCH}
else
  echo "[INFO] IBM Entitled Registry detected, letting cpd-cli resolve the controller image"
  cpd-cli manage install-cpd-config-ac \
    --cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS}
fi

cpd-cli manage enable-cpd-config-ac \
  --cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS}
