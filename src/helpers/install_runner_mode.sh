#!/bin/zsh
# =============================================================================
# install_runner_mode.sh - cheap answers about the in-cluster runner (ir_run_mode, ...)
# -----------------------------------------------------------------------------
# Sourced by the env load (scripts/source_env_setup.sh) and by ir_dispatch, which
# need to know whether a run moves to a pod before install_runner_helpers.sh is
# loaded. Only shell and awk here: no oc, no podman, no other helper file.
#
# Plan: .claude/plans/multi-cluster-management/in-cluster-install-addon/ (X8, X12)
# =============================================================================

# The run mode of this run -> REPLY. A one-off override (--run-mode, read by
# env_bootstrap.sh, or INSTALL_RUN_MODE_OVERRIDE) wins over INSTALL_RUN_MODE: configs
# set INSTALL_RUN_MODE and load after the caller's environment, but never set the
# override, so a stale export of the config value can never act as an override.
ir_run_mode() {
    REPLY="${INSTALL_RUN_MODE_OVERRIDE:-${INSTALL_RUN_MODE:-local}}"
}

# 0 when <repo-relative path> is a chain some install module lists in RUNNER_ENTRYPOINTS.
# Same rule as ir_install_for_chain, read with awk so nothing else has to be loaded.
ir_is_runner_entrypoint() {   # <repo root> <repo-relative path>
    emulate -L zsh
    local root="$1" chain="$2" f
    [[ -n "${chain}" ]] || return 1
    for f in "${root}"/src/install_runner/installs/*.conf(N); do
        [[ "${f:t:r}" == _template ]] && continue
        awk -F= -v want="${chain}" '
            $1 == "RUNNER_ENTRYPOINTS" {
                v = substr($0, index($0, "=") + 1); gsub(/^"|"$/, "", v)
                n = split(v, list, " ")
                for (i = 1; i <= n; i++) if (list[i] == want) found = 1
            }
            END { exit found ? 0 : 1 }' "${f}" && return 0
    done
    return 1
}

# 0 when this load is a workstation chain that hands its run to a pod: the run mode is
# cluster, this is not the pod itself, and the running script is a runner entry point.
# Such a load needs no local olm-utils container and no lease (gap X8).
ir_remote_run_load() {   # <repo root>
    emulate -L zsh
    local REPLY
    [[ -z "${IR_IN_RUNNER:-}" ]] || return 1
    ir_run_mode
    [[ "${REPLY}" == cluster ]] || return 1
    # Both sides resolved: :A follows symlinks, and the repo may sit behind one.
    ir_is_runner_entrypoint "$1" "${${ZSH_ARGZERO:A}#${1:A}/}"
}

# --parallel (plan 15.1 D3): a run that hands its install to a pod launches it and
# returns, so the clusters of a fan-out install at the same time. env_bootstrap.sh
# takes the flag and exports IR_FANOUT_PARALLEL=1; the environment may set it too.
# A script with a --parallel option of its own keeps the flag: it is that script's.
# Read the way _mcm_help_requested reads -h|--help, as a case label in its source.
ir_script_owns_parallel() {   # <script>
    [[ -f "$1" ]] && grep -qE -e '(^|[[:space:]|(])--parallel([)|]|=\*)' -- "$1" 2>/dev/null
}

# Under --parallel, a chain whose install would run here (run mode local) would block
# like a normal run. It stops before any work, for this cluster only. Other scripts and
# the pod itself are left alone: env_bootstrap.sh refuses --parallel on a script that is
# no runner entry point. 1, with the error printed, when this load must stop.
ir_parallel_mode_check() {   # <repo root>
    emulate -L zsh
    local REPLY where why
    [[ "${IR_FANOUT_PARALLEL:-}" == 1 && -z "${IR_IN_RUNNER:-}" ]] || return 0
    ir_is_runner_entrypoint "$1" "${${ZSH_ARGZERO:A}#${1:A}/}" || return 0
    ir_run_mode
    [[ "${REPLY}" == local ]] || return 0
    if [[ -n "${MCM_CLUSTER:-}" ]]; then
        where="Cluster '${MCM_CLUSTER}'"
    else
        where="${OCP_URL:-This cluster}"
    fi
    if [[ -n "${INSTALL_RUN_MODE_OVERRIDE:-}" ]]; then
        why="--run-mode local"
    else
        why="INSTALL_RUN_MODE=${INSTALL_RUN_MODE:-local}"
    fi
    print -r -- "[ERROR] --parallel only applies to installs that run in the cluster (INSTALL_RUN_MODE=cluster)." >&2
    print -r -- "[ERROR] ${where} runs ${ZSH_ARGZERO:t} on this machine (${why}): nothing was run there." >&2
    return 1
}
