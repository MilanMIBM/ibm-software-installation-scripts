#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: the mirror config only (MIRROR_CONFIG_FILE selects another file) ---
export ENV_TARGET="${MIRROR_CONFIG_FILE:-registry_mirror}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"
preg_require_config

# ==============================================================================
# 0.2 Tools for mirroring
# ------------------------------------------------------------------------------
#   - checks this workstation: oc, skopeo, helm, podman, curl, openssl, python
#     (+ cpd-cli when cpd is selected)
#   - downloads oc-mirror for Linux into registry_mirror_workspace/tools/:
#     it only ships for Linux, so on macOS the steps run it in a UBI container on
#     the podman VM (arm64 on Apple Silicon, no emulation)
#   - --for-inside: the inside workstation's tools for the stop-over bundle
#     (MIRROR_INSIDE_PLATFORM): oc, oc-mirror, helm, cpd-cli, Python wheels
#     (PyYAML, Jinja2) into <bundle>/tools/<platform>-<arch>/
#
#   ./0.2_fetch_mirror_tools.sh [--for-inside] [--force]
#
# Settings: MIRROR_OCP_MINOR (client channel, default the latest stable),
# MIRROR_INSIDE_ARCH (amd64), MIRROR_HELM_VERSION (v3.18.4: Mission Control
# supports Helm 3.14-3.18), MIRROR_INSIDE_PYTHON (3.9 = RHEL 9's python3).
# ==============================================================================

FOR_INSIDE=false FORCE=false
for _a in "$@"; do
    case "${_a}" in
        --for-inside) FOR_INSIDE=true ;;
        --force) FORCE=true ;;
        *) preg_die "Unknown argument: ${_a} (--for-inside, --force)" ;;
    esac
done

HELM_VERSION="${MIRROR_HELM_VERSION:-v3.18.4}"
CHANNEL="stable${MIRROR_OCP_MINOR:+-${MIRROR_OCP_MINOR}}"
archdir() { [[ "$1" == arm64 ]] && print -r -- aarch64 || print -r -- x86_64; }

fetch() {   # <url> <dest file>
    [[ -s "$2" ]] && ! ${FORCE} && { preg_info "Have ${2:t}"; return 0; }
    mkdir -p "${2:h}"
    preg_info "Downloading ${1}"
    curl -fsSL --retry 3 -o "$2.part" "$1" && mv "$2.part" "$2"
}

# --- 1. This workstation ---------------------------------------------------------
print -r -- "Workstation tools"
missing=()
need=(oc skopeo helm podman curl openssl tar)
preg_in_list cpd "${MIRROR_INSTALLS:-}" && need+=(cpd-cli)
for t in "${need[@]}"; do
    if p="$(command -v "${t}" 2>/dev/null)"; then
        printf '  %-10s %s\n' "${t}" "${p}"
    else
        printf '  %-10s MISSING\n' "${t}"
        missing+=("${t}")
    fi
done
if [[ -x "${_CP4D_REPO_ROOT}/.venv/bin/python" ]]; then
    printf '  %-10s %s\n' python "${_CP4D_REPO_ROOT}/.venv/bin/python (repo venv)"
else
    printf '  %-10s %s\n' python "$(command -v python3 || print MISSING) (no repo venv: run uv sync for Jinja2/PyYAML)"
fi
if command -v helm >/dev/null 2>&1; then
    hv="$(helm version --template '{{.Version}}' 2>/dev/null || true)"
    printf '  %-10s %s\n' "" "helm ${hv} (Mission Control needs 3.14-3.18; 0.1_fetch_helm.sh of the MC track can provide one)"
