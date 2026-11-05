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
# Software Hub Control Center - OAuth client
# ------------------------------------------------------------------------------
# Creates the OAuth client Control Center uses to read cluster capacity data, on the
# cluster where Software Hub runs. This is IBM's client: prompt asks each user once
# and OpenShift remembers it. Keep respondWithChallenges false here, because it breaks
# the Refresh data button; the scripts change both only while they refresh. Safe to
# re-run.
# ==============================================================================

swhcc_activate
h_missing_vars CONTROL_OAUTH_CLIENT_ID CONTROL_OAUTH_SECRET || h_die "Not set: ${REPLY}. Check ${ENV_TARGET_FILE}."

# The route is on the Control Center cluster, the client on the Software Hub one.
swhcc_login
: "${CONTROL_CENTER_ROUTE:=$(oc get route cpd -n "${CONTROL_PROJECT_OPERANDS}" -o jsonpath='{.spec.host}')}"
[[ -n "${CONTROL_CENTER_ROUTE}" ]] || h_die "No 'cpd' route in project '${CONTROL_PROJECT_OPERANDS}': is Control Center installed?"

if [[ "${CONTROL_CLUSTER_MODE}" == different ]]; then
    h_missing_vars OC_LOGIN || h_die "OC_LOGIN is not set: the OAuth client goes on the Software Hub cluster, so cpd_vars.sh is needed."
    eval "${OC_LOGIN}"
fi

oc apply -f - <<OAUTH_EOF
apiVersion: oauth.openshift.io/v1
kind: OAuthClient
metadata:
  name: ${CONTROL_OAUTH_CLIENT_ID}
secret: "${CONTROL_OAUTH_SECRET}"
redirectURIs:
  - https://${CONTROL_CENTER_ROUTE}/zen/oauth/redirect
grantMethod: prompt
respondWithChallenges: false
accessTokenMaxAgeSeconds: 120
accessTokenInactivityTimeoutSeconds: 300
scopeRestrictions:
  - clusterRole:
      allowEscalation: false
      namespaces:
        - "*"
      roleNames:
        - cluster-reader
OAUTH_EOF

OAUTH_ROUTE="$(oc get route oauth-openshift -n openshift-authentication -o jsonpath='{.spec.host}')"
echo ""
h_info "Values for registering the cluster in the web client, if you do not use the scripts:"
h_info "  API address:     $(oc whoami --show-server)"
h_info "  OAuth route:     https://${OAUTH_ROUTE}"
h_info "  OAuth client ID: ${CONTROL_OAUTH_CLIENT_ID}"
h_info "  OAuth secret:    CONTROL_OAUTH_SECRET in ${ENV_TARGET_FILE}"
h_info "IBM then recommends the privileged monitoring service, so capacity data is collected automatically."
