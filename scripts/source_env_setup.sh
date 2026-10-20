#!/bin/zsh
# Sourceable env setup - use from any script in scripts/*/: source "$(dirname $0)/../source_env_setup.sh"
# Prints a short summary to stderr (so $(...) captures stay clean): target, files
# loaded, cluster. A child script that ends up with the same env as its parent
# prints one line instead. ENV_SETUP_VERBOSE=1 adds every detail (dirs, skipped
# files, cpd-cli paths); ENV_SETUP_QUIET=1 prints nothing but warnings.
_env_say() { [[ -n "${ENV_SETUP_QUIET:-}" ]] || print -r -- "[ENV] $*" >&2; }
_env_log() { [[ -n "${ENV_SETUP_VERBOSE:-}" && -z "${ENV_SETUP_QUIET:-}" ]] && print -r -- "[ENV]   . $*" >&2; return 0; }

# Guard against double-sourcing. _CP4D_ENV_LOADED records which target was
# loaded ("all" when ENV_TARGET is unset), so sourcing again with a different
# ENV_TARGET reloads instead of being skipped.
if [[ "${_CP4D_ENV_LOADED:-}" == "${ENV_TARGET:-all}" ]]; then
    _env_log "source_env_setup.sh already loaded in this shell (target: ${_CP4D_ENV_LOADED}) - skipping"
    unset -f _env_log _env_say
    return 0
fi
_env_prev="${_CP4D_ENV_LOADED:-}"
_CP4D_ENV_LOADED="${ENV_TARGET:-all}"

_ENV_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_env_repo="${_ENV_SETUP_DIR:h}"
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
_env_loaded=()   # repo-relative paths, for the summary
_source_if_exists() {
    local f="$1"
    if [[ ! -f "$f" ]]; then
        _env_log "not found, skipping: ${f#${_env_repo}/}"
        return 0
    fi
    local real; real="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
    for s in "${_sourced[@]:-}"; do
        if [[ "$s" == "$real" ]]; then
            _env_log "already sourced, skipping: ${real#${_env_repo}/}"
            return 0
        fi
    done
    _sourced+=("$real")
    _env_loaded+=("${real#${_env_repo}/}")
    source "$real"
}

# ------------------------------------------------------------------------------
# Config loading
# ------------------------------------------------------------------------------
# ENV_TARGET unset or "all": source every configs/*/*_vars.sh and
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
# subfolder) or a path to a config file. Scripts normally get ENV_TARGET from
# env_bootstrap.sh, which infers it from the script's folder (cpd, confluent,
# concert) unless ENV_TARGET or --env-target is given.
if [[ -n "${ENV_TARGET:-}" && "${ENV_TARGET}" != all ]]; then
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

    # Companion instance-details files next to it (e.g. confluent_vars.sh ->
    # confluent_instance_details.sh, confluent_flink_instance_details.sh),
    # written by the get_instance_details scripts. Sourced when present so
    # live endpoints are available too.
    if [[ "${ENV_TARGET_FILE}" == *_vars.sh ]]; then
        for _target_details in "${ENV_TARGET_FILE%_vars.sh}"*_instance_details.sh(N); do
            _source_if_exists "${_target_details}"
        done
    fi

    unset _target_file _target_details _d
else
    _source_if_exists "${CONFIG_DIR}/cpd_vars.sh"
    _source_if_exists "${CONFIG_DIR}/cpd_instance_details.sh"
    for _f in "${CONFIG_DIR}"/*.sh(N) "${CONFIGS_ROOT}"/*/*.sh(N); do
        # Only config files - other scripts dropped into configs/ (e.g. the
        # Turbonomic onboarding script downloaded from Concert) must not run.
        if [[ "$_f" != *_vars.sh && "$_f" != *_instance_details.sh ]]; then
            _env_log "not a config file, ignoring: ${_f#${_env_repo}/}"
            continue
        fi
        _source_if_exists "$_f"
    done
fi

unset _f _sourced
unset -f _source_if_exists

# Caller overrides (set by s_env.sh KEY=VALUE args): applied after the configs
# so they win, and before the login wrapping below so OCP_URL etc. take effect.
_env_overrides=()
for _o in ${_ENV_OVERRIDES[@]:+"${_ENV_OVERRIDES[@]}"}; do
    export "${_o}"
    _env_overrides+=("${_o%%=*}")
done
unset _o

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
    export OC_LOGIN="if oc whoami >/dev/null 2>&1 && [ \"\$(oc whoami --show-server 2>/dev/null)\" = \"${_oc_url}\" ]; then echo \"[INFO] oc already logged in to ${_oc_url} as \$(oc whoami) - skipping login\"; else ${OC_LOGIN_FORCE}; fi"
