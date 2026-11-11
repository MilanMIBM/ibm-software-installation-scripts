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
if [[ "${_CP4D_ENV_LOADED:-}" == "${ENV_TARGET:-all}" && "${_MCM_LOADED_CLUSTER:-}" == "${MCM_CLUSTER:-}" ]]; then
    _env_log "source_env_setup.sh already loaded in this shell (target: ${_CP4D_ENV_LOADED}) - skipping"
    unset -f _env_log _env_say
    return 0
fi

_ENV_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_env_repo="${_ENV_SETUP_DIR:h}"
# Multi-cluster mode: env_bootstrap.sh has already pinned the cluster for scripts.
# A sourced load (s_env.sh) resolves it here and always ends on one cluster.
source "${_env_repo}/src/helpers/multi_cluster_helpers.sh"
if [[ -z "${_MCM_ENV_READY:-}" ]]; then
    mcm_env_setup_no_fanout || { [[ -o interactive ]] && return 1; mcm_exit_no_trap 1; }
fi
_MCM_LOADED_CLUSTER="${MCM_CLUSTER:-}"
# Set only now: a load refused above has loaded nothing.
_env_prev="${_CP4D_ENV_LOADED:-}"
_CP4D_ENV_LOADED="${ENV_TARGET:-all}"
# All configs live in per-product subfolders of configs/ (cp4d_config/,
# confluent_platform_config/, ...). CONFIG_DIR stays the CP4D folder.
export CONFIGS_ROOT="${MCM_CLUSTER_ROOT:-$(cd "${_ENV_SETUP_DIR}/.." && pwd)/configs}"
export CONFIG_DIR="${CONFIGS_ROOT}/cp4d_config"
export CONFLUENT_CONFIG_DIR="${CONFIGS_ROOT}/confluent_platform_config"
export CONCERT_CONFIG_DIR="${CONFIGS_ROOT}/concert_config"
export DATASTAX_MC_CONFIG_DIR="${CONFIGS_ROOT}/datastax_mc_config"
export REGISTRY_MIRROR_CONFIG_DIR="${CONFIGS_ROOT}/registry_mirror_config"
export SERVICE_INSTANCE_FILE_DIR="${${MCM_CLUSTER_ROOT:+${MCM_CLUSTER_ROOT}/service_instances}:-${_ENV_SETUP_DIR}/../service_instances}"
# Ensure payload output dir exists so provisioning scripts can write into it
mkdir -p "${SERVICE_INSTANCE_FILE_DIR}"
_env_log "CONFIGS_ROOT=${CONFIGS_ROOT}"
_env_log "CONFIG_DIR=${CONFIG_DIR}"
_env_log "CONFLUENT_CONFIG_DIR=${CONFLUENT_CONFIG_DIR}"
_env_log "CONCERT_CONFIG_DIR=${CONCERT_CONFIG_DIR}"
_env_log "DATASTAX_MC_CONFIG_DIR=${DATASTAX_MC_CONFIG_DIR}"
_env_log "SERVICE_INSTANCE_FILE_DIR=${SERVICE_INSTANCE_FILE_DIR}"
unset _ENV_SETUP_DIR

