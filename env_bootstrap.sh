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

# Multi-cluster management: which cluster this run is on (see the resolve step below).
source "${_CP4D_REPO_ROOT}/src/helpers/multi_cluster_helpers.sh"

# Auto-prep: run scripts/0.0_make_executable.sh (chmod all .sh + start the
# podman machine) when it is actually needed, i.e. some .sh is not executable
# or the podman machine is not running. Done once per process tree: the
# exported _CP4D_PREP_DONE stops nested scripts from repeating the check.
if [[ -z "${_CP4D_PREP_DONE:-}" ]]; then
    export _CP4D_PREP_DONE=1
    _prep_needed=""
    # The multi-cluster state file is data, written owner read/write only.
    if [[ -n "$(find "${_CP4D_REPO_ROOT}" -name '*.sh' -not -path '*/.venv/*' -not -path "$(mcm_state_file)" ! -perm -u+x -print -quit 2>/dev/null)" ]]; then
        _prep_needed=1
    elif mcm_podman_machine_needs_prep; then
        # Stopped, or "running" with a dead API socket (stale VM after sleep):
        # 0.0_make_executable.sh starts or bounces the machine.
        _prep_needed=1
    fi
    if [[ -n "${_prep_needed}" ]]; then
        echo "[INFO] Running scripts/0.0_make_executable.sh (scripts not executable or podman machine not running/unresponsive)"
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
#        scripts/install_cloud_pak_for_data/optional_install_swhub_control_center/,
#        src/utilities/softwarehub_utils/softwarehub_control_center/
#                                                             -> swhub_control_center
#        scripts/install_cloud_pak_for_data/, src/utilities/  -> cpd
#        src/utilities/kubecost_utils/  -> kubecost when configs/kubecost_config/
#                                          kubecost_vars.sh exists, else cpd
#        scripts/install_confluent_platform/                  -> confluent
#        scripts/install_ibm_concert/                         -> concert
#        scripts/install_datastax_mc_standalone/              -> datastax_mc
#        scripts/private_registry_mirroring/                  -> registry_mirror
#      Anything else loads every config, as before.
#
# Other flags taken out of "$@" here:
#   --target-cluster NAME, --target-clusters a,b, --all-clusters, --yes-all-clusters
#                        which clusters the run is for (multi-cluster management)
#   --run-mode local|cluster
#                        run an install here or in the cluster, for this run only
#   --parallel           installs that run in the cluster (INSTALL_RUN_MODE=cluster)
#                        are launched, not watched: the clusters of a multi-cluster
#                        run install at the same time, and the run ends with how to
#                        watch each one. Without it each cluster's install is watched
#                        to its end, one cluster at a time. Refused for a script that
#                        does not run in the cluster, or for a cluster whose config
#                        says local, and for two targets with the same URL.
# "all" loads every configs/*/*_vars.sh. The inferred value is not exported, so
# a child script in another product folder still infers its own target.
# _CP4D_ENV_TARGET_WHY says which rule picked it, for the env summary.
_CP4D_ENV_TARGET_WHY="ENV_TARGET"
# Multi-cluster flags (--target-cluster, --target-clusters, --all-clusters and
# --yes-all-clusters, which answers a destructive script's confirmation): taken out
# here too, for the resolve step below.
mcm_take_target_flags "$@" || { [[ -o interactive ]] && return 1; mcm_exit_no_trap 1; }
set -- "${_MCM_ARGV[@]}"
_argv=()
while (( $# )); do
    case "$1" in
        --env-target)
            [[ -n "${2:-}" ]] || { echo "[ERROR] --env-target needs a config name, path or 'all'" >&2; unset _argv; return 1 2>/dev/null || exit 1; }
            export ENV_TARGET="$2"; _CP4D_ENV_TARGET_WHY="--env-target"; shift 2 ;;
        --env-target=*)
            export ENV_TARGET="${1#--env-target=}"; _CP4D_ENV_TARGET_WHY="--env-target"; shift ;;
        # One run in another run mode than the config's (gap X12). Configs set
        # INSTALL_RUN_MODE and load after this, so the flag goes to a name they never set.
        # A missing or bad value stops the run here, before any fan-out: the flag is
        # never passed on to the script.
        --run-mode)
            [[ "${2:-}" == (local|cluster) ]] || { echo "[ERROR] --run-mode needs local or cluster" >&2; unset _argv; [[ -o interactive ]] && return 1; mcm_exit_no_trap 1; }
            export INSTALL_RUN_MODE_OVERRIDE="$2"; shift 2 ;;
        --run-mode=*)
            export INSTALL_RUN_MODE_OVERRIDE="${1#--run-mode=}"; shift ;;
        # --parallel (plan 15.1 D3): an install that runs in the cluster is launched and
        # not watched, so a fan-out installs its clusters at the same time. Without it a
        # fan-out watches each run to its end, one cluster at a time. Exported, so the
        # fan-out's children see it; taken out here, so the chain never does. Not in
        # mcm_take_target_flags: the OADP and mirror callers run that too, and a script
        # with a --parallel option of its own (the scale-config table's -j|--parallel N)
        # keeps the flag.
        --parallel)
            (( $+functions[ir_script_owns_parallel] )) || source "${_CP4D_REPO_ROOT}/src/helpers/install_runner_mode.sh"
            if ! ir_is_runner_entrypoint "${_CP4D_REPO_ROOT}" "${${ZSH_ARGZERO:A}#${_CP4D_REPO_ROOT:A}/}" \
                && ir_script_owns_parallel "${ZSH_ARGZERO:A}"; then
                _argv+=("$1")
            else
                export IR_FANOUT_PARALLEL=1; _ir_parallel_flag=1
            fi
            shift ;;
        *)  _argv+=("$1"); shift ;;
    esac
