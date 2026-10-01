#!/bin/zsh
# =============================================================================
# cpd-cli_upgrade_to_version.sh - align the local cpd-cli with ${VERSION}
# -----------------------------------------------------------------------------
# Why this exists:
#   The cpd-cli binary is version-locked to an IBM Software Hub release. It
#   launches its olm-utils container from that built-in release version and
#   ignores ${OLM_UTILS_IMAGE}. So a cpd-cli built for SWH 5.3.1 keeps starting
#   a 5.3.1 olm-utils container no matter what cpd_vars.sh says, and the only
#   fix is to replace the binary itself.
#
#   This script reads ${VERSION} from cp4d_config/cpd_vars.sh, finds the
#   matching cpd-cli release on GitHub, and installs it over ${INSTALL_DIR}.
#
# Patch numbers:
#   ${PATCH_ID} is the olm-utils/CASE patch and does NOT track cpd-cli patch
#   numbers (SWH 5.4.0 ships cpd-cli patches 3, 5, 7 - there is no 6). This
#   script therefore matches on ${VERSION} only and takes the newest cpd-cli
#   release for it, which is the backward-compatible choice within a SWH
#   release. Use --patch to pin an exact one.
#
# Usage:
#   ./cpd-cli_upgrade_to_version.sh [-e SE|EE] [--patch N] [--list] [-n] [-f]
#
#   -e, --edition SE|EE   Edition to install (default: EE)
#       --patch N         Pin an exact cpd-cli patch instead of the newest
#       --list            Show the cpd-cli releases available for ${VERSION}
#   -n, --dry-run         Resolve and report, change nothing
#   -f, --force           Reinstall even if the running binary already matches
# =============================================================================

# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; REPO_ROOT="${_b}"; unset _b

# Shared SWH-version -> cpd-cli-release resolver (also used by
# src/scripts/0_initial_setup/0.2_install_cpd_cli-MAC-ONLY.sh).
source "${REPO_ROOT}/src/helpers/resolve_cpd_cli_release.sh"

#---

EDITION="EE"
PIN_PATCH=""
DRY_RUN=0
FORCE=0
LIST_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--edition) EDITION="${2:-}"; shift 2 ;;
        --patch)      PIN_PATCH="${2:-}"; shift 2 ;;
        --list)       LIST_ONLY=1; shift ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        -f|--force)   FORCE=1; shift ;;
        -h|--help)    sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "[ERROR] Unknown argument: $1 (try --help)"; exit 1 ;;
    esac
done

if [[ "${EDITION}" != "SE" && "${EDITION}" != "EE" ]]; then
    echo "[ERROR] Edition must be SE or EE, got: ${EDITION}"
    exit 1
fi

if [[ -z "${VERSION:-}" ]]; then
    echo "[ERROR] VERSION is not set. Set it in cp4d_config/cpd_vars.sh before running this script."
    exit 1
fi

INSTALL_DIR="${CPD_CLI_MANAGE_WORKSPACE:-${HOME}/cpd-cli}"
CONTAINER_NAME="olm-utils-play-v4"

ASSET_PLATFORM="$(cpd_cli_platform_asset)" || exit 1

echo "=== cpd-cli upgrade for IBM Software Hub ${VERSION} (${EDITION}, ${ASSET_PLATFORM}) ==="

# -----------------------------------------------------------------------------
# Resolve the matching release from the GitHub API.
# -----------------------------------------------------------------------------
# The release NAME carries the SWH version ("... interface 5.4.0 - Patch 7"),
# the TAG carries the cpd-cli version ("v14.4.0.7"), and the ASSET drops the
# patch ("cpd-cli-darwin-EE-14.4.0.tgz"). Resolve the download URL from the
# asset list rather than rebuilding the filename, so a naming change upstream
# surfaces as "no asset" instead of a 404 halfway through.
echo "[1/5] Querying IBM/cpd-cli releases for SWH ${VERSION}..."