_sourced=()
_env_loaded=()   # repo-relative paths, for the summary
_env_url_files=()   # "URL<TAB>file" for each file that changed OCP_URL, for the flat-load guard
# Per-instance details: <config dir>/managed-service-instances/<type>/<instance>-instance_details.sh,
# one file per service instance, written by the service-instance scripts (4.5_*, 5_*) and the
# instance manager TUI (src/helpers/common_helpers.sh h_write_instance_details). Oldest first, so
# the newest instance wins where two export the same name (as the old appended blocks did);
# files of deleted instances (a "# deleted" line) are skipped.
_source_managed_instances() {
    local dir="$1/managed-service-instances" f
    for f in "${dir}"/*/*-instance_details.sh(N.Om); do
        if grep -q '^# deleted' "$f" 2>/dev/null; then
            _env_log "deleted instance, skipping: ${f#${_env_repo}/}"
            continue
        fi
        _source_if_exists "$f"
    done
}

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
    local _env_url_before="${OCP_URL-}"
    source "$real"
    [[ "${OCP_URL-}" == "${_env_url_before}" ]] || _env_url_files+=("${OCP_URL-}"$'\t'"${real}")
}

# registry_overrides.sh next to an install's *_vars.sh is written by
# scripts/private_registry_mirroring/3_configure_cluster/3.5_point_installs_at_registry.sh
# and points that install at the private registry. Sourced right after the
# install's config so it wins; absent file = no change. The mirroring track's
# own map hooks set PREG_SKIP_REGISTRY_OVERRIDES=1 to read the original sources.
_source_registry_overrides() {
    [[ "$1" == *_vars.sh && -z "${PREG_SKIP_REGISTRY_OVERRIDES:-}" ]] || return 0
    _source_if_exists "${1:h}/registry_overrides.sh"
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
# subfolder or subfolder of cp4d_config/) or a path to a config file. Scripts normally get ENV_TARGET from
# env_bootstrap.sh, which infers it from the script's folder (cpd, confluent,
# concert, datastax_mc) unless ENV_TARGET or --env-target is given.
mcm_snapshot_exports
if [[ -n "${ENV_TARGET:-}" && "${ENV_TARGET}" != all ]]; then
    _target_file="${ENV_TARGET}"
    for _d in "${CONFIGS_ROOT}"/*(N/) "${CONFIG_DIR}"/*(N/); do
        [[ -f "${_target_file}" ]] && break
        _target_file="${_d}/${ENV_TARGET}_vars.sh"
        [[ -f "${_target_file}" ]] || _target_file="${_d}/${ENV_TARGET}"
    done

    if [[ ! -f "${_target_file}" ]]; then
        # Multi-cluster: this cluster has no config for the script's product (an
        # entitled cluster on the mirror track, Concert on a CP4D-only cluster, ...).
        # MCM_SKIP_EXIT_CODE lets a fan-out report it as skipped, not failed. A step
        # nested in a fan-out gets 1 instead: its run has already done part of the work.
        if [[ -n "${MCM_CLUSTER:-}" && "${ENV_TARGET}" != */* ]]; then
            if [[ "${MCM_SKIP_EXIT_CODE}" == 1 ]]; then
                echo "[ERROR] A step of this run needs a '${ENV_TARGET}' config, which cluster '${MCM_CLUSTER}' does not have (looked in ${CONFIGS_ROOT})." >&2
            else
                echo "[WARN] Cluster '${MCM_CLUSTER}' has no '${ENV_TARGET}' config (looked in ${CONFIGS_ROOT}) - skipped." >&2
            fi
            [[ "${ENV_TARGET}" == registry_mirror ]] && echo "[WARN] Entitled install? Nothing to mirror here. Otherwise create the mirror config with scripts/private_registry_mirroring/0_initial_setup/0.0_generate_mirror_config.sh --target-cluster ${MCM_CLUSTER}." >&2
            [[ -o interactive ]] && return 1
            mcm_exit_no_trap "${MCM_SKIP_EXIT_CODE}"
        fi
        echo "[ERROR] ENV_TARGET='${ENV_TARGET}' does not resolve to a config file." >&2
        echo "[ERROR] Tried: ${ENV_TARGET}, ${CONFIGS_ROOT}/*/${ENV_TARGET}_vars.sh, ${CONFIGS_ROOT}/*/${ENV_TARGET}" >&2
        [[ "${ENV_TARGET}" == datastax_mc ]] && echo "[ERROR] Create it with scripts/install_datastax_mc_standalone/0_initial_setup/0.0_generate_datastax_mc_config.sh --empty (or --from-cpd)" >&2
        [[ "${ENV_TARGET}" == swhub_control_center ]] && echo "[ERROR] Create it with scripts/install_cloud_pak_for_data/optional_install_swhub_control_center/0_swhub_control_center_generate_config.sh or the softwarehub_cp4d_vars_generation.py notebook." >&2
        return 1 2>/dev/null || exit 1
    fi

    _source_if_exists "${_target_file}"
    export ENV_TARGET_FILE="$(cd "$(dirname "${_target_file}")" && pwd)/$(basename "${_target_file}")"
    _source_registry_overrides "${ENV_TARGET_FILE}"

    # Companion instance-details files next to it (e.g. confluent_vars.sh ->
    # confluent_instance_details.sh, confluent_flink_instance_details.sh),
    # written by the get_instance_details scripts. Sourced when present so
    # live endpoints are available too.
    if [[ "${ENV_TARGET_FILE}" == *_vars.sh ]]; then
        for _target_details in "${ENV_TARGET_FILE%_vars.sh}"*_instance_details.sh(N); do
            _source_if_exists "${_target_details}"
        done
    fi
    _source_managed_instances "${ENV_TARGET_FILE:h}"

    unset _target_file _target_details _d
