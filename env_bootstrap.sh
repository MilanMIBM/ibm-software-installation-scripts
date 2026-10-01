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
#   - This file lives at the repo root and is the search marker, so moving the
#     numbered step scripts around never breaks env loading.
# =============================================================================

# Resolve the directory THIS file lives in (the repo root) and export it, so
# scripts can source other shared files (e.g. scripts/operator_install_helpers.sh)
# by absolute path. Set before the loaded-guard so it is always defined.
export _CP4D_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Already loaded? Nothing to do.
[[ -n "${_CP4D_ENV_LOADED:-}" ]] && return 0

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
