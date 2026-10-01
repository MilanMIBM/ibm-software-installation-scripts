#!/bin/zsh
# Sourceable env setup - use from any script in src/scripts/*/: source "$(dirname $0)/../source_env_setup.sh"
# Guard against double-sourcing
[[ -n "${_CP4D_ENV_LOADED:-}" ]] && return 0
_CP4D_ENV_LOADED=1

_ENV_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
export CONFIG_DIR="${_ENV_SETUP_DIR}/../../cp4d_config"
export SERVICE_INSTANCE_FILE_DIR="${_ENV_SETUP_DIR}/../../service_instances"
# Ensure payload output dir exists so provisioning scripts can write into it
mkdir -p "${SERVICE_INSTANCE_FILE_DIR}"
unset _ENV_SETUP_DIR

_sourced=()
_source_if_exists() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    local real; real="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
    for s in "${_sourced[@]:-}"; do [[ "$s" == "$real" ]] && return 0; done
    _sourced+=("$real")
    source "$real"
}

# ------------------------------------------------------------------------------
# Config loading
# ------------------------------------------------------------------------------
# Default (ENV_TARGET unset): source every cp4d_config/*.sh, CP4D first. Names
# defined in more than one file (OCP_URL, OC_LOGIN, STG_CLASS_BLOCK, ...) then
# resolve to whichever file sorted last.
#
# With ENV_TARGET set, ONLY that config is sourced:
#
#     ENV_TARGET=confluent source .../source_env_setup.sh
#
# so a script targeting a different cluster gets exactly the values in its own
# config, with nothing from cpd_vars.sh able to override them. ENV_TARGET may be
# a bare name (confluent -> confluent_vars.sh) or a path to a config file.
if [[ -n "${ENV_TARGET:-}" ]]; then
    _target_file="${ENV_TARGET}"
    [[ -f "${_target_file}" ]] || _target_file="${CONFIG_DIR}/${ENV_TARGET}_vars.sh"
    [[ -f "${_target_file}" ]] || _target_file="${CONFIG_DIR}/${ENV_TARGET}"

    if [[ ! -f "${_target_file}" ]]; then
        echo "[ERROR] ENV_TARGET='${ENV_TARGET}' does not resolve to a config file." >&2
        echo "[ERROR] Tried: ${ENV_TARGET}, ${CONFIG_DIR}/${ENV_TARGET}_vars.sh, ${CONFIG_DIR}/${ENV_TARGET}" >&2
        return 1 2>/dev/null || exit 1
    fi

    _source_if_exists "${_target_file}"
    export ENV_TARGET_FILE="$(cd "$(dirname "${_target_file}")" && pwd)/$(basename "${_target_file}")"

    # Companion instance-details file (e.g. confluent_vars.sh ->
    # confluent_instance_details.sh), written by the get_instance_details
    # scripts. Sourced when present so live endpoints are available too.
    _target_details="${ENV_TARGET_FILE%_vars.sh}_instance_details.sh"
    [[ "${_target_details}" != "${ENV_TARGET_FILE}" ]] && _source_if_exists "${_target_details}"

    unset _target_file _target_details
else
    _source_if_exists "${CONFIG_DIR}/cpd_vars.sh"
    _source_if_exists "${CONFIG_DIR}/cpd_instance_details.sh"
    for _f in "${CONFIG_DIR}"/*.sh; do
        _source_if_exists "$_f"
    done
fi

unset _f _sourced
unset -f _source_if_exists

export CPD_CLI_MANAGE_WORKSPACE="$HOME/cpd-cli"
export PATH="$HOME/cpd-cli:$PATH"
export CPD_CLI_WORK_PATH="$HOME/cpd-cli/work"
export CPD_CLI_WORK_PATH_CONTAINER="/tmp/work"
export CPD_CONFIG_PATH_CONTAINER="/cp4d_config"

# Copy cp4d_config files into the work directory so the container can read them at /tmp/work/cp4d_config/
_CONFIG_WORK_DIR="${CPD_CLI_WORK_PATH}/cp4d_config"
mkdir -p "${_CONFIG_WORK_DIR}"
cp "${CONFIG_DIR}/"* "${_CONFIG_WORK_DIR}/" 2>/dev/null || true
unset _CONFIG_WORK_DIR

# Override CPD_CONFIG_PATH_CONTAINER to point at the copied location inside the container
export CPD_CONFIG_PATH_CONTAINER="/tmp/work/cp4d_config"
