#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -uo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
: "${ENV_TARGET:=confluent}"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/confluent_operator_helpers.sh"   # loads common, confluent, operator_install, version_resolver helpers

# ==============================================================================
# Confluent Platform (operator mode) - status
# ------------------------------------------------------------------------------
# Read-only health report for the platform on Confluent for Kubernetes (CFK):
#   Operators         CFK / cp-fko Subscription, CSV phase, operator Deployment
#   Custom resources  phase, ready replicas and observedGeneration per CR
#   Pods, Storage     by label (CFK pods and the repo's own, PVCs)
#   Endpoints         bootstrap, web UI auth, Routes
#
# 1.2_confluent_status.sh hands over to this script in operator mode.
#
# Exit status: 0 if every expected component is ready, 1 otherwise - so this can
# gate a follow-up step in a pipeline (same contract as the scripts-mode 1.2).
#
# Note: `set -e` is deliberately NOT used here; this script inspects a possibly
# broken install and must report on everything before exiting.
# ==============================================================================

usage() { sed -n '/^# Confluent Platform (operator mode)/,/^# Note:/p' "${ZSH_ARGZERO}" | sed 's/^# \{0,1\}//'; }

while (( $# > 0 )); do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Use --help." >&2; exit 1 ;;
    esac
done

cfo_entry platform

NS="${PROJECT_CONFLUENT_SERVER}"

if ! oc get namespace "${NS}" &>/dev/null; then
    echo "[ERROR] Project '${NS}' does not exist. Nothing installed?" >&2
    exit 1
fi

_overall_ok=true

echo "=============================================================================="
echo " Confluent Platform status (operator mode) - project '${NS}'"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# Operators - one row per CFK / cp-fko Subscription in each platform target namespace
# ------------------------------------------------------------------------------
echo ""
echo "Operators:"
_targets="$(cfo_plan_targets platform 2>/dev/null)"
typeset -a _op_ns=()
for _t in "${(@f)_targets}"; do
    [[ -n "${_t}" ]] && _op_ns+=("${_t%% *}")
done
# The platform namespace is always reported: a CFK installed elsewhere (reuse) shows up through cfo_detect.
(( ${_op_ns[(Ie)${NS}]} )) || _op_ns=("${NS}" "${_op_ns[@]}")
_rows_seen=0
for _ns in "${_op_ns[@]}"; do
    _rows="$(cfo_operator_rows "${_ns}" 2>/dev/null)"
    [[ -z "${_rows}" ]] && continue
    for _row in "${(@f)_rows}"; do
        _f=("${(@s:	:)_row}")
        # subscription package channel approval state installedCSV csv-phase pending-plan deployment ready vs-starting
        _rows_seen=$(( _rows_seen + 1 ))
        printf '  %-26s %-26s channel=%-14s %-9s state=%-16s %s\n' \
            "${_ns}" "${_f[2]}" "${_f[3]}" "${_f[4]}" "${_f[5]}" "${_f[6]}"
        printf '  %-26s %-26s csv=%-10s deploy/%s ready=%s  pending-plan=%s  vs-starting=%s\n' \
            "" "" "${_f[7]}" "${_f[9]}" "${_f[10]}" "${_f[8]}" "${_f[11]}"
        if [[ "${_f[7]}" != Succeeded ]]; then
            _overall_ok=false
        fi
        _rd="${_f[10]}"
        if [[ "${_rd}" != */* || "${_rd%%/*}" != "${_rd#*/}" || "${_rd#*/}" == 0 ]]; then
            _overall_ok=false
        fi
        [[ "${_f[8]}" != "-" ]] && echo "  [WARN] InstallPlan ${_f[8]} in ${_ns} waits for approval (x.7_confluent_operator_upgrade.sh)."
    done
done
if (( _rows_seen == 0 )); then
    # No Subscription of ours in the target namespaces: report what watches the platform namespace.
    cfo_detect "${CFO_PKG_CFK}" "${NS}" >/dev/null 2>&1 || CFO_RESULT=none
    if [[ "${CFO_RESULT}" == reuse ]]; then
        printf '  %-26s %-26s %s\n' "${CFO_NS}" "${CFO_PKG_CFK}" "${CFO_CSV} (not one of the target namespaces)"
    else
        echo "  (no CFK operator watches ${NS} - run operator/1.0o_confluent_operators.sh)"
        _overall_ok=false
    fi
fi

# ------------------------------------------------------------------------------
# Custom resources
# ------------------------------------------------------------------------------
# check_cr <Kind> <name> <enabled>
check_cr() {
    local kind="$1" name="$2" enabled="$3" res st phase ready want gen obs
    if [[ "${enabled}" != "true" ]]; then
        printf '  %-34s %s\n' "${kind}/${name}" "SKIPPED (disabled in confluent_vars.sh)"
        return 0
    fi
    res="$(cfo_resource "${kind}")"
    if ! oc get "${res}" "${name}" -n "${NS}" &>/dev/null; then
        printf '  %-34s %s\n' "${kind}/${name}" "MISSING (${res} not found)"
        _overall_ok=false
        return 1
    fi
    st="$(oc get "${res}" "${name}" -n "${NS}" \
        -o jsonpath='{.status.phase}|{.status.readyReplicas}|{.status.replicas}|{.spec.replicas}|{.metadata.generation}|{.status.observedGeneration}' 2>/dev/null)"
    local -a p=("${(@s:|:)st}")
    phase="${p[1]:-}" ready="${p[2]:-0}" want="${p[3]:-${p[4]:-}}" gen="${p[5]:-}" obs="${p[6]:-}"
    if [[ "${(U)phase}" == RUNNING && -n "${want}" && "${ready:-0}" == "${want}" ]]; then
        printf '  %-34s %s\n' "${kind}/${name}" "READY phase=${phase} ready=${ready}/${want} generation=${gen:-?} observedGeneration=${obs:--}"
    else
        printf '  %-34s %s\n' "${kind}/${name}" "NOT READY phase=${phase:-none} ready=${ready:-0}/${want:-?} generation=${gen:-?} observedGeneration=${obs:--}"
        _overall_ok=false
    fi
}

echo ""
echo "Custom resources:"
check_cr KRaftController "${CF_KRAFT_CR}"   "true"
check_cr Kafka           "${CF_KAFKA_CR}"   "true"
check_cr SchemaRegistry  "${CF_SR_CR}"      "${CONFLUENT_INSTALL_SCHEMA_REGISTRY:-true}"
check_cr Connect         "${CF_CONNECT_CR}" "${CONFLUENT_INSTALL_CONNECT:-true}"
check_cr KsqlDB          "${CF_KSQLDB_CR}"  "${CONFLUENT_INSTALL_KSQLDB:-true}"
check_cr KafkaRestProxy  "${CF_KRP_CR}"     "${CONFLUENT_INSTALL_REST_PROXY:-true}"
# Prometheus and Alertmanager run inside the ControlCenter CR (next-gen C3).
check_cr ControlCenter   "${CF_C3_CR}"      "${CONFLUENT_INSTALL_CONTROL_CENTER:-true}"

# The C3 front proxy is a plain Deployment of the repo.
: "${CONFLUENT_AUTH_ENABLED:=true}"
if [[ "${CONFLUENT_INSTALL_CONTROL_CENTER:-true}" == "true" && "${CONFLUENT_AUTH_ENABLED}" == "true" ]]; then
    _fp="$(oc get deployment "${CFO_FRONT_PROXY}" -n "${NS}" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null)"
    if [[ -z "${_fp}" ]]; then
        printf '  %-34s %s\n' "Deployment/${CFO_FRONT_PROXY}" "MISSING (front proxy for the Control Center UI)"
        _overall_ok=false
    elif [[ "${_fp%%/*}" == "${_fp#*/}" && "${_fp#*/}" != 0 ]]; then
        printf '  %-34s %s\n' "Deployment/${CFO_FRONT_PROXY}" "READY (${_fp})"
    else
        printf '  %-34s %s\n' "Deployment/${CFO_FRONT_PROXY}" "NOT READY (${_fp})"
        _overall_ok=false
    fi
fi

# ------------------------------------------------------------------------------
# Pods - CFK pods (confluent-platform=true) and the repo's own (part-of=confluent)
# ------------------------------------------------------------------------------
echo ""
echo "Pods:"
_cols='NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,NODE:.spec.nodeName'
_pods="$( { oc get pods -n "${NS}" -l confluent-platform=true -o custom-columns="${_cols}" --no-headers 2>/dev/null
            oc get pods -n "${NS}" -l app.kubernetes.io/part-of=confluent -o custom-columns="${_cols}" --no-headers 2>/dev/null
          } | sort -u -k1,1)"

if [[ -z "${_pods}" ]]; then
    echo "  (no pods found)"
    _overall_ok=false
else
    echo "${_pods}" | while read -r _name _phase _ready _restarts _node; do
        printf '  %-38s %-10s ready=%-6s restarts=%-4s %s\n' \
            "${_name}" "${_phase}" "${_ready}" "${_restarts}" "${_node}"
    done
    while read -r _name _phase _ready _restarts _node; do
        [[ -z "${_name}" ]] && continue
        if [[ "${_phase}" != "Running" || "${_ready}" != "true" ]]; then
            # A finished Job pod (the connect-plugins loader is a Pod, not a Job) is not a failure.
            [[ "${_phase}" == Succeeded ]] || _overall_ok=false
        fi
        if [[ "${_restarts}" =~ ^[0-9]+$ ]] && (( _restarts >= 5 )); then
            echo "  [WARN] ${_name} has restarted ${_restarts} times."
        fi
    done <<< "${_pods}"
fi

# ------------------------------------------------------------------------------
# Storage - CFK labels its PVCs through spec.injectLabels (V12)
# ------------------------------------------------------------------------------
echo ""
echo "Storage:"
_pvcs="$(oc get pvc -n "${NS}" -l app.kubernetes.io/part-of=confluent \
    -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,SIZE:.status.capacity.storage' \
    --no-headers 2>/dev/null)"

if [[ -z "${_pvcs}" ]]; then
    echo "  (no Confluent PVCs found)"
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
echo "  in-cluster bootstrap: $(cf_bootstrap_internal "${NS}")"
_ext="$(cf_external_bootstrap "${NS}")"
[[ -n "${_ext}" ]] && echo "  external bootstrap:   ${_ext}"
_sec=""
oc get kafkas.platform.confluent.io "${CF_KAFKA_CR}" -n "${NS}" &>/dev/null && _sec="$(cf_live_security "${NS}" 2>/dev/null)"
_s=(${=_sec})
if [[ -n "${_sec}" ]]; then
    echo "  Kafka auth:           in-cluster ${_s[1]}${${_s[3]:#-}:+ / ${_s[3]}}${${_s[4]:#-}:+, external SASL_SSL / ${_s[4]}}"
fi

# Web UI auth state, read from the live secrets, as the scripts-mode 1.2 does.
: "${CONFLUENT_AUTH_SECRET:=confluent-auth}"
_auth_user="$(oc get secret "${CONFLUENT_AUTH_SECRET}" -n "${NS}" -o jsonpath='{.data.username}' 2>/dev/null | base64 --decode || true)"
if oc get secret "${CONFLUENT_AUTH_SECRET}-oauth" -n "${NS}" &>/dev/null; then
    echo "  web UI auth: openshift (Control Center behind cluster login, no shared password)"
    echo "    grant access: oc policy add-role-to-user view <user> -n ${NS}"
elif [[ -n "${_auth_user}" ]]; then
    echo "  web UI auth: basic, user '${_auth_user}'"
    echo "    password: oc get secret ${CONFLUENT_AUTH_SECRET} -n ${NS} -o jsonpath='{.data.password}' | base64 --decode"
else
    echo "  web UI auth: NONE (endpoints are unauthenticated)"
fi
_routes="$(oc get routes -n "${NS}" -l app.kubernetes.io/part-of=confluent \
    -o custom-columns='NAME:.metadata.name,HOST:.spec.host' --no-headers 2>/dev/null)"
if [[ -z "${_routes}" ]]; then
    echo "  (no routes - CONFLUENT_CREATE_ROUTES=${CONFLUENT_CREATE_ROUTES:-true})"
else
    echo "${_routes}" | while read -r _name _host; do
        printf '  %-18s https://%s\n' "${_name}" "${_host}"
    done
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
    echo "[WARN] or its CR: oc describe <kind>.platform.confluent.io <name> -n ${NS}" >&2
    exit 1
fi
