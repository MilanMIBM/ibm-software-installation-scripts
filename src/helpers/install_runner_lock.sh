#!/bin/zsh
# =============================================================================
# install_runner_lock.sh - one install of each type per cluster (ir_lock_*)
# -----------------------------------------------------------------------------
# Two installs of the same type (the same install id, such as cpd with cpd) on one
# cluster would fight over the same operators, projects and cluster-wide steps. So a
# launch is refused while one runs there. Installs of different types (cpd with
# confluent) may run together. "One cluster" means the same URL key (_mcm_url_key):
# two cluster names for one URL are one cluster. Users cannot override it (user
# decision Q-a1, 2026-11-12).
#
# What each side can see, without changing anything:
#
#   a launch in the cluster (ir_preflight)
#       pod runs     every live slot on the cluster (its ir-status ConfigMap: staged,
#                    running, interrupted), from any machine. Its type is the module
#                    that lists its chain, else the module its slot name starts with.
#                    And a launch from this machine that is still on its way (image
#                    build, pod start, upload: no ir-status says staged yet), through
#                    its launch mark (ir_lock_launch_mark, below).
#       local runs   live leases of runs on this machine whose script is one of the
#                    install's entry points (multi-cluster mode only: a flat local run
#                    takes no lease).
#   a run on this machine (ir_dispatch, local mode)
#       local runs   the same leases.
#       pod runs     the launch marks of this machine, and its launch records
#                    (install_runner_slots.sh) of the same install that are not
#                    collected yet. A record says nothing of the run's state, so the
#                    cluster is asked (one oc get of that slot's ir-status): only a
#                    live run (staged, running, interrupted) refuses, and a run that
#                    has ended only gets a note. When the cluster cannot be asked, the
#                    run is refused (the state is unknown), and the message says how
#                    to clear the record. A pod launched from another machine leaves
#                    no record here and is not seen.
#
# Not covered: a flat local run (mode off) is invisible to everything, and a local
# run started through a script that is not an entry point (a wrapper) holds a lease
# no module claims. A lease or launch mark whose PID now belongs to another program is
# read as live. A launch from another machine is seen only once it is staged. Two
# launches of the same type that mark themselves at the same moment both refuse.
#
# Shell only, plus the paths of multi_cluster_helpers.sh and the launch records; oc only
# for the state of a slot this machine has a record of. No podman. Sourced by
# ir_dispatch (common_helpers.sh) and install_runner_helpers.sh.
# Plan: .claude/plans/multi-cluster-management/in-cluster-install-addon/remaining-work.md (C10)
# =============================================================================

[[ -n "${_IR_LOCK_LOADED:-}" ]] && return 0
_IR_LOCK_LOADED=1
_IR_LOCK_HELPER_DIR="${${(%):-%x}:A:h}"

(( $+functions[ir_entrypoint_install] )) || source "${_IR_LOCK_HELPER_DIR}/install_runner_mode.sh"
(( $+functions[ir_slot_records] )) || source "${_IR_LOCK_HELPER_DIR}/install_runner_slots.sh"

_ir_lock_err() { print -r -- "[ERROR] $*" >&2; }
_ir_lock_warn() { print -r -- "[WARN] $*" >&2; }

# The URL key of this run's cluster: the loaded config's OCP_URL, else the cluster
# folder's marker. Empty when neither has one.
ir_lock_url_key() {   # -> REPLY
    emulate -L zsh
    local url="${OCP_URL:-}" root
    if [[ -z "${url}" && -n "${MCM_CLUSTER:-}" ]] && root="$(mcm_cluster_root "${MCM_CLUSTER}" 2>/dev/null)"; then
        url="$(_mcm_marker_value "${root}/.cluster" OCP_URL)"
    fi
    REPLY="$(_mcm_url_key "${url}")"
}

# 0 when cluster folder NAME is this run's cluster: the same name, or a marker whose URL
# has the same key.
_ir_lock_same_cluster() {   # <name> <key>
    emulate -L zsh
    local root
    [[ -n "${MCM_CLUSTER:-}" && "$1" == "${MCM_CLUSTER}" ]] && return 0
    [[ -n "$2" ]] || return 1
    root="$(mcm_cluster_root "$1" 2>/dev/null)" || return 1
    [[ "$(_mcm_url_key "$(_mcm_marker_value "${root}/.cluster" OCP_URL)")" == "$2" ]]
}

