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

# The folders that hold install modules (<id>.conf, <id>.sh) -> reply, searched in
# this order: src/install_runner/installs, then each folder in IR_MODULE_DIRS. That
# variable is for tests only (tests/install_runner_smoke/): colon-separated, a
# relative entry is under the repo root. Unset, only the real installs exist, so a
# test module is never listed, offered or auto-detected as an install.
ir_module_dirs() {   # <repo root>
    emulate -L zsh
    local root="$1" dir
    reply=("${root}/src/install_runner/installs")
    for dir in ${(s.:.)IR_MODULE_DIRS:-}; do
        [[ "${dir}" == /* ]] || dir="${root}/${dir}"
        (( ${reply[(Ie)${dir}]} )) || reply+=("${dir}")
    done
}

# Every module's .conf file, the template left out -> reply. The first folder that
# has an id wins.
ir_module_confs() {   # <repo root>
    emulate -L zsh
    local dir f
    local -a dirs found ids
    ir_module_dirs "$1"; dirs=("${reply[@]}")
    for dir in "${dirs[@]}"; do
        for f in "${dir}"/*.conf(N); do
            [[ "${f:t:r}" == _template ]] && continue
            (( ${ids[(Ie)${f:t:r}]} )) && continue
            ids+=("${f:t:r}") found+=("${f}")
        done
    done
    reply=("${found[@]}")
}

# A module's file -> REPLY (empty, and 1, when no module folder has it).
ir_module_file() {   # <repo root> <id> <conf|sh>
    emulate -L zsh
    local dir
    local -a dirs reply
    ir_module_dirs "$1"; dirs=("${reply[@]}")
    REPLY=""
    # The conf decides where a module lives: its hooks sit next to it.
    for dir in "${dirs[@]}"; do
        if [[ -f "${dir}/$2.conf" ]]; then
            [[ -f "${dir}/$2.$3" ]] || return 1
            REPLY="${dir}/$2.$3"
            return 0
        fi
    done
    return 1
}

# 0 when <repo-relative path> is a chain some install module lists in RUNNER_ENTRYPOINTS.
# Same rule as ir_install_for_chain, read with awk so nothing else has to be loaded.
ir_is_runner_entrypoint() {   # <repo root> <repo-relative path>
    emulate -L zsh
    local root="$1" chain="$2" f
    local -a confs reply
    [[ -n "${chain}" ]] || return 1
    ir_module_confs "${root}"; confs=("${reply[@]}")
    for f in "${confs[@]}"; do
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

# The install module that lists <chain> in RUNNER_ENTRYPOINTS -> REPLY = its id, empty and
# 1 when none does. --suffix also takes a path that ends in /<entry point>: a lease holds
# the path a run was started by. Leases written before they held an absolute path hold
# it as typed, relative to wherever the run was started (./full_x.sh): with --suffix, a
# relative path whose file name is the file name of exactly one entry point of all
# modules is that entry point (their file names are unique in this repo).
# The modules searched are those of <installs folder>, then those of the test-only
# IR_MODULE_DIRS folders (_ir_installs_confs).
ir_entrypoint_install() {   # <installs folder> <chain> [--suffix]
    emulate -L zsh
    local dir="$1" chain="$2" suffix=0 f e
    local -a owners confs reply
    [[ "${3:-}" == --suffix ]] && suffix=1
    REPLY=""
    [[ -n "${chain}" ]] || return 1
    _ir_installs_confs "${dir}"; confs=("${reply[@]}")
    for f in "${confs[@]}"; do
        awk -F= -v want="${chain}" -v suffix="${suffix}" '
            $1 == "RUNNER_ENTRYPOINTS" {
                v = substr($0, index($0, "=") + 1); gsub(/^"|"$/, "", v)
                n = split(v, list, " ")
                for (i = 1; i <= n; i++) {
                    e = list[i]
                    if (want == e) found = 1
                    else if (suffix && length(want) > length(e) \
                             && substr(want, length(want) - length(e)) == "/" e) found = 1
                }
            }
            END { exit found ? 0 : 1 }' "${f}" || continue
        REPLY="${f:t:r}"
        return 0
    done
    (( suffix )) && [[ "${chain}" != /* && "${chain:t}" == *.sh ]] || return 1
    for f in "${confs[@]}"; do
        for e in ${=$(ir_module_value "${dir}" "${f:t:r}" RUNNER_ENTRYPOINTS)}; do
            [[ "${e:t}" == "${chain:t}" ]] && owners+=("${f:t:r}")
        done
    done
    (( ${#owners} == 1 )) || return 1
    REPLY="${owners[1]}"
}

# One value of an install module, read as ir_conf reads it -> stdout (empty when absent).
# The module is looked up as _ir_installs_confs finds it.
ir_module_value() {   # <installs folder> <id> <key>
    emulate -L zsh
    local f conf=""
    local -a reply
    _ir_installs_confs "$1"
    for f in "${reply[@]}"; do
        [[ "${f:t:r}" == "$2" ]] && { conf="${f}"; break; }
    done
    [[ -n "${conf}" ]] || return 0
    awk -F= -v k="$3" '$1 == k { v = substr($0, index($0, "=") + 1); gsub(/^"|"$/, "", v); print v; exit }' "${conf}"
}

# The .conf files of the modules in <installs folder>, then those of the test-only
# IR_MODULE_DIRS folders, the template left out -> reply. The same order and rule as
# ir_module_confs (the first folder that has an id wins), with <installs folder> in
# place of src/install_runner/installs; a relative IR_MODULE_DIRS entry is under the
# repo that holds <installs folder> (<repo>/src/install_runner/installs).
_ir_installs_confs() {   # <installs folder>
    emulate -L zsh
    local dir f
    local -a dirs found ids
    ir_module_dirs "${1:h:h:h}"; dirs=("$1" "${(@)reply[2,-1]}")
    for dir in "${dirs[@]}"; do
        for f in "${dir}"/*.conf(N); do
            [[ "${f:t:r}" == _template ]] && continue
            (( ${ids[(Ie)${f:t:r}]} )) && continue
            ids+=("${f:t:r}") found+=("${f}")
        done
    done
    reply=("${found[@]}")
}
