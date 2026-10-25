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
# 4.1 Copy the patch delta (--phase=mirror|save|load, default MIRROR_PHASE)
# ------------------------------------------------------------------------------
# Copies only 4.0's delta, with oc image mirror per CASE, MIRROR_CPD_PARALLEL_JOBS
# CASEs at a time (one progress row each; manifest lists kept, so digests stay):
#   mirror  source -> <push root>/cpd
#   save    source -> the patch bundle (MIRROR_CPD_PATCH_BUNDLE_DIR/
#           cpd-<release>-p<from>-to-p<to>/): images/<case>/, plus the CASE
#           versions the patch adds, its patch metadata, the plan, checksums
#   load    the bundle -> <push root>/cpd; the CASE packages and the patch
#           metadata go into cpd-cli's work dir (the install's offline
#           case-download needs them)
# A tag the patch moves (same tag, new digest) first keeps its old digest as
# <tag>-p<from>, so the previous patch stays complete. Re-running is safe:
# images already copied are skipped.
#
#   ./4.1_mirror_cpd_patch_delta.sh [--phase=...]
# ==============================================================================

preg_parse_phase_args "$@"
(( ${#PREG_ARGS} == 0 )) || preg_die "Unknown argument: ${PREG_ARGS[1]}"
preg_resolve_registry
PHASE="$(preg_resolve_phase "${PREG_PHASE_ARG}")"
export MIRROR_PHASE="${PHASE}"
preg_in_list cpd "${MIRROR_INSTALLS:-}" || preg_die "cpd is not in MIRROR_INSTALLS - nothing to update."
preg_info "Phase: ${PHASE}   push root: $(preg_push_root)"
preg_run_hook 4_update_cpd_patch cpd copy "--phase=${PHASE}" || preg_die "cpd: copying the patch delta failed"
preg_info "Next: 4.2_verify_and_record_cpd_patch.sh --phase=${PHASE}"
