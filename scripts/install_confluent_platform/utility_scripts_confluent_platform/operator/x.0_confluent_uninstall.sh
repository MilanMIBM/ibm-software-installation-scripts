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
# Confluent Platform (operator mode) - uninstall
# ------------------------------------------------------------------------------
# Removes what the operator-mode install created in PROJECT_CONFLUENT_SERVER, in
# Confluent's documented order (CFK must be alive while its CRs go):
#   [1/7] list the CFK CRs (CRs without our owner label are listed and left)
#   [2/7] application resources: ClusterLink ConfluentRolebinding Connector
#         KafkaTopic SchemaExporter Schema KafkaRestClass
#   [3/7] stateless components: Connect SchemaRegistry KafkaRestProxy USMAgent
#   [4/7] KsqlDB ControlCenter, then Kafka KRaftController
#   [5/7] repo objects: front proxy, routes, NetworkPolicies, derived and named
#         secrets, the connect-plugins loader, OpenLDAP / Keycloak
#   [6/7] --remove-operator: our Subscriptions, CSVs and OperatorGroups
#   [7/7] the namespace (only when it is safe, see below); --delete-crds last
#
# Data (plan 15.14 item 1): CFK deletes a stateful CR's PVCs with the CR. With
# the default (keep data), the PVs behind the data PVCs of Kafka, KRaft, ksqlDB
# and Control Center (incl. Prometheus) are first set to reclaim Retain and
# labelled confluent.ibm-scripts/retained-from=<ns>.<cr>; their names are
# printed. Re-attaching a retained PV is not documented by Confluent: the PVs
# are a backup and recovery is manual. --delete-data skips that, and also
# deletes the PVCs left behind (connect-plugins, ...).
#
# The namespace is deleted only without --keep-project AND with
# --remove-operator AND when every Subscription/OperatorGroup in it is ours AND
# it is not the Flink namespace; otherwise it is kept, with the reason.
#
# Flink add-on: when DO_FLINK_UNINSTALL is true (default) and the config holds
# the Flink settings, x.0_flink_uninstall.sh runs first (it picks its own mode).
#
# Usage:
#   ./x.0_confluent_uninstall.sh [--keep-data | --delete-data] [--keep-project]
#        [--remove-operator] [--delete-crds] [--force-finalizers] [--yes] [--dry-run]
#
#   --keep-data         keep the data (default): PVs set to reclaim Retain
#   --delete-data       no Retain patch; leftover PVCs are deleted too
#   --keep-project      never delete the namespace
#   --remove-operator   also remove our CFK (and cp-fko) Subscriptions/CSVs
#   --delete-crds       at the end, offer the platform.confluent.io CRDs and (with
#                       the Flink add-on configured) the flink.apache.org CRDs,
#                       each only when nothing uses it and each on its own y/N
#                       prompt (never --yes); a "no" on one still offers the other
#   --force-finalizers  clear the finalizers of a CR that does not go in time
#   --yes               skip the interactive confirmation (default)
#   --dry-run           print what would be deleted, delete nothing
#
# Only the --delete-crds flag enables CRD deletion: CONFLUENT_DELETE_CRDS and
# DELETE_CRDS are ignored. Internal (x.1_confluent_reinstall.sh):
# CFO_X0_KEEP_STATEFUL=1 removes steps 2, 3 and 5 only and keeps the stateful
# CRs, so 1.1 can re-apply them in place; step 5 then keeps the secrets, the
# identity store and the Kafka CR's routes, which the running brokers use.
#
# Exit status: 0 ok, 1 error, 2 blocked (--delete-crds refused).
# ==============================================================================

# CRD deletion comes from the flag only (plan 15.8).
unset CONFLUENT_DELETE_CRDS DELETE_CRDS

usage() { sed -n '/^# Confluent Platform (operator mode) - uninstall/,/^# Exit status/p' "${ZSH_ARGZERO}" | sed 's/^# \{0,1\}//'; }

KEEP_DATA=true
KEEP_PROJECT=false
ASSUME_YES=true
DRY_RUN=false
REMOVE_OPERATOR=false
DELETE_CRDS_FLAG=false
FORCE_FINALIZERS=false
DO_FLINK_UNINSTALL="${DO_FLINK_UNINSTALL:-true}"
KEEP_STATEFUL=false
[[ "${CFO_X0_KEEP_STATEFUL:-}" == 1 ]] && KEEP_STATEFUL=true
_keep_given=false
_delete_given=false