else
    _source_if_exists "${CONFIG_DIR}/cpd_vars.sh"
    _source_registry_overrides "${CONFIG_DIR}/cpd_vars.sh"
    _source_if_exists "${CONFIG_DIR}/cpd_instance_details.sh"
    _source_managed_instances "${CONFIG_DIR}"
    for _f in "${CONFIG_DIR}"/*.sh(N) "${CONFIGS_ROOT}"/*/*.sh(N); do
        # Only config files - other scripts dropped into configs/ (e.g. the
        # Turbonomic onboarding script downloaded from Concert) must not run.
        if [[ "$_f" != *_vars.sh && "$_f" != *_instance_details.sh ]]; then
            _env_log "not a config file, ignoring: ${_f#${_env_repo}/}"
            continue
        fi
        _source_if_exists "$_f"
        _source_registry_overrides "$_f"
    done
fi

# Multi-cluster fan-out: this run's config is loaded, so from here on a missing config
# in a later load or a nested step is a failure, not a skipped cluster.
if [[ -n "${_MCM_FANOUT_SCRIPT:-}" ]]; then
    export _MCM_FANOUT_SCRIPT=loaded
    MCM_SKIP_EXIT_CODE=1
fi

# One-off overrides for a single child run: the private registry mirroring track
# runs an install's own script (e.g. Concert's 1.1 mirror step) against the push
# side of the registry this way, without touching the install's config.
[[ -n "${PREG_RUN_OVERRIDES_FILE:-}" && -f "${PREG_RUN_OVERRIDES_FILE}" ]] && _source_if_exists "${PREG_RUN_OVERRIDES_FILE}"

unset _f _sourced
unset -f _source_if_exists _source_registry_overrides

# Caller overrides (set by s_env.sh KEY=VALUE args): applied after the configs
# so they win, and before the login wrapping below so OCP_URL etc. take effect.
_env_overrides=()
for _o in ${_ENV_OVERRIDES[@]:+"${_ENV_OVERRIDES[@]}"}; do
    export "${_o}"
    _env_overrides+=("${_o%%=*}")
done
unset _o
# Below the overrides, so a KEY=VALUE given for this load is forgotten on a switch too.
mcm_record_config_exports

# A flat load (no cluster pinned) must not reach a cluster that is delineated: that
# cluster is managed from configs/clusters/<name>/ for good, and one cluster never has
# two configs. Checks every URL this load set, and the final OCP_URL (an override, or a
# value the shell already had). Silent when no cluster is delineated.
if [[ -z "${MCM_CLUSTER:-}" ]]; then
    _env_conflict=0
    for _env_u in "${(@u)${_env_url_files[@]%%$'\t'*}}" "${OCP_URL:-}"; do
        mcm_flat_config_conflict "${_env_u}" "${(@)${(@M)_env_url_files:#${(b)_env_u}$'\t'*}#*$'\t'}" || { _env_conflict=1; break; }
    done
    if (( _env_conflict )); then
        # An interactive shell outlives the refusal: drop what this load exported, so
        # nothing in it points at that cluster, and let the next load run again.
        if [[ -o interactive ]]; then
            _mcm_forget_names ${=_MCM_FLAT_CONFIG_VARS:-} OCP_URL OC_LOGIN CPDM_OC_LOGIN ENV_TARGET_FILE
            unset _MCM_FLAT_CONFIG_VARS _CP4D_ENV_LOADED _MCM_LOADED_CLUSTER
            unset _env_conflict _env_u _env_url_files _oc_url _env_prev _env_repo _env_loaded _env_overrides
            unset -f _env_log _env_say
            return 1
        fi
        mcm_exit_no_trap 1
    fi
    unset _env_conflict _env_u
fi
unset _env_url_files

