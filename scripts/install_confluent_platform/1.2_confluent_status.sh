#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -uo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: source confluent_vars.sh LAST so its cluster/storage values
# win over the CP4D ones defined in cpd_vars.sh. Override to point these
# scripts at a different config:  ENV_TARGET=<name|path> ./<script>.sh
: "${ENV_TARGET:=confluent}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# ==============================================================================
# Confluent Platform - status
# ------------------------------------------------------------------------------
# Read-only health report for the cp-all-in-one stack. Reports per-component
# workload readiness, pod state, PVC binding, routes and recent warning events.
#
# Exit status: 0 if every expected component is ready, 1 otherwise - so this can
# gate a follow-up step in a pipeline.
#
# Note: `set -e` is deliberately NOT used here; this script inspects a possibly
# broken install and must report on everything before exiting.
# ==============================================================================

eval "${OC_LOGIN}"

NS="${PROJECT_CONFLUENT_SERVER}"

if ! oc get namespace "${NS}" &>/dev/null; then
    echo "[ERROR] Project '${NS}' does not exist. Nothing installed?" >&2
    exit 1
fi

_overall_ok=true

# ------------------------------------------------------------------------------
# check_workload <kind> <name> <enabled>
# ------------------------------------------------------------------------------
check_workload() {
    local kind="$1" name="$2" enabled="$3"

    if [[ "${enabled}" != "true" ]]; then
        printf '  %-18s %s\n' "${name}" "SKIPPED (disabled in confluent_vars.sh)"
        return 0
    fi

    if ! oc get "${kind}" "${name}" -n "${NS}" &>/dev/null; then
        printf '  %-18s %s\n' "${name}" "MISSING (${kind} not found)"
        _overall_ok=false
        return 1
    fi

    local desired ready
    desired="$(oc get "${kind}" "${name}" -n "${NS}" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
    ready="$(oc get "${kind}" "${name}" -n "${NS}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
    desired="${desired:-0}"
    ready="${ready:-0}"

    if [[ "${ready}" == "${desired}" && "${desired}" != "0" ]]; then
        printf '  %-18s %s\n' "${name}" "READY (${ready}/${desired})"
    else
        printf '  %-18s %s\n' "${name}" "NOT READY (${ready}/${desired})"
        _overall_ok=false
    fi
}

echo "=============================================================================="
echo " Confluent Platform status - project '${NS}'"
echo "=============================================================================="
echo ""
echo "Workloads:"
check_workload statefulset broker           "true"
check_workload deployment  schema-registry  "${CONFLUENT_INSTALL_SCHEMA_REGISTRY}"
check_workload deployment  connect          "${CONFLUENT_INSTALL_CONNECT}"
check_workload deployment  ksqldb-server     "${CONFLUENT_INSTALL_KSQLDB}"
check_workload deployment  rest-proxy       "${CONFLUENT_INSTALL_REST_PROXY}"
# Prometheus and Alertmanager have no toggle of their own: next-gen Control
# Center reads its metrics from them, so they install with it or not at all.
check_workload deployment  prometheus       "${CONFLUENT_INSTALL_CONTROL_CENTER}"
check_workload deployment  alertmanager     "${CONFLUENT_INSTALL_CONTROL_CENTER}"
check_workload deployment  control-center   "${CONFLUENT_INSTALL_CONTROL_CENTER}"

# ------------------------------------------------------------------------------
# Pods - surface restart counts and non-running phases
# ------------------------------------------------------------------------------
echo ""
echo "Pods:"
_pods="$(oc get pods -n "${NS}" -l app.kubernetes.io/part-of=confluent \
    -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,NODE:.spec.nodeName' \
    --no-headers 2>/dev/null)"

if [[ -z "${_pods}" ]]; then
    echo "  (no pods found)"
    _overall_ok=false
