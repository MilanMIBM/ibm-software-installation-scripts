#!/bin/zsh
# Sourceable env setup - use from any script in scripts/*/: source "$(dirname $0)/../source_env_setup.sh"
# Verbose by default: progress lines go to stderr (so $(...) captures stay clean).
# Silence with ENV_SETUP_QUIET=1.
_env_log() { [[ -n "${ENV_SETUP_QUIET:-}" ]] || echo "[ENV] $*" >&2; }

# Guard against double-sourcing. _CP4D_ENV_LOADED records which target was
# loaded ("all" when ENV_TARGET is unset), so sourcing again with a different
# ENV_TARGET reloads instead of being skipped.
if [[ "${_CP4D_ENV_LOADED:-}" == "${ENV_TARGET:-all}" ]]; then
    _env_log "source_env_setup.sh already loaded in this shell (target: ${_CP4D_ENV_LOADED}) - skipping"
    unset -f _env_log
    return 0
fi
[[ -n "${_CP4D_ENV_LOADED:-}" ]] && _env_log "Previously loaded target '${_CP4D_ENV_LOADED}', reloading for '${ENV_TARGET:-all}' (vars from the previous load not overwritten here are kept)"
_CP4D_ENV_LOADED="${ENV_TARGET:-all}"
_env_log "Loading environment (source_env_setup.sh)"

_ENV_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# All configs live in per-product subfolders of configs/ (cp4d_config/,
# confluent_platform_config/, ...). CONFIG_DIR stays the CP4D folder.
export CONFIGS_ROOT="$(cd "${_ENV_SETUP_DIR}/.." && pwd)/configs"
export CONFIG_DIR="${CONFIGS_ROOT}/cp4d_config"
export CONFLUENT_CONFIG_DIR="${CONFIGS_ROOT}/confluent_platform_config"
export CONCERT_CONFIG_DIR="${CONFIGS_ROOT}/concert_config"
export SERVICE_INSTANCE_FILE_DIR="${_ENV_SETUP_DIR}/../service_instances"
# Ensure payload output dir exists so provisioning scripts can write into it
mkdir -p "${SERVICE_INSTANCE_FILE_DIR}"
_env_log "CONFIGS_ROOT=${CONFIGS_ROOT}"
_env_log "CONFIG_DIR=${CONFIG_DIR}"
_env_log "CONFLUENT_CONFIG_DIR=${CONFLUENT_CONFIG_DIR}"
_env_log "CONCERT_CONFIG_DIR=${CONCERT_CONFIG_DIR}"
_env_log "SERVICE_INSTANCE_FILE_DIR=${SERVICE_INSTANCE_FILE_DIR}"
unset _ENV_SETUP_DIR

_sourced=()
_source_if_exists() {
    local f="$1"
    if [[ ! -f "$f" ]]; then
        _env_log "  not found, skipping: $f"
        return 0
    fi
    local real; real="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
    for s in "${_sourced[@]:-}"; do
        if [[ "$s" == "$real" ]]; then
            _env_log "  already sourced, skipping: $real"
            return 0
        fi
    done
    _sourced+=("$real")
    _env_log "  sourcing: $real"
    source "$real"
}

# ------------------------------------------------------------------------------
# Config loading
# ------------------------------------------------------------------------------
# Default (ENV_TARGET unset): source every configs/*/*_vars.sh and
# configs/*/*_instance_details.sh, CP4D first. Names
# defined in more than one file (OCP_URL, OC_LOGIN, STG_CLASS_BLOCK, ...) then
# resolve to whichever file sorted last.
#
# With ENV_TARGET set, ONLY that config is sourced:
#
#     ENV_TARGET=confluent source .../source_env_setup.sh
#
# so a script targeting a different cluster gets exactly the values in its own
# config, with nothing from cpd_vars.sh able to override them. ENV_TARGET may be
# a bare name (confluent -> confluent_vars.sh, looked up in every configs/*/
# subfolder) or a path to a config file.
if [[ -n "${ENV_TARGET:-}" ]]; then
    _env_log "ENV_TARGET='${ENV_TARGET}' - sourcing only that config"
    _target_file="${ENV_TARGET}"
    for _d in "${CONFIGS_ROOT}"/*(N/); do
        [[ -f "${_target_file}" ]] && break
        _target_file="${_d}/${ENV_TARGET}_vars.sh"
        [[ -f "${_target_file}" ]] || _target_file="${_d}/${ENV_TARGET}"
    done

    if [[ ! -f "${_target_file}" ]]; then
        echo "[ERROR] ENV_TARGET='${ENV_TARGET}' does not resolve to a config file." >&2
        echo "[ERROR] Tried: ${ENV_TARGET}, ${CONFIGS_ROOT}/*/${ENV_TARGET}_vars.sh, ${CONFIGS_ROOT}/*/${ENV_TARGET}" >&2
        return 1 2>/dev/null || exit 1
    fi

    _source_if_exists "${_target_file}"
    export ENV_TARGET_FILE="$(cd "$(dirname "${_target_file}")" && pwd)/$(basename "${_target_file}")"
    _env_log "ENV_TARGET_FILE=${ENV_TARGET_FILE}"

    # Companion instance-details file (e.g. confluent_vars.sh ->
    # confluent_instance_details.sh), written by the get_instance_details
    # scripts. Sourced when present so live endpoints are available too.
    _target_details="${ENV_TARGET_FILE%_vars.sh}_instance_details.sh"
    [[ "${_target_details}" != "${ENV_TARGET_FILE}" ]] && _source_if_exists "${_target_details}"

    unset _target_file _target_details _d
else
    _env_log "ENV_TARGET unset - sourcing all configs/*/*_vars.sh and *_instance_details.sh (CP4D first)"
    _source_if_exists "${CONFIG_DIR}/cpd_vars.sh"
    _source_if_exists "${CONFIG_DIR}/cpd_instance_details.sh"
    for _f in "${CONFIG_DIR}"/*.sh(N) "${CONFIGS_ROOT}"/*/*.sh(N); do
        # Only config files - other scripts dropped into configs/ (e.g. the
        # Turbonomic onboarding script downloaded from Concert) must not run.
        if [[ "$_f" != *_vars.sh && "$_f" != *_instance_details.sh ]]; then
            _env_log "  not a config file, ignoring: $_f"
            continue
        fi
        _source_if_exists "$_f"
    done