# ------------------------------------------------------------------------------
# Login only when needed
# ------------------------------------------------------------------------------
# Scripts run eval "${OC_LOGIN}" / eval "${CPDM_OC_LOGIN}" before touching the
# cluster. Wrap both so they skip the login when the existing session is still
# valid (token accepted by the API) and points at ${OCP_URL}; otherwise log in
# as before. CPDM_OC_LOGIN covers the local oc too. The unconditional commands
# stay available as *_FORCE.
# The wrapped strings are self-contained so they also work in child shells.
[[ -n "${MCM_CLUSTER:-}" ]] && export OLM_UTILS_CONTAINER="$(mcm_container_name "${MCM_CLUSTER}")"
export OLM_UTILS_CONTAINER="${OLM_UTILS_CONTAINER:-olm-utils-play-v4}"
# OCP_URL is unset when there is no cpd_vars.sh; treat that as empty under 'set -u'.
_oc_url="${OCP_URL:-}"; _oc_url="${_oc_url%/}"
if [[ -n "${OC_LOGIN:-}" && -n "${_oc_url}" ]]; then
    export OC_LOGIN_FORCE="${OC_LOGIN}"
    export OC_LOGIN="if oc whoami >/dev/null 2>&1 && [ \"\$(oc whoami --show-server 2>/dev/null)\" = \"${_oc_url}\" ]; then echo \"[INFO] oc already logged in to ${_oc_url} as \$(oc whoami) - skipping login\"; else ${OC_LOGIN_FORCE}; fi"
fi
if [[ -n "${CPDM_OC_LOGIN:-}" && -n "${_oc_url}" ]]; then
    export CPDM_OC_LOGIN_FORCE="${CPDM_OC_LOGIN}"
    # cpd-cli manage recreates the container (dropping its login) when its image name differs
    # from OLM_UTILS_IMAGE, e.g. after a PATCH_ID bump or a cpd-cli run without cpd_vars.sh
    # (cpd-cli then defaults to olm-utils-v4:<release>) - so only skip when the name matches.
    CPDM_OC_LOGIN="if { [ -z \"\${OLM_UTILS_IMAGE:-}\" ] || [ \"\$(podman inspect -f '{{.ImageName}}' ${OLM_UTILS_CONTAINER} 2>/dev/null)\" = \"\${OLM_UTILS_IMAGE}\" ]; } && podman exec ${OLM_UTILS_CONTAINER} oc whoami >/dev/null 2>&1 && [ \"\$(podman exec ${OLM_UTILS_CONTAINER} oc whoami --show-server 2>/dev/null)\" = \"${_oc_url}\" ]; then echo \"[INFO] cpd-cli (${OLM_UTILS_CONTAINER}) already logged in to ${_oc_url} - skipping login-to-ocp\"; else ${CPDM_OC_LOGIN_FORCE}; fi"
    # Multi-cluster mode: each probe is an exec event for the idle watcher. Logged as our own,
    # so a login check alone does not count as using the container (plan 5.7.1).
    [[ -n "${MCM_CLUSTER:-}" ]] && CPDM_OC_LOGIN="${CPDM_OC_LOGIN//podman exec ${OLM_UTILS_CONTAINER} oc whoami/$(mcm_login_probe_command) ${OLM_UTILS_CONTAINER} oc whoami}"
    # The container login does not touch the local kubeconfig, yet nearly every script that
    # logs cpd-cli in also runs local oc (directly or through helpers). Log that in too, so a
    # script run on its own never works against an expired session or another cluster.
    # Joined with ';', not '&&': zsh's errexit ignores a failure on the left of '&&', so this
    # way either failed login still stops a 'set -e' script.
    [[ -n "${OC_LOGIN:-}" ]] && CPDM_OC_LOGIN="if command -v oc >/dev/null 2>&1; then ${OC_LOGIN}; fi; ${CPDM_OC_LOGIN}"
    export CPDM_OC_LOGIN
fi

