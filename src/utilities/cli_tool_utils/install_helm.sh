#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
TMP=""
trap '[[ -n "${TMP}" ]] && rm -rf "${TMP}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- No config needed: find the repo root without sourcing env_bootstrap.sh ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; unset _b
source "${REPO_ROOT}/src/helpers/cli_install_helpers.sh"
source "${REPO_ROOT}/src/helpers/version_resolver.sh"

# ---

usage() {
    cat <<'EOF'
Install the Helm CLI (helm) from get.helm.sh, sha256 verified.

  install_helm.sh [options]

Nothing is installed when helm is already on PATH, unless --force is given or
--version names a different version. A helm elsewhere on PATH (Homebrew, ...)
is never touched; only DIR/helm is written.

Options:
  --version V   vX.Y.Z, "latest" (newest release) or "latest-3" (newest Helm 3).
                Default: HELM_VERSION, else the version this repo pins for
                DataStax Mission Control (Helm 3.14 - 3.18 only) and the
                Concert installer runner: helm/pinned_version in
                src/helpers/version_catalog.json (v3.18.4).
  --dir DIR     install folder (default: CLI_INSTALL_DIR, else /usr/local/bin;
                ~/bin on Windows). sudo is used when DIR is not writable.
  --force       install even when helm is already on PATH
  --yes, -y     do not ask before installing
  --check       only report the helm on PATH (exit 1 when there is none)
  --no-path-check
                skip the PATH warnings after installing (for a pinned helm
                kept in a folder that is deliberately off PATH)
  -h, --help    this help
EOF
}

VERSION="${HELM_VERSION:-}" DIR="" FORCE=false CHECK_ONLY=false PATH_CHECK=true
while (( $# )); do
    case "$1" in
        --version) [[ -n "${2:-}" ]] || cli_die "--version needs a value"; VERSION="$2"; shift 2 ;;
        --version=*) VERSION="${1#*=}"; shift ;;
        --dir) [[ -n "${2:-}" ]] || cli_die "--dir needs a value"; DIR="$2"; shift 2 ;;
        --dir=*) DIR="${1#*=}"; shift ;;
        --force) FORCE=true; shift ;;
        -y|--yes) export CLI_ASSUME_YES=true; shift ;;
        --check) CHECK_ONLY=true; shift ;;
        --no-path-check) PATH_CHECK=false; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; cli_die "Unknown argument: $1" ;;
    esac
done
VERSION_ASKED="${VERSION:+true}"
DIR="${DIR:-$(cli_default_dir)}"
DIR="${DIR/#\~/${HOME}}"

# --- 1. The helm on PATH -----------------------------------------------------------
current_path="$(whence -p helm 2>/dev/null || true)"
current_ver=""
if [[ -n "${current_path}" ]]; then
    current_ver="$(cli_semver "$(helm version --template '{{.Version}}' 2>/dev/null || true)")"
    cli_info "helm on PATH: ${current_path} (${current_ver:-unknown version})"
    [[ "${current_ver}" == v3.* ]] \
        || cli_info "DataStax Mission Control needs Helm 3.14 - 3.18; its 0.1_fetch_helm.sh downloads a pinned one when needed."
else
    cli_info "helm is not on PATH."
fi

if ${CHECK_ONLY}; then
    [[ -n "${current_path}" ]] && exit 0 || exit 1
fi

# --- 2. Which version ------------------------------------------------------------------
VERSION="${VERSION:-$(vr_catalog helm/pinned_version)}"
case "${VERSION}" in
    latest)   VERSION="$(curl -fsSL --retry 3 https://get.helm.sh/helm-latest-version || true)" ;;
    latest-3) VERSION="$(curl -fsSL --retry 3 https://get.helm.sh/helm3-latest-version || true)" ;;
    *)        VERSION="v${VERSION#v}" ;;
esac
[[ "${VERSION}" == v<->.<->.<->* ]] || cli_die "Not a helm version: '${VERSION}' (vX.Y.Z, latest or latest-3)."

if [[ -n "${current_path}" ]] && ! ${FORCE}; then
    if [[ -z "${VERSION_ASKED}" || "${current_ver}" == "${VERSION}" ]]; then
        cli_info "Nothing to do (--force installs ${VERSION} into ${DIR} anyway)."
        exit 0
    fi
fi

# --- 3. Download, verify, install ---------------------------------------------------
OS="$(cli_os)" ARCH="$(cli_arch)" EXE="$(cli_exe_suffix)"
EXT="$([[ "${OS}" == windows ]] && print -r -- zip || print -r -- tar.gz)"
PKG="helm-${VERSION}-${OS}-${ARCH}.${EXT}"
TARGET="${DIR}/helm${EXE}"

question="Install helm ${VERSION} (${OS}-${ARCH}) as ${TARGET}"
if [[ -e "${TARGET}" ]]; then
    question+=" (replaces $(cli_semver "$("${TARGET}" version --template '{{.Version}}' 2>/dev/null || true)") there)"
fi
cli_confirm "${question}?" || cli_die "Not installed."

TMP="$(mktemp -d)"
cli_fetch_verified "https://get.helm.sh/${PKG}" "${TMP}/${PKG}" "https://get.helm.sh/${PKG}.sha256sum"
if [[ "${EXT}" == zip ]]; then
    if command -v unzip >/dev/null 2>&1; then
        unzip -q "${TMP}/${PKG}" -d "${TMP}"
    else
        powershell.exe -NoProfile -Command "Expand-Archive -Force -Path '$(cygpath -w "${TMP}/${PKG}")' -DestinationPath '$(cygpath -w "${TMP}")'"
    fi
else
    tar -xzf "${TMP}/${PKG}" -C "${TMP}"
fi
[[ -f "${TMP}/${OS}-${ARCH}/helm${EXE}" ]] || cli_die "helm${EXE} not found in ${PKG}."

cli_install_binary "${TMP}/${OS}-${ARCH}/helm${EXE}" "${DIR}" "helm${EXE}"
cli_info "Installed: ${TARGET} ($("${TARGET}" version --short 2>/dev/null || print -r -- "${VERSION}"))"
if ${PATH_CHECK}; then
    cli_check_path "${DIR}" helm
fi
