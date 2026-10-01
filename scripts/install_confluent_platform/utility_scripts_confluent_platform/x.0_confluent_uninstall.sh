#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

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
# Confluent Platform - uninstall
# ------------------------------------------------------------------------------
# Removes everything 1.0_confluent_prep.sh and 1.1_confluent_install.sh create
# from the target project.
#
# DESTRUCTIVE: the broker PVCs hold all Kafka topic data, and deleting them is
# irreversible. They are removed by default because a reinstall against stale
# PVCs fails - the KRaft metadata on disk will not match a freshly formatted
# cluster. Pass --keep-data to preserve them.
#
# Usage:
#   ./x.0_confluent_uninstall.sh [--keep-data] [--keep-project] [--yes] [--dry-run]
#
#   --keep-data      leave the broker PVCs in place (topic data survives)
#   --keep-project   delete the workloads but keep the namespace, service
#                    account and pull secret (leaves prep's work intact)
#   --yes            skip the interactive confirmation
#   --dry-run        print what would be deleted, delete nothing
#
# By default the project itself is deleted, which removes everything in one
# step. --keep-project switches to itemised deletion of just the Confluent
# resources, which is the right choice when the namespace holds anything else.
# ==============================================================================

KEEP_DATA=true
KEEP_PROJECT=false
ASSUME_YES=true
DRY_RUN=false

for _arg in "$@"; do
    case "${_arg}" in
        --keep-data)    KEEP_DATA=true ;;
        --keep-project) KEEP_PROJECT=true ;;
        --yes|-y)       ASSUME_YES=true ;;
        --dry-run)      DRY_RUN=true ;;
        -h|--help)
            sed -n '19,40p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "[ERROR] Unknown argument '${_arg}'. Try --help." >&2
            exit 1 ;;
    esac
done

eval "${OC_LOGIN}"

NS="${PROJECT_CONFLUENT_SERVER}"
SA="confluent"

if ! oc get namespace "${NS}" &>/dev/null; then
    echo "[INFO] Project '${NS}' does not exist - nothing to uninstall."
    exit 0
fi

# ------------------------------------------------------------------------------
# run <cmd...> - executes, or just prints under --dry-run.
# ------------------------------------------------------------------------------
run() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "  [DRY-RUN] $*"
    else
        "$@" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Report what is about to go, then confirm
# ------------------------------------------------------------------------------
echo "=============================================================================="
echo " Confluent Platform uninstall - project '${NS}'"
echo "=============================================================================="
echo ""
echo "Workloads found:"
oc get statefulset,deployment -n "${NS}" -l app.kubernetes.io/part-of=confluent \
    -o custom-columns='KIND:.kind,NAME:.metadata.name,READY:.status.readyReplicas' \
    --no-headers 2>/dev/null | sed 's/^/  /' || echo "  (none)"

echo ""
echo "PersistentVolumeClaims:"
_pvc_list="$(oc get pvc -n "${NS}" -o custom-columns='NAME:.metadata.name,SIZE:.status.capacity.storage' --no-headers 2>/dev/null | grep '^confluent-broker-data' || true)"
if [[ -z "${_pvc_list}" ]]; then
    echo "  (none)"
else
    echo "${_pvc_list}" | sed 's/^/  /'
fi

echo ""
if [[ "${KEEP_DATA}" == "true" ]]; then
    echo "  --keep-data given: broker PVCs will be PRESERVED."