# In an in-cluster runner pod the session is the pod's own (a kubeconfig on its
# rotating service account token, written by the supervisor) and there is no
# container to log in to, so logging in means checking that session.
if [[ -n "${IR_IN_RUNNER:-}" ]]; then
    # The chain's own kubeconfig (run-attempt.sh, X17). A Control Center step on
    # another cluster points KUBECONFIG elsewhere, and the scripts' `eval
    # "${OC_LOGIN}"` that switches back to the Software Hub cluster then really does.
    if [[ -n "${IR_CHAIN_KUBECONFIG:-}" ]]; then
        export OC_LOGIN='export KUBECONFIG="${IR_CHAIN_KUBECONFIG}" K8S_AUTH_KUBECONFIG="${IR_CHAIN_KUBECONFIG}"; oc whoami >/dev/null'
    else
        export OC_LOGIN="oc whoami >/dev/null"
    fi
    export CPDM_OC_LOGIN="${OC_LOGIN}"
    export OC_LOGIN_FORCE="${OC_LOGIN}" CPDM_OC_LOGIN_FORCE="${CPDM_OC_LOGIN}"
fi

# CPD_CLI_HOME is where the binary is installed; CPD_CLI_MANAGE_WORKSPACE is the workspace root.
export CPD_CLI_HOME="$HOME/cpd-cli"
export CPD_CLI_MANAGE_WORKSPACE="${MCM_CPD_CLI_WORKSPACE:-${CPD_CLI_HOME}}"
export PATH="${CPD_CLI_HOME}:$PATH"
# Multi-cluster mode: the cpd-cli shim goes ahead of the real binary.
[[ -n "${MCM_CLUSTER:-}" ]] && mcm_activate_shim
export CPD_CLI_WORK_PATH="${CPD_CLI_MANAGE_WORKSPACE}/work"
# Keeps the regular work dir when swhcc_activate repoints CPD_CLI_WORK_PATH.
export CPD_CLI_BASE_WORK_PATH="${CPD_CLI_WORK_PATH}"
export CPD_CLI_WORK_PATH_CONTAINER="/tmp/work"
export CPD_CONFIG_PATH_CONTAINER="/cp4d_config"

# Copy cp4d_config files into the work directory so the container can read them at /tmp/work/cp4d_config/
_CONFIG_WORK_DIR="${CPD_CLI_WORK_PATH}/cp4d_config"
mkdir -p "${_CONFIG_WORK_DIR}"
# Top-level files only: subdirs (e.g. certs/) are host-side outputs and plain cp would fail on them.
_cfg_copy_ok=1
# A cluster folder (or an in-cluster runner slot of another product) may have no CP4D
# config at all (Concert-only, mirror-only), so an empty glob is fine there. The flat layout keeps its error for a missing cp4d_config.
if [[ -n "${MCM_CLUSTER:-}" || -n "${IR_IN_RUNNER:-}" ]]; then
    _cfg_files=("${CONFIG_DIR}/"*(N))
else
    _cfg_files=("${CONFIG_DIR}/"*)
fi
for _cfg_f in "${_cfg_files[@]}"; do
    [ -f "${_cfg_f}" ] || continue
    cp "${_cfg_f}" "${_CONFIG_WORK_DIR}/" 2>/dev/null || _cfg_copy_ok=0
done
unset _cfg_f _cfg_files
if [ "${_cfg_copy_ok}" = 1 ]; then
    _env_log "copied ${CONFIG_DIR#${_env_repo}/}/* -> ${_CONFIG_WORK_DIR}/"
else
    echo "[WARN] Could not copy ${CONFIG_DIR}/* -> ${_CONFIG_WORK_DIR}/ (continuing)" >&2
fi
unset _CONFIG_WORK_DIR _cfg_copy_ok

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
_env_key="${_CP4D_ENV_LOADED}|${(j:,:)_env_loaded}|${(j:,:)_env_overrides}|${_oc_url}${MCM_CLUSTER:+|${MCM_CLUSTER}}"
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
    [[ -n "${MCM_CLUSTER:-}" ]] && _env_row mcm "${MCM_CLUSTER}${_MCM_TARGET_WHY:+ (${_MCM_TARGET_WHY})}${_MCM_PIN_NOTE:+ - ${_MCM_PIN_NOTE}}"
    unset -f _env_row
    [[ -n "${_env_script}" ]] && export _CP4D_ENV_SHOWN="${_env_key}"
fi

# Multi-cluster mode: containers follow the target (plan 5.7). Never fails the load.
[[ -z "${MCM_CLUSTER:-}" ]] || mcm_sync_containers

unset _f _oc_url _env_prev _env_repo _env_loaded _env_overrides _env_script _env_key _CP4D_ENV_TARGET_WHY
unset -f _env_log _env_say
