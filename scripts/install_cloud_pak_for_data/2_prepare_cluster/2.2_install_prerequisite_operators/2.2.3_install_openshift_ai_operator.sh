#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# (legacy hardcoded sourcing - replaced by universal crawl below)
# source "${SCRIPT_DIR}/../../source_env_setup.sh"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/scripts/operator_install_helpers.sh"

eval "${OC_LOGIN}"

NAMESPACE="redhat-ods-operator"
# Service Mesh version to install: 2 or 3
SERVICE_MESH_VERSION="${SERVICE_MESH_VERSION:-2}"
TIMEOUT=60

# Map CP4D VERSION to the corresponding RHOAI channel.
# Channel names are OLM channel identifiers (e.g. "2.25"), not CSV version strings.
# For unmapped versions, the default channel is resolved from the marketplace.
case "${VERSION}" in
  5.3.0|5.3.1) CHANNEL_VERSION="stable-2.25" ;;
  *)
    echo "[INFO] No fixed RHOAI channel mapping for CP4D VERSION=${VERSION}, resolving latest stable from marketplace..."
    CHANNEL_VERSION=$(oc get packagemanifest rhods-operator \
      -n openshift-marketplace \
      -o jsonpath='{.status.defaultChannel}')
    ;;
esac

echo "[INFO] CP4D VERSION=${VERSION} -> RHOAI channel=${CHANNEL_VERSION}"

# --- Existing-install handling -------------------------------------------------
# Three outcomes are possible when RHOAI is already present:
#   1. already on the target channel and healthy  -> nothing to do, skip
#   2. on a different channel                     -> patch the Subscription channel
#                                                    and let OLM roll the upgrade
#   3. present but unhealthy / mid-install        -> fall through and reconcile
# Scope the CSV lookup to rhods-operator: other operators (DevWorkspace, External
# Secrets, Pipelines, Web Terminal) also live in this namespace and report
# Succeeded, so an unscoped grep reports healthy even when RHOAI has failed.
RHOAI_CSV_PHASE="$(cp4d_csv_phase "${NAMESPACE}" "rhods-operator")"

if [[ "${RHOAI_CSV_PHASE}" == "Succeeded" ]]; then
  DSCI_PHASE=$(oc get dscinitialization default-dsci -o jsonpath='{.status.phase}' 2>/dev/null || true)
  # DataScienceCluster reports readiness through its Ready condition, not .status.phase.
  DSC_READY=$(oc get datasciencecluster default-dsc \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)

  if [[ "${DSCI_PHASE}" == "Ready" && "${DSC_READY}" == "True" ]]; then
    # A different channel family (stable -> fast) or major version is not an
    # in-place upgrade OLM can roll, so the helper fails and we stop.
    CHANNEL_STATE="$(cp4d_reconcile_subscription_channel \
      "${NAMESPACE}" "rhods-operator" "${CHANNEL_VERSION}")" || {
      echo "[ERROR] RHOAI is on a channel CP4D ${VERSION} cannot upgrade in place (target ${CHANNEL_VERSION})." >&2
      echo "[ERROR] Migrate it manually before re-running." >&2
      exit 1
    }
    case "${CHANNEL_STATE}" in
      match)
        echo "[INFO] RHOAI already installed on channel ${CHANNEL_VERSION} and DataScienceCluster is Ready, skipping."
        exit 0
        ;;
      patched)
        echo "[INFO] RHOAI Subscription channel patched to ${CHANNEL_VERSION}; OLM will roll the upgrade."
        cp4d_wait_for_csv "${NAMESPACE}" "rhods-operator" "${TIMEOUT}"
        echo "[INFO] RHOAI upgraded to channel ${CHANNEL_VERSION} successfully."
        exit 0
        ;;
      absent)
        echo "[INFO] RHOAI CSV is Succeeded but has no Subscription; reconciling."
        ;;
    esac
  fi
fi

# Create the namespace
oc new-project "${NAMESPACE}" 2>/dev/null || echo "[INFO] Project ${NAMESPACE} already exists, continuing."

