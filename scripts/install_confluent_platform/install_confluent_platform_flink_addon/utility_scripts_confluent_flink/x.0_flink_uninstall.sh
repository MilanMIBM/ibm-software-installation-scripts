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
# Confluent Platform for Apache Flink - uninstall
# ------------------------------------------------------------------------------
# Removes everything 1.0_flink_prep.sh and 1.1_flink_install.sh create.
#
# The Confluent Platform installation is NOT touched. The only thing this can
# leave behind in the Kafka project is the 'allow-flink' NetworkPolicy added by
# x.4_flink_connect_kafka.sh --allow-network, which is removed here too.
#
# DESTRUCTIVE: running Flink jobs are stopped and the checkpoint volume is
# deleted, so in-flight state is lost. Kafka topics are not affected - Flink
# only reads and writes them, it does not own them.
#
# Order matters: the Flink jobs are deleted before the operator, because the
# operator has to run to process the FlinkDeployment finalizers. Removing it
# first leaves the deployments stuck in Terminating and the namespace hangs.
#
# Usage:
#   ./x.0_flink_uninstall.sh [--keep-data] [--keep-project] [--keep-cert-manager]
#        [--yes] [--dry-run]
#
#   --keep-data          leave the CMF metadata and checkpoint PVCs in place
#   --keep-project       delete the workloads but keep the namespace and its
#                        service accounts / SCC bindings
#   --keep-cert-manager  never remove cert-manager (default: it is never
#                        removed anyway; the flag exists for symmetry and to
#                        silence the note)
#   --yes                skip the interactive confirmation
#   --dry-run            print what would be deleted, delete nothing
# ==============================================================================

KEEP_DATA=false
KEEP_PROJECT=false
KEEP_CERT_MANAGER=true
ASSUME_YES=true
DRY_RUN=false

for _arg in "$@"; do
    case "${_arg}" in
        --keep-data)         KEEP_DATA=true ;;
        --keep-project)      KEEP_PROJECT=true ;;
        --keep-cert-manager) KEEP_CERT_MANAGER=true ;;
        --yes|-y)            ASSUME_YES=true ;;
        --dry-run)           DRY_RUN=true ;;
        -h|--help)
            sed -n '19,41p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "[ERROR] Unknown argument '${_arg}'. Try --help." >&2; exit 1 ;;
    esac
done

eval "${OC_LOGIN}"

NS="${PROJECT_CONFLUENT_FLINK}"
KAFKA_NS="${PROJECT_CONFLUENT_SERVER}"

if ! oc get namespace "${NS}" &>/dev/null; then
    echo "[INFO] Project '${NS}' does not exist - nothing to uninstall."
    exit 0
fi

run() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "  [DRY-RUN] $*"
    else
        "$@" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Report what is about to go
# ------------------------------------------------------------------------------
echo "=============================================================================="
echo " Confluent Platform for Apache Flink uninstall - project '${NS}'"
echo "=============================================================================="
echo ""
echo "Helm releases:"
if command -v helm &>/dev/null; then
    helm list -n "${NS}" --short 2>/dev/null | sed 's/^/  /' || echo "  (none)"
else
    echo "  (helm is not on PATH - releases cannot be removed cleanly)"
fi

echo ""
echo "Running Flink jobs:"
oc get flinkdeployments -n "${NS}" --no-headers -o custom-columns='NAME:.metadata.name,STATE:.status.jobStatus.state' 2>/dev/null \
    | sed 's/^/  /' || true
[[ -z "$(oc get flinkdeployments -n "${NS}" --no-headers 2>/dev/null || true)" ]] && echo "  (none)"

echo ""
echo "PersistentVolumeClaims:"
_pvc_list="$(oc get pvc -n "${NS}" --no-headers -o custom-columns='NAME:.metadata.name,SIZE:.status.capacity.storage' 2>/dev/null || true)"
[[ -z "${_pvc_list}" ]] && echo "  (none)" || echo "${_pvc_list}" | sed 's/^/  /'

