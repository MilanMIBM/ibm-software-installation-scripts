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
source "${_CP4D_REPO_ROOT}/src/helpers/confluent_helpers.sh"

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
cf_operator_guard flink || exit $?

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
if cf_flink_is_olm || [[ "$(cf_flink_cmf_resource_mode)" == cfk ]]; then
    source "${_CP4D_REPO_ROOT}/src/helpers/confluent_operator_helpers.sh"
    export CFO_OWNER_ID="${CFO_OWNER_ID:-$(cfo_owner_id)}"
fi

echo ""
echo "-- cert-manager --------------------------------------------------------------"
if cf_flink_is_olm; then
    # Operator mode (H20): OLM issues cp-fko's webhook certificate.
    printf '  %-42s %s\n' "cert-manager" "not required (cp-fko via OLM)"
elif oc get crd certificates.cert-manager.io &>/dev/null; then
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
    if cf_flink_is_olm; then
        # Operator mode: CMF is the only Helm release; a Flink operator release here would be a second operator.
        _fko_rel="$(helm list -n "${NS}" -o json 2>/dev/null | cfo_python "${_CP4D_REPO_ROOT}/src/helpers/confluent_operator_olm.py" guard-flink --helm /dev/stdin 2>/dev/null | awk '$1 == "fko" {print $2}' || true)"
        if [[ -n "${_fko_rel}" ]]; then
            echo "  [WARN] Helm Flink operator release(s) ${_fko_rel//$'\n'/, } in '${NS}' - cp-fko via OLM expects only CMF here"
        fi
    fi
else
    echo "  (helm is not on PATH)"
fi

# ------------------------------------------------------------------------------
# Operators (operator mode: cp-fko, and CFK for CMF resources as CRs)
# ------------------------------------------------------------------------------
if cf_flink_is_olm; then
    echo ""
    echo "-- Operators (OLM) -----------------------------------------------------------"
    _cfk_ns="${FLINK_CFK_NAMESPACE:-${NS}}"
    _op_nss=("${NS}")
    [[ "$(cf_flink_cmf_resource_mode)" == cfk && "${_cfk_ns}" != "${NS}" ]] && _op_nss+=("${_cfk_ns}")
    printf '  %-20s %-26s %-14s %-10s %-12s %-38s %s\n' NAMESPACE SUBSCRIPTION CHANNEL APPROVAL STATE CSV "PHASE / PENDING / DEPLOYMENT"
    for _ons in "${_op_nss[@]}"; do
        _rows="$(cfo_operator_rows "${_ons}" 2>/dev/null || true)"
        if [[ -z "${_rows}" ]]; then
            printf '  %-20s %s\n' "${_ons}" "(no Subscription)"
            continue
        fi
        for _row in "${(@f)_rows}"; do
            _c=("${(@s:	:)_row}")
            printf '  %-20s %-26s %-14s %-10s %-12s %-38s %s\n' "${_ons}" "${_c[1]:--}" "${_c[3]:--}" "${_c[4]:--}" \
                "${_c[5]:--}" "${_c[6]:--}" "${_c[7]:--} / ${_c[8]:--} / ${_c[9]:--} ${_c[10]:-} (vs startingCSV: ${_c[11]:--})"
        done
        _ogs="$(oc get operatorgroups.operators.coreos.com -n "${_ons}" \
            -o jsonpath='{range .items[*]}{.metadata.name}={.spec.targetNamespaces}{" "}{end}' 2>/dev/null || true)"
        printf '  %-20s %s\n' "" "OperatorGroup: ${_ogs:-(none)}"
    done
fi

# ------------------------------------------------------------------------------
# Workloads
# ------------------------------------------------------------------------------
echo ""
echo "-- Workloads -----------------------------------------------------------------"
printf '  %-42s %-12s %s\n' "NAME" "READY" "STATE"
# Operator mode (H20): the OLM Deployment of cp-fko is named after the package.
_workloads=(flink-kubernetes-operator confluent-manager-for-apache-flink)
cf_flink_is_olm && _workloads=("${CFO_PKG_FKO}" confluent-manager-for-apache-flink)
for _d in "${_workloads[@]}"; do
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
# CMF resources as CFK custom resources (FLINK_CMF_RESOURCE_MODE=cfk, H21)
# ------------------------------------------------------------------------------
if [[ "$(cf_flink_cmf_resource_mode)" == cfk ]]; then
    echo ""
    echo "-- CFK Flink resources (${FLINK_CFK_NAMESPACE:-${NS}}) ---------------------------------"
    _cfk_crs="$(oc get cmfrestclasses.platform.confluent.io,flinkenvironments.platform.confluent.io,flinkapplications.platform.confluent.io \
        -n "${FLINK_CFK_NAMESPACE:-${NS}}" 2>/dev/null || true)"
    if [[ -z "${_cfk_crs}" ]]; then
        echo "  (none)"
    else
        echo "${_cfk_crs}" | sed 's/^/  /'
    fi
    _env_sync="$(oc get flinkenvironments.platform.confluent.io "${FLINK_ENVIRONMENT}" -n "${FLINK_CFK_NAMESPACE:-${NS}}" \
        -o jsonpath='{.status.cmfSync.status}' 2>/dev/null || true)"
    printf '  %-42s %s\n' "FlinkEnvironment/${FLINK_ENVIRONMENT} cmfSync" "${_env_sync:-(none)}"
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
if cf_is_operator_mode || cf_flink_is_olm; then
    # Operator mode (H21): a CFK Kafka CR, or a scripts-mode broker StatefulSet.
    (( ${+functions[cf_kafka_present]} )) || source "${_CP4D_REPO_ROOT}/src/helpers/confluent_operator_helpers.sh"
    _kcr="$(oc get kafkas.platform.confluent.io "${CF_KAFKA_CR}" -n "${PROJECT_CONFLUENT_SERVER}" \
        -o jsonpath='{.metadata.name}|{.status.readyReplicas}|{.status.phase}' 2>/dev/null || true)"
    if [[ -n "${_kcr%%|*}" ]]; then
        _kparts=("${(@s:|:)_kcr}")
        printf '  %-42s %s\n' "Confluent cluster (${PROJECT_CONFLUENT_SERVER})" \
            "${_kparts[2]:-0} broker(s) ready (Kafka CR, phase ${_kparts[3]:-unknown}); bootstrap $(cf_bootstrap_internal "${PROJECT_CONFLUENT_SERVER}")"
    elif oc get statefulset broker -n "${PROJECT_CONFLUENT_SERVER}" &>/dev/null; then
        _br="$(oc get statefulset broker -n "${PROJECT_CONFLUENT_SERVER}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
        printf '  %-42s %s\n' "Confluent cluster (${PROJECT_CONFLUENT_SERVER})" "${_br:-0} broker(s) ready"
    else
        printf '  %-42s %s\n' "Confluent cluster (${PROJECT_CONFLUENT_SERVER})" "not installed"
    fi
elif oc get statefulset broker -n "${PROJECT_CONFLUENT_SERVER}" &>/dev/null; then
    _br="$(oc get statefulset broker -n "${PROJECT_CONFLUENT_SERVER}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    printf '  %-42s %s\n' "Confluent cluster (${PROJECT_CONFLUENT_SERVER})" "${_br:-0} broker(s) ready"
else
    printf '  %-42s %s\n' "Confluent cluster (${PROJECT_CONFLUENT_SERVER})" "not installed"
fi
echo ""