# Create the OperatorGroup only if the namespace has none. OLM fails any CSV in a
# namespace holding more than one OperatorGroup (TooManyOperatorGroups), and an
# existing group may carry a different name (the namespace-default "redhat-ods-operator"),
# so a blind `oc apply` of a named group would add a second one rather than update it.
cp4d_ensure_operatorgroup "${NAMESPACE}" "rhods-operator"

# Create the Subscription
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhods-operator
  namespace: ${NAMESPACE}
spec:
  name: rhods-operator
  channel: "${CHANNEL_VERSION}"
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  config:
    env:
      - name: "DISABLE_DSC_CONFIG"
        value: "true"
EOF


# --- Service Mesh Install ---
# Installs cluster-wide into openshift-operators; the global OperatorGroup already exists.
if [[ "${SERVICE_MESH_VERSION}" == "3" ]]; then
  SM_OPERATOR="servicemeshoperator3"
  SM_CHANNEL="stable"
  echo "[INFO] Installing Red Hat OpenShift Service Mesh 3..."
elif [[ "${SERVICE_MESH_VERSION}" == "2" ]]; then
  SM_OPERATOR="servicemeshoperator"
  SM_CHANNEL="stable"
  echo "[INFO] Installing Red Hat OpenShift Service Mesh 2..."
else
  echo "[ERROR] Unsupported SERVICE_MESH_VERSION=${SERVICE_MESH_VERSION}. Must be 2 or 3." >&2
  exit 1
fi

# Match the CSV by its real name prefix. The CSV is named servicemeshoperator.v2.x
# / servicemeshoperator3.v3.x, and "servicemeshoperator" is a strict prefix of
# "servicemeshoperator3", so a bare prefix test for v2 also matches an installed
# v3 and would skip the v2 install. Anchor on the version separator to keep the
# two apart.
SM_CSV_PHASE="$(cp4d_csv_phase openshift-operators "${SM_OPERATOR}\\.")"

if [[ "${SM_CSV_PHASE}" == "Succeeded" ]]; then
  echo "[INFO] Service Mesh ${SERVICE_MESH_VERSION} operator already installed, skipping."
else
  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${SM_OPERATOR}
  namespace: openshift-operators
spec:
  channel: ${SM_CHANNEL}
  name: ${SM_OPERATOR}
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

  echo "Waiting for Service Mesh ${SERVICE_MESH_VERSION} CSV to reach Succeeded (timeout: ${TIMEOUT}s)..."
  cp4d_wait_for_csv openshift-operators "${SM_OPERATOR}\\." "${TIMEOUT}"
  echo "[INFO] Service Mesh ${SERVICE_MESH_VERSION} operator installed successfully."
fi

#---

# Wait for the operator pod to be running
echo "Waiting for rhods-operator pod to become ready (timeout: ${TIMEOUT}s)..."
ELAPSED=0
until oc get pod -n "${NAMESPACE}" -l name=rhods-operator --no-headers 2>/dev/null | grep -q .; do
  sleep 10
  ELAPSED=$(( ELAPSED + 10 ))
  CSV_STATE=$(oc get csv -n "${NAMESPACE}" --no-headers 2>/dev/null | awk '{print $1, $NF}' | head -1)
  echo "  [${ELAPSED}s] pod not yet created - CSV: ${CSV_STATE:-pending}"
  if (( ELAPSED >= TIMEOUT )); then
    echo "[ERROR] rhods-operator pod never appeared in ${NAMESPACE} after ${TIMEOUT}s." >&2
    exit 1
  fi
done
REMAINING=$(( TIMEOUT - ELAPSED ))
echo "  Pod found after ${ELAPSED}s, waiting for Ready (up to ${REMAINING}s remaining)..."
oc wait pod \
  --namespace "${NAMESPACE}" \
  --for=condition=Ready \
  --selector=name=rhods-operator \
  --timeout="${REMAINING}s"

echo "rhods-operator pod is Running."
oc get pods -n "${NAMESPACE}"

# Create DSCInitialization
echo "Creating DSCInitialization..."
oc apply -f - <<EOF
apiVersion: dscinitialization.opendatahub.io/v1
kind: DSCInitialization
metadata:
  name: default-dsci
spec:
  applicationsNamespace: redhat-ods-applications
  monitoring:
    managementState: Managed
    namespace: redhat-ods-monitoring
  serviceMesh:
    managementState: Managed
  trustedCABundle:
    managementState: Managed
    customCABundle: ""
