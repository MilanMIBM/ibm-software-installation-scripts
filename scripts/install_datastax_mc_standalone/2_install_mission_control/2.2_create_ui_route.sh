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
# 2.2 Route to the Mission Control UI (control plane only)
# ------------------------------------------------------------------------------
# The UI serves HTTPS itself on service <release>-ui:8080 (ui.https.enabled), so
# the Route is passthrough: the browser sees Mission Control's own certificate
# (self-signed unless you configure tls.rootCaSecretName). DataStax's docs use a
# Kubernetes Ingress for this; on OpenShift a Route is the native equivalent.
# ==============================================================================

if [[ "${MC_PLANE}" != control ]]; then
    mc_info "Data plane: no UI, no Route."
    exit 0
fi

eval "${OC_LOGIN}"

ROUTE="${MC_UI_ROUTE_NAME:-${MC_RELEASE_NAME}-ui}"
SVC="${MC_RELEASE_NAME}-ui"
oc get service "${SVC}" -n "${MC_NAMESPACE}" >/dev/null 2>&1 \
    || mc_die "Service ${MC_NAMESPACE}/${SVC} not found - install Mission Control first (2.1)."

oc apply -f - >/dev/null <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${ROUTE}
  namespace: ${MC_NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: datastax-mc-scripts
spec:
  to:
    kind: Service
    name: ${SVC}
    weight: 100
  port:
    targetPort: 8080
  tls:
    termination: passthrough
    insecureEdgeTerminationPolicy: Redirect
EOF

host="$(mc_ui_route_host)"
mc_info "Mission Control UI: https://${host}"
if [[ -n "${MC_UI_BASE_URL:-}" && "${MC_UI_BASE_URL%/}" != "https://${host}" ]]; then
    mc_warn "MC_UI_BASE_URL (${MC_UI_BASE_URL}) differs from the Route host - set it to https://${host} and re-run 2.1 if you use OIDC."
fi
