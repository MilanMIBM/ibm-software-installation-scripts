#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
: "${ENV_TARGET:=confluent}"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/confluent_operator_helpers.sh"   # loads common, confluent, operator_install, version_resolver helpers

# ==============================================================================
# Confluent Platform - wipe a scripts-mode install (any mode)
# ------------------------------------------------------------------------------
# Removes what the scripts-mode install (CONFLUENT_DEPLOY_MODE=scripts) created
# in PROJECT_CONFLUENT_SERVER, so the namespace can take an operator-mode
# install. Independent: it calls no other x.* script (plan 15.8).
#
# Refuses when the namespace holds CFK CRs (kafkas.platform.confluent.io):
# that is an operator-mode install - use x.0_confluent_uninstall.sh.
#
# Deletes, in this order (each step printed as [i/N]):
#   Deployments, the StatefulSet broker, Services (+ broker, broker-headless,
#   broker-N-external), Routes, NetworkPolicies, ConfigMaps and leftover pods
#   labelled app.kubernetes.io/part-of=confluent; the secrets scripts mode
#   creates (SASL, MDS, LDAP, Keycloak, the two TLS secrets). The pull secret
#   (confluent-registry) and the auth secrets (confluent-auth*) are kept:
#   operator mode reuses them.
#   --include-flink also removes the scripts-mode Flink add-on in
#   PROJECT_CONFLUENT_FLINK: FlinkEnvironment CRs (mixed setups), the remaining
#   FlinkDeployments, the CMF and Flink operator Helm releases, route cmf and the
#   Flink secrets.
#
# Data: --keep-data keeps the PVCs, labels them
# confluent.ibm-scripts/wiped-from=scripts-mode and lists them. They are a
# backup only: CFK cannot mount combined-mode KRaft data as its own (plan O19);
# move data with ClusterLink or by re-producing it. Without --keep-data the PVCs
# are deleted after typing the namespace name (or --confirm-delete-data <ns>);
# that confirmation is asked before the first delete, so a "no" deletes nothing.
#
# Never touches CRDs, the namespace itself, OperatorGroups, Subscriptions or
# other namespaces.
#
# Usage:
#   ./x.8_confluent_wipe_scripts_mode.sh [--keep-data] [--include-flink]
#        [--dry-run] [--yes] [--confirm-delete-data <namespace>]
#
#   --keep-data              keep (and label) the PVCs
#   --include-flink          also wipe the scripts-mode Flink add-on
#   --dry-run                print every delete, delete nothing
#   --yes                    skip the "continue?" question (not the data confirmation)
#   --confirm-delete-data N  confirm deleting the PVCs of namespace N without a terminal
#
# Exit status: 0 ok, 1 error, 2 blocked (CFK CRs found).
# ==============================================================================

usage() { sed -n '/^# Confluent Platform - wipe a scripts-mode install/,/^# Exit status/p' "${ZSH_ARGZERO}" | sed 's/^# \{0,1\}//'; }

KEEP_DATA=false
INCLUDE_FLINK=false
DRY_RUN=false
ASSUME_YES=false
CONFIRM_NS=""

while (( $# > 0 )); do
    case "$1" in
        --keep-data)           KEEP_DATA=true; shift ;;
        --include-flink)       INCLUDE_FLINK=true; shift ;;
        --dry-run)             DRY_RUN=true; shift ;;
        --yes|-y)              ASSUME_YES=true; shift ;;
        --confirm-delete-data) h_need_value "$1" "${2:-}"; CONFIRM_NS="$2"; shift 2 ;;
        -h|--help)             usage; exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Use --help." >&2; exit 1 ;;
    esac
done
export DRY_RUN

if [[ -z "${OC_LOGIN:-}" ]]; then
    echo "[ERROR] OC_LOGIN is not set - check the cluster login in your config." >&2
    exit 1
fi
eval "${OC_LOGIN}"