fi

unset _f _sourced
unset -f _source_if_exists

# ------------------------------------------------------------------------------
# Login only when needed
# ------------------------------------------------------------------------------
# Scripts run eval "${OC_LOGIN}" / eval "${CPDM_OC_LOGIN}" before touching the
# cluster. Wrap both so they skip the login when the existing session is still
# valid (token accepted by the API) and points at ${OCP_URL}; otherwise log in
# as before. The unconditional commands stay available as *_FORCE.
# The wrapped strings are self-contained so they also work in child shells.
export OLM_UTILS_CONTAINER="${OLM_UTILS_CONTAINER:-olm-utils-play-v4}"
# OCP_URL is unset when there is no cpd_vars.sh; treat that as empty under 'set -u'.
_oc_url="${OCP_URL:-}"; _oc_url="${_oc_url%/}"
if [[ -n "${OC_LOGIN:-}" && -n "${_oc_url}" ]]; then
    export OC_LOGIN_FORCE="${OC_LOGIN}"
    _env_log "OC_LOGIN wrapped: skips login if oc session is valid for ${_oc_url} (OC_LOGIN_FORCE = unconditional)"
    export OC_LOGIN="if oc whoami >/dev/null 2>&1 && [ \"\$(oc whoami --show-server 2>/dev/null)\" = \"${_oc_url}\" ]; then echo \"[INFO] oc already logged in to ${_oc_url} as \$(oc whoami) - skipping login\"; else ${OC_LOGIN_FORCE}; fi"
fi
if [[ -n "${CPDM_OC_LOGIN:-}" && -n "${_oc_url}" ]]; then
    export CPDM_OC_LOGIN_FORCE="${CPDM_OC_LOGIN}"
    _env_log "CPDM_OC_LOGIN wrapped: skips login if ${OLM_UTILS_CONTAINER} session is valid for ${_oc_url} (CPDM_OC_LOGIN_FORCE = unconditional)"
    export CPDM_OC_LOGIN="if podman exec ${OLM_UTILS_CONTAINER} oc whoami >/dev/null 2>&1 && [ \"\$(podman exec ${OLM_UTILS_CONTAINER} oc whoami --show-server 2>/dev/null)\" = \"${_oc_url}\" ]; then echo \"[INFO] cpd-cli (${OLM_UTILS_CONTAINER}) already logged in to ${_oc_url} - skipping login-to-ocp\"; else ${CPDM_OC_LOGIN_FORCE}; fi"
fi
[[ -z "${_oc_url}" ]] && _env_log "OCP_URL not set - OC_LOGIN/CPDM_OC_LOGIN left unwrapped"
unset _oc_url

export CPD_CLI_MANAGE_WORKSPACE="$HOME/cpd-cli"
export PATH="$HOME/cpd-cli:$PATH"
export CPD_CLI_WORK_PATH="$HOME/cpd-cli/work"
export CPD_CLI_WORK_PATH_CONTAINER="/tmp/work"
export CPD_CONFIG_PATH_CONTAINER="/cp4d_config"

# Copy cp4d_config files into the work directory so the container can read them at /tmp/work/cp4d_config/
_CONFIG_WORK_DIR="${CPD_CLI_WORK_PATH}/cp4d_config"
mkdir -p "${_CONFIG_WORK_DIR}"
if cp "${CONFIG_DIR}/"* "${_CONFIG_WORK_DIR}/" 2>/dev/null; then
    _env_log "Copied ${CONFIG_DIR}/* -> ${_CONFIG_WORK_DIR}/"
else
    _env_log "Could not copy ${CONFIG_DIR}/* -> ${_CONFIG_WORK_DIR}/ (continuing)"
fi
unset _CONFIG_WORK_DIR

# Override CPD_CONFIG_PATH_CONTAINER to point at the copied location inside the container
export CPD_CONFIG_PATH_CONTAINER="/tmp/work/cp4d_config"
_env_log "CPD_CLI_MANAGE_WORKSPACE=${CPD_CLI_MANAGE_WORKSPACE}"
_env_log "CPD_CLI_WORK_PATH=${CPD_CLI_WORK_PATH}"
_env_log "CPD_CONFIG_PATH_CONTAINER=${CPD_CONFIG_PATH_CONTAINER}"
_env_log "Environment loaded"
unset -f _env_log
