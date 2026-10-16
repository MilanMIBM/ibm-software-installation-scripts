#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: only configs/concert_config/concert_vars.sh is in scope ---
export ENV_TARGET="${ENV_TARGET:-concert}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/concert_helpers.sh"
concert_require_config

# ==============================================================================
# 0.1 Fetch the IBM Concert installer
# ------------------------------------------------------------------------------
# Downloads the release archive (github.com/IBM/Concert/releases) into
# concert_workspace/archives/<tag>/, checks its SHA-256, and extracts it to
# concert_workspace/<version>/ibm-concert. The extracted copy is what the
# scripts read IBM's image lists and level_*.cfg files from, and what the
# container/native runners execute. The in-cluster runner bakes the archive
# into its image (0.2).
#
# Also fetches a linux-amd64 helm tarball for the runner image (IBM's
# Workflows installer runs `helm upgrade --install`).
#
# SHA-256: CONCERT_ARCHIVE_SHA256 pins it when set. Otherwise the hash of the
# first download is recorded next to the archive and later runs must match it,
# so a re-published release asset is caught.
# ==============================================================================

_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}

_download() {   # <url> <dest>
    local url="$1" dest="$2" tmp
    tmp="${dest}.part"
    concert_info "Downloading ${url}"
    curl -fSL --retry 3 -o "${tmp}" "${url}"
    mv "${tmp}" "${dest}"
}

# --- Installer archive --------------------------------------------------------
ARCHIVE="$(concert_archive_path)"
ARCHIVE_URL="https://github.com/IBM/Concert/releases/download/${CONCERT_RELEASE_TAG}/${CONCERT_ARCHIVE}"
mkdir -p "${ARCHIVE:h}"

if [[ -f "${ARCHIVE}" ]]; then
    concert_info "Archive already present: ${ARCHIVE}"
else
    _download "${ARCHIVE_URL}" "${ARCHIVE}"
fi

actual_sha="$(_sha256 "${ARCHIVE}")"
recorded_sha_file="${ARCHIVE}.sha256"
if [[ -n "${CONCERT_ARCHIVE_SHA256:-}" ]]; then
    [[ "${actual_sha}" == "${CONCERT_ARCHIVE_SHA256}" ]] \
        || concert_die "SHA-256 mismatch for ${ARCHIVE}: got ${actual_sha}, CONCERT_ARCHIVE_SHA256=${CONCERT_ARCHIVE_SHA256}"
    concert_info "SHA-256 matches CONCERT_ARCHIVE_SHA256."
elif [[ -f "${recorded_sha_file}" ]]; then
    [[ "${actual_sha}" == "$(<"${recorded_sha_file}")" ]] \
        || concert_die "SHA-256 of ${ARCHIVE} changed since it was first recorded (${recorded_sha_file}). Delete both files to accept the new archive."
    concert_info "SHA-256 matches the recorded value."
else
    print -r -- "${actual_sha}" > "${recorded_sha_file}"
    concert_info "SHA-256 recorded: ${actual_sha} (pin it with CONCERT_ARCHIVE_SHA256 if you like)."
fi

# --- Extract ------------------------------------------------------------------
INSTALL_ROOT="$(concert_local_install_root)"
marker="${INSTALL_ROOT}/.extracted"
if [[ -f "${marker}" && "$(<"${marker}")" == "${actual_sha}" ]]; then
    concert_info "Already extracted: $(concert_local_install_dir)"
else
    rm -rf "${INSTALL_ROOT}"
    mkdir -p "${INSTALL_ROOT}"
    tar -xzf "${ARCHIVE}" -C "${INSTALL_ROOT}"
    print -r -- "${actual_sha}" > "${marker}"
    concert_info "Extracted to $(concert_local_install_dir)"
fi

INSTALL_DIR="$(concert_local_install_dir)"
[[ -x "${INSTALL_DIR}/bin/setup" ]] || concert_die "Unexpected archive layout: ${INSTALL_DIR}/bin/setup not found."

concert_info "Build versions in this archive:"
for f in etc concert-hub/etc concert/etc dataapps/etc concert-workflows/etc itom/etc; do
    [[ -f "${INSTALL_DIR}/${f}/build_version" ]] && printf '  %-22s %s\n' "${f%/etc}" "$(<"${INSTALL_DIR}/${f}/build_version")"
done

# --- helm for the runner image ------------------------------------------------
HELM_TGZ="${CONCERT_WORKSPACE}/tools/helm-${CONCERT_HELM_VERSION}-linux-amd64.tar.gz"
mkdir -p "${HELM_TGZ:h}"
if [[ ! -f "${HELM_TGZ}" ]]; then
    _download "https://get.helm.sh/helm-${CONCERT_HELM_VERSION}-linux-amd64.tar.gz" "${HELM_TGZ}"
    expected="$(curl -fsSL "https://get.helm.sh/helm-${CONCERT_HELM_VERSION}-linux-amd64.tar.gz.sha256sum" | awk '{print $1}')"
    if [[ -n "${expected}" && "${expected}" != "$(_sha256 "${HELM_TGZ}")" ]]; then
        rm -f "${HELM_TGZ}"
        concert_die "helm ${CONCERT_HELM_VERSION} checksum mismatch."
    fi
fi
concert_info "helm ${CONCERT_HELM_VERSION} (linux-amd64): ${HELM_TGZ}"

concert_info "Next: 0.2_prepare_installer_runner.sh"
