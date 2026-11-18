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
# Confluent Platform for Apache Flink (operator mode) - uninstall
# ------------------------------------------------------------------------------
# The operator-mode twin of ../x.0_flink_uninstall.sh, which hands over here when
# the Flink operator is cp-fko via OLM (FLINK_OPERATOR_SOURCE olm|existing) or the
# CMF resources are CFK custom resources (FLINK_CMF_RESOURCE_MODE=cfk).
# The Confluent Platform installation is NOT touched.
#
# Order (plan H32, 15.14 item 2; every step prints its [n/9] header):
#   [1/9] FlinkApplication CRs we own (CFK deletes their CMF applications)
#   [2/9] CMF statements and applications made through the CLI
#   [3/9] CMF compute pools, the Kafka catalog + its databases, the secret mapping
#         and secret x.4 made (CMF 2.5 refuses to delete an environment while the
#         default database of its catalog holds tables or views - drop those first)
#   [4/9] the FlinkEnvironment: CMF REST delete, then the CR; when CMF answered
#         and the CR still hangs on its finalizer, the documented removal
#         (block-reconcile, delete --wait=false, clear finalizers) with a
#         [WORKAROUND] line. A CMF 422 or failed delete stops the uninstall.
#   [5/9] the CMFRestClass, last of the CFK Flink objects (the finalizer needs it)
#   [6/9] remaining FlinkDeployments (the Flink operator must still run)
#   [7/9] auth-delegator grant, the CMF Helm release, the deploy-mode marker,
#         the Flink NetworkPolicies in the Kafka project, PVCs per --keep-data
#   [8/9] --remove-operator: our cp-fko Subscription/CSV/OperatorGroup, and our CFK
#         in the Flink namespace / FLINK_CFK_NAMESPACE when it serves only Flink
#   [9/9] the namespace - only without --keep-project, when every Subscription and
#         OperatorGroup in it is ours and gone (--remove-operator) and it is not
#         the Kafka project; otherwise it is kept and said why
#
# --keep-data keeps the CMF metadata: steps 2-3 are skipped, the FlinkEnvironment
# CR is removed with the documented block-reconcile sequence WITHOUT deleting the
# CMF environment, and the CMF / checkpoint PVCs stay (in a kept namespace).
#
# Usage:
#   ./x.0_flink_uninstall.sh [--keep-data] [--keep-project] [--keep-cert-manager]
#        [--remove-operator] [--delete-crds] [--force-finalizers] [--yes] [--dry-run]
#
#   --keep-data          keep the CMF metadata and the checkpoint / CMF PVCs
#   --keep-project       keep the namespace (itemised delete instead)
#   --keep-cert-manager  accepted for symmetry (cert-manager is never touched)
#   --remove-operator    also remove the OLM operators this install created
#   --delete-crds        last: delete the flink.apache.org CRDs (refused while any
#                        CSV or CR uses them; y/N confirmation on the terminal)
#   --force-finalizers   clear the finalizers of a CR that does not go in time
#   --yes                skip the interactive confirmation
#   --dry-run            print what would be deleted, delete nothing
#
# Exit status: 0 ok, 1 error (the uninstall stopped), 2 blocked.
# ==============================================================================

usage() { sed -n '/^# Confluent Platform for Apache Flink (operator mode) - uninstall/,/^# Exit status/p' "${ZSH_ARGZERO}" | sed 's/^# \{0,1\}//'; }

# --delete-crds is a flag only (never from the environment or --yes; contract 5.5).
unset CONFLUENT_DELETE_CRDS DELETE_CRDS

KEEP_DATA=false
KEEP_PROJECT=false
ASSUME_YES=true
DRY_RUN=false
REMOVE_OPERATOR=false
DELETE_CRDS=false
FORCE_FINALIZERS=false

while (( $# > 0 )); do
    case "$1" in
        --keep-data)         KEEP_DATA=true; shift ;;
        --keep-project)      KEEP_PROJECT=true; shift ;;
        --keep-cert-manager) shift ;;
        --remove-operator)   REMOVE_OPERATOR=true; shift ;;
        --delete-crds)       DELETE_CRDS=true; shift ;;
        --force-finalizers)  FORCE_FINALIZERS=true; shift ;;
        --yes|-y)            ASSUME_YES=true; shift ;;
        --dry-run)           DRY_RUN=true; shift ;;
        -h|--help)           usage; exit 0 ;;
        *) echo "[ERROR] Unknown argument '$1'. Use --help." >&2; exit 1 ;;
    esac
