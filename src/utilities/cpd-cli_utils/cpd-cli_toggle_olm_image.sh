#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

# =============================================================================
# cpd-cli_toggle_olm_image.sh - switch cpd-cli between the standard and the
# Premium olm-utils image.
# -----------------------------------------------------------------------------
# Why this exists:
#   A handful of cpd-cli manage commands only ship in the Premium olm-utils
#   image. In the standard image icr.io/cpopen/cpd/olm-utils-v4 they exist as
#   stubs that print a notice and exit 1:
#
#       /opt/ansible/bin/enable-premium-features
#       /opt/ansible/bin/get-premium-feature-status
#
#   Switching variants means pointing OLM_UTILS_IMAGE at
#   icr.io/cpopen/cpd/olm-utils-premium-v4 and restarting the olm-utils
#   container so cpd-cli stops reusing the old one.
#
#   The premium image is published per-architecture, so its tag carries an arch
#   suffix (5.4.0.6.amd64). The standard image does not support that suffix.
#
# How the setting persists:
#   The choice is written to cp4d_config/.env as OLM_UTILS_VARIANT.
#   cpd_vars.sh sources that .env on line 6, before it computes
#   OLM_UTILS_IMAGE, so the setting survives regenerating cpd_vars.sh from
#   the config generator.
#
# Usage:
#   ./cpd-cli_toggle_olm_image.sh                 # show current variant
#   ./cpd-cli_toggle_olm_image.sh premium         # switch to premium
#   ./cpd-cli_toggle_olm_image.sh standard        # switch back
#   ./cpd-cli_toggle_olm_image.sh toggle          # flip to the other one
#   ./cpd-cli_toggle_olm_image.sh premium --no-restart   # persist only
# =============================================================================

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# cpd_vars.sh reassigns SCRIPT_DIR when sourced, so keep our own copy.
UTILS_DIR="${SCRIPT_DIR}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

CONTAINER_NAME="olm-utils-play-v4"
STANDARD_REPO="icr.io/cpopen/cpd/olm-utils-v4"
PREMIUM_REPO="icr.io/cpopen/cpd/olm-utils-premium-v4"

ENV_FILE="${CONFIG_DIR}/.env"

# -----------------------------------------------------------------------------
# Parse arguments
# -----------------------------------------------------------------------------
REQUESTED=""
DO_RESTART=true
DO_PULL=true

for arg in "$@"; do
    case "${arg}" in
        premium|standard|toggle|status) REQUESTED="${arg}" ;;
        --no-restart)                   DO_RESTART=false ;;
        --no-pull)                      DO_PULL=false ;;
        -h|--help)
            sed -n '6,36p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "[ERROR] Unknown argument: ${arg}"
            echo "        Valid: premium | standard | toggle | status [--no-restart] [--no-pull]"
            exit 1
            ;;
    esac
done

CURRENT="${OLM_UTILS_VARIANT:-standard}"

if [[ -z "${REQUESTED}" || "${REQUESTED}" == "status" ]]; then
    echo "[INFO] Current variant : ${CURRENT}"
    echo "[INFO] Current image   : ${OLM_UTILS_IMAGE:-<unset>}"
    echo "[INFO] Persisted in    : ${ENV_FILE}"
    if podman ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "[INFO] Running container image: $(podman inspect -f '{{.ImageName}}' "${CONTAINER_NAME}" 2>/dev/null || echo '<unknown>')"
    else
        echo "[INFO] No ${CONTAINER_NAME} container present."
    fi
    exit 0
fi

if [[ "${REQUESTED}" == "toggle" ]]; then
    if [[ "${CURRENT}" == "premium" ]]; then TARGET="standard"; else TARGET="premium"; fi
else
    TARGET="${REQUESTED}"
fi

# -----------------------------------------------------------------------------
# Work out the image tag for the target variant
# -----------------------------------------------------------------------------
for var in VERSION CONFIG_DIR; do
    if [[ -z "${(P)var:-}" ]]; then
        echo "[ERROR] ${var} is not set. Generate cp4d_config/cpd_vars.sh first."
        exit 1
    fi