while (( $# > 0 )); do
    case "$1" in
        --keep-data)        KEEP_DATA=true; _keep_given=true; shift ;;
        --delete-data)      KEEP_DATA=false; _delete_given=true; shift ;;
        --keep-project)     KEEP_PROJECT=true; shift ;;
        --remove-operator)  REMOVE_OPERATOR=true; shift ;;
        --delete-crds)      DELETE_CRDS_FLAG=true; shift ;;
        --force-finalizers) FORCE_FINALIZERS=true; shift ;;
        --yes|-y)           ASSUME_YES=true; shift ;;
        --dry-run)          DRY_RUN=true; shift ;;
        -h|--help)          usage; exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Use --help." >&2; exit 1 ;;
    esac
done
if ${_keep_given} && ${_delete_given}; then
    echo "[ERROR] --keep-data and --delete-data exclude each other." >&2
    exit 1
fi
if ${KEEP_STATEFUL} && { ! ${KEEP_DATA} || ${REMOVE_OPERATOR} || ${DELETE_CRDS_FLAG}; }; then
    echo "[ERROR] CFO_X0_KEEP_STATEFUL=1 (reinstall) cannot be combined with --delete-data, --remove-operator or --delete-crds." >&2
    exit 1
fi
export DRY_RUN

# Static checks, login and the read-only scripts-mode guard before any write
# (contract 1.2): a blocked platform namespace must not lose its Flink add-on first.
cfo_entry platform

# ------------------------------------------------------------------------------
# Flink add-on first (as the scripts-mode x.0), so no Flink job is left reading
# from brokers that are going away. It dispatches to its own operator twin.
# ------------------------------------------------------------------------------
FLINK_UNINSTALL="${CF_FLINK_DIR}/utility_scripts_confluent_flink/x.0_flink_uninstall.sh"
if [[ "${DO_FLINK_UNINSTALL}" != "true" ]]; then
    echo "[INFO] Skipping Flink addon uninstall (DO_FLINK_UNINSTALL=${DO_FLINK_UNINSTALL})."
elif ! cf_flink_configured; then
    echo "[INFO] No Flink settings in confluent_vars.sh - skipping Flink addon uninstall."
else
    echo "[INFO] Flink settings detected - uninstalling the Flink addon first."
    echo ""
    # Only the flags the Flink x.0 of the resolved Flink mode accepts.
    _flink_args=()
    # CONTRACT-DEVIATION (approved 2026-11-18): --keep-data (the default) goes on to the Flink x.0, which then
    # keeps the CMF environment and removes the FlinkEnvironment CR only.
    ${KEEP_DATA} && _flink_args+=(--keep-data)
    ${KEEP_PROJECT} && _flink_args+=(--keep-project)
    ${ASSUME_YES} && _flink_args+=(--yes)
    [[ "${DRY_RUN}" == true ]] && _flink_args+=(--dry-run)
    if cf_flink_operator_mode; then
        ${REMOVE_OPERATOR} && _flink_args+=(--remove-operator)
        ${FORCE_FINALIZERS} && _flink_args+=(--force-finalizers)
    fi
    _flink_rc=0
    zsh "${FLINK_UNINSTALL}" "${_flink_args[@]}" || _flink_rc=$?
    if (( _flink_rc != 0 )); then
        echo "[ERROR] Flink addon uninstall exited ${_flink_rc}; the Confluent Platform was not touched." >&2
        echo "[ERROR] Re-run with DO_FLINK_UNINSTALL=false to remove the platform alone." >&2
        exit "${_flink_rc}"
    fi
    unset _flink_rc _flink_args
    echo ""
fi

# --delete-crds: each CRD group is checked (in use?) and offered on its own yes/no. A "no" or a refusal on
# one group still lets the other be checked (user request 2026-11-18). The Flink CRDs are offered only when
# the Flink add-on is configured: they are shared with any cp-fko install, which the in-use check catches.
_x0_delete_crd_groups() {
    local rc=0 one
    echo "[INFO] --delete-crds: checking the platform.confluent.io CRDs"
    one=0; cfo_delete_crds cfk || one=$?
    (( one > rc )) && rc=${one}
    if cf_flink_configured; then
        echo ""
        echo "[INFO] --delete-crds: checking the flink.apache.org CRDs (Flink add-on configured)"
        one=0; cfo_delete_crds flink || one=$?
        (( one > rc )) && rc=${one}
    fi
    return "${rc}"
}