done
export DRY_RUN

cfo_entry flink

NS="${PROJECT_CONFLUENT_FLINK}"
KAFKA_NS="${PROJECT_CONFLUENT_SERVER}"
CFK_NS="${FLINK_CFK_NAMESPACE:-${NS}}"
ENV_NAME="${FLINK_ENVIRONMENT}"
SOURCE="$(cf_flink_operator_source)"
CMF_MODE="$(cf_flink_cmf_resource_mode)"
_cfo_int "${CONFLUENT_OPERATOR_COMPONENT_TIMEOUT:-}" 600; WAIT_T="${REPLY}"
_cfo_owner; OWNER="${REPLY}"
RES_APP=flinkapplications.platform.confluent.io
RES_ENV=flinkenvironments.platform.confluent.io

run() { cf_dry_run --ignore-errors "$@"; }

_ns_exists() { oc get namespace "$1" -o name >/dev/null 2>&1; }

if ! _ns_exists "${NS}" && { [[ "${CFK_NS}" == "${NS}" ]] || ! _ns_exists "${CFK_NS}"; }; then
    echo "[INFO] Project '${NS}' does not exist - nothing to uninstall."
    # A finished uninstall leaves no namespace, which is exactly when --delete-crds is run: still run it.
    if ${DELETE_CRDS}; then
        echo "[INFO] --delete-crds: the flink.apache.org CRDs"
        _rc=0
        cfo_delete_crds flink || _rc=$?
        exit "${_rc}"
    fi
    exit 0
fi

# _x0_names <json-file> - one .metadata.name per line of an "items" list or a plain list.
_x0_names() {
    cfo_python -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
except ValueError:
    sys.exit(0)
items = d.get("items", []) if isinstance(d, dict) else d
for i in items or []:
    if isinstance(i, dict):
        n = (i.get("metadata") or {}).get("name") or i.get("name")
        if n:
            print(n)' "$1"
}

# _x0_finalize <res> <name> <ns> <label> <i> <n> - waits until gone; on timeout clears the finalizers
# with --force-finalizers (logged), else status 1.
_x0_finalize() {
    local res="$1" name="$2" ns="$3" label="$4" i="$5" n="$6"
    [[ "${DRY_RUN}" == true ]] && return 0
    _cfo_wait_gone "${ns}" "${res}" "${name}" "${WAIT_T}" "${i}" "${n}" "${label}" && return 0
    if ${FORCE_FINALIZERS}; then
        oc patch "${res}" "${name}" -n "${ns}" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null || return 1
        echo "[WORKAROUND] finalizers removed from ${label}"
        _cfo_wait_gone "${ns}" "${res}" "${name}" 60 "${i}" "${n}" "${label}" && return 0
    fi
    echo "[ERROR] ${label} not gone after ${WAIT_T}s (re-run with --force-finalizers to clear its finalizers)." >&2
    return 1
}

# _x0_env_cr_only_removal - Confluent's documented removal of the FlinkEnvironment CR that keeps the CMF
# environment (co-manage-flink-environments): block-reconcile, delete --wait=false, clear the finalizers.
# A CR that is already gone after the delete (no finalizer left) is fine; any other failure is status 1.
_x0_env_cr_only_removal() {
    if [[ "${DRY_RUN}" == true ]]; then
        echo "  [DRY-RUN] oc annotate ${RES_ENV} ${ENV_NAME} -n ${CFK_NS} ${CFO_ANNOT_BLOCK_RECONCILE}=true --overwrite"
        echo "  [DRY-RUN] oc delete ${RES_ENV} ${ENV_NAME} -n ${CFK_NS} --wait=false"
        echo "  [DRY-RUN] oc patch ${RES_ENV} ${ENV_NAME} -n ${CFK_NS} --type=merge -p '{\"metadata\":{\"finalizers\":[]}}'"
        return 0
    fi
    oc annotate "${RES_ENV}" "${ENV_NAME}" -n "${CFK_NS}" "${CFO_ANNOT_BLOCK_RECONCILE}=true" --overwrite >/dev/null || return 1
    oc delete "${RES_ENV}" "${ENV_NAME}" -n "${CFK_NS}" --wait=false --ignore-not-found >/dev/null || return 1
    if oc get "${RES_ENV}" "${ENV_NAME}" -n "${CFK_NS}" -o name >/dev/null 2>&1 \
            && ! oc patch "${RES_ENV}" "${ENV_NAME}" -n "${CFK_NS}" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null; then
        # The patch may lose the race against a CR that went in the meantime; only a CR still there is an error.
        oc get "${RES_ENV}" "${ENV_NAME}" -n "${CFK_NS}" -o name >/dev/null 2>&1 && return 1
    fi
    _cfo_wait_gone "${CFK_NS}" "${RES_ENV}" "${ENV_NAME}" 60 1 1 "FlinkEnvironment/${ENV_NAME}"
}