fi
(( ${#missing} )) && preg_warn "Missing: ${missing[*]} - install them (Homebrew on macOS, dnf on RHEL)."

# --- 2. oc-mirror for this machine's Linux ---------------------------------------------
LARCH="$(preg_linux_arch)"
OCM="$(preg_oc_mirror_binary)"
if [[ "$(uname -s)" == Linux ]] && command -v oc-mirror >/dev/null 2>&1 && ! ${FORCE}; then
    preg_info "oc-mirror on PATH: $(command -v oc-mirror)"
else
    _tgz="$(preg_tools_dir)/linux-${LARCH}/oc-mirror.tar.gz"
    if [[ ! -x "${OCM}" ]] || ${FORCE}; then
        fetch "https://mirror.openshift.com/pub/openshift-v4/$(archdir "${LARCH}")/clients/ocp/${CHANNEL}/oc-mirror.rhel9.tar.gz" "${_tgz}"
        tar -xzf "${_tgz}" -C "${_tgz:h}" oc-mirror
        chmod +x "${OCM}"
        rm -f "${_tgz}"
    fi
    preg_info "oc-mirror (linux/${LARCH}): ${OCM#${_CP4D_REPO_ROOT}/}"
    if [[ "$(uname -s)" != Linux ]]; then
        podman image exists "${MIRROR_TOOLS_IMAGE:-registry.access.redhat.com/ubi9/ubi:latest}" \
            || podman pull "${MIRROR_TOOLS_IMAGE:-registry.access.redhat.com/ubi9/ubi:latest}" >/dev/null
        preg_info "oc-mirror runs in ${MIRROR_TOOLS_IMAGE:-registry.access.redhat.com/ubi9/ubi:latest} on the podman VM: $(preg_oc_mirror "$(preg_tools_dir)" version 2>/dev/null | tail -1 | cut -c1-80)"
    fi
fi

${FOR_INSIDE} || exit 0

# --- 3. The inside workstation (stop-over bundle) --------------------------------------
BUNDLE="$(preg_bundle_dir)"
IARCH="${MIRROR_INSIDE_ARCH:-amd64}"
source "${_CP4D_REPO_ROOT}/src/helpers/resolve_cpd_cli_release.sh"
SWH="${MIRROR_CPD_VERSION:-}"
if [[ -z "${SWH}" ]] && preg_in_list cpd "${MIRROR_INSTALLS:-}"; then
    SWH="$(ENV_TARGET=cpd ENV_SETUP_QUIET=1 zsh -c 'source "${_CP4D_REPO_ROOT}/env_bootstrap.sh"; print -r -- "${VERSION:-}"' 2>/dev/null || true)"
fi

for plat in ${(s:,:)MIRROR_INSIDE_PLATFORM:-linux}; do
    dest="${BUNDLE}/tools/${plat}-${IARCH}"
    mkdir -p "${dest}"
    preg_info "Tools for the inside workstation: ${plat}/${IARCH} -> ${dest#${_CP4D_REPO_ROOT}/}"
    case "${plat}" in
        linux)
            fetch "https://mirror.openshift.com/pub/openshift-v4/$(archdir "${IARCH}")/clients/ocp/${CHANNEL}/openshift-client-linux.tar.gz" "${dest}/openshift-client.tar.gz"
            fetch "https://mirror.openshift.com/pub/openshift-v4/$(archdir "${IARCH}")/clients/ocp/${CHANNEL}/oc-mirror.rhel9.tar.gz" "${dest}/oc-mirror.tar.gz"
            fetch "https://get.helm.sh/helm-${HELM_VERSION}-linux-${IARCH}.tar.gz" "${dest}/helm.tar.gz"
            cli_platform="$([[ "${IARCH}" == arm64 ]] && print -r -- arm64 || print -r -- linux)"
            pip_platform="manylinux2014_$([[ "${IARCH}" == arm64 ]] && print -r -- aarch64 || print -r -- x86_64)"
            ;;
        darwin)
            fetch "https://mirror.openshift.com/pub/openshift-v4/$(archdir "${IARCH}")/clients/ocp/${CHANNEL}/openshift-client-mac$([[ "${IARCH}" == arm64 ]] && print -rn -- -arm64).tar.gz" "${dest}/openshift-client.tar.gz"
            # oc-mirror is Linux-only: the Mac runs it in a container on its podman VM
            fetch "https://mirror.openshift.com/pub/openshift-v4/$(archdir "${IARCH}")/clients/ocp/${CHANNEL}/oc-mirror.rhel9.tar.gz" "${dest}/oc-mirror.tar.gz"
            fetch "https://get.helm.sh/helm-${HELM_VERSION}-darwin-${IARCH}.tar.gz" "${dest}/helm.tar.gz"
            _img="${MIRROR_TOOLS_IMAGE:-registry.access.redhat.com/ubi9/ubi:latest}"
            if [[ ! -s "${dest}/tools-image.tar" ]] || ${FORCE}; then
                podman pull --arch "${IARCH}" "${_img}" >/dev/null
                podman save -o "${dest}/tools-image.tar" "${_img}"
            fi
            cli_platform="darwin"
            pip_platform="macosx_11_0_$([[ "${IARCH}" == arm64 ]] && print -r -- arm64 || print -r -- x86_64)"
            ;;
        *) preg_die "MIRROR_INSIDE_PLATFORM: unknown platform '${plat}' (linux, darwin)" ;;
    esac

    if [[ -n "${SWH}" ]]; then
        if url="$(cpd_cli_resolve_release "${SWH}" "${cli_platform}" EE | awk -F'\t' '$1=="URL"{print $2}')" && [[ -n "${url}" ]]; then
            fetch "${url}" "${dest}/${url:t}"
        else
            preg_warn "No cpd-cli release found for SWH ${SWH} on ${cli_platform} - fetch it by hand."
        fi
    fi

    # Python packages the scripts import (PyYAML; Jinja2 for regenerating configs).
    pyv="${MIRROR_INSIDE_PYTHON:-3.9}"
    if preg_python -m pip --version >/dev/null 2>&1; then
        preg_python -m pip download --quiet --only-binary=:all: --platform "${pip_platform}" \
            --python-version "${pyv}" -d "${dest}/wheelhouse" pyyaml jinja2 markupsafe \
            && preg_info "Wheels for python ${pyv}: $(ls "${dest}/wheelhouse" | wc -l | tr -d ' ') files" \
            || preg_warn "pip download failed - copy PyYAML/Jinja2 wheels for python ${pyv} into ${dest}/wheelhouse by hand."
    else
        preg_warn "pip is not available to $(whence -p python3) - copy PyYAML/Jinja2 wheels for python ${pyv} into ${dest}/wheelhouse by hand."
    fi
done
preg_info "Inside-workstation tools staged under ${BUNDLE#${_CP4D_REPO_ROOT}/}/tools/"