NS="${PROJECT_CONFLUENT_SERVER}"
_ns_rc=0
_ns_found="$(_cfo_read get namespace "${NS}" -o name)" || _ns_rc=$?
if (( _ns_rc != 0 )); then
    echo "[ERROR] Cannot read namespace ${NS} - nothing deleted." >&2
    exit 1
fi
if [[ -z "${_ns_found}" ]]; then
    echo "[INFO] Project '${NS}' does not exist - nothing to uninstall."
    # A finished uninstall leaves no namespace, which is exactly when --delete-crds is run (live clean-up
    # test 2026-11-18): the CRD step still runs, with its usual in-use checks and yes/no confirmation.
    if ${DELETE_CRDS_FLAG}; then
        _final_rc=0
        _x0_delete_crd_groups || _final_rc=$?
        exit "${_final_rc}"
    fi
    exit 0
fi

_cfo_int "${CONFLUENT_OPERATOR_COMPONENT_TIMEOUT:-}" 600; T_COMPONENT="${REPLY}"
_cfo_int "${CONFLUENT_OPERATOR_KAFKA_TIMEOUT:-}" 900; T_KAFKA="${REPLY}"
_cfo_owner; OWNER="${REPLY}"

typeset -a GROUP_FLAGS=() ALL_RETAINED=()
${FORCE_FINALIZERS} && GROUP_FLAGS+=(--force-finalizers)
${KEEP_DATA} || GROUP_FLAGS+=(--delete-data)

# _group <step> <title> <timeout> <Kind>... - one cfo_delete_group with our flags; stops the run on failure.
_group() {
    local step="$1" title="$2" t="$3" rc=0
    shift 3
    echo "${step} ${title}"
    cfo_delete_group "${NS}" "${t}" "${GROUP_FLAGS[@]}" "$@" || rc=$?
    ALL_RETAINED+=("${CFO_RETAINED_PVS[@]}")
    if (( rc != 0 )); then
        echo "[ERROR] ${title}: delete failed (exit ${rc}) - stopping; later steps did not run." >&2
        exit 1
    fi
}

_dr=""
[[ "${DRY_RUN}" == true ]] && _dr=" - DRY RUN"
echo "=============================================================================="
echo " Confluent Platform uninstall (operator mode) - project '${NS}'${_dr}"
echo "=============================================================================="

# ------------------------------------------------------------------------------
echo "[1/7] Custom resources"
_crs_rc=0
CRS="$(cfo_list_crs "${NS}")" || _crs_rc=$?
if (( _crs_rc != 0 )); then
    echo "[ERROR] Cannot list the CFK CRs in ${NS} - nothing deleted." >&2
    exit 1
fi
typeset -a _foreign=()
if [[ -z "${CRS}" ]]; then
    echo "  (none)"
else
    for _l in ${(f)CRS}; do
        if [[ "${_l##* }" == true ]]; then
            echo "  ${_l% *}"
        else
            _foreign+=("${_l% *}")
        fi
    done
