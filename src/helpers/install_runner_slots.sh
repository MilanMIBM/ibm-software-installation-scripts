#!/bin/zsh
# =============================================================================
# install_runner_slots.sh - launch records of in-cluster runs (ir_slot_record_*)
# -----------------------------------------------------------------------------
# A run handed to a pod holds no lease and leaves no local process, so the
# multi-cluster tools could not see it: remove --purge would delete the only
# config and login that reach it, and claim its credentials were gone while the
# slot's volume still holds a copy (gaps X15, X16, decision D5). Each launch from
# this workstation leaves a small record instead, readable without the cluster:
#
#   ~/cpd-cli/clusters/<cluster>/.runner_slots/<slot>   a run pinned to a cluster
#   ~/cpd-cli/.runner_slots/<slot>                      a flat run
#
# key=value lines, never sourced: url, run, install, launched, state.
# state: starting (the slot is being created), launched (the run is staged and
# going), collected (its results are home). ir_handoff writes it, ir_collect sets
# collected, ir_teardown removes it.
#
#   ir_slot_record_dir [cluster]              REPLY = the folder
#   ir_slot_record_set <cluster|""> <slot> key=value...
#   ir_slot_record_remove <cluster|""> <slot>
#   ir_slot_records [--cluster NAME | --flat | --clusters]
#       one TSV line per record: cluster slot state url run install launched.
#       cluster is "-" for a flat run, an empty value is "-". No option: all.
#   ir_slot_record_teardown_hint <cluster|-> <slot> [install]   REPLY = command
#   ir_slot_records_explain <TSV lines>       the refusal text, on stderr
#
# Sourced by install_runner_helpers.sh, multi_cluster.sh and the migration. Only
# shell here, and the paths of multi_cluster_helpers.sh: no oc, no podman.
# Plan: .claude/plans/multi-cluster-management/in-cluster-install-addon/ (§7, X15)
# =============================================================================

[[ -n "${_IR_SLOTS_LOADED:-}" ]] && return 0
_IR_SLOTS_LOADED=1
_IR_SLOTS_HELPER_DIR="${${(%):-%x}:A:h}"

(( $+functions[mcm_cpd_cli_root] )) || source "${_IR_SLOTS_HELPER_DIR}/multi_cluster_helpers.sh"

typeset -ga IR_SLOT_RECORD_KEYS=(url run install launched state)

ir_slot_record_dir() {   # [cluster] -> REPLY
    if [[ -n "${1:-}" ]]; then
        REPLY="$(mcm_cpd_cli_root "$1")" || return 1
        REPLY="${REPLY}/.runner_slots"
    else
        # Next to ~/cpd-cli/clusters, the flat layout's own cpd-cli home.
        REPLY="$(_mcm_clusters_home)"
        REPLY="${REPLY:h}/.runner_slots"
    fi
}

# Reads one record into the caller's _IR_SLOT_RECORD (keys as written).
_ir_slot_record_read() {   # <file>
    local line
    [[ -f "$1" ]] || return 0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ "${line}" == [a-z_]*=* ]] || continue
        _IR_SLOT_RECORD[${line%%=*}]="${line#*=}"
    done < "$1"
}

# Merges the given keys into the record and writes it whole, so a reader never
# sees half a file. A record is only bookkeeping: a failed write warns, never
# fails the run.
ir_slot_record_set() {   # <cluster|""> <slot> key=value...
    emulate -L zsh
    local cluster="$1" slot="$2" dir file pair key tmp
    shift 2
    local -A _IR_SLOT_RECORD
    ir_slot_record_dir "${cluster}" || return 0
    dir="${REPLY}" file="${REPLY}/${slot}"
    _ir_slot_record_read "${file}"
    for pair in "$@"; do
        # One line per value: a newline would start a key of its own.
        _IR_SLOT_RECORD[${pair%%=*}]="${${pair#*=}//[$'\n\r']/ }"
    done
    if ! ( umask 077; mkdir -p "${dir}" ) 2>/dev/null; then
        print -r -- "[WARN] Could not write the launch record in ${dir}; multi_cluster.sh cannot see this run." >&2
        return 0
    fi
    tmp="${file}.new.$$"
    {
        for key in "${IR_SLOT_RECORD_KEYS[@]}"; do
            print -r -- "${key}=${_IR_SLOT_RECORD[${key}]:-}"
        done
        # Keys a newer version wrote stay.
        for key in ${(ok)_IR_SLOT_RECORD}; do
            (( ${IR_SLOT_RECORD_KEYS[(Ie)${key}]} )) || print -r -- "${key}=${_IR_SLOT_RECORD[${key}]}"
        done
    } 2>/dev/null > "${tmp}" && mv -f "${tmp}" "${file}" 2>/dev/null \
        || { rm -f "${tmp}" 2>/dev/null; print -r -- "[WARN] Could not write the launch record ${file}." >&2; }
    return 0
}