NS="${PROJECT_CONFLUENT_SERVER:?PROJECT_CONFLUENT_SERVER is not set}"
LABEL="${CFO_LABEL_PART_OF}"

_ns_rc=0
_ns="$(_cfo_read get namespace "${NS}" -o name)" || _ns_rc=$?
(( _ns_rc == 0 )) || { echo "[ERROR] Cannot read namespace ${NS}." >&2; exit 1; }
if [[ -z "${_ns}" ]]; then
    echo "[INFO] Project '${NS}' does not exist - nothing to wipe."
    exit 0
fi

# Fail closed: an unreadable answer is not "no CFK CRs".
_kafka_rc=0
_kafka="$(_cfo_read get kafkas.platform.confluent.io -n "${NS}" -o name)" || _kafka_rc=$?
if (( _kafka_rc != 0 )); then
    echo "[ERROR] Cannot check ${NS} for CFK Kafka CRs - nothing deleted." >&2
    exit 1
fi
if [[ -n "${_kafka}" ]]; then
    cfo_banner "Namespace ${NS} holds CFK CRs (an operator-mode install) - x.8 wipes scripts-mode installs only" \
        "found: ${${(f)_kafka}[1]} in ${NS}" \
        "use ${CF_PLATFORM_DIR}/utility_scripts_confluent_platform/x.0_confluent_uninstall.sh instead"
    exit "${CFO_RC_BLOCKED}"
fi

# ------------------------------------------------------------------------------
# The plan
# ------------------------------------------------------------------------------
_replicas="${CONFLUENT_BROKER_REPLICAS:-3}"
[[ "${_replicas}" == <-> ]] || _replicas=3
typeset -a _ext_svcs=()
for (( _i = 0; _i < _replicas; _i++ )); do _ext_svcs+=("broker-${_i}-external"); done
typeset -a _secrets=(
    "${CONFLUENT_SASL_SECRET:-confluent-sasl}" "${CONFLUENT_MDS_SECRET:-confluent-mds}"
    "${CONFLUENT_LDAP_SECRET:-confluent-ldap}" "${CONFLUENT_KEYCLOAK_SECRET:-confluent-keycloak}"
    "${CONFLUENT_EXTERNAL_TLS_SECRET:-confluent-kafka-tls}" "${CONFLUENT_INTERNAL_TLS_SECRET:-confluent-kafka-internal-tls}")

typeset -a STEPS=(
    "Deployments (${LABEL})|oc delete deployment -n ${NS} -l ${LABEL} --ignore-not-found --wait=true"
    "StatefulSet broker|oc delete statefulset broker -n ${NS} --ignore-not-found --wait=true"
    "Services (${LABEL})|oc delete service -n ${NS} -l ${LABEL} --ignore-not-found"
    "Services broker, broker-headless, broker-N-external|oc delete service broker broker-headless ${_ext_svcs[*]} -n ${NS} --ignore-not-found"
    "Routes (${LABEL})|oc delete route -n ${NS} -l ${LABEL} --ignore-not-found"
    "NetworkPolicies (${LABEL})|oc delete networkpolicy -n ${NS} -l ${LABEL} --ignore-not-found"
    "ConfigMaps (${LABEL}, confluent-monitoring-config)|oc delete configmap -n ${NS} -l ${LABEL} --ignore-not-found"
    "ConfigMap confluent-monitoring-config|oc delete configmap confluent-monitoring-config -n ${NS} --ignore-not-found"
    "leftover pods (${LABEL})|oc delete pod -n ${NS} -l ${LABEL} --ignore-not-found --wait=true"
    "secrets made by scripts mode (pull and auth secrets kept)|oc delete secret ${_secrets[*]} -n ${NS} --ignore-not-found"
)

FNS="${PROJECT_CONFLUENT_FLINK:-}"
if ${INCLUDE_FLINK}; then
    if [[ -z "${FNS}" ]]; then
        echo "[ERROR] --include-flink: PROJECT_CONFLUENT_FLINK is not set." >&2
        exit 1
    fi
    command -v helm >/dev/null 2>&1 || { echo "[ERROR] --include-flink needs helm on PATH (the Flink add-on is a Helm install)." >&2; exit 1; }
