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
source "${_CP4D_REPO_ROOT}/src/helpers/version_resolver.sh"

# SKIP_GPU_OPERATORS_INSTALL (shared by 2.2.1 NFD and 2.2.2 NVIDIA GPU Operator):
#   auto (default from 2.2_install_prerequisite_operators.sh) - install only when
#        CPD_COMPONENTS has a service that needs GPU with its install options
#   true / false - always skip / install
#   Run directly, this script installs it whatever CPD_COMPONENTS holds (with a banner).
cp4d_prereq_gate gpu SKIP_GPU_OPERATORS_INSTALL "the GPU operators (NFD + NVIDIA GPU Operator)" || exit 0

eval "${OC_LOGIN}"

NAMESPACE="openshift-nfd"
# The catalog's default channel (PackageManifest); "stable" when it cannot be read.
CHANNEL="$(vr_operator_channel nfd)"
TIMEOUT=300

# --- Existing-install handling -------------------------------------------------
# Match the CSV by name prefix, not by an unscoped grep for "Succeeded": other
# operators share this namespace on some clusters and report Succeeded on their
# own, which would make a never-installed NFD look present and skip the install.
NFD_PHASE="$(cp4d_csv_phase "${NAMESPACE}" "nfd")"

if [[ "${NFD_PHASE}" == "Succeeded" ]]; then
  CHANNEL_STATE="$(cp4d_reconcile_subscription_channel "${NAMESPACE}" "nfd" "${CHANNEL}")" || {
    # Healthy as-is: warn and keep going rather than stop the whole install.
    echo "[WARN] NFD is healthy but on a channel that cannot move to ${CHANNEL} in place; leaving it as-is (migrate manually if needed)." >&2
    exit 0
  }
  case "${CHANNEL_STATE}" in
    match)
      echo "[INFO] NFD Operator already installed on channel ${CHANNEL} in ${NAMESPACE}, skipping."
      exit 0
      ;;
    patched)
      echo "[INFO] NFD Subscription channel patched to ${CHANNEL}; waiting for OLM to roll the upgrade."
      cp4d_wait_for_csv "${NAMESPACE}" "nfd" "${TIMEOUT}"
      echo "[INFO] NFD Operator upgraded to channel ${CHANNEL} successfully."
      exit 0
      ;;
    absent)
      # CSV present without a Subscription (manual or orphaned install).
      # Fall through and reconcile it back under OLM management.
      echo "[INFO] NFD CSV is Succeeded but has no Subscription; reconciling."
      ;;
  esac
fi

cp4d_ensure_namespace "${NAMESPACE}" \
  "name=${NAMESPACE}" \
  "openshift.io/cluster-monitoring=true"

# A second OperatorGroup in this namespace makes OLM fail every CSV in it
# (TooManyOperatorGroups), so create one only when the namespace has none. A
# pre-existing group here often carries a different name, and the previous
# unguarded `oc apply` of a named group would then add a second one rather than
# update it. (That manifest also carried both generateName and name, where name
# silently wins - dead config worth dropping either way.)
cp4d_ensure_operatorgroup "${NAMESPACE}" "openshift-nfd" "${NAMESPACE}"

# Create the Subscription
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: nfd
  namespace: ${NAMESPACE}
spec:
  channel: "${CHANNEL}"
  installPlanApproval: Automatic
  name: nfd
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

echo "Waiting for NFD controller pod to become ready (timeout: ${TIMEOUT}s)..."
ELAPSED=0
INTERVAL=10
until oc get pod --namespace "${NAMESPACE}" --selector=control-plane=controller-manager --no-headers 2>/dev/null | grep -q .; do
  if (( ELAPSED >= TIMEOUT )); then
    echo "[ERROR] Timed out waiting for NFD controller pod to appear" >&2
    exit 1
  fi
  sleep ${INTERVAL}
  (( ELAPSED += INTERVAL ))
  CSV_STATE=$(oc get csv -n "${NAMESPACE}" --no-headers 2>/dev/null | awk '{print $1, $NF}' | head -1)
  echo "  [${ELAPSED}s] pod not yet created - CSV: ${CSV_STATE:-pending}"
done
REMAINING=$(( TIMEOUT - ELAPSED ))
echo "  Pod found after ${ELAPSED}s, waiting for Ready (up to ${REMAINING}s remaining)..."
oc wait pod \
  --namespace "${NAMESPACE}" \
  --for=condition=Ready \
  --selector=control-plane=controller-manager \
  --timeout="${REMAINING}s"

echo "NFD Operator installed successfully."
oc get pods --namespace "${NAMESPACE}"