fi
if [[ -n "${CPDM_OC_LOGIN:-}" && -n "${_oc_url}" ]]; then
    export CPDM_OC_LOGIN_FORCE="${CPDM_OC_LOGIN}"
    export CPDM_OC_LOGIN="if podman exec ${OLM_UTILS_CONTAINER} oc whoami >/dev/null 2>&1 && [ \"\$(podman exec ${OLM_UTILS_CONTAINER} oc whoami --show-server 2>/dev/null)\" = \"${_oc_url}\" ]; then echo \"[INFO] cpd-cli (${OLM_UTILS_CONTAINER}) already logged in to ${_oc_url} - skipping login-to-ocp\"; else ${CPDM_OC_LOGIN_FORCE}; fi"
fi

export CPD_CLI_MANAGE_WORKSPACE="$HOME/cpd-cli"
export PATH="$HOME/cpd-cli:$PATH"
export CPD_CLI_WORK_PATH="$HOME/cpd-cli/work"
export CPD_CLI_WORK_PATH_CONTAINER="/tmp/work"
export CPD_CONFIG_PATH_CONTAINER="/cp4d_config"

# Copy cp4d_config files into the work directory so the container can read them at /tmp/work/cp4d_config/
_CONFIG_WORK_DIR="${CPD_CLI_WORK_PATH}/cp4d_config"
mkdir -p "${_CONFIG_WORK_DIR}"
if cp "${CONFIG_DIR}/"* "${_CONFIG_WORK_DIR}/" 2>/dev/null; then
    _env_log "copied ${CONFIG_DIR#${_env_repo}/}/* -> ${_CONFIG_WORK_DIR}/"
else
    echo "[WARN] Could not copy ${CONFIG_DIR}/* -> ${_CONFIG_WORK_DIR}/ (continuing)" >&2
fi
unset _CONFIG_WORK_DIR

# Override CPD_CONFIG_PATH_CONTAINER to point at the copied location inside the container
export CPD_CONFIG_PATH_CONTAINER="/tmp/work/cp4d_config"
_env_log "CPD_CLI_MANAGE_WORKSPACE=${CPD_CLI_MANAGE_WORKSPACE}"
_env_log "CPD_CLI_WORK_PATH=${CPD_CLI_WORK_PATH}"
_env_log "CPD_CONFIG_PATH_CONTAINER=${CPD_CONFIG_PATH_CONTAINER}"

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
#   [ENV] 2.0_preliminary_setup.sh
#   [ENV]   target   cpd (script folder scripts/install_cloud_pak_for_data/)
#   [ENV]   loaded   configs/cp4d_config/cpd_vars.sh
#   [ENV]   cluster  https://api.example:6443
#   [ENV] 2.0.1_preliminary_project_setup.sh: same env as parent (cpd)
# _CP4D_ENV_SHOWN (exported by scripts only) lets child scripts spot the repeat.
_env_script="${ZSH_ARGZERO:t}"; [[ "${_env_script}" == *.sh ]] || _env_script=""
_env_key="${_CP4D_ENV_LOADED}|${(j:,:)_env_loaded}|${(j:,:)_env_overrides}|${_oc_url}"
if [[ -n "${_env_script}" && "${_CP4D_ENV_SHOWN:-}" == "${_env_key}" ]]; then
    _env_say "${_env_script}: same env as parent (${_CP4D_ENV_LOADED})"
else
    _env_row() { _env_say "  $(printf '%-8s' "$1") $2"; }
    _env_say "${_env_script:-env loaded}"
    _env_row target "${_CP4D_ENV_LOADED}${_CP4D_ENV_TARGET_WHY:+ (${_CP4D_ENV_TARGET_WHY})}"
    [[ -n "${_env_prev}" ]] && _env_row reload "was '${_env_prev}'; its vars not overwritten by '${_CP4D_ENV_LOADED}' are kept"
    if (( ${#_env_loaded} )); then
        _env_row loaded "${_env_loaded[1]}"
        for _f in "${(@)_env_loaded[2,-1]}"; do _env_row "" "${_f}"; done
        (( ${#_env_loaded} > 1 )) && [[ "${_CP4D_ENV_LOADED}" == all ]] && _env_row "" "(later files win where names repeat)"
    else
        _env_row loaded "nothing - no config files found"
    fi
    (( ${#_env_overrides} )) && _env_row override "${(j:, :)_env_overrides}"
    _env_row cluster "${_oc_url:-OCP_URL not set - login commands left as-is}"
    unset -f _env_row
    [[ -n "${_env_script}" ]] && export _CP4D_ENV_SHOWN="${_env_key}"
fi

unset _f _oc_url _env_prev _env_repo _env_loaded _env_overrides _env_script _env_key _CP4D_ENV_TARGET_WHY
unset -f _env_log _env_say
