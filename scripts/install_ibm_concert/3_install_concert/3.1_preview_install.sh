#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: only configs/concert_config/concert_vars.sh is in scope ---
export ENV_TARGET="${ENV_TARGET:-concert}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/concert_helpers.sh"
concert_require_config

# ==============================================================================
# 3.1 Preview IBM's manifests (EXPERIMENTAL, opt-in)
# ------------------------------------------------------------------------------
# IBM's `PREVIEW=1 bin/setup` renders the Hub/Concert/Data Apps manifests into
# CDW_PREVIEW_DIR instead of applying them. Its preview is not side-effect free
# on OpenShift, though: the Workflows Helm install, manage-product.sh and the
# Concert/Data Apps route creation are not guarded by PREVIEW. This step
# therefore previews with Workflows switched off, never fails the pipeline,
# and lists whatever was rendered (on the runner's work volume - copy it with
# x_fetch_installer_logs.sh --preview).
# ==============================================================================

PARAMS="${CONCERT_CONFIG_DIR}/params.ini"
[[ -f "${PARAMS}" ]] || concert_die "Run 3.0_render_params_ini.sh first."

eval "${OC_LOGIN}"

STAGE="$(concert_private_tmpdir)"
trap 'rm -rf "${STAGE}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT
sed -E "s/^INSTALL_WORKFLOWS=.*/INSTALL_WORKFLOWS='false'/" "${PARAMS}" > "${STAGE}/params.ini"

TS="$(date +%Y%m%d-%H%M%S)"
case "${CONCERT_RUNNER:-cluster}" in
    native) PREVIEW_DIR="${CONCERT_WORKSPACE}/native-work/preview/${TS}" ;;
    *)      PREVIEW_DIR="/work/preview/${TS}" ;;
esac
export PREVIEW=1 CDW_PREVIEW_DIR="${PREVIEW_DIR}"

files=(--file "${STAGE}/params.ini")
[[ -n "${CONCERT_OCP_ROUTE_CERT:-}" ]] && files+=(--file "${CONCERT_OCP_ROUTE_CERT}")

set +e
concert_run --name preview --timeout 3600 \
    --env PREVIEW --env CDW_PREVIEW_DIR \
    --env DEFAULT_ADMIN_USERNAME=CONCERT_ADMIN_USERNAME \
    --env DEFAULT_ADMIN_PASSWORD=CONCERT_ADMIN_PASSWORD \
    --env REG_PASS=CONCERT_REGISTRY_PASSWORD \
    "${files[@]}" -- __shell__ \
    './bin/setup --license_acceptance=y; rc=$?; echo; echo "setup exit code (preview): ${rc}"; echo "Rendered into ${CDW_PREVIEW_DIR}:"; find "${CDW_PREVIEW_DIR}" -type f 2>/dev/null | sort | head -200'
rc=$?
set -e
(( rc == 0 )) || concert_warn "The preview Job ended with ${rc} - expected on OpenShift for the unguarded steps; review the output above."
concert_info "Preview kept in ${PREVIEW_DIR} on the runner work volume (x_fetch_installer_logs.sh --preview copies it here)."
