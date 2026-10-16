#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: only configs/concert_config/concert_vars.sh is in scope ---
export ENV_TARGET="${ENV_TARGET:-concert}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/concert_helpers.sh"
concert_require_config

# ==============================================================================
# 2.3.3 S3 object storage: OpenShift Data Foundation Multicloud Object Gateway
# ------------------------------------------------------------------------------
# Duplicate of the CP4D track's
#   2_prepare_cluster/2.2_install_prerequisite_operators/2.2.4_install_multicloud_object_gateway_operator.sh
# with two changes: it is driven by the Concert data store config instead of
# CPD_COMPONENTS, and `cpd-cli manage deploy-noobaa-backing-store` is replaced
# by Red Hat's documented standalone MCG install (odf-operator + StorageCluster
# with multiCloudGateway.reconcileStrategy=standalone), so no olm-utils
# container is needed. The NooBaa readiness wait is kept as is.
#
# An existing NooBaa (ODF / IBM Fusion Data Foundation) is reused untouched.
# Standalone MCG needs an OpenShift Data Foundation entitlement.
# ==============================================================================

if ! concert_ds_server_provisioned S3; then
    concert_info "S3 is not provisioned by these scripts - skipping the object gateway."
    exit 0
fi

eval "${OC_LOGIN}"

# ------------------------------------------------------------------------------
# Step 1: Install standalone Multicloud Object Gateway (skip if ODF/Fusion DDF)
# ------------------------------------------------------------------------------
MCG_ALREADY_INSTALLED=false
if oc get noobaa noobaa -n openshift-storage &>/dev/null; then
    echo "[INFO] NooBaa/MCG already installed in openshift-storage, skipping operator install."
    MCG_ALREADY_INSTALLED=true
fi

if [[ "${MCG_ALREADY_INSTALLED}" == "false" ]]; then
    MINOR="$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d. -f1,2)"
    CHANNEL="${CONCERT_DS_S3_MCG_CHANNEL:-stable-${MINOR}}"
    echo "[INFO] Installing standalone Multicloud Object Gateway (odf-operator, channel ${CHANNEL})..."
    cp4d_ensure_namespace openshift-storage "openshift.io/cluster-monitoring=true"
    concert_install_operator openshift-storage odf-operator "${CHANNEL}" redhat-operators 'odf-operator\.' own
    concert_wait_for 900 "CRD storageclusters.ocs.openshift.io" oc get crd storageclusters.ocs.openshift.io

    if [[ -z "$(oc get storageclusters.ocs.openshift.io -n openshift-storage -o name 2>/dev/null)" ]]; then
        oc apply -f - <<EOF
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ocs-storagecluster
  namespace: openshift-storage
  labels:
    app.kubernetes.io/managed-by: ${CONCERT_MANAGED_BY}
spec:
  multiCloudGateway:
    dbStorageClassName: ${CONCERT_STG_CLASS_DATASTORES:-${CONCERT_STG_CLASS_BLOCK}}
    reconcileStrategy: standalone
EOF
    else
        echo "[INFO] A StorageCluster already exists in openshift-storage - not creating another."
    fi

    echo "[INFO] Waiting for NooBaa to become Ready..."
    TIMEOUT=1200
    ELAPSED=0
    INTERVAL=15
    while true; do
        NOOBAA_PHASE=$(oc get noobaa noobaa -n openshift-storage -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [[ "${NOOBAA_PHASE}" == "Ready" ]]; then
            echo "[INFO] NooBaa is Ready."
            break
        fi
        if (( ELAPSED >= TIMEOUT )); then
            echo "[ERROR] Timed out waiting for NooBaa to become Ready (phase: ${NOOBAA_PHASE:-unknown})." >&2
            exit 1
        fi
        echo "[INFO] Waiting for NooBaa (phase: ${NOOBAA_PHASE:-unknown})... ${ELAPSED}s elapsed"
        sleep "${INTERVAL}"
        (( ELAPSED += INTERVAL ))
    done
fi

# ------------------------------------------------------------------------------
# Step 2: The bucket storage class used by 2.3.4
# ------------------------------------------------------------------------------
SC="${CONCERT_DS_S3_STORAGE_CLASS:-openshift-storage.noobaa.io}"
concert_wait_for 600 "StorageClass ${SC}" oc get storageclass "${SC}"
concert_info "Object gateway ready (bucket class ${SC})."
