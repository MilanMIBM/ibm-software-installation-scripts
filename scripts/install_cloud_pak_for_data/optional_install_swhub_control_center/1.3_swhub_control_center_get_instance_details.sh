#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/swhub_control_center_helpers.sh"

# ==============================================================================
# Software Hub Control Center - instance details
# ------------------------------------------------------------------------------
# Writes the route, web client URL and initial admin login to
# swhub_control_center_instance_details.sh next to the vars file; the env loader
# sources it with them. The password stays out of the run output.
# ==============================================================================

swhcc_activate
swhcc_login

CONTROL_CENTER_ROUTE="$(oc get route cpd -n "${CONTROL_PROJECT_OPERANDS}" -o jsonpath='{.spec.host}')"
[[ -n "${CONTROL_CENTER_ROUTE}" ]] || h_die "No 'cpd' route in project '${CONTROL_PROJECT_OPERANDS}': is Control Center installed?"

DETAILS="$(cpd-cli manage get-cpd-instance-details \
    --cpd_instance_ns=${CONTROL_PROJECT_OPERANDS} \
    --get_admin_initial_credentials=true)"
CONTROL_CENTER_USERNAME="$(print -r -- "${DETAILS}" | grep 'CPD Username:' | grep -oE '[^ ]+$' | tr -d '[:space:]')"
CONTROL_CENTER_PASSWORD="$(print -r -- "${DETAILS}" | grep 'CPD Password:' | grep -oE '[^ ]+$' | tr -d '[:space:]')"

VARS_FILE="${ENV_TARGET_FILE:h}/swhub_control_center_instance_details.sh"
( umask 077
  cat > "${VARS_FILE}" <<DETAILS_EOF
# Written by $(basename $0) on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
export CONTROL_CENTER_ROUTE="${CONTROL_CENTER_ROUTE}"
export CONTROL_CENTER_URL="https://${CONTROL_CENTER_ROUTE}"
export CONTROL_CENTER_USERNAME="${CONTROL_CENTER_USERNAME}"
export CONTROL_CENTER_PASSWORD="${CONTROL_CENTER_PASSWORD}"
DETAILS_EOF
)
chmod 700 "${VARS_FILE}"

h_info "Control Center URL: https://${CONTROL_CENTER_ROUTE}"
h_info "Admin user: ${CONTROL_CENTER_USERNAME}; password in ${VARS_FILE}"