EOF

# Wait for DSCInitialization to be Ready
echo "Waiting for DSCInitialization to reach Ready phase..."
for i in $(seq 1 30); do
  PHASE=$(oc get dscinitialization default-dsci -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [[ "${PHASE}" == "Ready" ]] && break
  echo "  phase=${PHASE:-unknown}, retrying in 10s..."
  sleep 10
done

if [[ "${PHASE:-}" != "Ready" ]]; then
  echo "[ERROR] DSCInitialization did not reach Ready phase." >&2
  oc get dscinitialization
  exit 1
fi
echo "DSCInitialization is Ready."

# Create DataScienceCluster
echo "Creating DataScienceCluster..."
oc apply -f - <<EOF
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    codeflare:
      managementState: Removed
    dashboard:
      managementState: Managed
    datasciencepipelines:
      managementState: Managed
    kserve:
      managementState: Managed
      defaultDeploymentMode: RawDeployment
      serving:
        managementState: Removed
        name: knative-serving
    kueue:
      managementState: Removed
    modelmeshserving:
      managementState: Removed
    ray:
      managementState: Removed
    trainingoperator:
      managementState: Managed
    trustyai:
      managementState: Removed
    workbenches:
      managementState: Managed
EOF

# Wait for DataScienceCluster to be Ready
echo "Waiting for DataScienceCluster default-dsc to reach Ready phase..."
for i in $(seq 1 36); do
  DSC_PHASE=$(oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [[ "${DSC_PHASE}" == "Ready" ]] && break
  echo "  phase=${DSC_PHASE:-unknown}, retrying in 10s..."
  sleep 10
done

if [[ "${DSC_PHASE:-}" != "Ready" ]]; then
  echo "[ERROR] DataScienceCluster did not reach Ready phase." >&2
  oc get datasciencecluster default-dsc
  exit 1
fi
echo "DataScienceCluster is Ready."

# Verify expected pods in redhat-ods-applications are Running
echo "Verifying pods in redhat-ods-applications..."
KSERVE_STATE=$(oc get datasciencecluster default-dsc \
  -o jsonpath='{.spec.components.kserve.managementState}' 2>/dev/null || true)

SELECTORS=("app=kubeflow-training-operator" "app=odh-model-controller")
[[ "${KSERVE_STATE}" != "Removed" ]] && SELECTORS+=("control-plane=kserve-controller-manager")

for selector in "${SELECTORS[@]}"; do
  ELAPSED=0
  until oc get pod -n redhat-ods-applications -l "${selector}" --no-headers 2>/dev/null | grep -q .; do
    sleep 10
    ELAPSED=$(( ELAPSED + 10 ))
    echo "  [${ELAPSED}s] waiting for pod with selector ${selector}..."
    if (( ELAPSED >= TIMEOUT )); then
      echo "[ERROR] Pod with selector ${selector} never appeared after ${TIMEOUT}s." >&2
      exit 1
    fi
  done
  REMAINING=$(( TIMEOUT - ELAPSED ))
  oc wait pod \
    --namespace redhat-ods-applications \
    --for=condition=Ready \
    --selector="${selector}" \
    --timeout="${REMAINING}s"
done
oc get pods -n redhat-ods-applications

# Patch inferenceservice-config: disable managed mode and set domainTemplate to example.com
echo "Patching inferenceservice-config ConfigMap..."
oc annotate configmap inferenceservice-config \
  -n redhat-ods-applications \
  opendatahub.io/managed=false \
  --overwrite

# Patch the domainTemplate value in the ConfigMap data
CURRENT_DATA=$(oc get configmap inferenceservice-config \
  -n redhat-ods-applications \
  -o jsonpath='{.data.ingress}')

PATCHED_DATA=$(echo "${CURRENT_DATA}" | \
  sed 's|"domainTemplate": "[^"]*"|"domainTemplate": "example.com"|')

oc patch configmap inferenceservice-config \
  -n redhat-ods-applications \
  --type merge \
  --patch "{\"data\":{\"ingress\":$(echo "${PATCHED_DATA}" | jq -Rs .)}}"

echo "inferenceservice-config patched."
echo "Red Hat OpenShift AI Operator installation complete."