else
    echo "  Broker PVCs WILL BE DELETED - all Kafka topic data is lost."
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
# Whole-project delete (default)
# ==============================================================================
if [[ "${KEEP_PROJECT}" != "true" ]]; then
    if [[ "${KEEP_DATA}" == "true" ]]; then
        # Deleting the namespace takes its PVCs with it, so --keep-data has to
        # detach them first: drop the claims' owning workloads, then remove the
        # claimRef so the released PVs can be re-bound later.
        echo "[WARN] --keep-data with a project delete only preserves the underlying"
        echo "[WARN] PersistentVolumes, not the claims. Their reclaim policy decides"
        echo "[WARN] whether the data actually survives:"
        oc get pv -o custom-columns='NAME:.metadata.name,POLICY:.spec.persistentVolumeReclaimPolicy,CLAIM:.spec.claimRef.name' \
            --no-headers 2>/dev/null | grep 'confluent-broker-data' | sed 's/^/[WARN]   /' || true
        echo "[WARN] Any PV above with policy 'Delete' loses its data regardless."
        echo "[WARN] Use --keep-project --keep-data to genuinely retain the claims."
        echo ""
    fi

    echo "[INFO] Deleting project '${NS}'..."
    run oc delete namespace "${NS}" --wait=true

    if [[ "${DRY_RUN}" != "true" ]]; then
        # The namespace lingers in Terminating while finalizers run; callers
        # that immediately reinstall need it fully gone.
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

    echo ""
    echo "[INFO] Uninstall complete."
    exit 0
fi

# ==============================================================================
# Itemised delete (--keep-project)
# ==============================================================================
echo "[INFO] Deleting Confluent workloads from '${NS}' (project preserved)..."

# Workloads first so nothing restarts a pod that holds a PVC open.
run oc delete statefulset,deployment -n "${NS}" -l app.kubernetes.io/part-of=confluent --wait=true

# The label covers everything the install script applies; the explicit names
# cover the monitoring ConfigMap, which predates that convention on re-runs.
run oc delete service,route,configmap -n "${NS}" -l app.kubernetes.io/part-of=confluent --wait=true
run oc delete configmap confluent-monitoring-config -n "${NS}" --ignore-not-found

# Orphaned pods (e.g. left by a previous --cascade=orphan) are not covered by
# the workload delete above.
run oc delete pod -n "${NS}" -l app.kubernetes.io/part-of=confluent --ignore-not-found --wait=true

# Secrets minted by the x.2/x.4 scripts. These hold generated credentials, the
# MDS token keypair and the external-access CA, so they are deleted with the
# rest of the stack rather than left behind holding stale passwords.
run oc delete secret -n "${NS}" --ignore-not-found \
    "${CONFLUENT_SASL_SECRET:-confluent-sasl}" \
    "${CONFLUENT_MDS_SECRET:-confluent-mds}" \
    "${CONFLUENT_LDAP_SECRET:-confluent-ldap}" \
    "${CONFLUENT_KEYCLOAK_SECRET:-confluent-keycloak}" \
    "${CONFLUENT_EXTERNAL_TLS_SECRET:-confluent-kafka-tls}"

if [[ "${KEEP_DATA}" != "true" ]]; then
    echo "[INFO] Deleting broker PVCs..."
    # The volumeClaimTemplate names claims confluent-broker-data-broker-<n>;
    # they carry the part-of label from the template's metadata.
    run oc delete pvc -n "${NS}" -l app.kubernetes.io/part-of=confluent --wait=true
    # Older installs wrote the claims without the label.
    for _i in $(seq 0 $(( ${CONFLUENT_BROKER_REPLICAS:-3} - 1 ))); do
        run oc delete pvc "confluent-broker-data-broker-${_i}" -n "${NS}" --ignore-not-found
    done
else
    echo "[INFO] --keep-data: broker PVCs left in place."
fi

# Prep's artifacts (service account, SCC binding, pull secret) are deliberately
# left alone here: --keep-project means "keep what prep set up", so a reinstall
# can skip straight to 1.1. Drop them by hand if you want a bare namespace:
#   oc adm policy remove-scc-from-user anyuid -z ${SA} -n ${NS}
#   oc delete sa ${SA} secret ${CONFLUENT_PULL_SECRET:-confluent-registry} -n ${NS}
echo "[INFO] Service account, SCC binding and pull secret preserved (--keep-project)."

echo ""
if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[INFO] --dry-run complete. Nothing was deleted."
else
    echo "[INFO] Uninstall complete. Project '${NS}' preserved."
    if [[ "${KEEP_DATA}" == "true" ]]; then
        echo "[INFO] Broker PVCs retained. Note that reinstalling over them only works"
        echo "[INFO] if CONFLUENT_CLUSTER_ID is unchanged - a different id makes the"
        echo "[INFO] brokers reject the existing on-disk KRaft metadata."
    fi
fi
