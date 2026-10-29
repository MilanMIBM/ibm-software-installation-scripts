#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: the mirror config only (MIRROR_CONFIG_FILE selects another file) ---
export ENV_TARGET="${MIRROR_CONFIG_FILE:-registry_mirror}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/private_registry_helpers.sh"
preg_require_config

# ==============================================================================
# CP4D patch update - 4.0, 4.1, 4.2 in order
# ------------------------------------------------------------------------------
#   ./4.x_full_cpd_patch_update.sh [--phase=mirror|save|load] [--to N] [--from N]
#                                  [--all] [--estimate] [--regenerate | --reuse-mapping]
#                                  [--bundle DIR] [--quick]
#                                  [--full] [--no-tap] [--plan-only]
#                                  [--from-step <step>] [--skip <step>[,...]] [--list-steps]
#
#   mirror  plan (probe the registry) -> copy the delta -> verify, version tags,
#           record, 3.5 --only cpd
#   save    plan (against the last save) -> write the patch bundle -> record
#   load    plan (verify the bundle, probe) -> push -> verify, record, 3.5
#   --plan-only  stop after 4.0 (report.txt shows what would be copied)
# 4.0's options (--to --from --all --estimate --regenerate --reuse-mapping --bundle --quick) and 4.2's
# (--full --no-tap) are passed on.
#   Steps: plan (4.0), copy (4.1), record (4.2). --from-step <step> resumes at
#   one (--from is 4.0's version option here), --skip leaves steps out.
# ==============================================================================

h_steps_parse --no-from "$@"
H_STEPS_USAGE="  --phase=mirror|save|load, 4.0's and 4.2's options, --plan-only  (see the script header)"
preg_parse_phase_args "${H_STEPS_ARGS[@]}"
PLAN_ARGS=() RECORD_ARGS=() PLAN_ONLY=false
set -- "${PREG_ARGS[@]}"
while (( $# )); do
    case "$1" in
        --to|--from|--bundle) PLAN_ARGS+=("$1" "${2?$1 needs a value}"); shift 2 ;;
        --all|--estimate|--quick|--regenerate|--reuse-mapping) PLAN_ARGS+=("$1"); shift ;;
        --full|--no-tap) RECORD_ARGS+=("$1"); shift ;;
        --plan-only) PLAN_ONLY=true; shift ;;
        *) preg_die "Unknown argument: $1" ;;
    esac
done
preg_resolve_registry
PHASE="$(preg_resolve_phase "${PREG_PHASE_ARG}")"
print -r -- "Phase: ${PHASE}"

step() {   # <name> <label> <script> [args...]
    local name="$1" label="$2" script="$3"
    shift 3
    h_step "${name}" true "${label}" zsh "${SCRIPT_DIR}/${script}" "$@"
}

step plan   "4.0 plan the patch update"       4.0_plan_cpd_patch_update.sh "--phase=${PHASE}" "${PLAN_ARGS[@]}"
step copy   "4.1 copy the patch delta"        4.1_mirror_cpd_patch_delta.sh "--phase=${PHASE}"
step record "4.2 verify and record the patch" 4.2_verify_and_record_cpd_patch.sh "--phase=${PHASE}" "${RECORD_ARGS[@]}"
${PLAN_ONLY} && h_steps_until plan
h_steps_plan
h_steps_run
