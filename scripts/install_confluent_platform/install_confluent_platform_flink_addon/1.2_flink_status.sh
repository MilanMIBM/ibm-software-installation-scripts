#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
: "${ENV_TARGET:=confluent}"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# ==============================================================================
# Confluent Platform for Apache Flink - status
# ------------------------------------------------------------------------------
# Reports the state of the Flink installation: the two workloads, the Helm
# releases, the CMF resources (environments, pools, catalogs) and any running
# Flink jobs.
#
# Read-only. Never changes anything, so it is safe to run at any time.
#
# Usage:
#   ./1.2_flink_status.sh [--jobs] [--no-cmf]
#
#   --jobs     also list the FlinkDeployments and their pods
#   --no-cmf   skip the CMF resource listing (avoids the port-forward)
# ==============================================================================

SHOW_JOBS=false
NO_CMF=false

while (( $# > 0 )); do
    case "$1" in
        --jobs)   SHOW_JOBS=true; shift ;;
        --no-cmf) NO_CMF=true; shift ;;
        -h|--help)
            sed -n '19,31p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Use --help." >&2; exit 1 ;;
    esac
done

eval "${OC_LOGIN}" >/dev/null

NS="${PROJECT_CONFLUENT_FLINK}"

echo "=============================================================================="
echo " Confluent Platform for Apache Flink - project '${NS}'"
echo "=============================================================================="

if ! oc get namespace "${NS}" &>/dev/null; then
    echo ""
    echo "  Project '${NS}' does not exist - Flink is not installed."
    echo ""
    echo "  Install it with:  ./1.0_flink_prep.sh && ./1.1_flink_install.sh"
    exit 0
fi

# ------------------------------------------------------------------------------
# Prerequisite
# ------------------------------------------------------------------------------
echo ""
echo "-- cert-manager --------------------------------------------------------------"
if oc get crd certificates.cert-manager.io &>/dev/null; then
    printf '  %-42s %s\n' "cert-manager" "installed"
else
    printf '  %-42s %s\n' "cert-manager" "MISSING - the Flink operator webhook will fail"
fi

# ------------------------------------------------------------------------------
# Helm releases
# ------------------------------------------------------------------------------
echo ""
echo "-- Helm releases -------------------------------------------------------------"
if command -v helm &>/dev/null; then
    _releases="$(helm list -n "${NS}" --short 2>/dev/null || true)"
    if [[ -z "${_releases}" ]]; then
        echo "  (none)"
    else
        helm list -n "${NS}" 2>/dev/null | sed 's/^/  /'
    fi
else
    echo "  (helm is not on PATH)"
fi

# ------------------------------------------------------------------------------
# Workloads
# ------------------------------------------------------------------------------
echo ""
echo "-- Workloads -----------------------------------------------------------------"
printf '  %-42s %-12s %s\n' "NAME" "READY" "STATE"
for _d in flink-kubernetes-operator confluent-manager-for-apache-flink; do
    if ! oc get deployment "${_d}" -n "${NS}" &>/dev/null; then
        printf '  %-42s %-12s %s\n' "${_d}" "-" "not installed"
        continue
    fi
    _ready="$(oc get deployment "${_d}" -n "${NS}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    _want="$(oc get deployment "${_d}" -n "${NS}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
    _ready="${_ready:-0}"
    if [[ "${_ready}" == "${_want}" && "${_ready}" != "0" ]]; then
        _state="Available"
    else
        _state="NOT READY"
    fi
    printf '  %-42s %-12s %s\n' "${_d}" "${_ready}/${_want}" "${_state}"
done

# Any pod that is not Running/Succeeded is worth surfacing here rather than
# leaving the reader to go and look for it.
_bad="$(oc get pods -n "${NS}" --no-headers 2>/dev/null \
    | awk '$3 != "Running" && $3 != "Completed" {print "  " $1 "  " $3}' || true)"
if [[ -n "${_bad}" ]]; then
    echo ""
    echo "  Pods needing attention:"
    echo "${_bad}"
fi

# ------------------------------------------------------------------------------
# Storage
# ------------------------------------------------------------------------------
echo ""
echo "-- Storage -------------------------------------------------------------------"
_pvcs="$(oc get pvc -n "${NS}" --no-headers 2>/dev/null || true)"
if [[ -z "${_pvcs}" ]]; then
    echo "  (none)"
else
    printf '  %-42s %-12s %s\n' "NAME" "STATUS" "CAPACITY"
    oc get pvc -n "${NS}" --no-headers -o custom-columns='N:.metadata.name,S:.status.phase,C:.status.capacity.storage' 2>/dev/null \
        | awk '{printf "  %-42s %-12s %s\n", $1, $2, $3}'
