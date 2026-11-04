#!/bin/zsh
# =============================================================================
# run-attempt.sh <run dir> - one attempt at a run's chain, inside script's PTY
# -----------------------------------------------------------------------------
# run.env (written at launch) holds the chain, its arguments and the DO_* style
# toggles the user started it with. stdin is /dev/null so a stray prompt reads
# empty instead of waiting for a keyboard nobody is at.
# =============================================================================
run="${1:?run dir}"
source "${run}/run.env"
stty rows "${IR_TTY_SIZE##*x}" cols "${IR_TTY_SIZE%%x*}" 2>/dev/null

export IR_IN_RUNNER=1 IR_RUN_DIR="${run}" IR_JOURNAL_FILE="${run}/journal.tsv"
export _CP4D_PREP_DONE=1 TERM="${TERM:-xterm-256color}"
[[ -s "${run}/retry-warned" ]] && export IR_RETRY_WARNED=1

cd "${IR_WORK:-/work}/snapshots/${IR_RUN_ID}" || exit 1
exec zsh "${IR_CHAIN}" "${IR_ARGS[@]}" </dev/null
