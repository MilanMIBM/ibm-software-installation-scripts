#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# --- Inputs (env vars from cp4d_config/, with presets as fallback) ---
CCS_NAMESPACE="${PROJECT_CPD_INST_OPERANDS:-cpd-operands}"
CCS_OPERATOR_NAMESPACE="${PROJECT_CPD_INST_OPERATORS:-cpd-operators}"
CCS_BLOCK_SC="${STG_CLASS_BLOCK:-ocs-storagecluster-ceph-rbd}"
CCS_FILE_SC="${STG_CLASS_FILE:-ocs-storagecluster-cephfs}"
CCS_PULL_SECRET="${IMAGE_PULL_SECRET:-pull-secret}"
CCS_SCALE_CONFIG="${CCS_SCALE_CONFIG:-small}"
# Not IMAGE_PULL_PREFIX: that is the operator-image registry (icr.io);
# CCS operand images come from the entitled registry (cp.icr.io).
CCS_DEFAULT_REGISTRY_PREFIX="cp.icr.io"
CCS_DEFAULT_VERSION="13.0.6"

# ---
eval "${OC_LOGIN}"

# --- The CCS operator must be installed before a CCS CR can exist ---
if ! oc get crd ccs.ccs.cpd.ibm.com >/dev/null; then
    echo "[ERROR] CRD ccs.ccs.cpd.ibm.com not found - install the ccs operator first."
    exit 1
fi

# --- Skip if the CR already exists (InProgress, Completed or anything else) ---
if oc get ccs ccs-cr -n "${CCS_NAMESPACE}" >/dev/null 2>&1; then
    _status="$(oc get ccs ccs-cr -n "${CCS_NAMESPACE}" -o jsonpath='{.status.ccsStatus}')"
    _version="$(oc get ccs ccs-cr -n "${CCS_NAMESPACE}" -o jsonpath='{.spec.version}')"
    echo "[INFO] ccs-cr already exists in ${CCS_NAMESPACE} (version: ${_version:-unset}, status: ${_status:-not reported yet})."
    case "${_status}" in
        Completed)  echo "[INFO] Nothing to do." ;;
        InProgress) echo "[INFO] Reconcile in progress - leaving it alone." ;;
        Failed)     echo "[WARN] ccs-cr reports Failed - inspect with: oc describe ccs ccs-cr -n ${CCS_NAMESPACE}" ;;
    esac
    exit 0
fi

# --- Resolve version + registry prefix from the installed ccs operator ---
# The operator (installed by cpd-cli for this Software Hub release) stamps the
# CCS version it reconciles on its pod template as productVersion, and carries
# the operand registry in HELM_IMAGE_PULL_PREFIX. CCS_VERSION /
# CCS_REGISTRY_PREFIX override; the presets are the last resort.
_op_version="$(oc get deploy ibm-cpd-ccs-operator -n "${CCS_OPERATOR_NAMESPACE}" \
    -o jsonpath='{.spec.template.metadata.annotations.productVersion}' || true)"
_op_prefix="$(oc get deploy ibm-cpd-ccs-operator -n "${CCS_OPERATOR_NAMESPACE}" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="HELM_IMAGE_PULL_PREFIX")].value}' || true)"

if [[ -n "${CCS_VERSION:-}" ]]; then
    echo "[INFO] Using CCS_VERSION=${CCS_VERSION} from environment."
elif [[ -n "${_op_version}" ]]; then
    CCS_VERSION="${_op_version}"
    echo "[INFO] Installed ccs operator reconciles CCS ${CCS_VERSION} (Software Hub ${VERSION:-unknown})."
else
    CCS_VERSION="${CCS_DEFAULT_VERSION}"
    echo "[WARN] Could not read productVersion from ibm-cpd-ccs-operator in ${CCS_OPERATOR_NAMESPACE}; falling back to ${CCS_VERSION}."
fi

if [[ -n "${CCS_REGISTRY_PREFIX:-}" ]]; then
    echo "[INFO] Using CCS_REGISTRY_PREFIX=${CCS_REGISTRY_PREFIX} from environment."
elif [[ -n "${_op_prefix}" ]]; then
    CCS_REGISTRY_PREFIX="${_op_prefix}"
else
    CCS_REGISTRY_PREFIX="${CCS_DEFAULT_REGISTRY_PREFIX}"
fi

# --- Create the CR ---
echo "[INFO] Creating ccs-cr in ${CCS_NAMESPACE} (version ${CCS_VERSION}, scale ${CCS_SCALE_CONFIG})..."
oc apply -f - <<EOF
apiVersion: ccs.cpd.ibm.com/v1beta1
kind: CCS
metadata:
  name: ccs-cr
  namespace: ${CCS_NAMESPACE}
spec:
  license:
    accept: true
  non_olm_deploy: true
  nonOlmDeploy: true
  blockStorageClass: ${CCS_BLOCK_SC}
  fileStorageClass: ${CCS_FILE_SC}
  storageClass: ${CCS_FILE_SC}
  scaleConfig: ${CCS_SCALE_CONFIG}
  imagePullSecret: ${CCS_PULL_SECRET}
  docker_registry_prefix: ${CCS_REGISTRY_PREFIX}
  version: ${CCS_VERSION}
EOF

echo "[INFO] ccs-cr created. Track progress with:"
echo "       oc get ccs ccs-cr -n ${CCS_NAMESPACE} -o jsonpath='{.status.ccsStatus}'"
