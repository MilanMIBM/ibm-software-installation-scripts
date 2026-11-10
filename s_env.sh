#!/bin/zsh
# Load the env into the current shell and log in to the cluster.
#
#     source s_env.sh [TARGET] [KEY=VALUE ...] [--target-cluster NAME]
#
#   TARGET     config to load (same as ENV_TARGET): a bare name (cpd, confluent,
#              concert, datastax_mc) or a path to a *_vars.sh file. Omitted: uses ENV_TARGET
#              from the shell if set, otherwise loads every config.
#   KEY=VALUE  variables to override after the config is loaded (and before the
#              login commands are built, so e.g. OCP_URL=... is honoured).
#   --target-cluster NAME
#              load this cluster from configs/clusters/NAME/. The shell stays pinned
#              to the cluster it loads: scripts started from it run there, whatever
#              APPLY_TO_ALL or the current cluster say. Works for any delineated
#              cluster even with multi-cluster mode off (a delineated cluster never
#              goes back to the flat layout). Without the flag the state file
#              decides again; a sourced load never runs across clusters.
#
# Examples:
#     source s_env.sh cpd
#     source s_env.sh confluent OCP_URL=https://api.other:6443
#     source s_env.sh PROJECT_CPD_INST_OPERANDS=cpd-test
#     source s_env.sh cpd --target-cluster itz-r0247p
#
# Always reloads, even if the env was already loaded in this shell.

_s_env_target=""
_s_env_cluster=""
_s_env_want_cluster=""
_ENV_OVERRIDES=()
for _a in "$@"; do
    if [[ -n "${_s_env_want_cluster}" ]]; then
        _s_env_cluster="${_a}"
        _s_env_want_cluster=""
        continue
    fi
    case "${_a}" in
        --target-cluster)
            _s_env_want_cluster=1 ;;
        --target-cluster=*)
            _s_env_cluster="${_a#*=}" ;;
        --target-clusters|--target-clusters=*|--all-clusters)
            echo "[ERROR] s_env.sh loads one cluster into this shell; use --target-cluster NAME." >&2
            unset _a _s_env_target _s_env_cluster _s_env_want_cluster _ENV_OVERRIDES
            return 1 ;;
        -h|--help)
            sed -n '2,26p' "${${(%):-%x}:A}" | sed 's/^# \{0,1\}//'
            unset _a _s_env_target _s_env_cluster _s_env_want_cluster _ENV_OVERRIDES
            return 0 ;;
        *=*)
            if [[ ! "${_a%%=*}" =~ '^[A-Za-z_][A-Za-z0-9_]*$' ]]; then
                echo "[ERROR] Invalid variable name in '${_a}'" >&2
                unset _a _s_env_target _s_env_cluster _s_env_want_cluster _ENV_OVERRIDES
                return 1
            fi
            _ENV_OVERRIDES+=("${_a}") ;;
        *)
            if [[ -n "${_s_env_target}" ]]; then
                echo "[ERROR] Only one target allowed (got '${_s_env_target}' and '${_a}')" >&2
                unset _a _s_env_target _s_env_cluster _s_env_want_cluster _ENV_OVERRIDES
                return 1
            fi
            _s_env_target="${_a}" ;;
    esac
done

if [[ -n "${_s_env_want_cluster}" ]]; then
    echo "[ERROR] --target-cluster needs a cluster name" >&2
    unset _a _s_env_target _s_env_cluster _s_env_want_cluster _ENV_OVERRIDES
    return 1
fi

unset _CP4D_ENV_LOADED _MCM_ENV_READY
source "${${(%):-%x}:A:h}/src/helpers/multi_cluster_helpers.sh"
# Multi-cluster: a flag is the pin for this load. Otherwise re-resolve from the state
# file, unless the pin in the environment came from outside this shell's last load.
_s_env_prior_pin=""
if [[ -n "${_s_env_cluster}" ]]; then
    _MCM_ARG_TARGETS=("${_s_env_cluster}")
elif [[ -n "${MCM_CLUSTER:-}" && "${MCM_CLUSTER}" == "${_MCM_SHELL_PIN:-}" ]]; then
    _s_env_prior_pin="${MCM_CLUSTER}"
    unset MCM_CLUSTER
fi
# Multi-cluster: the shared podman VM may have been stopped by the idle watcher. Ahead
# of the env load, whose container sync would warn that podman is not reachable. That
# sync runs while the mode is on, and for a load of a delineated cluster when it is off.
if { mcm_is_on 2>/dev/null || mcm_is_delineated "${_s_env_cluster:-${MCM_CLUSTER:-}}"; } \
    && mcm_podman_machine_needs_prep; then
    echo "[INFO] Running scripts/0.0_make_executable.sh (podman machine not running/unresponsive)"
    zsh "${${(%):-%x}:A:h}/scripts/0.0_make_executable.sh" \
        || echo "[WARN] 0.0_make_executable.sh failed; continuing" >&2
fi
ENV_TARGET="${_s_env_target:-${ENV_TARGET:-}}" source "${${(%):-%x}:A:h}/scripts/source_env_setup.sh" || {
    [[ -n "${_s_env_prior_pin}" ]] && export MCM_CLUSTER="${_s_env_prior_pin}"
    mcm_clear_target_flags
    unset _a _s_env_target _s_env_cluster _s_env_want_cluster _s_env_prior_pin _ENV_OVERRIDES
    return 1
}
unset _a _s_env_target _s_env_cluster _s_env_want_cluster _s_env_prior_pin _ENV_OVERRIDES
mcm_clear_target_flags
_MCM_SHELL_PIN="${MCM_CLUSTER:-}"

eval "${CPDM_OC_LOGIN}"

eval "${OC_LOGIN}"
