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
export PREG_SKIP_REGISTRY_OVERRIDES=1   # hooks read the installs' own settings, not 3.5's overrides

# ==============================================================================
# 2.0 Install-native content (--phase=mirror|save|load, default MIRROR_PHASE)
# ------------------------------------------------------------------------------
# Content an install's own tooling must move, from 1.0's <path>/native.jsonl:
#   cpd      cpd-cli: case-download, list-images, mirror-images (direct to
#            <root>/cpd, or via cpd-cli's stop-over registry 127.0.0.1:12443),
#            olm-utils (save-image / load-image)
#   concert  Concert's own 1_registry_access_and_mirroring/1.1 (oc image mirror
#            with IBM's cp/<suffix> layout) into <root>/concert
# Each runs 2_download_and_mirror/installs/<id>.sh download --phase=<phase>.
# Everything else (plain images, operators, charts, files) is 2.1 - 2.3.
# ==============================================================================

preg_parse_phase_args "$@"
preg_resolve_registry
PHASE="$(preg_resolve_phase "${PREG_PHASE_ARG}")"
export MIRROR_PHASE="${PHASE}"
preg_info "Phase: ${PHASE}   push root: $(preg_push_root)   image source: $(preg_image_source)"

ran=0
for id in "${(@f)$(preg_installs)}"; do
    [[ -n "${id}" ]] || continue
    nat="${MIRROR_WORKSPACE}/$(preg_install_path "${id}")/native.jsonl"
    [[ -s "${nat}" ]] || continue
    preg_info "== ${id}: $(preg_python -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline()).get("summary",""))' "${nat}" | cut -c1-200)"
    preg_run_hook 2_download_and_mirror "${id}" download "--phase=${PHASE}" || preg_die "${id}: native download failed"
    ran=$((ran + 1))
done
(( ran )) || preg_info "No install-native content in the inventory (run 1.0 first, or nothing native was selected)."
