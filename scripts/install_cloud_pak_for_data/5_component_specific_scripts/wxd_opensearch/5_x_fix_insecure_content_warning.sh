#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# Re-exec under zsh if running under a different shell (e.g. bash)
if [ -z "${ZSH_VERSION:-}" ]; then exec /bin/zsh "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

eval "${OC_LOGIN}"

# ---
# WHY YOU SEE "Your connection to this site is not secure":
#   A route with TLS termination "passthrough" hands the raw TLS connection
#   straight to the backend pod (e.g. the opensearch traefik pod), which
#   presents its OWN self-signed certificate. The browser does not trust that
#   cert, so it shows the insecure-content / not-secure warning.
#
#   Switching the route to "reencrypt" makes the OpenShift router present the
#   cluster's trusted *ingress (wildcard) certificate* to the browser, and the
#   router re-encrypts traffic to the backend. The browser only ever sees the
#   trusted cluster cert, so the warning disappears.
#
#   ("edge" termination also fixes the browser warning but sends plain HTTP to
#   the backend pod; many CPD service backends require TLS and will reject that,
#   so "reencrypt" is the safe default here.)
# ---

# ---
# Routes to fix.
# Format: "route-name"  or  "route-name:namespace" to override the namespace.
# Namespace defaults to ROUTE_NAMESPACE below.
ROUTES=(
    "opensearch354-dashboards"
    "opensearch354-backend"
    # "my-other-route"
    # "some-route:${PROJECT_CPD_INST_OPERATORS}"
)

# Namespace in which the routes live (default).
ROUTE_NAMESPACE="${PROJECT_CPD_INST_OPERATORS:-cpd-operators}"

# ---
# TLS termination to set on the target routes.
# Options:
#   reencrypt   - Router presents the trusted cluster cert; re-encrypts to the
#                 backend (recommended for TLS backends - fixes the warning).
#   edge        - Router presents the trusted cluster cert; plain HTTP to backend
#                 (only use if the backend accepts plain HTTP).
TLS_TERMINATION="reencrypt"

# Insecure traffic policy (edge/reencrypt only).
#   Redirect  - HTTP -> HTTPS redirect (recommended).
#   Allow     - HTTP allowed unencrypted.
#   None      - HTTP dropped.
INSECURE_POLICY="Redirect"

# For reencrypt, the backend cert is typically self-signed. By default OpenShift
# requires a destinationCACertificate to verify the backend. Setting this to
# "true" removes that field so the router does not verify the backend cert
# (the browser <-> router leg is still fully trusted/encrypted).
SKIP_BACKEND_CERT_VERIFY="true"
# ---

if [[ ${#ROUTES[@]} -eq 0 ]]; then
    echo "[WARN] ROUTES array is empty - nothing to do."
    exit 0
fi

echo ""
echo "=== Fixing insecure-content warning on routes (termination -> ${TLS_TERMINATION}) ==="
echo ""

for ENTRY in "${ROUTES[@]}"; do
    ROUTE_NAME="${ENTRY%%:*}"
    if [[ "${ENTRY}" == *:* ]]; then
        local_ns="${ENTRY#*:}"
    else
        local_ns="${ROUTE_NAMESPACE}"
    fi

    echo "--- Route: ${ROUTE_NAME} (namespace: ${local_ns}) ---"

    if ! oc get route "${ROUTE_NAME}" -n "${local_ns}" &>/dev/null; then
        echo "  [WARN] Route '${ROUTE_NAME}' not found in ${local_ns}. Skipping."
        echo ""
        continue
    fi

    CURRENT_TERM=$(oc get route "${ROUTE_NAME}" -n "${local_ns}" -o jsonpath='{.spec.tls.termination}' 2>/dev/null || true)
    echo "  [INFO] Current termination: ${CURRENT_TERM:-<none>}"

    # Build the tls block.
    if [[ "${TLS_TERMINATION}" == "reencrypt" ]]; then
        if [[ "${SKIP_BACKEND_CERT_VERIFY}" == "true" ]]; then
            # Drop destinationCACertificate so the router does not verify the
            # backend's self-signed cert. Replace the whole tls object.
            TLS_PATCH=$(cat <<EOF
{"spec":{"tls":{"termination":"reencrypt","insecureEdgeTerminationPolicy":"${INSECURE_POLICY}","destinationCACertificate":null,"certificate":null,"key":null,"caCertificate":null}}}
EOF
)
        else
            TLS_PATCH="{\"spec\":{\"tls\":{\"termination\":\"reencrypt\",\"insecureEdgeTerminationPolicy\":\"${INSECURE_POLICY}\"}}}"
        fi
    else
        # edge
        TLS_PATCH="{\"spec\":{\"tls\":{\"termination\":\"edge\",\"insecureEdgeTerminationPolicy\":\"${INSECURE_POLICY}\",\"destinationCACertificate\":null}}}"
    fi

    oc patch route "${ROUTE_NAME}" -n "${local_ns}" --type=merge -p "${TLS_PATCH}"
    echo "  [OK] Patched '${ROUTE_NAME}' to ${TLS_TERMINATION} (insecure: ${INSECURE_POLICY})."

    ROUTE_HOST=$(oc get route "${ROUTE_NAME}" -n "${local_ns}" -o jsonpath='{.spec.host}' 2>/dev/null || true)
    [[ -n "${ROUTE_HOST:-}" ]] && echo "  [INFO] Host: https://${ROUTE_HOST}"
    echo ""
done

echo "=== Routes in ${ROUTE_NAMESPACE} ==="
oc get routes -n "${ROUTE_NAMESPACE}"