fi

# ------------------------------------------------------------------------------
# Endpoint
# ------------------------------------------------------------------------------
echo ""
echo "-- CMF endpoint --------------------------------------------------------------"
_route="$(oc get route cmf -n "${NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [[ -n "${_route}" ]]; then
    printf '  %-42s %s\n' "route" "https://${_route}"
    if [[ "$(oc get route cmf -n "${NS}" -o jsonpath='{.spec.to.name}' 2>/dev/null || true)" != "${FLINK_CMF_SERVICE}" ]]; then
        printf '  %-42s %s\n' "" "OpenShift login (oauth-proxy)"
    else
        printf '  %-42s %s\n' "" "UNAUTHENTICATED - anyone who can reach it controls Flink"
    fi
else
    printf '  %-42s %s\n' "route" "(none - use oc port-forward)"
fi
printf '  %-42s %s\n' "in-cluster" "http://${FLINK_CMF_SERVICE}.${NS}.svc.cluster.local:${FLINK_CMF_PORT}"

# ------------------------------------------------------------------------------
# CMF resources
# ------------------------------------------------------------------------------
if [[ "${NO_CMF}" != "true" ]] && command -v confluent &>/dev/null \
        && oc get deployment confluent-manager-for-apache-flink -n "${NS}" &>/dev/null; then
    echo ""
    echo "-- CMF resources -------------------------------------------------------------"
    # Failure here is not fatal: CMF may simply be starting, and the rest of
    # this report is still worth printing.
    if source "${SCRIPT_DIR}/flink_cmf_connect.sh" && cmf_connect &>/dev/null; then
        echo ""
        echo "  Environments:"
        confluent flink environment list --url "${CMF_URL}" 2>/dev/null | sed 's/^/    /' || echo "    (none)"
        echo ""
        echo "  Compute pools (${FLINK_ENVIRONMENT}):"
        confluent flink compute-pool list --environment "${FLINK_ENVIRONMENT}" --url "${CMF_URL}" 2>/dev/null \
            | sed 's/^/    /' || echo "    (none)"
        echo ""
        echo "  Catalogs:"
        _cat="$(confluent flink catalog list --url "${CMF_URL}" 2>/dev/null || true)"
        if [[ -z "${_cat}" || "${_cat}" == *"None found"* ]]; then
            echo "    (none - run ./utility_scripts_confluent_flink/x.4_flink_connect_kafka.sh to attach a Kafka cluster)"
        else
            echo "${_cat}" | sed 's/^/    /'
        fi
        echo ""
        echo "  Statements (${FLINK_ENVIRONMENT}):"
        confluent flink statement list --environment "${FLINK_ENVIRONMENT}" --url "${CMF_URL}" 2>/dev/null \
            | sed 's/^/    /' || echo "    (none)"
        echo ""
        echo "  Applications (${FLINK_ENVIRONMENT}):"
        confluent flink application list --environment "${FLINK_ENVIRONMENT}" --url "${CMF_URL}" 2>/dev/null \
            | sed 's/^/    /' || echo "    (none)"
    else
        echo "  (CMF is not reachable - it may still be starting)"
    fi
fi

# ------------------------------------------------------------------------------
# Jobs
# ------------------------------------------------------------------------------
if [[ "${SHOW_JOBS}" == "true" ]]; then
    echo ""
    echo "-- FlinkDeployments ----------------------------------------------------------"
    _fd="$(oc get flinkdeployments -n "${NS}" --no-headers 2>/dev/null || true)"
    if [[ -z "${_fd}" ]]; then
        echo "  (none)"
    else
        oc get flinkdeployments -n "${NS}" 2>/dev/null | sed 's/^/  /'
        echo ""
        echo "  Job pods:"
        oc get pods -n "${NS}" -l component 2>/dev/null | sed 's/^/    /' || echo "    (none)"
    fi
fi

# ------------------------------------------------------------------------------
# Attached Kafka
# ------------------------------------------------------------------------------
echo ""
echo "-- Kafka -----------------------------------------------------------------------"
if oc get statefulset broker -n "${PROJECT_CONFLUENT_SERVER}" &>/dev/null; then
    _br="$(oc get statefulset broker -n "${PROJECT_CONFLUENT_SERVER}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    printf '  %-42s %s\n' "Confluent cluster (${PROJECT_CONFLUENT_SERVER})" "${_br:-0} broker(s) ready"
else
    printf '  %-42s %s\n' "Confluent cluster (${PROJECT_CONFLUENT_SERVER})" "not installed"
fi
echo ""
