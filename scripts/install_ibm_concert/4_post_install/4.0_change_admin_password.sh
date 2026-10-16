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
# 4.0 Rotate the initial Concert admin password (Keycloak)
# ------------------------------------------------------------------------------
# IBM: "It is highly recommended to change the initial admin user password
# configured during installation". Sets CONCERT_ADMIN_USERNAME's password to
# CONCERT_ADMIN_NEW_PASSWORD with IBM's concert-hub/bin/kc-usermgmt, run in the
# runner against the Hub's in-cluster Keycloak URL (kc-usermgmt reads the
# bootstrap admin from the Hub namespace).
#
# Then refreshes concert_instance_details.sh (3.4) so CONCERT_UI_PASSWORD holds
# the new password. Afterwards put the new value into CONCERT_ADMIN_PASSWORD and clear
# CONCERT_ADMIN_NEW_PASSWORD in concert_vars.sh: a later 3.2 run sends
# CONCERT_ADMIN_PASSWORD to the installer again.
# ==============================================================================

concert_product_enabled hub || concert_die "The Hub is remote - change the password on the Hub cluster."
concert_require_vars CONCERT_ADMIN_USERNAME CONCERT_ADMIN_NEW_PASSWORD
(( ${#CONCERT_ADMIN_NEW_PASSWORD} >= 12 )) || concert_die "CONCERT_ADMIN_NEW_PASSWORD must be at least 12 characters."

eval "${OC_LOGIN}"

export KC_URL="https://ibm-solis-hub-gw-svc.${PROJECT_CONCERT_HUB}.svc.cluster.local:11443/sys/internal/kc"
export KC_NS="${PROJECT_CONCERT_HUB}" KC_USER="${CONCERT_ADMIN_USERNAME}"

concert_run --name kc-password --timeout 900 \
    --env KC_URL --env KC_NS --env KC_USER --env KC_NEW_PASSWORD=CONCERT_ADMIN_NEW_PASSWORD -- __shell__ \
    'concert-hub/bin/kc-usermgmt update-password --kc-url="${KC_URL}" --namespace="${KC_NS}" --username="${KC_USER}" --password="${KC_NEW_PASSWORD}"'

concert_info "Password changed for ${CONCERT_ADMIN_USERNAME}."
"${_CP4D_REPO_ROOT}/scripts/install_ibm_concert/3_install_concert/3.4_get_instance_details.sh" \
    || concert_warn "Could not refresh concert_instance_details.sh - run 3.4 yourself."
concert_warn "Now set CONCERT_ADMIN_PASSWORD to the new value and clear CONCERT_ADMIN_NEW_PASSWORD in configs/concert_config/concert_vars.sh."