fi
(( ${#_foreign} )) && echo "[INFO] Not ours (no ${CFO_LABEL_OWNER_KEY}=${OWNER}), left in place: ${_foreign[*]}"
if ${KEEP_STATEFUL}; then
    echo "  Reinstall: Kafka, KRaft, ksqlDB and Control Center CRs are kept with their data."
elif ${KEEP_DATA}; then
    echo "  Data: kept - the PVs of the Kafka, KRaft, ksqlDB and Control Center PVCs get reclaim Retain first."
else
    echo "  Data: --delete-data - the PVs follow their StorageClass reclaim policy; leftover PVCs are deleted."
fi
echo ""

if [[ "${DRY_RUN}" != true && "${ASSUME_YES}" != true ]]; then
    printf "Type the project name '%s' to confirm: " "${NS}"
    read -r _confirm
    if [[ "${_confirm}" != "${NS}" ]]; then
        echo "[INFO] Confirmation did not match - aborted. Nothing was deleted."
        exit 1
    fi
    echo ""
fi

_groups=("${(@f)$(cfo_delete_order)}")

# ------------------------------------------------------------------------------
_group "[2/7]" "Application resources" "${T_COMPONENT}" ${=_groups[1]}

# ------------------------------------------------------------------------------
_group "[3/7]" "Stateless components" "${T_COMPONENT}" Connect SchemaRegistry KafkaRestProxy USMAgent

# ------------------------------------------------------------------------------
if ${KEEP_STATEFUL}; then
    echo "[4/7] Stateful components"
    echo "[INFO] Kafka, KRaft, ksqlDB and Control Center CRs kept with their data; 1.1 re-applies them (CFK reconciles in place)."
else
    _group "[4/7]" "ksqlDB and Control Center" "${T_COMPONENT}" KsqlDB ControlCenter
    _group "     " "Kafka and KRaft (CFK still running)" "${T_KAFKA}" Kafka KRaftController
    if ! ${KEEP_DATA}; then
        echo "[INFO] --delete-data: deleting the PVCs left in ${NS} (${CFO_LABEL_PART_OF})."
        cf_dry_run oc delete pvc -n "${NS}" -l "${CFO_LABEL_PART_OF}" --wait=false --ignore-not-found \
            || { echo "[ERROR] Deleting the leftover PVCs failed." >&2; exit 1; }
    else
        echo "[INFO] Other PVCs (${CFO_LABEL_PART_OF}, e.g. connect-plugins) kept."
    fi
fi

# ------------------------------------------------------------------------------
echo "[5/7] Repo objects"
_auth="${CONFLUENT_AUTH_SECRET:-confluent-auth}"
if ${KEEP_STATEFUL}; then
    # Reinstall (x.1) keeps Kafka, KRaft, ksqlDB and C3 running, so only objects 1.1 rebuilds as they were go:
    # - routes of ours except CFK's Kafka routes (kafka-bootstrap, kafka-<N>: they carry our label through
    #   externalAccess.route.labels but belong to the kept Kafka CR);
    # - no secrets and no OpenLDAP / Keycloak: the running brokers mount the SASL/TLS secrets, and 1.0 would
    #   mint new passwords and a new CA for missing ones (a password change under a rolling restart splits the
    #   cluster), MDS reads the identity store and 1.1 cannot recreate it.
    typeset -a _own_routes=()
    for _r in ${(f)"$(oc get route -n "${NS}" -l "${CFO_LABEL_OWNER_KEY}=${OWNER}" -o name 2>/dev/null || true)"}; do
        [[ "${_r#*/}" == "${CF_KAFKA_CR}-bootstrap" || "${_r#*/}" == ${CF_KAFKA_CR}-<-> ]] && continue
        _own_routes+=("${_r}")
    done
    typeset -a _repo_steps=(
        "front proxy, NetworkPolicies, ConfigMaps (ours)|oc delete deployment,service,networkpolicy,configmap -n ${NS} -l ${CFO_LABEL_OWNER_KEY}=${OWNER} --ignore-not-found"
        "connect-plugins loader|oc delete pod connect-plugins-loader -n ${NS} --ignore-not-found"
        "front proxy secrets|oc delete secret ${_auth}-gateway ${_auth}-oauth -n ${NS} --ignore-not-found"
    )
    (( ${#_own_routes} )) && _repo_steps+=("routes (ours; the Kafka CR's routes stay)|oc delete ${_own_routes[*]} -n ${NS} --ignore-not-found")
    unset _r
else
typeset -a _repo_steps=(
    "front proxy, routes, NetworkPolicies, ConfigMaps (ours)|oc delete deployment,service,route,networkpolicy,configmap -n ${NS} -l ${CFO_LABEL_OWNER_KEY}=${OWNER} --ignore-not-found"
    "connect-plugins loader|oc delete pod connect-plugins-loader -n ${NS} --ignore-not-found"
    "OpenLDAP / Keycloak (x.4_confluent_user_store.sh)|oc delete deployment/openldap svc/openldap deployment/keycloak svc/keycloak route/keycloak -n ${NS} --ignore-not-found"
    "secrets derived for CFK|oc delete secret -n ${NS} -l ${CFO_LABEL_DERIVED_KEY} --ignore-not-found"
    "secrets made by operator mode (ours)|oc delete secret -n ${NS} -l ${CFO_LABEL_OWNER_KEY}=${OWNER} --ignore-not-found"
    "front proxy secrets|oc delete secret ${_auth}-gateway ${_auth}-oauth -n ${NS} --ignore-not-found"
    "named secrets (as the scripts-mode uninstall)|oc delete secret ${CONFLUENT_SASL_SECRET:-confluent-sasl} ${CONFLUENT_MDS_SECRET:-confluent-mds} ${CONFLUENT_LDAP_SECRET:-confluent-ldap} ${CONFLUENT_KEYCLOAK_SECRET:-confluent-keycloak} ${CONFLUENT_EXTERNAL_TLS_SECRET:-confluent-kafka-tls} ${CONFLUENT_INTERNAL_TLS_SECRET:-confluent-kafka-internal-tls} -n ${NS} --ignore-not-found"
)
fi
_k=0
for _s in "${_repo_steps[@]}"; do
    (( _k += 1 ))
    echo "  (${_k}/${#_repo_steps}) ${_s%%|*}"
    # Names only in argv (no secret value); a delete of something already gone is not an error.
    cf_dry_run --ignore-errors ${=_s#*|}
done
echo "[INFO] Service account, SCC binding, pull secret and ${_auth} preserved (re-run 1.0_confluent_prep.sh to refresh them)."
${KEEP_STATEFUL} && echo "[INFO] Reinstall: the SASL/TLS/MDS secrets, the CFK-derived secrets and OpenLDAP / Keycloak are kept for the running brokers."

if ${KEEP_STATEFUL}; then
    echo ""
    echo "[INFO] Reinstall teardown complete (stateful CRs kept)."
    exit 0
fi

# ------------------------------------------------------------------------------
echo "[6/7] Operators"
if ${REMOVE_OPERATOR}; then
    _targets="$(cfo_plan_targets platform)" || { echo "[ERROR] Cannot work out the operator targets." >&2; exit 1; }
    for _t in ${(f)_targets}; do
        _tns="${_t%% *}"
        for _pkg in ${=_t#* }; do
            _rc=0
            cfo_remove_operator "${_tns}" "${_pkg}" || _rc=$?
            if (( _rc != 0 )); then
                echo "[ERROR] Removing ${_pkg} from ${_tns} failed (exit ${_rc})." >&2
                exit 1
            fi
        done
    done
else
    echo "[INFO] Operators kept (add --remove-operator to remove our Subscriptions)."
fi

# ------------------------------------------------------------------------------
echo "[7/7] Namespace"
_keep_reason=""
if ${KEEP_PROJECT}; then
    _keep_reason="--keep-project given"
elif ! ${REMOVE_OPERATOR}; then
    _keep_reason="the operators stay (no --remove-operator), and an OwnNamespace operator lives in it"
elif [[ "${NS}" == "${PROJECT_CONFLUENT_FLINK:-}" ]]; then
    _keep_reason="it is also the Flink namespace (PROJECT_CONFLUENT_FLINK)"
elif ! cfo_namespace_deletable "${NS}"; then
    _keep_reason="it holds Subscriptions or OperatorGroups that are not ours"
fi
if [[ -n "${_keep_reason}" ]]; then
    echo "[INFO] Keeping namespace ${NS}: ${_keep_reason}."
else
    echo "[INFO] Deleting project '${NS}'..."
    cf_dry_run oc delete namespace "${NS}" --wait=false || { echo "[ERROR] Deleting namespace ${NS} failed." >&2; exit 1; }
    if [[ "${DRY_RUN}" != true ]]; then
        _e=0
        while [[ -n "$(oc get namespace "${NS}" -o name --ignore-not-found 2>/dev/null || true)" ]]; do
            echo "  [${_e}s/300s] namespace ${NS} terminating"
            if (( _e >= 300 )); then
                echo "[ERROR] Project '${NS}' still terminating after ${_e}s. Check: oc get namespace ${NS} -o yaml" >&2
                exit 1
            fi
            sleep "${CFO_POLL_INTERVAL}"
            _e=$(( _e + CFO_POLL_INTERVAL ))
        done
        echo "[INFO] Project '${NS}' deleted."
    fi
fi

_final_rc=0
if ${DELETE_CRDS_FLAG}; then
    # CONTRACT-DEVIATION (approved 2026-11-18): 5.5 says "Exit 0"; a refused --delete-crds is a [BLOCKED] refusal (9.2), so x.0 still
    # finishes every other step but exits 2 to tell a caller the requested CRD removal did not happen. Answering "no" is not a refusal.
    _x0_delete_crd_groups || _final_rc=$?
    (( _final_rc == 0 )) || echo "[WARN] CRDs kept (exit ${_final_rc}); everything else is done." >&2
fi

echo ""
if (( ${#ALL_RETAINED} )); then
    CFO_RETAINED_PVS=("${ALL_RETAINED[@]}")
    echo "Summary"
    cfo_print_retained
fi
if [[ "${DRY_RUN}" == true ]]; then
    echo "[INFO] --dry-run complete. Nothing was deleted."
else
    echo "[INFO] Uninstall complete."
fi
exit "${_final_rc}"