# 0 when a record or mark of cluster folder NAME (- for a flat run) with URL is this
# run's cluster: the same cluster name, or the same URL key. KEY is this run's.
_ir_lock_same_target() {   # <name or -> <url or -> <key>
    [[ "$1" != - && "$1" == "${MCM_CLUSTER:-}" ]] && return 0
    [[ -n "$3" && "$2" != - && "$(_mcm_url_key "$2")" == "$3" ]]
}

# Runs on this machine of install <id> on this run's cluster: a live lease of another
# process whose script is one of the install's entry points. A lease holds the script
# the run was started by (mcm_take_lease). One line each, tab-separated:
#   cluster  pid  script  lease file
# This run's URL key is worked out only once there is a lease to compare.
ir_lock_local_runs() {   # <installs folder> <id>
    emulate -L zsh
    local dir="$1" id="$2" key="" file name script REPLY
    local -i keyed=0
    for file in "$(_mcm_clusters_home)"/*/.leases/<->(N.); do
        [[ "${file:t}" == "$$" ]] && continue
        kill -0 "${file:t}" 2>/dev/null || continue
        name="${file:h:h:t}"
        _mcm_name_ok "${name}" || continue
        if (( ! keyed )); then
            ir_lock_url_key; key="${REPLY}"; keyed=1
        fi
        _ir_lock_same_cluster "${name}" "${key}" || continue
        script="$(<"${file}")" 2>/dev/null || continue
        script="${script%%$'\n'*}"
        ir_entrypoint_install "${dir}" "${script}" --suffix || continue
        [[ "${REPLY}" == "${id}" ]] || continue
        print -r -- "${name}"$'\t'"${file:t}"$'\t'"${script}"$'\t'"${file}"
    done
    return 0
}

# Launches of install <id> from this machine for this run's cluster that are not
# collected yet (launch records in state starting or launched). One line each:
#   cluster (- for a flat run)  slot  state
ir_lock_recorded_runs() {   # <id>
    emulate -L zsh
    local id="$1" key="" cluster slot state url run install launched REPLY
    local -i keyed=0
    while IFS=$'\t' read -r cluster slot state url run install launched; do
        [[ -n "${slot}" && "${install}" == "${id}" && "${state}" == (starting|launched) ]] || continue
        if (( ! keyed )); then
            ir_lock_url_key; key="${REPLY}"; keyed=1
        fi
        _ir_lock_same_target "${cluster}" "${url}" "${key}" && print -r -- "${cluster}"$'\t'"${slot}"$'\t'"${state}"
    done <<< "$(ir_slot_records)"
    return 0
}

# The state of <slot>'s run as the cluster has it (the state in its ir-status
# ConfigMap) -> REPLY. 0 when read; empty when there is no ir-status (the slot is gone,
# or its pod never started). 2 when the cluster cannot be asked; REPLY then says why.
# A failed first try logs in once with OC_LOGIN: a local chain logs in anyway, and the
# token saved at launch time may have expired since.
_ir_lock_slot_state() {   # <slot>
    emulate -L zsh
    local ns="install-runner-$1" out=""
    local -i try
    for (( try = 1; try <= 2; try++ )); do
        if out="$(oc get configmap ir-status -n "${ns}" -o jsonpath='{.data.state}' 2>&1)"; then
            REPLY="${out}"
            return 0
        fi
        if [[ "${out}" == *NotFound* || "${out}" == *"not found"* ]]; then
            REPLY=""
            return 0
        fi
        (( try == 1 )) && [[ -n "${OC_LOGIN:-}" ]] || break
        { eval "${OC_LOGIN}" } >/dev/null 2>&1 || break
    done
    REPLY="${${out%%$'\n'*}:-oc gave no answer}"
    return 2
}

# The folder of this machine's launch marks, next to the flat launch records
# (~/cpd-cli/.runner_launching) -> REPLY.
ir_lock_launch_dir() {
    REPLY="$(_mcm_clusters_home)"
    REPLY="${REPLY:h}/.runner_launching"
}

# ir_handoff, from just before its preflight until the run is staged: marks this launch
# of install <id> into <slot> as on its way, in a file named after this PID. Until the
# supervisor says staged, nothing in the cluster tells a second launch (or a local run)
# of the same type that this one is building its image, starting its pod or uploading.
# The mark is written before the check, so of two launches at the same moment neither
# goes. A dead PID is a launch that has ended; ir_lock_launch_unmark removes the mark
# once the run is staged. Never fails.
ir_lock_launch_mark() {   # <id> <slot>
    emulate -L zsh
    local dir REPLY
    ir_lock_launch_dir; dir="${REPLY}"
    if ! { mkdir -p "${dir}" && print -r -- "install=$1"$'\n'"slot=$2"$'\n'"cluster=${MCM_CLUSTER:--}"$'\n'"url=${OCP_URL:--}" > "${dir}/$$" } 2>/dev/null; then
        _ir_lock_warn "Could not mark this launch in ${dir}: another launch of $1 from this machine cannot see it until it is staged."
    fi
    return 0
}

ir_lock_launch_unmark() {
    emulate -L zsh
    local REPLY
    ir_lock_launch_dir
    [[ "${REPLY}" == */.runner_launching ]] || return 0
    rm -f -- "${REPLY}/$$" 2>/dev/null
    return 0
}

