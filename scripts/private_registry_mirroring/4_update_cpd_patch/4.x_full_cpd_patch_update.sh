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
#                                  [--all] [--estimate] [--bundle DIR] [--quick]
#                                  [--full] [--no-tap] [--plan-only]
#
#   mirror  plan (probe the registry) -> copy the delta -> verify, version tags,
#           record, 3.5 --only cpd
#   save    plan (against the last save) -> write the patch bundle -> record
#   load    plan (verify the bundle, probe) -> push -> verify, record, 3.5
#   --plan-only  stop after 4.0 (report.txt shows what would be copied)
# 4.0's options (--to --from --all --estimate --bundle --quick) and 4.2's
# (--full --no-tap) are passed on.
# ==============================================================================

preg_parse_phase_args "$@"
PLAN_ARGS=() RECORD_ARGS=() PLAN_ONLY=false
set -- "${PREG_ARGS[@]}"
while (( $# )); do
    case "$1" in
        --to|--from|--bundle) PLAN_ARGS+=("$1" "${2?$1 needs a value}"); shift 2 ;;
        --all|--estimate|--quick) PLAN_ARGS+=("$1"); shift ;;
        --full|--no-tap) RECORD_ARGS+=("$1"); shift ;;
        --plan-only) PLAN_ONLY=true; shift ;;
        *) preg_die "Unknown argument: $1" ;;
    esac
done
preg_resolve_registry
PHASE="$(preg_resolve_phase "${PREG_PHASE_ARG}")"
print -r -- "Phase: ${PHASE}"

run() {   # <label> <script> [args...]
    local label="$1" script="$2"
    shift 2
    print -r -- ""; print -r -- "==> Running:  ${label}"
    zsh "${SCRIPT_DIR}/${script}" "$@"
}

run "4.0 plan the patch update" 4.0_plan_cpd_patch_update.sh "--phase=${PHASE}" "${PLAN_ARGS[@]}"
${PLAN_ONLY} && exit 0
run "4.1 copy the patch delta" 4.1_mirror_cpd_patch_delta.sh "--phase=${PHASE}"
run "4.2 verify and record the patch" 4.2_verify_and_record_cpd_patch.sh "--phase=${PHASE}" "${RECORD_ARGS[@]}"
