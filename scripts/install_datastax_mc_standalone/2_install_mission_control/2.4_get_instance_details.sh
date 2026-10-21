#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: only configs/datastax_mc_config/datastax_mc_vars.sh is in scope ---
export ENV_TARGET="${ENV_TARGET:-datastax_mc}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/datastax_mc_helpers.sh"
mc_require_config

# ==============================================================================
# 2.4 Write configs/datastax_mc_config/datastax_mc_instance_details.sh
# ------------------------------------------------------------------------------
# UI URL and admin login, under the same DATASTAX_MC_* names the CP4D DataStax
# scripts use. The env loader sources this file next to datastax_mc_vars.sh.
# Rewritten (not appended) on every run.
# ==============================================================================

eval "${OC_LOGIN}"
OUT="${MC_CONFIG_DIR}/datastax_mc_instance_details.sh"

url=""
if [[ "${MC_PLANE}" == control ]]; then
    host="$(mc_ui_route_host)"
    [[ -n "${host}" ]] && url="https://${host}" || mc_warn "No UI Route yet - run 2.2_create_ui_route.sh, then this again."
fi

q() { print -r -- "${(qq)1}"; }
umask 077
cat > "${OUT}" <<EOF
# Written by $(basename $0) on $(date -u +%Y-%m-%dT%H:%M:%SZ)
[[ "\${ENV_TARGET:-}" == datastax_mc || "\${ENV_TARGET:-}" == *datastax_mc_vars.sh ]] || return 0
#--- DataStax Mission Control (standalone, ${MC_PLANE} plane, release ${MC_RELEASE_NAME} in ${MC_NAMESPACE})
export DATASTAX_MC_URL=$(q "${url}")
export DATASTAX_MC_USERNAME=$(q "${MC_ADMIN_EMAIL}")
export DATASTAX_MC_LOGIN_USERNAME=$(q "${MC_ADMIN_EMAIL}")
export DATASTAX_MC_PASSWORD=$(q "${MC_ADMIN_PASSWORD}")
EOF

mc_info "Wrote ${OUT#${_CP4D_REPO_ROOT}/}"
if [[ -n "${url}" ]]; then
    mc_info "UI:    ${url}"
    mc_info "Login: ${MC_ADMIN_EMAIL} (password: MC_ADMIN_PASSWORD in datastax_mc_vars.sh)"
fi