# Launches of install <id> on their way from this machine, by another process, for this
# run's cluster. One line each, tab-separated:
#   cluster (- for a flat run)  slot  pid
ir_lock_launching_runs() {   # <id>
    emulate -L zsh
    local id="$1" dir key="" file line install slot cluster url REPLY
    local -i keyed=0
    ir_lock_launch_dir; dir="${REPLY}"
    for file in "${dir}"/<->(N.); do
        [[ "${file:t}" == "$$" ]] && continue
        kill -0 "${file:t}" 2>/dev/null || continue
        install="" slot="" cluster="-" url="-"
        while IFS= read -r line || [[ -n "${line}" ]]; do
            case "${line}" in
                install=*) install="${line#*=}" ;;
                slot=*)    slot="${line#*=}" ;;
                cluster=*) cluster="${line#*=}" ;;
                url=*)     url="${line#*=}" ;;
            esac
        done < "${file}" 2>/dev/null
        [[ -n "${slot}" && "${install}" == "${id}" ]] || continue
        if (( ! keyed )); then
            ir_lock_url_key; key="${REPLY}"; keyed=1
        fi
        _ir_lock_same_target "${cluster}" "${url}" "${key}" && print -r -- "${cluster}"$'\t'"${slot}"$'\t'"${file:t}"
    done
    return 0
}

# The refusal lines for launches found by ir_lock_launching_runs, on stderr.
ir_lock_explain_launching() {   # <id> <lines>
    emulate -L zsh
    local cluster slot pid tc
    while IFS=$'\t' read -r cluster slot pid; do
        [[ -n "${pid}" ]] || continue
        tc=""
        [[ "${cluster}" == - ]] || tc=" --target-cluster ${cluster}"
        _ir_lock_err "  being launched from this machine: slot ${slot} (PID ${pid}; its image, pod or upload is on its way)."
        _ir_lock_err "  Once it is staged, watch it with: scripts/install_runner/x_watch_install.sh --install $1 --slot ${slot}${tc}"
    done <<< "$2"
}

# The refusal lines for local runs found by ir_lock_local_runs, on stderr.
ir_lock_explain_local_runs() {   # <lines>
    emulate -L zsh
    local cluster pid script file
    while IFS=$'\t' read -r cluster pid script file; do
        [[ -n "${pid}" ]] || continue
        _ir_lock_err "  on this machine: ${script:t} (PID ${pid}, cluster ${cluster})."
        _ir_lock_err "  It runs in the terminal that started it, not in a slot, so there is nothing to attach to: wait for it to end."
        _ir_lock_err "  If PID ${pid} is no longer that run, its lease is stale: delete ${file}"
    done <<< "$1"
}

