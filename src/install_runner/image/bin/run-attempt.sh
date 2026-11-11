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

# The pod is always flat (plan §5.5): the workstation mapped every folder at
# staging. A pin here would point KUBECONFIG, the work dir and cpd-cli at
# per-cluster places that don't exist in the pod, so nothing may pin it: no
# multi-cluster names, and a state file of its own that says mode off, so a
# staged one can never be read.
unset MCM_CLUSTER MCM_CLUSTER_ROOT MCM_CPD_CLI_WORKSPACE MCM_CONTAINER_SUFFIX MCM_KUBECONFIG_OVERRIDE \
      MCM_TARGET_CLUSTERS MCM_RUN_TARGETS CPDCONFIG CPD_CLI_WORKSPACE
export MCM_STATE_FILE="${run}/mcm_off.sh"

cd "${IR_WORK:-/work}/snapshots/${IR_RUN_ID}" || exit 1

if [[ ! -f "${MCM_STATE_FILE}" ]]; then
    # The repo's own format (_mcm_render_state), with every default: mode off.
    ( source src/helpers/multi_cluster_helpers.sh || exit 1
      typeset -A _mcm_kv; typeset -a _mcm_unknown _mcm_raw
      _mcm_set_defaults
      _mcm_kv[MULTI_CLUSTER_MANAGEMENT]=false
      _mcm_render_state ) > "${MCM_STATE_FILE}" 2>/dev/null \
        || print -r -- 'export MULTI_CLUSTER_MANAGEMENT="false"' > "${MCM_STATE_FILE}"
    chmod 600 "${MCM_STATE_FILE}"
fi

# A staged config path is relative to the snapshot; a child that changes folder
# must still find it.
[[ "${ENV_TARGET:-}" == */* && "${ENV_TARGET}" != /* ]] && export ENV_TARGET="${PWD}/${ENV_TARGET}"

exec zsh "${IR_CHAIN}" "${IR_ARGS[@]}" </dev/null