fi

_pvcs="$(oc get pvc -n "${NS}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
typeset -a PVCS=()
for _p in ${(f)_pvcs}; do
    [[ "${_p}" == confluent-broker-data-* || "${_p}" == data-broker-* ]] && PVCS+=("${_p}")
done
for _p in ${(f)"$(oc get pvc -n "${NS}" -l "${LABEL}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"}; do
    (( ${PVCS[(Ie)${_p}]} )) || PVCS+=("${_p}")
done
typeset -a FPVCS=()
if ${INCLUDE_FLINK}; then
    FPVCS=(${(f)"$(oc get pvc -n "${FNS}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"})
fi

_dr=""
[[ "${DRY_RUN}" == true ]] && _dr=" - DRY RUN"
echo "=============================================================================="
echo " Wipe the scripts-mode Confluent install - project '${NS}'${_dr}"
echo "=============================================================================="
_n=$(( ${#STEPS} + 1 ))
${INCLUDE_FLINK} && _n=$(( _n + 1 ))
_what="platform objects"
${INCLUDE_FLINK} && _what+=", the Flink add-on in ${FNS}"
echo "  steps   : ${_n} (${_what}, data)"
echo "  PVCs    : ${PVCS[*]:-(none)}${FPVCS:+ / Flink: ${FPVCS[*]}}"
if ${KEEP_DATA}; then
    echo "  data    : kept (labelled ${CFO_LABEL_WIPED}) - a backup only, CFK cannot mount it (plan O19)"
else
    echo "  data    : PVCs DELETED after typed confirmation - all Kafka topic data is lost"
fi
echo "  kept    : the namespace, CRDs, OperatorGroups, Subscriptions, ${CONFLUENT_PULL_SECRET:-confluent-registry}, ${CONFLUENT_AUTH_SECRET:-confluent-auth}*"
echo ""

if [[ "${DRY_RUN}" != true && "${ASSUME_YES}" != true ]]; then
    cf_continue_or_abort
fi

typeset -a _all_pvcs=()
for _p in "${PVCS[@]}"; do _all_pvcs+=("${NS}/${_p}"); done
for _p in "${FPVCS[@]}"; do _all_pvcs+=("${FNS}/${_p}"); done

# The data confirmation comes before the first delete: an unconfirmed run must leave everything in place,
# not remove the workloads and then stop at the PVCs.
if ! ${KEEP_DATA} && (( ${#_all_pvcs} )) && [[ "${DRY_RUN}" != true ]]; then
    _ok=false
    if [[ -n "${CONFIRM_NS}" ]]; then
        [[ "${CONFIRM_NS}" == "${NS}" ]] && _ok=true \
            || echo "[ERROR] --confirm-delete-data '${CONFIRM_NS}' does not match namespace '${NS}'." >&2
    else
        _answer=""
        if { print -n "Type the namespace name '${NS}' to delete ${#_all_pvcs} PVC(s) and their data: " > /dev/tty \
                && read -r _answer < /dev/tty; } 2>/dev/null; then
            [[ "${_answer}" == "${NS}" ]] && _ok=true
        else
            echo "[ERROR] No terminal for the confirmation: pass --confirm-delete-data ${NS} or --keep-data." >&2
        fi
    fi
    if ! ${_ok}; then
        echo "[INFO] Not confirmed - nothing deleted. Re-run with --keep-data or confirm the delete."
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
_i=0
for _s in "${STEPS[@]}"; do
    (( _i += 1 ))
    echo "[${_i}/${_n}] ${_s%%|*}"
    cf_dry_run --ignore-errors ${=_s#*|}
done

# ------------------------------------------------------------------------------
if ${INCLUDE_FLINK}; then
    (( _i += 1 ))
    echo "[${_i}/${_n}] Flink add-on in ${FNS}"
    _envs="$(_cfo_read get flinkenvironments.platform.confluent.io -n "${FLINK_CFK_NAMESPACE:-${FNS}}" -o name)" \
        || { echo "[ERROR] Cannot read the FlinkEnvironments - Flink not wiped." >&2; exit 1; }
    if [[ -n "${_envs}" ]]; then
        # Mixed setups: CMF must still run for its environments to go (plan 15.14 item 2).
        source "${CF_FLINK_DIR}/flink_cmf_connect.sh"
        [[ "${DRY_RUN}" == true ]] || cmf_connect || { echo "[ERROR] Cannot reach CMF to delete its environments." >&2; exit 1; }
        for _e in ${(f)_envs}; do
            _frc=0
            cfo_flinkenv_delete "${FLINK_CFK_NAMESPACE:-${FNS}}" "${_e#*/}" || _frc=$?
            (( _frc == 0 )) || { echo "[ERROR] FlinkEnvironment ${_e#*/} could not be deleted - Flink not wiped further." >&2; exit 1; }
        done
    fi
    echo "  FlinkDeployments (the operator must still run)"
    cf_dry_run --ignore-errors oc delete flinkdeployments.flink.apache.org --all -n "${FNS}" --wait=true --timeout=180s
    for _rel in "${FLINK_CMF_RELEASE_NAME:-cmf}" "${FLINK_OPERATOR_RELEASE_NAME:-cp-flink-kubernetes-operator}"; do
        if helm status "${_rel}" -n "${FNS}" >/dev/null 2>&1; then
            echo "  Helm release ${_rel}"
            cf_dry_run --ignore-errors helm uninstall "${_rel}" -n "${FNS}" --wait --timeout 300s
        fi
    done
    echo "  route cmf, Flink secrets"
    cf_dry_run --ignore-errors oc delete route cmf -n "${FNS}" --ignore-not-found
    cf_dry_run --ignore-errors oc delete secret ${FLINK_LICENSE_SECRET:-} ${FLINK_S3_SECRET:-} "${FLINK_AUTH_SECRET:-cmf-oauth}" -n "${FNS}" --ignore-not-found
fi

# ------------------------------------------------------------------------------
(( _i += 1 ))
echo "[${_i}/${_n}] Data"
if (( ${#_all_pvcs} == 0 )); then
    echo "  (no PVCs)"
elif ${KEEP_DATA}; then
    for _q in "${_all_pvcs[@]}"; do
        cf_dry_run oc label pvc "${_q#*/}" -n "${_q%%/*}" "${CFO_LABEL_WIPED}" --overwrite \
            || { echo "[ERROR] Labelling PVC ${_q} failed." >&2; exit 1; }
    done
    echo "[INFO] PVCs kept and labelled ${CFO_LABEL_WIPED}:"
    for _q in "${_all_pvcs[@]}"; do echo "         ${_q}"; done
    echo "[INFO] They are a backup only (CFK cannot use combined-mode KRaft data); delete them later with:"
    echo "         oc delete pvc -n ${NS} -l ${CFO_LABEL_WIPED}"
else
    # Confirmed before step 1 (or --dry-run).
    for _q in "${_all_pvcs[@]}"; do
        cf_dry_run oc delete pvc "${_q#*/}" -n "${_q%%/*}" --ignore-not-found --wait=false \
            || { echo "[ERROR] Deleting PVC ${_q} failed." >&2; exit 1; }
    done
fi

echo ""
[[ "${DRY_RUN}" == true ]] && echo "[INFO] --dry-run: nothing was deleted."
_full="${CF_PLATFORM_DIR}/full_installprocess-confluent_platform.sh"
${INCLUDE_FLINK} && _full+=" (and ${CF_FLINK_DIR}/full_installprocess-confluent_flink.sh)"
echo "next: re-run ${_full} with CONFLUENT_DEPLOY_MODE=operator"
