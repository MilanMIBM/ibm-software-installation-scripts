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
export PREG_SKIP_REGISTRY_OVERRIDES=1   # the hook reads cpd_vars.sh itself, not 3.5's overrides

# ==============================================================================
# 4.0 Plan a CP4D patch update (--phase=mirror|save|load, default MIRROR_PHASE)
# ------------------------------------------------------------------------------
# Works out what moving <root>/cpd from the patch it has (<from>) to another
# patch of the same release (<to>) has to copy - nothing is pushed:
#   mirror  case-download --patch_id=<to>, mirror-images writing only the
#           mapping files, then each mapping line that is not in the recorded
#           <from> mapping is probed in the registry by digest (skopeo,
#           MIRROR_CPD_PATCH_PROBE_JOBS at a time). The first update after 2.0
#           probes every line (about a minute for ~1500 lines).
#   save    the same without the registry (stop-over, internet side): the delta
#           is the <to> mapping minus the <from> one - recorded by the last
#           save, or generated once from the <from> CASE packages.
#   load    (inside) verifies the patch bundle, then probes its lines in the
#           registry, so only what is still missing is pushed.
# <to>: --to, else MIRROR_CPD_PATCH_ID, else PATCH_ID in cpd_vars.sh.
# <from>: --from (0 = no patch), else what the registry is recorded at
# (patches/current; the last save for --phase=save), else 1.0's patch_id.
# Output: registry_mirror_workspace/cpd/patches/<release>-p<to>/ (report.txt,
# delta.tsv, changed-components.tsv); 4.1 and 4.2 continue from it.
#
#   ./4.0_plan_cpd_patch_update.sh [--phase=...] [--to N] [--from N] [--all]
#                                  [--estimate] [--regenerate | --reuse-mapping]
#                                  [--bundle DIR] [--quick]
#     --all       probe every line, even those recorded for <from> (repair)
#     --estimate  also add up the delta's layer sizes at the source
#     --regenerate     run case-download + mapping again, even when the last
#                      generation for this patch and selection is recorded
#                      (patches/<release>-p<to>/mapping-p<to>.files) and reused
#     --reuse-mapping  after an interrupted plan: take the mapping files it
#                      already wrote instead of running cpd-cli again
#     --bundle    load: the patch bundle (default: the newest in
#                 MIRROR_CPD_PATCH_BUNDLE_DIR); --quick skips its checksums
# ==============================================================================

preg_parse_phase_args "$@"
preg_resolve_registry
PHASE="$(preg_resolve_phase "${PREG_PHASE_ARG}")"
export MIRROR_PHASE="${PHASE}"
preg_in_list cpd "${MIRROR_INSTALLS:-}" || preg_die "cpd is not in MIRROR_INSTALLS - nothing to update."
preg_info "Phase: ${PHASE}   push root: $(preg_push_root)   image source: $(preg_image_source)"
preg_run_hook 4_update_cpd_patch cpd plan "--phase=${PHASE}" "${PREG_ARGS[@]}" || preg_die "cpd: planning the patch update failed"
preg_info "Next: 4.1_mirror_cpd_patch_delta.sh --phase=${PHASE}"