if (( LIST_ONLY )); then
    _LIST="$(cpd_cli_resolve_release "${VERSION}" "${ASSET_PLATFORM}" "${EDITION}" "" 1)" || exit 1
    echo "[INFO] cpd-cli releases available for SWH ${VERSION}:"
    echo "${_LIST}" | awk -F'\t' '$1=="AVAILABLE" { printf "  %-14s patch %-3s %s\n", $2, $3, $4 }'
    exit 0
fi

_RESOLVED="$(cpd_cli_resolve_release "${VERSION}" "${ASSET_PLATFORM}" "${EDITION}" "${PIN_PATCH}")" || {
    echo "[ERROR] Could not resolve a cpd-cli release (see message above)."
    exit 1
}

RELEASE_TAG="$(cpd_cli_field "${_RESOLVED}" TAG)"
RELEASE_PATCH="$(cpd_cli_field "${_RESOLVED}" PATCH)"
CLI_VERSION="$(cpd_cli_field "${_RESOLVED}" CLI_VERSION)"
PACKAGE_NAME="$(cpd_cli_field "${_RESOLVED}" ASSET)"
DOWNLOAD_URL="$(cpd_cli_field "${_RESOLVED}" URL)"
ALL_PATCHES="$(cpd_cli_field "${_RESOLVED}" OTHERS)"

echo "[INFO] Selected ${RELEASE_TAG} (cpd-cli ${CLI_VERSION}, patch ${RELEASE_PATCH})"
echo "[INFO] Available patches for ${VERSION}: ${ALL_PATCHES}"
if [[ -n "${PATCH_ID:-}" && -z "${PIN_PATCH}" ]]; then
    echo "[INFO] PATCH_ID=${PATCH_ID} applies to olm-utils/CASE, not cpd-cli; ignoring it here."
fi

# -----------------------------------------------------------------------------
# Compare against what is installed now.
# -----------------------------------------------------------------------------
echo "[2/5] Checking the installed cpd-cli..."
CURRENT_SWH=""
CURRENT_CLI=""
if [[ -x "${INSTALL_DIR}/cpd-cli" ]]; then
    _ver_out="$("${INSTALL_DIR}/cpd-cli" version 2>/dev/null || true)"
    CURRENT_CLI="$(echo "${_ver_out}" | awk -F': *' '/^[[:space:]]*Version:/ { print $2; exit }')"
    CURRENT_SWH="$(echo "${_ver_out}" | awk -F': *' '/SWH Release Version:/ { print $2; exit }')"
    echo "[INFO] Installed: cpd-cli ${CURRENT_CLI:-unknown} (SWH ${CURRENT_SWH:-unknown})"
else
    echo "[INFO] No cpd-cli found at ${INSTALL_DIR}; this will be a fresh install."
fi

if [[ "${CURRENT_SWH}" == "${VERSION}" && "${CURRENT_CLI}" == "${CLI_VERSION}" ]] && (( ! FORCE )); then
    echo "[INFO] Already on cpd-cli ${CLI_VERSION} for SWH ${VERSION}; nothing to do."
    echo "[INFO] Re-run with --force to reinstall anyway."
    exit 0
fi

if (( DRY_RUN )); then
    echo ""
    echo "=== Dry run - no changes made ==="
    echo "  Would download: ${DOWNLOAD_URL}"
    echo "  Would install to: ${INSTALL_DIR}"
    echo "  Would remove container: ${CONTAINER_NAME}"
    exit 0
fi

# -----------------------------------------------------------------------------
# Download and install.
# -----------------------------------------------------------------------------
echo "[3/5] Downloading ${PACKAGE_NAME} (${RELEASE_TAG})..."
_TMP_TGZ="$(mktemp -t cpd-cli-pkg)"
trap 'rm -f "${_TMP_TGZ}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

curl -fSL --retry 3 --retry-delay 2 -o "${_TMP_TGZ}" "${DOWNLOAD_URL}"

# Verify the archive before it is allowed to overwrite a working install.
if ! tar -tzf "${_TMP_TGZ}" >/dev/null 2>&1; then
    echo "[ERROR] Downloaded archive is not a readable gzip tarball: ${PACKAGE_NAME}"
    exit 1
fi