echo ""
if [[ "${KEEP_DATA}" == "true" ]]; then
    echo "  --keep-data given: PVCs will be PRESERVED."
else
    echo "  PVCs WILL BE DELETED - CMF metadata (environments, catalogs, pools)"
    echo "  and all Flink checkpoints are lost. Kafka topics are NOT affected."
fi
if [[ "${KEEP_PROJECT}" == "true" ]]; then
    echo "  --keep-project given: namespace '${NS}' will be PRESERVED."
else
    echo "  Namespace '${NS}' WILL BE DELETED, along with everything in it."
fi
echo ""

if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[INFO] --dry-run: no changes will be made."
    echo ""
elif [[ "${ASSUME_YES}" != "true" ]]; then
    printf "Type the project name '%s' to confirm: " "${NS}"
    read -r _confirm
    if [[ "${_confirm}" != "${NS}" ]]; then
        echo "[INFO] Confirmation did not match - aborted. Nothing was deleted."
        exit 1
    fi
    echo ""
fi

# ==============================================================================
# 1. Flink jobs
# ==============================================================================
# Deleted first and waited on: each FlinkDeployment carries a finalizer that
# only the operator can clear. Deleting the operator with jobs still present
# leaves them stuck in Terminating, which in turn blocks the namespace delete
# and needs a manual finalizer patch to escape.
if oc get crd flinkdeployments.flink.apache.org &>/dev/null; then
    _jobs="$(oc get flinkdeployments -n "${NS}" -o name 2>/dev/null || true)"
    if [[ -n "${_jobs}" ]]; then
        echo "[INFO] Deleting Flink jobs (the operator must be alive to do this)..."
        run oc delete flinkdeployments --all -n "${NS}" --wait=true --timeout=180s
        run oc delete flinksessionjobs --all -n "${NS}" --wait=true --timeout=120s

        if [[ "${DRY_RUN}" != "true" ]]; then
            # If any are still stuck, clear the finalizers by hand rather than
            # leaving the namespace to hang for good.
            _stuck="$(oc get flinkdeployments -n "${NS}" -o name 2>/dev/null || true)"
            if [[ -n "${_stuck}" ]]; then
                echo "[WARN] Some FlinkDeployments did not finalize - clearing finalizers."
                for _r in ${=_stuck}; do
                    oc patch "${_r}" -n "${NS}" --type=merge \
                        -p '{"metadata":{"finalizers":[]}}' &>/dev/null || true
                done
            fi
        fi
    fi
fi

# ==============================================================================
# 2. Helm releases
# ==============================================================================
# The grant x.2_flink_add_auth_openshift.sh makes is cluster-scoped, so deleting
# the project would leave it behind.
run oc adm policy remove-cluster-role-from-user system:auth-delegator \
    -z confluent-manager-for-apache-flink -n "${NS}"

if command -v helm &>/dev/null; then
    for _rel in "${FLINK_CMF_RELEASE_NAME}" "${FLINK_OPERATOR_RELEASE_NAME}"; do
        if helm status "${_rel}" -n "${NS}" &>/dev/null; then
            echo "[INFO] Uninstalling Helm release '${_rel}'..."
            run helm uninstall "${_rel}" -n "${NS}" --wait --timeout 300s
        fi
    done
else
    echo "[WARN] helm is not on PATH - the releases were not uninstalled. Deleting"
    echo "[WARN] the namespace removes their objects, but the release records"
    echo "[WARN] survive in helm's storage and will confuse a later reinstall."
fi

# The operator chart's jobServiceAccount carries helm.sh/resource-policy: keep,
# so helm uninstall deliberately leaves it behind. Harmless in a namespace that
# is about to be deleted, but it blocks a clean --keep-project reinstall.
run oc delete serviceaccount flink -n "${NS}" --ignore-not-found