ir_slot_record_remove() {   # <cluster|""> <slot>
    emulate -L zsh
    ir_slot_record_dir "$1" || return 0
    rm -f -- "${REPLY}/$2" 2>/dev/null || true
    # An empty folder says nothing; the next launch makes it again.
    rmdir "${REPLY}" 2>/dev/null || true
    return 0
}

_ir_slot_record_line() {   # <cluster or -> <file>
    emulate -L zsh
    local key
    local -a fields
    local -A _IR_SLOT_RECORD
    _ir_slot_record_read "$2"
    fields=("$1" "${2:t}")
    for key in state url run install launched; do
        fields+=("${_IR_SLOT_RECORD[${key}]:--}")
    done
    print -r -- "${(pj:\t:)fields}"
}

ir_slot_records() {   # [--cluster NAME | --flat | --clusters]
    emulate -L zsh
    local scope="${1:---all}" home file name
    home="$(_mcm_clusters_home)"
    if [[ "${scope}" == (--all|--flat) ]]; then
        for file in "${home:h}/.runner_slots"/*(N.); do
            [[ "${file:t}" == *.new.* ]] || _ir_slot_record_line - "${file}"
        done
    fi
    if [[ "${scope}" == (--all|--clusters) ]]; then
        for file in "${home}"/*/.runner_slots/*(N.); do
            name="${file:h:h:t}"
            _mcm_name_ok "${name}" || continue
            [[ "${file:t}" == *.new.* ]] || _ir_slot_record_line "${name}" "${file}"
        done
    fi
    if [[ "${scope}" == --cluster ]]; then
        name="${2:-}"
        [[ -n "${name}" ]] && _mcm_name_ok "${name}" || return 0
        for file in "${home}/${name}/.runner_slots"/*(N.); do
            [[ "${file:t}" == *.new.* ]] || _ir_slot_record_line "${name}" "${file}"
        done
    fi
    return 0
}

# What tears the slot down, from this checkout. A flat run's needs no cluster flag.
ir_slot_record_teardown_hint() {   # <cluster|-> <slot> [install|-] -> REPLY
    local tc="" install=""
    [[ "$1" == - ]] || tc=" --target-cluster $1"
    [[ -z "${3:-}" || "$3" == - ]] || install=" --install $3"
    REPLY="scripts/install_runner/x_install_runner.sh teardown${tc}${install} --slot $2"
    return 0
}

# The refusal text for the multi-cluster tools: each slot, then how to clear it.
# Prints to stderr; the caller exits.
ir_slot_records_explain() {   # <TSV lines from ir_slot_records>
    emulate -L zsh
    local cluster slot state url run install launched where
    print -r -- "[ERROR] Install slots launched from this machine still exist in their clusters:" >&2
    while IFS=$'\t' read -r cluster slot state url run install launched; do
        [[ -n "${slot}" ]] || continue
        where="cluster ${cluster}"
        [[ "${cluster}" == - ]] && where="flat config"
        print -r -- "[ERROR]   ${slot} (${where}, ${url}, run ${run}, ${state})" >&2
    done <<< "$1"
    print -r -- "[ERROR] Each keeps a copy of its config, with credentials, in its cluster. Tear each one down first:" >&2
    while IFS=$'\t' read -r cluster slot state url run install launched; do
        [[ -n "${slot}" ]] || continue
        ir_slot_record_teardown_hint "${cluster}" "${slot}" "${install}"
        print -r -- "[ERROR]   ${REPLY}" >&2
    done <<< "$1"
    print -r -- "[ERROR] To keep a run's results, run collect with the same options before the teardown." >&2
    print -r -- "[ERROR] A cluster that no longer exists, or cannot be reached: add --forget to the teardown. It clears only the record here:" >&2
    while IFS=$'\t' read -r cluster slot state url run install launched; do
        [[ -n "${slot}" ]] || continue
        ir_slot_record_dir "${cluster:#-}" || continue
        print -r -- "[ERROR]   ${REPLY}/${slot}" >&2
    done <<< "$1"
}
