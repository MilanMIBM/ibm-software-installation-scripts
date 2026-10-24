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

# ---

usage() {
    cat <<'EOF'
Install the Kubernetes CLI (kubectl) from dl.k8s.io, sha256 verified.

  install_kubectl.sh [options]

kubectl is supported within one minor version of the cluster's API server, so
by default the version follows the cluster you are logged in to (oc or
kubectl's current context). Nothing is installed when kubectl is already on
PATH, unless --force is given or --version names a different version. A
kubectl elsewhere on PATH (Homebrew, the one next to oc, ...) is never
touched; only DIR/kubectl is written.

On OpenShift, oc already ships a matching kubectl: the CP4D track's
0.1_install_oc-MAC-ONLY.sh installs both.

Options:
  --version V   vX.Y.Z, "cluster" (newest patch of the cluster's Kubernetes
                minor), "latest" (newest stable) or "auto". Default:
                KUBECTL_VERSION, else auto = cluster when one is reachable,
                otherwise latest.
  --dir DIR     install folder (default: CLI_INSTALL_DIR, else /usr/local/bin;
                ~/bin on Windows). sudo is used when DIR is not writable.
  --force       install even when kubectl is already on PATH
  --yes, -y     do not ask before installing
  --check       only report the kubectl on PATH and its skew against the
                cluster (exit 1 when there is no kubectl)
  -h, --help    this help
EOF
}

VERSION="${KUBECTL_VERSION:-}" DIR="" FORCE=false CHECK_ONLY=false
while (( $# )); do
    case "$1" in
        --version) [[ -n "${2:-}" ]] || cli_die "--version needs a value"; VERSION="$2"; shift 2 ;;
        --version=*) VERSION="${1#*=}"; shift ;;
        --dir) [[ -n "${2:-}" ]] || cli_die "--dir needs a value"; DIR="$2"; shift 2 ;;
        --dir=*) DIR="${1#*=}"; shift ;;
        --force) FORCE=true; shift ;;
        -y|--yes) export CLI_ASSUME_YES=true; shift ;;
        --check) CHECK_ONLY=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; cli_die "Unknown argument: $1" ;;
    esac
done
VERSION_ASKED="${VERSION:+true}"
[[ "${VERSION}" == auto ]] && VERSION_ASKED=""
DIR="${DIR:-$(cli_default_dir)}"
DIR="${DIR/#\~/${HOME}}"

# The API server's Kubernetes version (OpenShift reports it too), from the
# current oc / kubectl login. Fails when no cluster answers within 5s.
cluster_k8s_version() {
    local c raw
    for c in oc kubectl; do
        command -v "${c}" >/dev/null 2>&1 || continue
        raw="$("${c}" get --raw /version --request-timeout=5s 2>/dev/null | tr -d '\n' \
            | sed -n 's/.*"gitVersion": *"\([^"]*\)".*/\1/p' || true)"
        if [[ -n "${raw}" ]]; then
            cli_semver "${raw}"
            return 0
        fi
    done
    return 1
}

minor_number() { local m="${1#v*.}"; print -r -- "${m%%.*}"; }

# --- 1. The kubectl on PATH and the cluster ---------------------------------------------
current_path="$(whence -p kubectl 2>/dev/null || true)"
current_ver=""
if [[ -n "${current_path}" ]]; then
    current_ver="$(cli_semver "$(kubectl version --client -o json 2>/dev/null | tr -d '\n' \
        | sed -n 's/.*"gitVersion": *"\([^"]*\)".*/\1/p' || true)")"
    cli_info "kubectl on PATH: ${current_path} (${current_ver:-unknown version})"
else
    cli_info "kubectl is not on PATH."
fi

server_ver="$(cluster_k8s_version || true)"
if [[ -n "${server_ver}" ]]; then
    cli_info "Cluster API server: Kubernetes ${server_ver}"
    if [[ -n "${current_ver}" ]]; then
        skew=$(( $(minor_number "${current_ver}") - $(minor_number "${server_ver}") ))
        (( skew < 0 )) && skew=$(( -skew ))
        (( skew > 1 )) && cli_warn "kubectl ${current_ver} is ${skew} minor versions from the cluster's ${server_ver} (supported: 1). Run with --version cluster --force for a matching one."
    fi
else
    cli_info "No cluster reachable with the current oc / kubectl login."
fi

if ${CHECK_ONLY}; then
    [[ -n "${current_path}" ]] && exit 0 || exit 1
fi

# --- 2. Which version ------------------------------------------------------------------
stable_of() {   # [<minor, e.g. 1.33>]
    curl -fsSL --retry 3 "https://dl.k8s.io/release/stable${1:+-$1}.txt" 2>/dev/null || true
}
case "${VERSION:-auto}" in
    auto)    if [[ -n "${server_ver}" ]]; then VERSION=cluster; else VERSION=latest; fi ;;
esac
case "${VERSION}" in
    cluster)
        [[ -n "${server_ver}" ]] || cli_die "--version cluster: no cluster reachable. Log in with oc first, or pass --version."
        VERSION="$(stable_of "$(cli_minor_of "${server_ver#v}")")"
        VERSION="${VERSION:-${server_ver}}"
        ;;
    latest) VERSION="$(stable_of)" ;;
    *)      VERSION="v${VERSION#v}" ;;
esac
[[ "${VERSION}" == v<->.<->.<->* ]] || cli_die "Not a kubectl version: '${VERSION}' (vX.Y.Z, cluster, latest or auto)."

if [[ -n "${current_path}" ]] && ! ${FORCE}; then
    if [[ -z "${VERSION_ASKED}" || "${current_ver}" == "${VERSION}" ]]; then
        cli_info "Nothing to do (--force installs ${VERSION} into ${DIR} anyway)."
        exit 0
    fi
fi

# --- 3. Download, verify, install ---------------------------------------------------
OS="$(cli_os)" ARCH="$(cli_arch)" EXE="$(cli_exe_suffix)"
URL="https://dl.k8s.io/release/${VERSION}/bin/${OS}/${ARCH}/kubectl${EXE}"
TARGET="${DIR}/kubectl${EXE}"

question="Install kubectl ${VERSION} (${OS}-${ARCH}) as ${TARGET}"
[[ -e "${TARGET}" ]] && question+=" (replaces the one there)"
cli_confirm "${question}?" || cli_die "Not installed."

TMP="$(mktemp -d)"
cli_fetch_verified "${URL}" "${TMP}/kubectl${EXE}" "${URL}.sha256"
cli_install_binary "${TMP}/kubectl${EXE}" "${DIR}" "kubectl${EXE}"
cli_info "Installed: ${TARGET} ($("${TARGET}" version --client 2>/dev/null | head -1 || print -r -- "${VERSION}"))"
cli_check_path "${DIR}" kubectl
