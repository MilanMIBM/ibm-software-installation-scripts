#!/bin/zsh
# =============================================================================
# install_runner_fanout.sh - the questions before a multi-cluster install run (ir_fanout_*)
# -----------------------------------------------------------------------------
# A multi-cluster run (--all-clusters, --target-clusters, MCM_TARGET_CLUSTERS or
# APPLY_TO_ALL) of a chain that can run in the cluster (a RUNNER_ENTRYPOINTS script of
# src/install_runner/installs/). Each cluster's own config decides where its install
# runs: INSTALL_RUN_MODE in that cluster's cpd_vars.sh (C11). --run-mode local|cluster
# (INSTALL_RUN_MODE_OVERRIDE) overrides every target. An install on this machine runs
# in the foreground for hours, so one multi-cluster run runs at most one of them here
# (C12, user decisions Q-a2 to Q-a6, 2026-11-12):
#
#   1. The targets are listed with their mode. With more than one local target: which
#      of them run in the cluster instead, for this run only (none is an answer). Not
#      asked with --run-mode, which already set every target's mode.
#   2. Still more than one local: only the main target, the current cluster
#      (MCM_CURRENT_CLUSTER, while the mode is on), runs here. The other local targets
#      are skipped, and shown as skipped in the result table.
#   3. No main target among them: which one of them runs here.
#
# --local-cluster X (Q-b2, 2026-11-12): X, a target whose own mode is local, is the
# one that runs here in this run, the current cluster or not. Nothing is saved. Rules
# 2 and 3 do not apply then: question 1 asks about the other local targets only (the
# current cluster too), and those not switched are skipped. X cannot be switched too.
#   4. The plan, and a last confirmation. Targets that would then run at the same time
#      on one cluster under two names are refused before it.
#
# A target whose INSTALL_RUN_MODE is not a plain "local" or "cluster" (a variable, a
# command, any other word) refuses the run up front: the plan has to know where each
# install runs, and only the child could work such a value out.
#
# Every question offers cancel, which ends the whole run with nothing started. The
# flags answer them in the command, at a terminal too: --switch-to-cluster a,b (or
# none), --local-cluster NAME and --yes. With no terminal, a question that is needed
# and not answered by a flag refuses the run, naming the flags. One local target needs
# no question. No local target: the fan-out runs as it always has.
#
# Once answered, mcm_fanout launches the in-cluster targets first, without watching
# them (IR_FANOUT_PARALLEL=1, exit 76 each), then runs the one local target in the
# foreground, then prints x_install_runner.sh status --all-clusters. When every local
# target is switched, each target is watched in turn, as before.
#
# --parallel runs nothing on this machine: it only launches. So with --parallel, one
# local target is enough for question 1, and a local target left after it refuses the
# whole run, with nothing launched (drop --parallel to run one of them here).
# --local-cluster is refused with it. Once every local target is switched, every target
# is launched without watching, as --parallel does.
#
#   ir_fanout_plan <script> [args...]
#       0  a plan: _IR_PLAN_PODS (they run in the cluster, in target order),
#          _IR_PLAN_SWITCHED (those of them switched for this run), _IR_PLAN_LOCAL
#          (the one that runs here; empty when every local one was switched),
#          _IR_PLAN_SKIPPED
#       1  refused or cancelled, with the reason printed
#       2  no target runs here (or a question about the chain): the fan-out goes on
#          as before
#   ir_fanout_status    x_install_runner.sh status --all-clusters
#
# Sourced by mcm_fanout (multi_cluster_helpers.sh). Configs are read as text, never
# sourced (a config may read the keychain). The answers come from env_bootstrap.sh,
# which takes the flags out of the arguments: _IR_ARG_SWITCH, _IR_ARG_LOCAL, _IR_ARG_YES.
# Plan: .claude/plans/multi-cluster-management/in-cluster-install-addon/remaining-work.md (C12)
# =============================================================================

[[ -n "${_IR_FANOUT_LOADED:-}" ]] && return 0
_IR_FANOUT_LOADED=1
_IR_FANOUT_HELPER_DIR="${${(%):-%x}:A:h}"

(( $+functions[ir_entrypoint_install] )) || source "${_IR_FANOUT_HELPER_DIR}/install_runner_mode.sh"