# ------------------------------------------------------------------------------
# What is there, and what happens to the namespace
# ------------------------------------------------------------------------------
# Namespace decision up front (step 7 cleans item by item when it stays).
DELETE_NS=true
KEEP_REASON=""
if ${KEEP_PROJECT}; then
    DELETE_NS=false KEEP_REASON="--keep-project given"
elif [[ "${NS}" == "${KAFKA_NS}" ]]; then
    DELETE_NS=false KEEP_REASON="it is also the Kafka project ${KAFKA_NS}"
elif ! cfo_namespace_deletable "${NS}"; then
    DELETE_NS=false KEEP_REASON="it holds a Subscription or OperatorGroup that is not ours"
elif [[ -n "$(oc get subscriptions.operators.coreos.com -n "${NS}" -o name 2>/dev/null || true)" ]] && ! ${REMOVE_OPERATOR}; then
    DELETE_NS=false KEEP_REASON="its OLM operators stay (add --remove-operator to remove them and the namespace)"
fi

_dr=""
[[ "${DRY_RUN}" == true ]] && _dr=" - DRY RUN"
echo "=============================================================================="
echo " Confluent Platform for Apache Flink uninstall (operator mode) - project '${NS}'${_dr}"
echo "=============================================================================="
echo "  Flink operator ${SOURCE}, CMF resources ${CMF_MODE} (CFK namespace ${CFK_NS}), environment ${ENV_NAME}"
echo ""
echo "Helm releases:"
if command -v helm &>/dev/null; then
    _rel="$(helm list -n "${NS}" --short 2>/dev/null || true)"
    [[ -n "${_rel}" ]] && echo "${_rel}" | sed 's/^/  /' || echo "  (none)"
else
    echo "  (helm is not on PATH - the CMF release cannot be removed cleanly)"
fi
echo ""
echo "CFK Flink resources (${CFK_NS}):"
_crs="$(oc get "${RES_APP},${RES_ENV},cmfrestclasses.platform.confluent.io" -n "${CFK_NS}" -o name 2>/dev/null || true)"
[[ -n "${_crs}" ]] && echo "${_crs}" | sed 's/^/  /' || echo "  (none)"
echo ""
echo "PersistentVolumeClaims:"
_pvc_list="$(oc get pvc -n "${NS}" --no-headers -o custom-columns='NAME:.metadata.name,SIZE:.status.capacity.storage' 2>/dev/null || true)"
[[ -n "${_pvc_list}" ]] && echo "${_pvc_list}" | sed 's/^/  /' || echo "  (none)"
echo ""
if ${KEEP_DATA}; then
    echo "  --keep-data given: CMF metadata and PVCs are KEPT (the CMF environment is not deleted)."
else
    echo "  CMF metadata (environment, pools, catalog) and all Flink checkpoints are deleted."
    echo "  Kafka topics are NOT affected."
fi
if ${DELETE_NS}; then
    echo "  Namespace '${NS}' WILL BE DELETED, along with everything in it."
else
    echo "  Namespace '${NS}' is kept: ${KEEP_REASON}."
fi
echo ""

if [[ "${DRY_RUN}" == true ]]; then
    echo "[INFO] --dry-run: no changes will be made."
    echo ""
elif [[ "${ASSUME_YES}" != true ]]; then
    printf "Type the project name '%s' to confirm: " "${NS}"
    read -r _confirm
    if [[ "${_confirm}" != "${NS}" ]]; then
        echo "[INFO] Confirmation did not match - aborted. Nothing was deleted."
        exit 1
    fi
    echo ""
fi