echo "[4/5] Installing to ${INSTALL_DIR}..."
# Keep work/ - it holds the ansible logs and override files from prior runs.
# Everything else (binary, plugins/, LICENSES/) belongs to the old release and
# is replaced wholesale, since plugins are built against their own cpd-cli.
if [[ -d "${INSTALL_DIR}" ]]; then
    for _stale in "${INSTALL_DIR}/cpd-cli" "${INSTALL_DIR}/plugins" "${INSTALL_DIR}/LICENSES"; do
        [[ -e "${_stale}" ]] && rm -rf "${_stale}"
    done
    unset _stale
fi
mkdir -p "${INSTALL_DIR}"
tar -xzf "${_TMP_TGZ}" -C "${INSTALL_DIR}" --strip-components=1

if [[ "${ASSET_PLATFORM}" == "darwin" ]]; then
    # Strip the quarantine flag, otherwise Gatekeeper blocks each binary until
    # it is opened by hand. Same component list as 0.2_install_cpd_cli-MAC-ONLY.sh.
    echo "[INFO] Removing macOS quarantine flags..."
    xattr -rd com.apple.quarantine "${INSTALL_DIR}" 2>/dev/null || true
fi

chmod +x "${INSTALL_DIR}/cpd-cli" 2>/dev/null || true
for _p in "${INSTALL_DIR}"/plugins/lib/*/*; do
    [[ -f "${_p}" ]] && chmod +x "${_p}" 2>/dev/null || true
done
unset _p

# -----------------------------------------------------------------------------
# Drop the stale olm-utils container so the new cpd-cli cannot reuse it.
# -----------------------------------------------------------------------------
echo "[5/5] Clearing the stale olm-utils container..."
_ENGINE=""
command -v podman >/dev/null 2>&1 && _ENGINE="podman"
[[ -z "${_ENGINE}" ]] && command -v docker >/dev/null 2>&1 && _ENGINE="docker"

if [[ -n "${_ENGINE}" ]]; then
    if "${_ENGINE}" ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${CONTAINER_NAME}"; then
        _old_img="$("${_ENGINE}" inspect "${CONTAINER_NAME}" --format '{{.ImageName}}' 2>/dev/null || echo unknown)"
        echo "[INFO] Removing ${CONTAINER_NAME} (was ${_old_img})"
        "${_ENGINE}" rm -f "${CONTAINER_NAME}" >/dev/null
        unset _old_img
    else
        echo "[INFO] No ${CONTAINER_NAME} container present."
    fi
else
    echo "[WARN] No podman/docker found; remove ${CONTAINER_NAME} yourself before the next cpd-cli run."
fi
unset _ENGINE

# -----------------------------------------------------------------------------
# Verify.
# -----------------------------------------------------------------------------
echo ""
NEW_OUT="$("${INSTALL_DIR}/cpd-cli" version 2>/dev/null || true)"
NEW_SWH="$(echo "${NEW_OUT}" | awk -F': *' '/SWH Release Version:/ { print $2; exit }')"
NEW_CLI="$(echo "${NEW_OUT}" | awk -F': *' '/^[[:space:]]*Version:/ { print $2; exit }')"

echo "=== Upgrade complete ==="
echo "  Installed:   cpd-cli ${NEW_CLI:-unknown} (SWH ${NEW_SWH:-unknown})"
echo "  Release:     ${RELEASE_TAG}"
echo "  Location:    ${INSTALL_DIR}"
echo "  Workspace:   ${CPD_CLI_WORK_PATH:-${INSTALL_DIR}/work} (kept)"

if [[ -n "${NEW_SWH}" && "${NEW_SWH}" != "${VERSION}" ]]; then
    echo ""
    echo "[WARN] The new binary reports SWH ${NEW_SWH} but VERSION is ${VERSION}."
    echo "[WARN] Check that VERSION in cp4d_config/cpd_vars.sh is a published SWH release."
    exit 1
fi

echo ""
echo "[INFO] Next cpd-cli manage run will start a fresh olm-utils container."
echo "[INFO] To pre-pull the matching olm-utils image, run:"
echo "         ${SCRIPT_DIR}/cpd-cli_refresh_olm_container.sh"
