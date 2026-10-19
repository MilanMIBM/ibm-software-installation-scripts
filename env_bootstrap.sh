#!/bin/zsh
# =============================================================================
# env_bootstrap.sh - universal environment loader for cp4d-installation-scripts
# -----------------------------------------------------------------------------
# Purpose:
#   Provide a single, location-independent way for any script in this repo to
#   load the shared environment (source_env_setup.sh), no matter how deeply it
#   is nested or where it is moved to.
#
# How scripts use it (one line, near the top, after SCRIPT_DIR is defined):
#
#     _b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
#
#   That snippet walks up the directory tree until it finds THIS file at the
#   repo root, then sources it. This file then locates and sources the shared
#   env (source_env_setup.sh) for you.
#
# Notes:
#   - Must be SOURCED, not executed: it exports variables into the caller.
#   - Safe to source multiple times (source_env_setup.sh guards itself via
#     _CP4D_ENV_LOADED).
#   - Loads only the config for the calling script's product (see "Which
#     config to load" below); override with ENV_TARGET or --env-target.
#   - This file lives at the repo root and is the search marker, so moving the
#     numbered step scripts around never breaks env loading.
# =============================================================================

# Resolve the directory THIS file lives in (the repo root) and export it, so
# scripts can source other shared files (e.g. scripts/operator_install_helpers.sh)
# by absolute path. Set before the loaded-guard so it is always defined.
export _CP4D_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Auto-prep: run scripts/0.0_make_executable.sh (chmod all .sh + start the
# podman machine) when it is actually needed, i.e. some .sh is not executable
# or the podman machine is not running. Done once per process tree: the
# exported _CP4D_PREP_DONE stops nested scripts from repeating the check.
if [[ -z "${_CP4D_PREP_DONE:-}" ]]; then
    export _CP4D_PREP_DONE=1
    _prep_needed=""
    if [[ -n "$(find "${_CP4D_REPO_ROOT}" -name '*.sh' -not -path '*/.venv/*' ! -perm -u+x -print -quit 2>/dev/null)" ]]; then
        _prep_needed=1
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        _pm_state="$(podman machine inspect --format '{{.State}}' 2>/dev/null || true)"
        [[ "${_pm_state}" != "running" ]] && _prep_needed=1
        unset _pm_state
    fi
    if [[ -n "${_prep_needed}" ]]; then
        echo "[INFO] Running scripts/0.0_make_executable.sh (scripts not executable or podman machine not running)"
        zsh "${_CP4D_REPO_ROOT}/scripts/0.0_make_executable.sh" \
            || echo "[WARN] 0.0_make_executable.sh failed; continuing" >&2
    fi
    unset _prep_needed
fi

# Which config to load. Precedence:
#   1. --env-target <name|path|all> (or --env-target=...) in the calling
#      script's arguments; removed from "$@" before the script parses them.
#   2. ENV_TARGET from the environment / caller (e.g. ENV_TARGET=confluent ./x.sh).
#   3. Inferred from the calling script's location:
#        scripts/install_cloud_pak_for_data/, src/utilities/  -> cpd
#        scripts/install_confluent_platform/                  -> confluent
#        scripts/install_ibm_concert/                         -> concert
#      Anything else loads every config, as before.
# "all" loads every configs/*/*_vars.sh. The inferred value is not exported, so
# a child script in another product folder still infers its own target.
_argv=()
while (( $# )); do
    case "$1" in
        --env-target)
            [[ -n "${2:-}" ]] || { echo "[ERROR] --env-target needs a config name, path or 'all'" >&2; unset _argv; return 1 2>/dev/null || exit 1; }
            export ENV_TARGET="$2"; shift 2 ;;
        --env-target=*)
            export ENV_TARGET="${1#--env-target=}"; shift ;;
        *)  _argv+=("$1"); shift ;;
    esac
done
set -- "${_argv[@]}"
unset _argv

if [[ -z "${ENV_TARGET:-}" ]]; then
    # The running script: $ZSH_ARGZERO for ./x.sh or zsh x.sh, else the caller's SCRIPT_DIR.
    _caller="${ZSH_ARGZERO:A}"
    [[ "${_caller}" == "${_CP4D_REPO_ROOT}"/* ]] || _caller="${SCRIPT_DIR:-}/"
    case "${_caller#${_CP4D_REPO_ROOT}/}" in
        scripts/install_cloud_pak_for_data/*|src/utilities/*) ENV_TARGET=cpd ;;
        scripts/install_confluent_platform/*)                 ENV_TARGET=confluent ;;
        scripts/install_ibm_concert/*)                        ENV_TARGET=concert ;;
    esac
    unset _caller
fi

# Already loaded for this ENV_TARGET? Nothing to do. (_CP4D_ENV_LOADED holds the
# loaded target, "all" when ENV_TARGET is unset; a different target reloads.)
[[ "${_CP4D_ENV_LOADED:-}" == "${ENV_TARGET:-all}" ]] && return 0

# The shared env setup lives under scripts/.
_ENV_SETUP="${_CP4D_REPO_ROOT}/scripts/source_env_setup.sh"

if [[ -f "${_ENV_SETUP}" ]]; then
    source "${_ENV_SETUP}"
else
    echo "ERROR: env_bootstrap.sh could not find scripts/source_env_setup.sh under ${_CP4D_REPO_ROOT}" >&2
    unset _ENV_SETUP
    return 1 2>/dev/null || exit 1
fi

unset _ENV_SETUP
