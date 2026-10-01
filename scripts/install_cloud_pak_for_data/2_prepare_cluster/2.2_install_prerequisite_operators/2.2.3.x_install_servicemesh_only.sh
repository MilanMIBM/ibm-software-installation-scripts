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

# Installs cluster-wide into openshift-operators; the global OperatorGroup already exists.
NAMESPACE="openshift-operators"
# Service Mesh version to install: 2 or 3. Defaults to 3 for CP4D 5.4.0+ and 2 for
# earlier releases; export SERVICE_MESH_VERSION to override.
SERVICE_MESH_VERSION="${SERVICE_MESH_VERSION:-$(cp4d_default_service_mesh_version)}"
CHANNEL="stable"
TIMEOUT=60

case "${SERVICE_MESH_VERSION}" in
  3) SM_OPERATOR="servicemeshoperator3" ;;
  2) SM_OPERATOR="servicemeshoperator" ;;
  *)
    echo "[ERROR] Unsupported SERVICE_MESH_VERSION=${SERVICE_MESH_VERSION}. Must be 2 or 3." >&2
    exit 1
    ;;
esac

echo "[INFO] Installing Red Hat OpenShift Service Mesh ${SERVICE_MESH_VERSION} (${SM_OPERATOR})..."

# --- Existing-install handling -------------------------------------------------
# Match the CSV by its real name prefix. The CSV is named servicemeshoperator.v2.x
# / servicemeshoperator3.v3.x, and "servicemeshoperator" is a strict prefix of
# "servicemeshoperator3", so a bare prefix test for v2 also matches an installed
# v3 and would skip the v2 install. Anchor on the version separator to keep the
# two apart. openshift-operators also holds every other cluster-wide operator,
# so an unscoped grep for "Succeeded" would be meaningless here.
SM_PHASE="$(cp4d_csv_phase "${NAMESPACE}" "${SM_OPERATOR}\\.")"

if [[ "${SM_PHASE}" == "Succeeded" ]]; then
  CHANNEL_STATE="$(cp4d_reconcile_subscription_channel "${NAMESPACE}" "${SM_OPERATOR}" "${CHANNEL}")" || {
    echo "[ERROR] Service Mesh ${SERVICE_MESH_VERSION} is on an incompatible channel for target ${CHANNEL}; migrate it manually." >&2
    exit 1
  }
  case "${CHANNEL_STATE}" in
    match)
      echo "[INFO] Service Mesh ${SERVICE_MESH_VERSION} operator already installed on channel ${CHANNEL} in ${NAMESPACE}, skipping."
      exit 0
      ;;
    patched)
      echo "[INFO] Service Mesh ${SERVICE_MESH_VERSION} Subscription channel patched to ${CHANNEL}; waiting for OLM to roll the upgrade."
      cp4d_wait_for_csv "${NAMESPACE}" "${SM_OPERATOR}\\." "${TIMEOUT}"
      echo "[INFO] Service Mesh ${SERVICE_MESH_VERSION} operator upgraded to channel ${CHANNEL} successfully."
      exit 0
      ;;
    absent)
      echo "[INFO] Service Mesh ${SERVICE_MESH_VERSION} CSV is Succeeded but has no Subscription; reconciling."
      ;;
  esac
else
  [[ -n "${SM_PHASE}" ]] && \
    echo "[INFO] Service Mesh ${SERVICE_MESH_VERSION} CSV present in phase ${SM_PHASE}; reconciling the install."
fi

# Create the Subscription
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${SM_OPERATOR}
  namespace: ${NAMESPACE}
spec:
  channel: "${CHANNEL}"
  installPlanApproval: Automatic
  name: ${SM_OPERATOR}
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "Waiting for Service Mesh ${SERVICE_MESH_VERSION} CSV to reach Succeeded (timeout: ${TIMEOUT}s)..."
cp4d_wait_for_csv "${NAMESPACE}" "${SM_OPERATOR}\\." "${TIMEOUT}"

echo "Red Hat OpenShift Service Mesh ${SERVICE_MESH_VERSION} installation complete."
oc get csv -n "${NAMESPACE}" --no-headers | grep "^${SM_OPERATOR}\." || true