# ==============================================================================
# 3. NetworkPolicy in the Kafka project
# ==============================================================================
# The one piece of this installation that lives outside the Flink namespace.
if oc get networkpolicy allow-flink -n "${KAFKA_NS}" &>/dev/null; then
    echo "[INFO] Removing the 'allow-flink' NetworkPolicy from '${KAFKA_NS}'..."
    run oc delete networkpolicy allow-flink -n "${KAFKA_NS}" --ignore-not-found
fi

# ==============================================================================
# 4. Namespace, or an itemised delete
# ==============================================================================
if [[ "${KEEP_PROJECT}" != "true" ]]; then
    if [[ "${KEEP_DATA}" == "true" ]]; then
        echo "[WARN] --keep-data with a project delete only preserves the underlying"
        echo "[WARN] PersistentVolumes, not the claims. Their reclaim policy decides"
        echo "[WARN] whether the data actually survives. Use --keep-project --keep-data"
        echo "[WARN] to genuinely retain the claims."
        echo ""
    fi

    echo "[INFO] Deleting project '${NS}'..."
    run oc delete namespace "${NS}" --wait=true

    if [[ "${DRY_RUN}" != "true" ]]; then
        echo "[INFO] Waiting for the project to terminate..."
        _waited=0
        while oc get namespace "${NS}" &>/dev/null; do
            sleep 5
            _waited=$(( _waited + 5 ))
            if (( _waited >= 300 )); then
                echo "[ERROR] Project '${NS}' still terminating after ${_waited}s." >&2
                echo "[ERROR] Check for stuck finalizers: oc get namespace ${NS} -o yaml" >&2
                exit 1
            fi
        done
        echo "[INFO] Project '${NS}' deleted after ${_waited}s."
    fi
else
    echo "[INFO] Deleting Flink resources from '${NS}' (project preserved)..."
    run oc delete deployment,service,route,configmap -n "${NS}" \
        -l app.kubernetes.io/part-of=confluent-flink --ignore-not-found
    run oc delete secret "${FLINK_LICENSE_SECRET}" "${FLINK_S3_SECRET}" "${FLINK_AUTH_SECRET:-cmf-oauth}" -n "${NS}" --ignore-not-found

    if [[ "${KEEP_DATA}" != "true" ]]; then
        echo "[INFO] Deleting PVCs..."
        run oc delete pvc --all -n "${NS}" --wait=true
    else
        echo "[INFO] --keep-data: PVCs left in place."
    fi
    echo "[INFO] Service accounts and SCC bindings preserved (--keep-project)."
fi

# ==============================================================================
# 5. Cluster-scoped leftovers
# ==============================================================================
# The Flink CRDs are cluster-scoped, so deleting the namespace does not remove
# them. They are left in place deliberately: another Flink installation on this
# cluster would still need them, and removing a CRD deletes every object of that
# kind cluster-wide. Same reasoning for cert-manager.
echo ""
echo "[INFO] Left in place (cluster-scoped, may be shared):"
if oc get crd flinkdeployments.flink.apache.org &>/dev/null; then
    echo "[INFO]   Flink CRDs. Remove them only if no other Flink installation exists:"
    echo "[INFO]     oc delete crd flinkdeployments.flink.apache.org flinksessionjobs.flink.apache.org"
fi
if [[ "${KEEP_CERT_MANAGER}" == "true" ]] && oc get crd certificates.cert-manager.io &>/dev/null; then
    echo "[INFO]   cert-manager. Other operators commonly depend on it; remove with:"
    echo "[INFO]     oc delete -f https://github.com/cert-manager/cert-manager/releases/download/${FLINK_CERT_MANAGER_VERSION}/cert-manager.yaml"
fi

echo ""
if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[INFO] --dry-run complete. Nothing was deleted."
else
    echo "[INFO] Uninstall complete. The Confluent Platform installation in"
    echo "[INFO] '${KAFKA_NS}' was not touched."
fi