# ir_dispatch, run mode local: refuses a chain whose install already runs on this
# cluster: a lease of another run here, a launch on its way from here, or a launch from
# here that is not collected yet and still runs in its slot. Checked once per run: a
# chain started by another chain of the same run (2.0 from the full chain) is that
# run's, and a question about the chain (--help, --list-steps) changes nothing. 1, with
# the refusal printed, when the run must stop.
ir_lock_check_local() {   # <repo root> [chain args...]
    emulate -L zsh
    local root="$1" dir id mark label REPLY line cluster slot state tc why tool="scripts/install_runner" arg
    local -a records live unknown ended locals launching
    shift
    for arg in "$@"; do
        [[ "${arg}" == (--list-steps|--list_steps|-h|--help) ]] && return 0
    done
    dir="${root}/src/install_runner/installs"
    ir_entrypoint_install "${dir}" "${${ZSH_ARGZERO:A}#${root:A}/}" || return 0
    id="${REPLY}"
    mark="${MCM_CLUSTER:-flat}:${id}"
    [[ "${_IR_LOCK_CHECKED:-}" == "${mark}" ]] && return 0
    records=(${(f)"$(ir_lock_recorded_runs "${id}")"})
    locals=(${(f)"$(ir_lock_local_runs "${dir}" "${id}")"})
    launching=(${(f)"$(ir_lock_launching_runs "${id}")"})
    if (( ! ${#records} && ! ${#locals} && ! ${#launching} )); then
        export _IR_LOCK_CHECKED="${mark}"
        return 0
    fi
    # Hidden back-end bypass, for debugging the runner only: _IR_DEBUG_ALLOW_SAME_TYPE=true
    # runs a second install of the same type on one cluster anyway. Users have no
    # override (decision Q-a1, 2026-11-12), so it is documented nowhere else.
    if [[ "${_IR_DEBUG_ALLOW_SAME_TYPE:-}" == true ]]; then
        _ir_lock_warn "_IR_DEBUG_ALLOW_SAME_TYPE=true: running ${id} here although another ${id} install may run on this cluster."
        export _IR_LOCK_CHECKED="${mark}"
        return 0
    fi
    # A record is only bookkeeping: the cluster says whether its run still goes.
    for line in "${records[@]}"; do
        IFS=$'\t' read -r cluster slot state <<< "${line}"
        if _ir_lock_slot_state "${slot}"; then
            case "${REPLY}" in
                staged|running|interrupted) live+=("${cluster}"$'\t'"${slot}"$'\t'"${REPLY}") ;;
                *) ended+=("${cluster}"$'\t'"${slot}"$'\t'"${REPLY:-no status: the slot is gone, or its pod never started}") ;;
            esac
        else
            unknown+=("${cluster}"$'\t'"${slot}"$'\t'"${REPLY}")
        fi
    done
    for line in "${ended[@]}"; do
        IFS=$'\t' read -r cluster slot state <<< "${line}"
        tc=""
        [[ "${cluster}" == - ]] || tc=" --target-cluster ${cluster}"
        print -r -- "[INFO] Slot ${slot} (install ${id}), launched from this machine, is not running (${state}) and is not collected yet: ${tool}/x_install_runner.sh collect --install ${id} --slot ${slot}${tc}"
    done
    if (( ! ${#live} && ! ${#unknown} && ! ${#locals} && ! ${#launching} )); then
        export _IR_LOCK_CHECKED="${mark}"
        return 0
    fi
    label="$(ir_module_value "${dir}" "${id}" INSTALL_LABEL)"
    if (( ${#live} || ${#locals} || ${#launching} )); then
        _ir_lock_err "${label:-${id}} (install ${id}) already runs on this cluster${OCP_URL:+ (${OCP_URL})}. One install of each type per cluster: nothing was run."
    else
        _ir_lock_err "${label:-${id}} (install ${id}) may still run on this cluster${OCP_URL:+ (${OCP_URL})}: the state of its slot could not be read. One install of each type per cluster: nothing was run."
    fi
    for line in "${live[@]}"; do
        IFS=$'\t' read -r cluster slot state <<< "${line}"
        tc=""
        [[ "${cluster}" == - ]] || tc=" --target-cluster ${cluster}"
        _ir_lock_err "  in the cluster: slot ${slot} (${state}, launched from this machine)."
        _ir_lock_err "  Watch it with: ${tool}/x_watch_install.sh --install ${id} --slot ${slot}${tc}"
    done
    for line in "${unknown[@]}"; do
        IFS=$'\t' read -r cluster slot why <<< "${line}"
        tc=""
        [[ "${cluster}" == - ]] || tc=" --target-cluster ${cluster}"
        _ir_lock_err "  in the cluster: slot ${slot}, launched from this machine and not collected yet. Its state could not be read (${why})."
        _ir_lock_err "  Once it has ended, collect it (${tool}/x_install_runner.sh collect --install ${id} --slot ${slot}${tc}),"
        _ir_lock_err "  or tear it down (${tool}/x_install_runner.sh teardown --install ${id} --slot ${slot}${tc} --discard, or --forget instead of --discard when the cluster is gone)."
    done
    (( ${#launching} )) && ir_lock_explain_launching "${id}" "${(F)launching}"
    (( ${#locals} )) && ir_lock_explain_local_runs "${(F)locals}"
    return 1
}