# CMF connection (steps 2-4). CMF_URL from the environment wins (cmf_connect honours it).
CMF_OK=false
_x0_cmf() {
    ${CMF_OK} && return 0
    if [[ -z "${CMF_URL:-}" ]] && [[ -z "$(oc get deployment confluent-manager-for-apache-flink -n "${NS}" -o name --ignore-not-found 2>/dev/null || true)" ]]; then
        return 1
    fi
    source "${CF_FLINK_DIR}/flink_cmf_connect.sh"
    cmf_connect || return 1
    CMF_OK=true
}

# ==============================================================================
echo "[1/9] FlinkApplication CRs in ${CFK_NS}"
_apps="$(_cfo_read get "${RES_APP}" -n "${CFK_NS}" \
    -o jsonpath='{range .items[*]}{.metadata.name}|{.metadata.labels.confluent\.ibm-scripts/installed-by}|{.spec.flinkEnvironment}{"\n"}{end}')" \
    || { echo "[ERROR] Cannot list the FlinkApplications in ${CFK_NS} - nothing deleted." >&2; exit 1; }
_ours=() _foreign=()
for _l in ${(f)_apps}; do
    _p=("${(@s:|:)_l}")
    [[ -z "${_p[1]}" ]] && continue
    if [[ "${_p[2]:-}" == "${OWNER}" ]]; then
        _ours+=("${_p[1]}")
    elif [[ "${_p[3]:-}" == "${ENV_NAME}" ]]; then
        _foreign+=("${_p[1]}")
    fi
