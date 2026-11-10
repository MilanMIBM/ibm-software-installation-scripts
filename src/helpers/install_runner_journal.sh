#!/bin/zsh
# =============================================================================
# install_runner_journal.sh - step journal for runs in an in-cluster runner pod
# -----------------------------------------------------------------------------
# Sourced by common_helpers.sh only when IR_JOURNAL_FILE is set, which only
# run-attempt.sh does. h_step_run calls ir_step_begin / ir_step_end around every
# step, so a restarted chain skips what is finished. Sub-chains use the same
# helpers, so a restart walks down to the interrupted step by itself.
#
# Journal: one tab-separated line per event, appended by whichever chain runs:
#     <time> <event> <chain path>#<step> <exit code>
#     event: begin | done | warned | failed
#
# A step with a begin and no end was interrupted. It runs again, up to
# IR_MAX_RESUMES more times, after which the run stops and waits for a person.
# =============================================================================

[[ -n "${_IR_JOURNAL_LOADED:-}" ]] && return 0
_IR_JOURNAL_LOADED=1

_ir_step_key() { REPLY="${${ZSH_ARGZERO:A}#${_CP4D_REPO_ROOT:A}/}#$1"; }

_ir_journal_add() {   # <event> <key> <exit code>
    printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" >> "${IR_JOURNAL_FILE}"
}

# Returns 1 when the step needs no run. Exits when it was interrupted too often.
ir_step_begin() {   # <step>
    local key last begins
    _ir_step_key "$1"; key="${REPLY}"
    last="$(awk -F'\t' -v k="${key}" '$3==k && $2!="begin" {s=$2} END{print s}' "${IR_JOURNAL_FILE}" 2>/dev/null)"
    if [[ "${last}" == done || ( "${last}" == warned && -z "${IR_RETRY_WARNED:-}" ) ]]; then
        echo ""
        echo "==> Already finished: ${H_STEP_LABEL[$1]} (journal: ${last})"
        return 1
    fi
    # Consecutive starts only: a real failure a person resumed from is no interruption.
    begins="$(awk -F'\t' -v k="${key}" '$3==k {if ($2=="begin") n++; else n=0} END{print n+0}' "${IR_JOURNAL_FILE}" 2>/dev/null)"
    if (( begins > ${IR_MAX_RESUMES:-3} )); then
        h_die "Step '$1' has started $(( begins )) times without finishing. Stopping for a person to look at it."
    fi
    _ir_journal_add begin "${key}" ""
}

ir_step_end() {   # <step> <exit code> <mode: stop|warn>
    local event=done
    _ir_step_key "$1"
    if (( $2 != 0 )); then
        [[ "$3" == warn ]] && event=warned || event=failed
    fi
    _ir_journal_add "${event}" "${REPLY}" "$2"
}
