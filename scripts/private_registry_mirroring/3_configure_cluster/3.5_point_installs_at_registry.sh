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
# 3.5 Point the installs at the registry (tap)
# ------------------------------------------------------------------------------
# Runs installs/<id>.sh tap for every install in MIRROR_INSTALLS. Each writes
# configs/<install>_config/registry_overrides.sh, which scripts/source_env_setup.sh
# sources right after that install's *_vars.sh - the install's own config file is
# never edited. Delete the overrides file to go back.
#   cpd        CPD_IMAGE_SOURCE, PRIVATE_REGISTRY_LOCATION=<pull root>/cpd, pull
#              credentials, IMAGE_PULL_PREFIX/_CREDENTIALS, OLM_UTILS_IMAGE (from
#              the registry), CPD_CASE_SOURCE=offline (local); podman login +
#              cpd-cli manage restart-container
#   confluent  registry, image and Flink chart settings (explicit redirect)
#   datastax_mc  chart ref, pull secret source, mc-values-registry.yaml
#   concert    CONCERT_IMAGE_SOURCE, PRIVATE_REGISTRY_LOCATION=<pull root>/concert,
#              CONCERT_MIRROR_VIA_SHARED=true, data-store images
# Workstation-side references (OLM_UTILS_IMAGE, Helm charts) use the PUSH root,
# cluster-side ones the PULL root.
#
#   ./3.5_point_installs_at_registry.sh [--dry-run] [--only ID]
# ==============================================================================

DRY=false ONLY=""
while (( $# )); do
    case "$1" in
        --dry-run) DRY=true; shift ;;
        --only) ONLY="${2:?--only needs an install id}"; shift 2 ;;
        *) preg_die "Unknown argument: $1" ;;
    esac
done
preg_resolve_registry
[[ -f "${MIRROR_WORKSPACE}/inventory/inventory.json" ]] || preg_die "No inventory - run 1.0 first."
export MIRROR_TAP_DRY_RUN="${DRY}"
# The taps look up where each ORIGINAL image name landed.
export PREG_SKIP_REGISTRY_OVERRIDES=1

done_ids=()
for id in "${(@f)$(preg_installs)}"; do
    [[ -n "${id}" ]] || continue
    [[ -z "${ONLY}" || "${ONLY}" == "${id}" ]] || continue
    preg_info "== ${id}"
    preg_run_hook 3_configure_cluster "${id}" tap || preg_die "${id}: tap failed"
    done_ids+=("${id}")
done
(( ${#done_ids} )) || preg_info "No installs selected."
${DRY} || preg_info "Installs pointed at $(preg_pull_root): ${done_ids[*]:-none}"