done
if (( ${#_foreign} )); then
    cfo_banner "FlinkApplications that are not ours use FlinkEnvironment ${ENV_NAME} in ${CFK_NS}" \
        "${_foreign[@]/#/found: FlinkApplication/}" \
        "deleting the environment would cascade-delete them; remove them first, then re-run"
    exit "${CFO_RC_BLOCKED}"
fi
if (( ${#_ours} == 0 )); then
    echo "  (none of ours)"
else
    for _a in "${_ours[@]}"; do cf_dry_run oc delete "${RES_APP}" "${_a}" -n "${CFK_NS}" --wait=false; done
    _i=0
    for _a in "${_ours[@]}"; do
        (( _i += 1 ))
        _x0_finalize "${RES_APP}" "${_a}" "${CFK_NS}" "FlinkApplication/${_a}" "${_i}" "${#_ours}" || exit 1
    done
fi

# ==============================================================================
echo "[2/9] CMF statements and applications (CLI)"
if ${KEEP_DATA}; then
    echo "  --keep-data: kept in CMF."
elif ! command -v confluent &>/dev/null; then
    echo "[WARN] The confluent CLI is not on PATH - CLI-made statements and applications were not deleted;" >&2
    echo "[WARN] CMF refuses the environment delete in step 4 if any are left." >&2
elif ! _x0_cmf; then
    echo "  CMF is not reachable or not installed - nothing to delete through it."
else
    _tmp="$(_cfo_mktemp)"
    for _what in statement application; do
        if confluent flink "${_what}" list --environment "${ENV_NAME}" --url "${CMF_URL}" -o json > "${_tmp}/${_what}.json" 2>/dev/null; then
            _names=(${(f)"$(_x0_names "${_tmp}/${_what}.json")"})
            (( ${#_names} )) || echo "  no ${_what}s in ${ENV_NAME}"
            _i=0
            for _n in "${_names[@]}"; do
                (( _i += 1 ))
                echo "  [${_i}/${#_names}] ${_what} ${_n}"
                cf_dry_run confluent flink "${_what}" delete "${_n}" --environment "${ENV_NAME}" --url "${CMF_URL}" --force \
                    || echo "[WARN] Could not delete ${_what} ${_n}." >&2
            done
        else
            echo "  no ${_what}s listed (environment ${ENV_NAME} absent in CMF, or the list failed)"
        fi
    done
    rm -rf "${_tmp}"
fi

# ==============================================================================
echo "[3/9] CMF compute pools, catalog, secret mapping and secret (CLI / REST)"
if ${KEEP_DATA}; then
    echo "  --keep-data: kept in CMF."
elif ! command -v confluent &>/dev/null || ! _x0_cmf; then
    echo "  skipped (no confluent CLI or no CMF)."
else
    _tmp="$(_cfo_mktemp)"
    cf_dry_run --ignore-errors confluent flink secret-mapping delete "${FLINK_KAFKA_SECRET}" \
        --environment "${ENV_NAME}" --url "${CMF_URL}" --force
    if confluent flink compute-pool list --environment "${ENV_NAME}" --url "${CMF_URL}" -o json > "${_tmp}/pools.json" 2>/dev/null; then
        _names=(${(f)"$(_x0_names "${_tmp}/pools.json")"})
        _i=0
        for _n in "${_names[@]}"; do
            (( _i += 1 ))
            echo "  [${_i}/${#_names}] compute pool ${_n}"
            cf_dry_run confluent flink compute-pool delete "${_n}" --environment "${ENV_NAME}" --url "${CMF_URL}" --force \
                || echo "[WARN] Could not delete compute pool ${_n}." >&2
        done
    fi
    # The catalog's databases first (a sub-resource with no CLI command), as x.4 --replace does.
    if confluent flink catalog describe "${FLINK_CATALOG}" --url "${CMF_URL}" &>/dev/null; then
        curl -s "${CMF_URL}/cmf/api/v1/catalogs/kafka/${FLINK_CATALOG}/databases" -o "${_tmp}/dbs.json" 2>/dev/null || true
        [[ -s "${_tmp}/dbs.json" ]] || print -r -- '{}' > "${_tmp}/dbs.json"
        for _db in ${(f)"$(_x0_names "${_tmp}/dbs.json")"}; do
            cf_dry_run --ignore-errors curl -s -X DELETE "${CMF_URL}/cmf/api/v1/catalogs/kafka/${FLINK_CATALOG}/databases/${_db}" -o /dev/null
            echo "  database ${_db} of catalog ${FLINK_CATALOG}"
        done
        cf_dry_run confluent flink catalog delete "${FLINK_CATALOG}" --url "${CMF_URL}" --force \
            || echo "[WARN] Could not delete catalog ${FLINK_CATALOG}." >&2
    fi
    cf_dry_run --ignore-errors confluent flink secret delete "${FLINK_KAFKA_SECRET}" --url "${CMF_URL}" --force
    echo "  (tables and views in the default database of the environment's own catalog are not listable through"
    echo "   CMF REST; if step 4 reports HTTP 422, drop them with Flink SQL and re-run)"
    rm -rf "${_tmp}"
fi

# ==============================================================================
echo "[4/9] FlinkEnvironment ${ENV_NAME} in ${CFK_NS}"
_env="$(_cfo_read get "${RES_ENV}" "${ENV_NAME}" -n "${CFK_NS}" \
    -o 'jsonpath={.metadata.name}|{.metadata.labels.confluent\.ibm-scripts/installed-by}')" \
    || { echo "[ERROR] Cannot read FlinkEnvironment/${ENV_NAME} in ${CFK_NS} - stopping." >&2; exit 1; }
if [[ -z "${_env%%|*}" ]]; then
    echo "  (no FlinkEnvironment CR)"
elif [[ "${_env#*|}" != "${OWNER}" ]]; then
    echo "[INFO] FlinkEnvironment/${ENV_NAME} in ${CFK_NS} is not ours - leaving it."
elif ${KEEP_DATA}; then
    # CONTRACT-DEVIATION (approved 2026-11-18): --keep-data uses the documented removal that preserves the CMF environment
    # (co-manage-flink-environments) instead of cfo_flinkenv_delete, which deletes it in CMF first.
    echo "  --keep-data: removing the CR only (documented block-reconcile sequence; the CMF environment stays)."
    _x0_env_cr_only_removal \
        || { echo "[ERROR] FlinkEnvironment/${ENV_NAME} could not be removed (see above) - uninstall stopped." >&2; exit 1; }
else
    if [[ "${DRY_RUN}" != true ]] && ! _x0_cmf; then
        if ! ${FORCE_FINALIZERS}; then
            echo "[ERROR] CMF is not reachable, so FlinkEnvironment/${ENV_NAME} cannot be deleted through it (its finalizer" >&2
            echo "[ERROR] needs CMF). Start CMF, or re-run with --force-finalizers to remove only the CR." >&2
            exit 1
        fi
        echo "[WORKAROUND] CMF is not reachable: FlinkEnvironment/${ENV_NAME} removed with the documented sequence -" \
            "${CFO_ANNOT_BLOCK_RECONCILE}=true, delete --wait=false, clear finalizers (the CMF environment is not deleted)"
        _x0_env_cr_only_removal \
            || { echo "[ERROR] FlinkEnvironment/${ENV_NAME} could not be removed (see above) - uninstall stopped." >&2; exit 1; }
    else
        _rc=0
        cfo_flinkenv_delete "${CFK_NS}" "${ENV_NAME}" || _rc=$?
        if (( _rc != 0 )); then
            echo "[ERROR] The FlinkEnvironment could not be removed (see above) - uninstall stopped; nothing after step 4 ran." >&2
            exit 1
        fi
    fi
fi

# ==============================================================================
echo "[5/9] CMFRestClass ${FLINK_CMF_RESTCLASS_NAME:-default} in ${CFK_NS}"
_rc=0
cfo_cmfrestclass_delete "${CFK_NS}" "${FLINK_CMF_RESTCLASS_NAME:-default}" || _rc=$?
(( _rc == 0 )) || { echo "[ERROR] CMFRestClass not removed (see above) - uninstall stopped." >&2; exit 1; }

# ==============================================================================
echo "[6/9] FlinkDeployments in ${NS} (the Flink operator must still run)"
if _ns_exists "${NS}" && oc get crd flinkdeployments.flink.apache.org &>/dev/null; then
    _fds=()
    for _k in flinkdeployments.flink.apache.org flinksessionjobs.flink.apache.org; do
        for _n in ${(f)"$(oc get "${_k}" -n "${NS}" -o name 2>/dev/null || true)"}; do
            [[ -n "${_n}" ]] && _fds+=("${_k}|${_n#*/}")
        done
    done
    if (( ${#_fds} == 0 )); then
        echo "  (none)"
    else
        for _f in "${_fds[@]}"; do cf_dry_run oc delete "${_f%%|*}" "${_f#*|}" -n "${NS}" --wait=false; done
        _i=0
        for _f in "${_fds[@]}"; do
            (( _i += 1 ))
            _x0_finalize "${_f%%|*}" "${_f#*|}" "${NS}" "${${_f%%|*}%%.*}/${_f#*|}" "${_i}" "${#_fds}" || exit 1
        done
    fi
else
    echo "  (none)"
fi

# ==============================================================================
echo "[7/9] CMF release, marker, NetworkPolicies, PVCs"
if _ns_exists "${NS}"; then
    # The grant x.2_flink_add_auth_openshift.sh makes is cluster-scoped.
    run oc adm policy remove-cluster-role-from-user system:auth-delegator \
        -z confluent-manager-for-apache-flink -n "${NS}"
    if command -v helm &>/dev/null; then
        _rels=("${FLINK_CMF_RELEASE_NAME}")
        # The Helm Flink operator (FLINK_OPERATOR_SOURCE=helm with CMF resources as CRs) goes after its jobs.
        [[ "${SOURCE}" == helm ]] && _rels+=("${FLINK_OPERATOR_RELEASE_NAME}")
        for _rel in "${_rels[@]}"; do
            if helm status "${_rel}" -n "${NS}" &>/dev/null; then
                echo "[INFO] Uninstalling Helm release '${_rel}'..."
                run helm uninstall "${_rel}" -n "${NS}" --wait --timeout 300s
            fi
        done
    else
        echo "[WARN] helm is not on PATH - the CMF release was not uninstalled (its record survives in Helm's storage)." >&2
    fi
    run oc delete configmap "${CFO_MARKER_CM}" -n "${NS}" --ignore-not-found
    # The Helm operator chart's job account carries helm.sh/resource-policy: keep; the OLM one belongs to cp-fko.
    [[ "${SOURCE}" == helm ]] && run oc delete serviceaccount flink -n "${NS}" --ignore-not-found
fi
run oc delete networkpolicy -n "${KAFKA_NS}" -l "confluent.platform/flink-namespace=${NS}" --ignore-not-found
if oc get networkpolicy allow-flink -n "${KAFKA_NS}" &>/dev/null; then
    echo "[INFO] Removing the 'allow-flink' NetworkPolicy from '${KAFKA_NS}'..."
    run oc delete networkpolicy allow-flink -n "${KAFKA_NS}" --ignore-not-found
fi
if _ns_exists "${NS}"; then
    if ${DELETE_NS}; then
        ${KEEP_DATA} && echo "[WARN] --keep-data with a namespace delete keeps only the PVs whose reclaim policy is Retain." >&2
        echo "  (the namespace delete in step 9 removes the rest)"
    else
        run oc delete deployment,service,route,configmap -n "${NS}" -l app.kubernetes.io/part-of=confluent-flink --ignore-not-found
        run oc delete secret "${FLINK_LICENSE_SECRET}" "${FLINK_S3_SECRET}" "${FLINK_AUTH_SECRET:-cmf-oauth}" -n "${NS}" --ignore-not-found
        if ${KEEP_DATA}; then
            echo "[INFO] --keep-data: PVCs left in place."
        else
            echo "[INFO] Deleting PVCs..."
            run oc delete pvc --all -n "${NS}" --wait=true
        fi
    fi
fi

# ==============================================================================
echo "[8/9] OLM operators"
if ! ${REMOVE_OPERATOR}; then
    echo "  kept (add --remove-operator to remove the ones this install created)"
else
    if [[ "${SOURCE}" == olm ]]; then
        cfo_remove_operator "${NS}" "${CFO_PKG_FKO}" || { echo "[ERROR] cp-fko not removed - stopping." >&2; exit 1; }
    else
        echo "  Flink operator source ${SOURCE}: not ours to remove."
    fi
    # Our CFK in the Flink namespace (operator deploy mode puts one there even with CMF resources via the
    # CLI, contract 3.3 plan_operator_targets) and in FLINK_CFK_NAMESPACE; never the platform's own CFK.
    _cfk_nss=()
    [[ "${CMF_MODE}" == cfk ]] && _cfk_nss+=("${CFK_NS}")
    [[ "${NS}" != "${CFK_NS}" || "${CMF_MODE}" != cfk ]] && _cfk_nss+=("${NS}")
    for _cns in "${_cfk_nss[@]}"; do
        if [[ "${_cns}" == "${KAFKA_NS}" ]]; then
            echo "  CFK in ${_cns} is the platform's operator - the platform x.0 removes it."
            continue
        fi
        _ns_exists "${_cns}" || continue
        _left="$(cfo_list_crs "${_cns}")" || { echo "[ERROR] Cannot list the CFK CRs in ${_cns}; CFK kept." >&2; exit 1; }
        if [[ -n "${_left}" ]]; then
            echo "[INFO] CFK in ${_cns} kept: it still manages ${(j:, :)${(@)${(f)_left}%% *}}."
        else
            cfo_remove_operator "${_cns}" "${CFO_PKG_CFK}" || { echo "[ERROR] CFK not removed from ${_cns} - stopping." >&2; exit 1; }
        fi
    done
fi

# ==============================================================================
echo "[9/9] Namespace ${NS}"
if ! _ns_exists "${NS}"; then
    echo "  (already gone)"
elif ! ${DELETE_NS}; then
    echo "[INFO] Keeping namespace ${NS}: ${KEEP_REASON}"
else
    echo "[INFO] Deleting project '${NS}'..."
    run oc delete namespace "${NS}" --wait=false
    if [[ "${DRY_RUN}" != true ]]; then
        _waited=0
        while _ns_exists "${NS}"; do
            echo "  [${_waited}s/300s] namespace ${NS} terminating"
            if (( _waited >= 300 )); then
                echo "[ERROR] Project '${NS}' still terminating after ${_waited}s." >&2
                echo "[ERROR] Check for stuck finalizers: oc get namespace ${NS} -o yaml" >&2
                exit 1
            fi
            sleep "${CFO_POLL_INTERVAL}"
            _waited=$(( _waited + CFO_POLL_INTERVAL ))
        done
        echo "[INFO] Project '${NS}' deleted after ${_waited}s."
    fi
fi

if ${DELETE_CRDS}; then
    echo ""
    echo "[INFO] --delete-crds: the flink.apache.org CRDs"
    _rc=0
    cfo_delete_crds flink || _rc=$?
    (( _rc == 0 )) || exit "${_rc}"
fi

echo ""
if [[ "${DRY_RUN}" == true ]]; then
    echo "[INFO] --dry-run complete. Nothing was deleted."
else
    echo "[INFO] Uninstall complete. The Confluent Platform installation in '${KAFKA_NS}' was not touched."
fi
