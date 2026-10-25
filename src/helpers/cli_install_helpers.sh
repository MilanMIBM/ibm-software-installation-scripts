#!/bin/zsh
# =============================================================================
# cli_install_helpers.sh - shared functions for the workstation CLI installers
# in src/utilities/cli_tool_utils/ (install_helm.sh, install_kubectl.sh).
# -----------------------------------------------------------------------------
# The installers need no config, so they skip env_bootstrap.sh (it would load
# configs/ and start the podman machine) and source this by path instead:
#
#     source "${REPO_ROOT}/src/helpers/cli_install_helpers.sh"
#
# Must be SOURCED. Safe to source more than once.
# =============================================================================

[[ -n "${_CLI_HELPERS_LOADED:-}" ]] && return 0
_CLI_HELPERS_LOADED=1

source "${${(%):-%x}:A:h}/common_helpers.sh"

cli_info()  { h_info "$@"; }
cli_warn()  { h_warn "$@"; }
cli_error() { h_error "$@"; }
cli_die()   { h_die "$@"; }

# OS and CPU as upstream release URLs spell them (get.helm.sh, dl.k8s.io).
cli_os() {
    case "$(uname -s)" in
        Darwin) print -r -- darwin ;;
        Linux)  print -r -- linux ;;
        MINGW*|MSYS*|UCRT*|CLANG*|CYGWIN*) print -r -- windows ;;
        *) cli_die "Unsupported OS: $(uname -s)" ;;
    esac
}

cli_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  print -r -- amd64 ;;
        arm64|aarch64) print -r -- arm64 ;;
        ppc64le)       print -r -- ppc64le ;;
        s390x)         print -r -- s390x ;;
        *) cli_die "Unsupported CPU: $(uname -m)" ;;
    esac
}

# ".exe" on Windows, "" elsewhere.
cli_exe_suffix() { [[ "$(cli_os)" == windows ]] && print -r -- .exe || true; }

# Normalises "3.18.4", "v3.18.4+g43e8b7f" or "v1.33.5-eks-1a2b" to "v3.18.4".
# Prints nothing for an empty input.
cli_semver() {
    local v="${1#v}"
    v="${v%%[+-]*}"
    [[ -z "${v}" ]] || print -r -- "v${v}"
}

# "v1.33" from "v1.33.5".
cli_minor_of() { print -r -- "${1%.*}"; }

cli_sha256() { h_sha256 "$@"; }   # <file>

# Downloads <url> to <file> (curl's progress meter shows) and checks it against
# the sha256 published at <sha256 url>, either a bare hash (dl.k8s.io) or
# "<hash>  <name>" (get.helm.sh).
cli_fetch_verified() {   # <url> <file> <sha256 url>
    local expected actual
    cli_info "Downloading $1"
    curl -fSL --retry 3 -o "$2" "$1" || cli_die "Download failed: $1"
    expected="$(curl -fsSL --retry 3 "$3" 2>/dev/null | awk '{print $1; exit}' || true)"
    [[ -n "${expected}" ]] || cli_die "No checksum at $3"
    actual="$(cli_sha256 "$2")"
    [[ "${expected}" == "${actual}" ]] \
        || cli_die "Checksum mismatch for ${2:t} (expected ${expected}, got ${actual})."
    cli_info "sha256 verified: ${actual}"
}

# y/N question; CLI_ASSUME_YES=true answers yes. Without a terminal (and
# without --yes) the answer is no.
cli_confirm() {   # <question>
    [[ "${CLI_ASSUME_YES:-false}" == true ]] && return 0
    if [[ ! -t 0 ]]; then
        cli_warn "No terminal to ask on; pass --yes to accept."
        return 1
    fi
    local answer=""
    read -r "answer?$1 [y/N] " || true
    [[ "${answer}" == ([Yy]|[Yy][Ee][Ss]) ]]
}

# Default install folder: CLI_INSTALL_DIR, else /usr/local/bin (as the oc
# installer uses), else ~/bin on Windows, where Git Bash puts it on PATH.
cli_default_dir() {
    if [[ -n "${CLI_INSTALL_DIR:-}" ]]; then
        print -r -- "${CLI_INSTALL_DIR}"
    elif [[ "$(cli_os)" == windows ]]; then
        print -r -- "${HOME}/bin"
    else
        print -r -- /usr/local/bin
    fi
}

# Copies <file> to <dir>/<name> (mode 755), replacing what is there. Uses sudo
# when <dir> is not writable by this user.
cli_install_binary() {   # <file> <dir> <name>
    local src="$1" dir="$2" name="$3"
    local -a sudo=()
    if ! { mkdir -p "${dir}" 2>/dev/null && [[ -w "${dir}" ]]; }; then
        [[ "$(cli_os)" != windows ]] && command -v sudo >/dev/null 2>&1 \
            || cli_die "${dir} is not writable. Pass --dir with a folder you own (e.g. ~/.local/bin)."
        cli_info "${dir} is not writable by $(id -un); using sudo."
        sudo=(sudo)
        "${sudo[@]}" mkdir -p "${dir}"
    fi
    "${sudo[@]}" install -m 0755 "${src}" "${dir}/${name}"
    if [[ "$(uname -s)" == Darwin ]]; then
        "${sudo[@]}" xattr -d com.apple.quarantine "${dir}/${name}" 2>/dev/null || true
    fi
}

# Warns when <dir> is not on PATH, or when another <name> comes first on PATH
# (that one is what runs).
cli_check_path() {   # <dir> <name>
    local dir="${1%/}" found
    rehash
    if (( ! ${path[(Ie)${dir}]} )); then
        cli_warn "${dir} is not on PATH. Add it, e.g. in ~/.zshrc: export PATH=\"${dir}:\$PATH\""
        return 0
    fi
    found="$(whence -p "$2" 2>/dev/null || true)"
    if [[ -n "${found}" && "${found:h:A}" != "${dir:A}" ]]; then
        cli_warn "${found} comes before ${dir}/$2 on PATH, so that one runs. Reorder PATH or remove it."
    fi
}