done
set -- "${_argv[@]}"
unset _argv
# --parallel means nothing to a script whose run never moves to a pod, or to a run told
# to stay here: stop before a fan-out runs it on every cluster. A chain whose own config
# says local stops later, for that cluster only, once the config is loaded.
if [[ -n "${_ir_parallel_flag:-}" && -z "${IR_IN_RUNNER:-}" ]]; then
    unset _ir_parallel_flag
    if ! ir_is_runner_entrypoint "${_CP4D_REPO_ROOT}" "${${ZSH_ARGZERO:A}#${_CP4D_REPO_ROOT:A}/}"; then
        echo "[ERROR] --parallel only applies to installs that run in the cluster (INSTALL_RUN_MODE=cluster), and ${ZSH_ARGZERO:t} is not one (no install module in src/install_runner/installs/ lists it)." >&2
        [[ -o interactive ]] && return 1
        mcm_exit_no_trap 1
    fi
    if [[ "${INSTALL_RUN_MODE_OVERRIDE:-}" == local ]]; then
        echo "[ERROR] --parallel only applies to installs that run in the cluster (INSTALL_RUN_MODE=cluster), not with --run-mode local." >&2
        [[ -o interactive ]] && return 1
        mcm_exit_no_trap 1
    fi
fi
unset _ir_parallel_flag
# Also checks a value from the environment, before a fan-out runs it on every cluster.
if [[ -n "${INSTALL_RUN_MODE_OVERRIDE:-}" && "${INSTALL_RUN_MODE_OVERRIDE}" != (local|cluster) ]]; then
    echo "[ERROR] The run mode must be local or cluster (--run-mode or INSTALL_RUN_MODE_OVERRIDE is '${INSTALL_RUN_MODE_OVERRIDE}')." >&2
    [[ -o interactive ]] && return 1
    mcm_exit_no_trap 1
fi