else
    echo "${_pods}" | while read -r _name _phase _ready _restarts _node; do
        printf '  %-38s %-10s ready=%-6s restarts=%-4s %s\n' \
            "${_name}" "${_phase}" "${_ready}" "${_restarts}" "${_node}"
    done
    # Flag any pod that is not Running, and any with a high restart count.
    while read -r _name _phase _ready _restarts _node; do
        [[ -z "${_name}" ]] && continue
        if [[ "${_phase}" != "Running" || "${_ready}" != "true" ]]; then
            _overall_ok=false
        fi
        if [[ "${_restarts}" =~ ^[0-9]+$ ]] && (( _restarts >= 5 )); then
            echo "  [WARN] ${_name} has restarted ${_restarts} times."
        fi
    done <<< "${_pods}"
fi

# ------------------------------------------------------------------------------
# Storage
# ------------------------------------------------------------------------------
echo ""
echo "Storage:"
# The broker StatefulSet uses a volumeClaimTemplate, so claims are named
# confluent-broker-data-broker-<ordinal> - one per broker.
_pvcs="$(oc get pvc -n "${NS}" \
    -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,SIZE:.status.capacity.storage' \
    --no-headers 2>/dev/null | grep '^confluent-broker-data' || true)"

if [[ -z "${_pvcs}" ]]; then
    echo "  (no broker PVCs found)"
    _overall_ok=false
else
    echo "${_pvcs}" | while read -r _pname _pphase _psize; do
        printf '  %-38s %-10s %s\n' "${_pname}" "${_pphase}" "${_psize:-unknown size}"
    done
    while read -r _pname _pphase _psize; do
        [[ -n "${_pname}" && "${_pphase}" != "Bound" ]] && _overall_ok=false
    done <<< "${_pvcs}"
fi

# ------------------------------------------------------------------------------
# Endpoints
# ------------------------------------------------------------------------------
echo ""
echo "Endpoints:"
echo "  in-cluster bootstrap: broker:${CONFLUENT_BROKER_INTERNAL_PORT}"

# Basic-auth state for the web UIs.
: "${CONFLUENT_AUTH_SECRET:=confluent-auth}"
_auth_user="$(oc get secret "${CONFLUENT_AUTH_SECRET}" -n "${NS}" -o jsonpath='{.data.username}' 2>/dev/null | base64 --decode || true)"
if [[ -n "${_auth_user}" ]]; then
    echo "  web UI auth: basic, user '${_auth_user}'"
    echo "    password: oc get secret ${CONFLUENT_AUTH_SECRET} -n ${NS} -o jsonpath='{.data.password}' | base64 --decode"
else
    echo "  web UI auth: NONE (endpoints are unauthenticated)"
fi
_routes="$(oc get routes -n "${NS}" -l app.kubernetes.io/part-of=confluent \
    -o custom-columns='NAME:.metadata.name,HOST:.spec.host' --no-headers 2>/dev/null)"
if [[ -z "${_routes}" ]]; then
    echo "  (no routes - CONFLUENT_CREATE_ROUTES=${CONFLUENT_CREATE_ROUTES})"
else
    echo "${_routes}" | while read -r _name _host; do
        printf '  %-18s https://%s\n' "${_name}" "${_host}"
    done
fi

# ------------------------------------------------------------------------------
# Recent warnings - the fastest signal when something is wedged
# ------------------------------------------------------------------------------
echo ""
echo "Recent warning events (last 10):"
_events="$(oc get events -n "${NS}" --field-selector type=Warning \
    --sort-by=.lastTimestamp -o custom-columns='TIME:.lastTimestamp,OBJECT:.involvedObject.name,REASON:.reason,MESSAGE:.message' \
    --no-headers 2>/dev/null | tail -10)"
if [[ -z "${_events}" ]]; then
    echo "  (none)"
else
    echo "${_events}" | while IFS= read -r _line; do echo "  ${_line}"; done
fi

# ------------------------------------------------------------------------------
# Verdict
# ------------------------------------------------------------------------------
echo ""
echo "=============================================================================="
if $_overall_ok; then
    echo "[INFO] All enabled Confluent components are ready."
    exit 0
else
    echo "[WARN] One or more Confluent components are not ready (see above)." >&2
    echo "[WARN] Inspect a component with: oc logs -n ${NS} -l app=<component> --tail=100" >&2
    exit 1
fi