# The last assignment of KEY in FILE, as text -> REPLY. 0 for a plain value (no
# variable, no command), 2 for any other value, 1 when there is none. _IR_ASSIGN_LINE:
# that assignment's line number and text ("12: INSTALL_RUN_MODE=...").
_ir_fanout_assignment() {   # <file> <key>
    emulate -L zsh
    local file="$1" key="$2" line found=1
    local -i n=0
    REPLY=""
    typeset -g _IR_ASSIGN_LINE=""
    [[ -r "${file}" ]] || return 1
    for line in "${(@f)$(<"${file}")}"; do
        (( ++n ))
        [[ "${line}" =~ "^[[:space:]]*(export[[:space:]]+)?${key}=" ]] || continue
        _IR_ASSIGN_LINE="${n}: ${${line##[[:space:]]#}%%[[:space:]]#}"
        if [[ "${line}" =~ "^[[:space:]]*(export[[:space:]]+)?${key}=[\"']?([^\"'[:space:]\$\`]*)[\"']?[[:space:]]*(#.*)?$" ]]; then
            REPLY="${match[2]}"
            found=0
        else
            REPLY=""
            found=2
        fi
    done
    return "${found}"
}

# Which config the chain loads, as env_bootstrap.sh would pick it -> REPLY: ENV_TARGET
# when it is a config name, else the module's target for this chain.
_ir_fanout_env_target() {   # <installs folder> <repo-relative chain>
    emulate -L zsh
    local dir="$1" chain="$2" id pair
    if [[ -n "${ENV_TARGET:-}" && "${ENV_TARGET}" != all && "${ENV_TARGET}" != */* ]]; then
        REPLY="${ENV_TARGET}"
        return 0
    fi
    ir_entrypoint_install "${dir}" "${chain}" || { REPLY=cpd; return 0; }
    id="${REPLY}"
    for pair in ${=$(ir_module_value "${dir}" "${id}" RUNNER_CHAIN_ENV_TARGETS)}; do
        if [[ "${pair%%=*}" == "${chain}" ]]; then
            REPLY="${pair#*=}"
            return 0
        fi
    done
    REPLY="$(ir_module_value "${dir}" "${id}" INSTALL_ENV_TARGET)"
}

# Where a target's install runs -> REPLY: local, cluster, none (the cluster has no
# config for the chain; its run is skipped as usual), or unknown (INSTALL_RUN_MODE is
# not a plain local or cluster; _IR_MODE_WHY then quotes its line). _IR_MODE_FILE: the
# cpd_vars.sh where INSTALL_RUN_MODE is set, or would be. _IR_MODE_WHY: what decided it.
_ir_fanout_target_mode() {   # <cluster> <env target>
    emulate -L zsh
    local name="$1" target="$2" root f file="" cpd rc
    typeset -g _IR_MODE_FILE="" _IR_MODE_WHY=""
    if ! root="$(mcm_cluster_root "${name}" 2>/dev/null)"; then
        REPLY=none
        return 0
    fi
    for f in "${root}"/*/"${target}"_vars.sh(N) "${root}"/cp4d_config/*/"${target}"_vars.sh(N); do
        file="${f}"
        break
    done
    cpd="${root}/cp4d_config/cpd_vars.sh"
    _IR_MODE_FILE="${cpd}"
    if [[ -z "${file}" ]]; then
        REPLY=none
        _IR_MODE_WHY="no ${target} config: skipped"
        return 0
    fi
    [[ -f "${cpd}" ]] || _IR_MODE_FILE="${file}"
    if [[ -n "${INSTALL_RUN_MODE_OVERRIDE:-}" ]]; then
        REPLY="${INSTALL_RUN_MODE_OVERRIDE}"
        _IR_MODE_WHY="--run-mode ${REPLY}"
        return 0
    fi
    # The chain's own vars file first; Control Center's sources cpd_vars.sh.
    for f in "${file}" "${cpd}"; do
        rc=0
        _ir_fanout_assignment "${f}" INSTALL_RUN_MODE || rc=$?
        (( rc == 1 )) && continue
        _IR_MODE_FILE="${f}"
        if (( rc == 0 )) && [[ "${REPLY}" == (local|cluster) ]]; then
            _IR_MODE_WHY="INSTALL_RUN_MODE"
            return 0
        fi
        # An empty value is the default, as the child reads it (ir_run_mode).
        if (( rc == 0 )) && [[ -z "${REPLY}" ]]; then
            REPLY=local
            _IR_MODE_WHY="INSTALL_RUN_MODE is empty: local"
            return 0
        fi
        REPLY=unknown
        _IR_MODE_WHY="line ${_IR_ASSIGN_LINE}"
        return 0
    done
    REPLY=local
    _IR_MODE_WHY="no INSTALL_RUN_MODE: local"
}

# Reads a pick from ANSWER -> reply = the names picked. One NAME... list, numbered from
# 1 as printed. 0 picked, 1 not understood (why printed), 3 cancel, 4 none (when MULTI).
_ir_fanout_pick() {   # <multi 0|1> <answer> <name...>
    emulate -L zsh
    local -i multi="$1" i
    local answer="${${2##[[:space:]]#}%%[[:space:]]#}" word
    local -a names=("${@:3}") words
    reply=()
    words=(${(s: :)${answer//,/ }})
    if (( ! ${#words} )); then
        if (( multi )); then _mcm_err "No answer: type numbers or names, none, or cancel."
        else _mcm_err "No answer: type a number or a name, or cancel."
        fi
        return 1
    fi
    for word in "${words[@]}"; do
        [[ "${word:l}" == (cancel|c|q|quit) ]] && return 3
    done
    if (( multi )) && [[ "${(L)answer}" == none ]]; then
        return 4
    fi
    (( multi || ${#words} == 1 )) || { _mcm_err "Pick one cluster only."; return 1; }
    for word in "${words[@]}"; do
        if [[ "${word}" == <-> ]] && (( word >= 1 && word <= ${#names} )); then
            word="${names[word]}"
        elif (( ! ${names[(Ie)${word}]} )); then
            _mcm_err "'${word}' is not one of: ${(j:, :)names} (or 1-${#names})."
            return 1
        fi
        (( ${reply[(Ie)${word}]} )) || reply+=("${word}")
    done
    return 0
}

# Asks QUESTION until it is understood, three tries -> reply. 0 picked, 3 cancel (end
# of input too), 4 none.
_ir_fanout_ask_pick() {   # <multi 0|1> <prompt> <name...>
    emulate -L zsh
    local -i tries rc
    local prompt="$2" REPLY
    for (( tries = 1; tries <= 3; tries++ )); do
        _mcm_ask "${prompt}" || { print; return 3; }
        rc=0
        _ir_fanout_pick "$1" "${REPLY}" "${@:3}" || rc=$?
        (( rc == 1 )) || return "${rc}"
    done
    return 3
}

_ir_fanout_cancelled() {
    _mcm_err "Cancelled: nothing was run on any cluster."
    return 1
}

# No terminal to ask on (a notebook, CI, a pipe): the run stops before anything starts.
_ir_fanout_no_terminal() {   # <what needs an answer>
    _mcm_err "$1 There is no terminal to ask on, so nothing was run on any cluster."
    _mcm_err "Answer it in the command:"
    _mcm_err "  --switch-to-cluster a,b   these local targets run in the cluster, for this run only (none: --switch-to-cluster none)"
    _mcm_err "  --local-cluster NAME      the one local target that runs on this machine; the other local targets are skipped unless switched"
    _mcm_err "  --yes                     start without the last confirmation"
    return 1
}

ir_fanout_plan() {   # <script> [args...]
    emulate -L zsh
    local script="$1" repo dir chain target name arg REPLY main="" here="" pinned="" text
    local -a targets locals switched skipped pods wanted reply unknown together asked
    local -A mode why file
    local -i tty=0 several=0 i rc parallel=0
    shift
    # A question about the chain runs as before, on each cluster (ir_handoff keeps it here).
    for arg in "$@"; do
        [[ "${arg}" == (--list-steps|--list_steps|-h|--help) ]] && return 2
    done
    repo="$(mcm_repo_root)" || return 2
    dir="${repo}/src/install_runner/installs"
    chain="${${script:A}#${repo:A}/}"
    _ir_fanout_env_target "${dir}" "${chain}"; target="${REPLY}"
    targets=("${_MCM_RESOLVED[@]}")
    for name in "${targets[@]}"; do
        _ir_fanout_target_mode "${name}" "${target}"
        mode[${name}]="${REPLY}" why[${name}]="${_IR_MODE_WHY}" file[${name}]="${_IR_MODE_FILE}"
        [[ "${REPLY}" == local ]] && locals+=("${name}")
        [[ "${REPLY}" == unknown ]] && unknown+=("${name}")
    done
    # Only the child could work such a value out, and the plan must know it now.
    if (( ${#unknown} )); then
        for name in "${unknown[@]}"; do
            _mcm_err "${name}: INSTALL_RUN_MODE in ${file[${name}]} is not a plain \"local\" or \"cluster\" (${why[${name}]})."
        done
        _mcm_err "A run on several clusters has to know where each install runs before anything starts. Set it to \"local\" or \"cluster\" there, or give --run-mode local|cluster for every target. Nothing was run."
        return 1
    fi
    typeset -ga _IR_PLAN_PODS=() _IR_PLAN_SWITCHED=() _IR_PLAN_SKIPPED=()
    typeset -g _IR_PLAN_LOCAL=""
    if (( ! ${#locals} )); then
        if [[ -n "${_IR_ARG_SWITCH:-}${_IR_ARG_LOCAL:-}" ]]; then
            _mcm_warn "No target runs ${script:t} on this machine: --switch-to-cluster and --local-cluster are ignored."
        fi
        return 2
    fi
    [[ -t 0 ]] && tty=1
    [[ "${IR_FANOUT_PARALLEL:-}" == 1 ]] && parallel=1
    (( ${#locals} > 1 )) && several=1

    # 1. The targets and where each one's install runs.
    print -r -- "[MCM] ${script:t} on ${#targets} clusters. Where each one's install runs:"
    for name in "${targets[@]}"; do
        text="${why[${name}]}"
        [[ "${text}" == INSTALL_RUN_MODE ]] && text="INSTALL_RUN_MODE in ${file[${name}]#${repo}/}"
        printf '[MCM]   %-20s %-8s %s\n' "${name}" "${mode[${name}]/none/-}" "${text}"
    done

    # The flags first: a wrong name stops the run before any question.
    if [[ -n "${_IR_ARG_SWITCH:-}" ]]; then
        if [[ -n "${INSTALL_RUN_MODE_OVERRIDE:-}" ]]; then
            _mcm_err "--switch-to-cluster cannot be combined with --run-mode, which sets the mode of every target. Nothing was run."
            return 1
        fi
        if [[ "${(L)_IR_ARG_SWITCH}" != none ]]; then
            for name in ${(s: :)${_IR_ARG_SWITCH//,/ }}; do
                if (( ! ${targets[(Ie)${name}]} )); then
                    _mcm_err "--switch-to-cluster: '${name}' is not a target of this run (targets: ${targets[*]}). Nothing was run."
                    return 1
                fi
                if [[ "${mode[${name}]}" != local ]]; then
                    print -r -- "[MCM] --switch-to-cluster: ${name} does not run on this machine anyway."
                    continue
                fi
                (( ${wanted[(Ie)${name}]} )) || wanted+=("${name}")
            done
        fi
    fi
    if [[ -n "${_IR_ARG_LOCAL:-}" ]] && (( ! ${targets[(Ie)${_IR_ARG_LOCAL}]} )); then
        _mcm_err "--local-cluster: '${_IR_ARG_LOCAL}' is not a target of this run (targets: ${targets[*]}). Nothing was run."
        return 1
    fi
    if [[ -n "${_IR_ARG_LOCAL:-}" ]] && (( parallel )); then
        _mcm_err "--local-cluster cannot be combined with --parallel, which runs nothing on this machine. Drop --parallel to run ${_IR_ARG_LOCAL} here once the others are launched. Nothing was run."
        return 1
    fi
    # --local-cluster X (Q-b2): a local target, by its own config or --run-mode local,
    # runs here in this run whether or not it is the current cluster. The others go to
    # question 1 (switch them, or they are skipped).
    if [[ -n "${_IR_ARG_LOCAL:-}" ]]; then
        if (( ! ${locals[(Ie)${_IR_ARG_LOCAL}]} )); then
            _mcm_err "--local-cluster: ${_IR_ARG_LOCAL} does not run on this machine in this run (${(j:, :)locals}). Nothing was run."
            return 1
        fi
        if (( ${wanted[(Ie)${_IR_ARG_LOCAL}]} )); then
            _mcm_err "--local-cluster ${_IR_ARG_LOCAL} and --switch-to-cluster ${_IR_ARG_LOCAL} contradict each other: it cannot run here and in the cluster. Nothing was run."
            return 1
        fi
        pinned="${_IR_ARG_LOCAL}"
    fi
    asked=("${(@)locals:#${pinned}}")

    # 1. More than one local target (with --parallel, any): which run in the cluster
    # instead, this run only. --switch-to-cluster answers it in the command; --run-mode
    # already set every target's mode, so there is nothing to switch (Q-a4).
    if [[ -n "${_IR_ARG_SWITCH:-}" ]]; then
        switched=("${wanted[@]}")
    elif (( ${#asked} )) && (( ${#locals} > 1 || parallel )) && [[ -z "${INSTALL_RUN_MODE_OVERRIDE:-}" ]]; then
        if (( parallel )); then
            text="--parallel runs nothing on this machine, but ${#locals} target(s) would run ${script:t} here (${(j:, :)locals})."
        elif [[ -n "${pinned}" ]]; then
            text="${pinned} runs ${script:t} on this machine (--local-cluster), and ${#asked} other target(s) would run it here too (${(j:, :)asked}): they run in the cluster for this run, or are skipped."
        else
            text="${#locals} targets would run ${script:t} on this machine (${(j:, :)locals}), and one multi-cluster run runs at most one install here."
        fi
        if (( ! tty )); then
            _ir_fanout_no_terminal "${text}"
            return 1
        fi
        if (( parallel )); then
            print -r -- "[MCM] --parallel runs nothing on this machine, but ${#locals} target(s) would run ${script:t} here."
        elif [[ -n "${pinned}" ]]; then
            print -r -- "[MCM] ${pinned} runs ${script:t} on this machine in this run (--local-cluster). The other local targets are skipped unless they run in the cluster."
        else
            print -r -- "[MCM] ${#locals} targets would run ${script:t} on this machine, but one multi-cluster run runs at most one install here."
        fi
        print -r -- "[MCM] Which of them should run in the cluster instead, for this run only?"
        i=0
        for name in "${asked[@]}"; do
            print -r -- "[MCM]   $(( ++i ))) ${name}"
        done
        print -r -- "[MCM] To switch a cluster for good, set INSTALL_RUN_MODE=\"cluster\" in its cpd_vars.sh:"
        for name in "${asked[@]}"; do
            print -r -- "[MCM]   ${name}: ${file[${name}]}"
        done
        rc=0
        _ir_fanout_ask_pick 1 "Numbers or names (comma or space separated), none, or cancel: " "${asked[@]}" || rc=$?
        case "${rc}" in
            0) switched=("${reply[@]}") ;;
            4) ;;
            *) _ir_fanout_cancelled; return 1 ;;
        esac
    fi
    locals=("${(@)locals:|switched}")
    if (( parallel && ${#locals} )); then
        _mcm_err "--parallel only launches installs in the cluster, and these targets would still run ${script:t} on this machine: ${(j:, :)locals}. Nothing was run."
        _mcm_err "Switch them to the cluster for this run (--switch-to-cluster ${(j:,:)locals}), or drop --parallel to run one of them here once the others are launched."
        return 1
    fi

    # 2 and 3. Still more than one: one runs here, the others are skipped. The main
    # target is the current cluster (Q-a3), which counts only while the mode is on.
    # --local-cluster settled it already (Q-b2): it wins over the main target.
    if (( ${#locals} > 1 )) && [[ "${MULTI_CLUSTER_MANAGEMENT:-}" == true && -n "${MCM_CURRENT_CLUSTER:-}" ]] \
        && (( ${locals[(Ie)${MCM_CURRENT_CLUSTER}]} )); then
        main="${MCM_CURRENT_CLUSTER}"
    fi
    if [[ -n "${pinned}" ]]; then
        here="${pinned}"
        if (( ${#locals} > 1 )); then
            text="${(j:, :)${(@)locals:#${pinned}}}"
            [[ -n "${main}" && "${main}" != "${pinned}" ]] && text="${text/${main}/${main} (the current cluster)}"
            print -r -- "[MCM] --local-cluster: ${pinned} runs here in this run. Skipped in this run: ${text}."
        fi
    elif (( ${#locals} > 1 )); then
        if [[ -n "${main}" ]]; then
            here="${main}"
            print -r -- "[MCM] Only the current cluster, ${main} (MCM_CURRENT_CLUSTER), runs here. Skipped in this run: ${(j:, :)${(@)locals:#${main}}}."
        elif (( ! tty )); then
            _ir_fanout_no_terminal "${#locals} targets would still run ${script:t} on this machine (${(j:, :)locals}), and none of them is the current cluster${MCM_CURRENT_CLUSTER:+ (${MCM_CURRENT_CLUSTER})}."
            return 1
        else
            print -r -- "[MCM] Still ${#locals} targets would run here, and none of them is the current cluster${MCM_CURRENT_CLUSTER:+ (${MCM_CURRENT_CLUSTER})}."
            print -r -- "[MCM] Only one runs on this machine; the others are skipped in this run. Which one?"
            i=0
            for name in "${locals[@]}"; do
                print -r -- "[MCM]   $(( ++i ))) ${name}"
            done
            rc=0
            _ir_fanout_ask_pick 0 "Number or name, or cancel: " "${locals[@]}" || rc=$?
            (( rc == 0 )) || { _ir_fanout_cancelled; return 1; }
            here="${reply[1]}"
        fi
    elif (( ${#locals} == 1 )); then
        here="${locals[1]}"
    fi
    [[ -n "${here}" ]] && skipped=("${(@)locals:#${here}}")

    for name in "${targets[@]}"; do
        [[ "${name}" == "${here}" ]] && continue
        (( ${skipped[(Ie)${name}]} )) && continue
        pods+=("${name}")
    done

    # Targets that run at the same time must be distinct clusters: the pods and the
    # local one, or with --parallel every pod. Checked before the plan is confirmed.
    if [[ -n "${here}" ]]; then
        together=("${pods[@]}" "${here}")
        _mcm_fanout_refuse_same_url "These targets run at the same time" "${together[@]}" || return 1
    elif (( parallel && ${#pods} )); then
        _mcm_fanout_refuse_same_url --parallel "${pods[@]}" || return 1
    fi

    # 4. The plan. With more than one local target to begin with, it is confirmed.
    print -r -- "[MCM] The plan:"
    if (( ${#pods} )); then
        text="${(j:, :)pods}"
        (( ${#switched} )) && text+=" (switched for this run: ${(j:, :)switched})"
        if [[ -n "${here}" ]]; then
            print -r -- "[MCM]   in the cluster, launched first and not watched: ${text}"
        elif (( parallel )); then
            print -r -- "[MCM]   in the cluster, launched one after the other and not watched (--parallel): ${text}"
        else
            print -r -- "[MCM]   in the cluster, one after the other, each watched to its end: ${text}"
        fi
    fi
    if [[ -n "${here}" ]]; then
        text=""
        (( ${#pods} )) && text=", once those are launched"
        print -r -- "[MCM]   on this machine, in the foreground${text}: ${here}"
    fi
    (( ${#skipped} )) && print -r -- "[MCM]   skipped (one install at most runs on this machine): ${(j:, :)skipped}"
    if (( ${#pods} )) && [[ -n "${here}" ]]; then
        print -r -- "[MCM]   then: scripts/install_runner/x_install_runner.sh status --all-clusters"
    fi
    if (( several )) && [[ "${_IR_ARG_YES:-0}" != 1 ]]; then
        if (( ! tty )); then
            _ir_fanout_no_terminal "This plan needs a last confirmation."
            return 1
        fi
        _mcm_ask "Start? Type y to start (anything else cancels): " || REPLY=""
        [[ "${(L)${${REPLY##[[:space:]]#}%%[[:space:]]#}}" == (y|yes) ]] || { _ir_fanout_cancelled; return 1; }
    fi
    _IR_PLAN_PODS=("${pods[@]}")
    _IR_PLAN_SWITCHED=("${switched[@]}")
    _IR_PLAN_LOCAL="${here}"
    _IR_PLAN_SKIPPED=("${skipped[@]}")
    return 0
}

# After a launch of pods and a local run: where each install stands. Run as a separate
# multi-cluster run of its own, out of this fan-out (its children would read the
# fan-out's pin), with no input.
ir_fanout_status() {
    emulate -L zsh
    local tool="scripts/install_runner/x_install_runner.sh"
    print -r -- "[MCM] Where each install stands (${tool} status --all-clusters):"
    env -u _MCM_FANOUT_CHILD -u _MCM_FANOUT_SCRIPT -u _MCM_FANOUT_NOTE -u MCM_CLUSTER -u MCM_RUN_TARGETS \
        -u IR_FANOUT_PARALLEL -u IR_STATUS_ROWS -u MCM_SCRIPT_POLICY \
        zsh "$(mcm_repo_root)/${tool}" status --all-clusters < /dev/null \
        || _mcm_warn "Could not show every cluster's status. Run: ${tool} status --all-clusters"
    return 0
}