done

TAG="${VERSION}"
if [[ -n "${PATCH_ID:-}" ]]; then
    TAG="${VERSION}.${PATCH_ID}"
fi

if [[ "${TARGET}" == "premium" ]]; then
    REPO="${PREMIUM_REPO}"
    # Premium images are published per-architecture.
    if [[ -n "${IMAGE_ARCH:-}" ]]; then
        TAG="${TAG}.${IMAGE_ARCH}"
    fi
else
    REPO="${STANDARD_REPO}"
fi

TARGET_IMAGE="${REPO}:${TAG}"

echo "[INFO] Variant : ${CURRENT} -> ${TARGET}"
echo "[INFO] Image   : ${TARGET_IMAGE}"

if [[ "${TARGET}" == "premium" ]]; then
    echo "[WARN] The premium olm-utils image requires an IBM Software Hub Premium"
    echo "[WARN] entitlement. Without it the pull fails with 'manifest unknown'."
fi

# -----------------------------------------------------------------------------
# Persist the choice to cp4d_config/.env
# -----------------------------------------------------------------------------
mkdir -p "${CONFIG_DIR}"
touch "${ENV_FILE}"

# Drop any previous OLM_UTILS_VARIANT / OLM_UTILS_IMAGE lines, then re-add.
# A stale explicit OLM_UTILS_IMAGE would otherwise override the variant.
TMP_ENV="$(mktemp)"
grep -v -E '^[[:space:]]*(export[[:space:]]+)?(OLM_UTILS_VARIANT|OLM_UTILS_IMAGE)=' "${ENV_FILE}" > "${TMP_ENV}" || true
mv "${TMP_ENV}" "${ENV_FILE}"

printf 'export OLM_UTILS_VARIANT="%s"\n' "${TARGET}" >> "${ENV_FILE}"
echo "[INFO] Wrote OLM_UTILS_VARIANT=${TARGET} to ${ENV_FILE}"

export OLM_UTILS_VARIANT="${TARGET}"
export OLM_UTILS_IMAGE="${TARGET_IMAGE}"

# Keep the copy the container reads in sync (source_env_setup.sh copies
# cp4d_config/* into the work dir on every load).
if [[ -n "${CPD_CLI_WORK_PATH:-}" && -d "${CPD_CLI_WORK_PATH}/cp4d_config" ]]; then
    cp "${ENV_FILE}" "${CPD_CLI_WORK_PATH}/cp4d_config/.env" 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# Pull the image and restart the container
# -----------------------------------------------------------------------------
if [[ "${DO_PULL}" == true ]]; then
    echo "[INFO] Pulling ${TARGET_IMAGE}"
    if ! podman pull --arch="${IMAGE_ARCH:-amd64}" "${TARGET_IMAGE}"; then
        echo "[ERROR] Could not pull ${TARGET_IMAGE}"
        if [[ "${TARGET}" == "premium" ]]; then
            echo "[ERROR] Confirm your registry credentials carry an IBM Software Hub"
            echo "[ERROR] Premium entitlement, and that the tag exists for ${IMAGE_ARCH:-amd64}."
        fi
        echo "[INFO] OLM_UTILS_VARIANT is already persisted; re-run once the pull can succeed."
        exit 1
    fi
fi

if [[ "${DO_RESTART}" == false ]]; then
    echo "[INFO] --no-restart given. Open a new shell (or re-source the env) and run:"
    echo "       cpd-cli manage restart-container"
    exit 0
fi

if podman ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "[INFO] Removing existing container: ${CONTAINER_NAME}"
    podman rm -f "${CONTAINER_NAME}"
fi

echo "[INFO] Starting olm-utils container on ${TARGET_IMAGE}"
cpd-cli manage restart-container

echo "[INFO] Now running variant: ${TARGET}"
if [[ "${TARGET}" == "premium" ]]; then
    echo "[INFO] enable-premium-features / get-premium-feature-status are now available."
else
    echo "[INFO] Premium-only commands are stubs again in this variant."
fi