# Multi-cluster mode: resolve the target clusters (plan 5.4) before anything reads a
# per-cluster path. One target pins this process to it; several re-run the calling
# script once per cluster and never return here (mcm_fanout ends the process, after
# applying the script's policy from mcm_script_policy: allow, single-only or confirm).
# Mode off: nothing changes, unless the run names a delineated cluster (--target-cluster,
# MCM_CLUSTER), which stays per cluster for good. A failure must not fall through to the
# flat paths.
mcm_env_setup "$@" || { [[ -o interactive ]] && return 1; mcm_exit_no_trap 1; }

if [[ -z "${ENV_TARGET:-}" ]]; then
    # The running script: $ZSH_ARGZERO for ./x.sh or zsh x.sh, else the caller's SCRIPT_DIR.
    _caller="${ZSH_ARGZERO:A}"
    [[ "${_caller}" == "${_CP4D_REPO_ROOT}"/* ]] || _caller="${SCRIPT_DIR:-}/"
    _CP4D_ENV_TARGET_WHY="no target for this script's folder"
    case "${_caller#${_CP4D_REPO_ROOT}/}" in
        scripts/install_cloud_pak_for_data/optional_install_swhub_control_center/*|src/utilities/softwarehub_utils/softwarehub_control_center/*)
            ENV_TARGET=swhub_control_center; _CP4D_ENV_TARGET_WHY="Software Hub Control Center script folder" ;;
        scripts/install_cloud_pak_for_data/*) ENV_TARGET=cpd;       _CP4D_ENV_TARGET_WHY="script folder scripts/install_cloud_pak_for_data/" ;;
        # Kubecost: its own config when there is one, else the CP4D config as before.
        src/utilities/kubecost_utils/*)
            if [[ -f "${MCM_CLUSTER_ROOT:-${CONFIGS_ROOT:-${_CP4D_REPO_ROOT}/configs}}/kubecost_config/kubecost_vars.sh" ]]; then
                ENV_TARGET=kubecost; _CP4D_ENV_TARGET_WHY="script folder src/utilities/kubecost_utils/ + configs/kubecost_config/kubecost_vars.sh"
            else
                ENV_TARGET=cpd;      _CP4D_ENV_TARGET_WHY="script folder src/utilities/kubecost_utils/, no kubecost_vars.sh"
            fi ;;
        src/utilities/*)                      ENV_TARGET=cpd;       _CP4D_ENV_TARGET_WHY="script folder src/utilities/" ;;
        scripts/install_confluent_platform/*) ENV_TARGET=confluent; _CP4D_ENV_TARGET_WHY="script folder scripts/install_confluent_platform/" ;;
        scripts/install_ibm_concert/*)        ENV_TARGET=concert;   _CP4D_ENV_TARGET_WHY="script folder scripts/install_ibm_concert/" ;;
        scripts/install_datastax_mc_standalone/*) ENV_TARGET=datastax_mc; _CP4D_ENV_TARGET_WHY="script folder scripts/install_datastax_mc_standalone/" ;;
        scripts/private_registry_mirroring/*) ENV_TARGET=registry_mirror; _CP4D_ENV_TARGET_WHY="script folder scripts/private_registry_mirroring/" ;;
    esac
    unset _caller
    # A script whose target depends on which configs this run's cluster has (the
    # in-cluster runner's x_install_runner.sh) defines this hook. It runs here: after
    # the cluster is pinned, before the config is loaded. $1 is the configs folder.
    if [[ -z "${ENV_TARGET:-}" ]] && (( $+functions[env_bootstrap_target_hook] )); then
        env_bootstrap_target_hook "${MCM_CLUSTER_ROOT:-${CONFIGS_ROOT:-${_CP4D_REPO_ROOT}/configs}}"
    fi
fi

# Already loaded for this ENV_TARGET? Nothing to do. (_CP4D_ENV_LOADED holds the
# loaded target, "all" when ENV_TARGET is unset; a different target reloads.)
[[ "${_CP4D_ENV_LOADED:-}" == "${ENV_TARGET:-all}" && "${_MCM_LOADED_CLUSTER:-}" == "${MCM_CLUSTER:-}" ]] && return 0

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
