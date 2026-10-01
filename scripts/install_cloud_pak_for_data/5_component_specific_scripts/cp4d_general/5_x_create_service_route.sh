#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# Re-exec under zsh if running under a different shell (e.g. bash)
if [ -z "${ZSH_VERSION:-}" ]; then exec /bin/zsh "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# (legacy hardcoded sourcing - replaced by universal crawl below)
# source "${SCRIPT_DIR}/../source_env_setup.sh"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

eval "${OC_LOGIN}"

# ---
# Services to expose as routes.
# Format: "service-name:port" - port is optional; omit to use the service's default port.
# Namespace defaults to PROJECT_CPD_INST_OPERANDS; override per-entry as "service-name:port:namespace".
SERVICES=(
    # mongo-mini-bongo-mongodb-svc
    edb-pustgres-edb-db-rw
    # "my-service:8080"
    # "my-service:8080:${PROJECT_CPD_INST_OPERATORS}"
    # "my-service"     # uses default service port
)

# Route name prefix (leave empty to use the service name as-is).
ROUTE_NAME_PREFIX=""

# Namespace in which routes are created (defaults to operands namespace).
ROUTE_NAMESPACE="${PROJECT_CPD_INST_OPERANDS:-}"

# ---
# TLS termination type.
# Options:
#   edge        - TLS terminated at the router; backend receives plain HTTP.
#   reencrypt   - TLS terminated at the router and re-encrypted toward the backend.
#   passthrough - TLS passed through to the backend pod unchanged (no cert needed on router).
TLS_TERMINATION="reencrypt"

# Insecure traffic policy (applies to edge and reencrypt termination only).
# Options:
#   Redirect  - HTTP requests are redirected to HTTPS (recommended).
#   Allow     - HTTP requests are allowed through unencrypted.
#   None      - HTTP requests are dropped.
INSECURE_POLICY="Redirect"

# Wildcard policy for the route.
# Options: None, Subdomain
WILDCARD_POLICY="None"

# ---

if [[ -z "${ROUTE_NAMESPACE:-}" ]]; then
    echo "Error: ROUTE_NAMESPACE is not set and PROJECT_CPD_INST_OPERANDS is empty."
    exit 1
fi

if [[ ${#SERVICES[@]} -eq 0 ]]; then
    echo "[WARN] SERVICES array is empty - nothing to do."
    exit 0
fi

echo ""
echo "=== Creating routes in namespace: ${ROUTE_NAMESPACE} ==="
echo "    Termination : ${TLS_TERMINATION}"
if [[ "${TLS_TERMINATION}" != "passthrough" ]]; then
    echo "    Insecure    : ${INSECURE_POLICY}"
fi
echo ""

for ENTRY in "${SERVICES[@]}"; do
    # Parse "service:port" or "service:port:namespace" or "service"
    local_ns="${ROUTE_NAMESPACE}"
    SVC_NAME="${ENTRY%%:*}"
    _rest="${ENTRY#*:}"

    if [[ "${_rest}" == "${ENTRY}" ]]; then
        # No colon at all - no port, no namespace override
        SVC_PORT=""
    else
        SVC_PORT="${_rest%%:*}"
        _ns_part="${_rest#*:}"
        if [[ "${_ns_part}" != "${SVC_PORT}" ]]; then
            local_ns="${_ns_part}"
        fi
    fi

    ROUTE_NAME="${ROUTE_NAME_PREFIX}${SVC_NAME}"

    echo "--- Service: ${SVC_NAME} (namespace: ${local_ns}) ---"

    # Verify the service exists
    if ! oc get svc "${SVC_NAME}" -n "${local_ns}" &>/dev/null; then
        echo "  [WARN] Service '${SVC_NAME}' not found in ${local_ns}. Skipping."
        echo ""
        continue
    fi

    # Skip if the route already exists
    if oc get route "${ROUTE_NAME}" -n "${local_ns}" &>/dev/null; then
        echo "  [SKIP] Route '${ROUTE_NAME}' already exists in ${local_ns}."
        echo ""
        continue
    fi

    # Build oc create route arguments
    ROUTE_ARGS=(
        "route" "${TLS_TERMINATION}" "${ROUTE_NAME}"
        "--service=${SVC_NAME}"
        "-n" "${local_ns}"
        "--wildcard-policy=${WILDCARD_POLICY}"
    )

    [[ -n "${SVC_PORT:-}" ]] && ROUTE_ARGS+=("--port=${SVC_PORT}")

    # insecureEdgeTerminationPolicy is only valid for edge and reencrypt
    if [[ "${TLS_TERMINATION}" != "passthrough" ]]; then
        ROUTE_ARGS+=("--insecure-policy=${INSECURE_POLICY}")
    fi

    oc create "${ROUTE_ARGS[@]}"
    echo "  [OK] Created ${TLS_TERMINATION} route '${ROUTE_NAME}'${SVC_PORT:+ (port ${SVC_PORT})}."

    ROUTE_HOST=$(oc get route "${ROUTE_NAME}" -n "${local_ns}" -o jsonpath='{.spec.host}' 2>/dev/null || true)
    [[ -n "${ROUTE_HOST:-}" ]] && echo "  [INFO] Host: https://${ROUTE_HOST}"
    echo ""
done

echo "=== Routes in ${ROUTE_NAMESPACE} ==="
oc get routes -n "${ROUTE_NAMESPACE}"
