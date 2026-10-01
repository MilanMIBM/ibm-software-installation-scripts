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

NAMESPACE="nvidia-gpu-operator"
TIMEOUT=120

# Resolve channel and startingCSV dynamically. This has to happen before the
# existing-install check so the channel comparison has a target to compare to.
echo "Resolving GPU Operator channel and CSV from marketplace..."
CHANNEL=$(oc get packagemanifest gpu-operator-certified \
  -n openshift-marketplace \
  -o jsonpath='{.status.defaultChannel}')
echo "  channel: ${CHANNEL}"

# --- Existing-install handling -------------------------------------------------
# The previous version exited on the mere existence of a Subscription, which
# meant a half-finished or failed install could never be repaired by re-running
# the script - it reported "skipping" and left the cluster broken. Branch on the
# CSV phase instead, so only a genuinely healthy install is skipped.
GPU_PHASE="$(cp4d_csv_phase "${NAMESPACE}" "gpu-operator-certified")"

if [[ "${GPU_PHASE}" == "Succeeded" ]]; then
  CHANNEL_STATE="$(cp4d_reconcile_subscription_channel "${NAMESPACE}" "gpu-operator-certified" "${CHANNEL}")" || {
    echo "[ERROR] GPU Operator is on an incompatible channel for target ${CHANNEL}; migrate it manually." >&2
    exit 1
  }
  case "${CHANNEL_STATE}" in
    match)
      echo "[INFO] NVIDIA GPU Operator already installed on channel ${CHANNEL} in ${NAMESPACE}, skipping."
      exit 0
      ;;
    patched)
      echo "[INFO] GPU Operator Subscription channel patched to ${CHANNEL}; waiting for OLM to roll the upgrade."
      # installPlanApproval is Manual below, so the upgrade needs its InstallPlan
      # approved too; approve any pending plan rather than waiting on one that
      # will never progress on its own.
      for _i in $(seq 1 30); do
        PENDING_PLAN=$(oc get installplan -n "${NAMESPACE}" \
          -o jsonpath='{range .items[?(@.spec.approved==false)]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1 || true)
        [[ -n "${PENDING_PLAN}" ]] && break
        sleep 5
      done
      if [[ -n "${PENDING_PLAN:-}" ]]; then
        echo "[INFO] Approving upgrade InstallPlan: ${PENDING_PLAN}"
        oc patch "installplan/${PENDING_PLAN}" -n "${NAMESPACE}" \
          --type merge --patch '{"spec":{"approved":true}}'
      fi
      cp4d_wait_for_csv "${NAMESPACE}" "gpu-operator-certified" "${TIMEOUT}"
      echo "[INFO] NVIDIA GPU Operator upgraded to channel ${CHANNEL} successfully."
      exit 0
      ;;
    absent)
      echo "[INFO] GPU Operator CSV is Succeeded but has no Subscription; reconciling."
      ;;
  esac
else
  [[ -n "${GPU_PHASE}" ]] && \
    echo "[INFO] GPU Operator CSV present in phase ${GPU_PHASE}; reconciling the install."
fi

cp4d_ensure_namespace "${NAMESPACE}" "openshift.io/cluster-monitoring=true"

# Only create an OperatorGroup when the namespace has none: a second group makes
# OLM fail every CSV in the namespace (TooManyOperatorGroups).
cp4d_ensure_operatorgroup "${NAMESPACE}" "nvidia-gpu-operator-group" "${NAMESPACE}"

STARTING_CSV=$(oc get packagemanifests/gpu-operator-certified \
  -n openshift-marketplace \
  -ojson | jq -r --arg ch "${CHANNEL}" \
  '.status.channels[] | select(.name == $ch) | .currentCSV')
echo "  startingCSV: ${STARTING_CSV}"

# startingCSV only pins where OLM BEGINS resolving, and it is meaningful only on
# a first install. Re-applying it against an already-installed operator pins the
# Subscription back to a version that may be older than the CSV on the cluster,
# which leaves OLM unable to resolve and the Subscription stuck. So include it
# only when no CSV exists yet.
{
  echo "apiVersion: operators.coreos.com/v1alpha1"
  echo "kind: Subscription"
  echo "metadata:"
  echo "  name: gpu-operator-certified"
  echo "  namespace: ${NAMESPACE}"
  echo "spec:"
  echo "  channel: \"${CHANNEL}\""
  echo "  installPlanApproval: Manual"
  echo "  name: gpu-operator-certified"
  echo "  source: certified-operators"
  echo "  sourceNamespace: openshift-marketplace"
  if [[ -z "${GPU_PHASE}" ]]; then
    echo "  startingCSV: \"${STARTING_CSV}\""
  fi
} | oc apply -f -

# Wait for the InstallPlan to appear then approve it
echo "Waiting for InstallPlan to be created..."
for i in $(seq 1 30); do
  INSTALL_PLAN=$(oc get installplan -n "${NAMESPACE}" -oname 2>/dev/null | head -1)
  [[ -n "${INSTALL_PLAN}" ]] && break
  sleep 10
done

if [[ -z "${INSTALL_PLAN:-}" ]]; then
  echo "[WARN] No InstallPlan found in ${NAMESPACE} after 5 minutes, continuing."
  exit 0
fi

echo "Approving InstallPlan: ${INSTALL_PLAN}"
oc patch "${INSTALL_PLAN}" -n "${NAMESPACE}" \
  --type merge \
  --patch '{"spec":{"approved":true}}'

echo "Waiting for GPU Operator pod to become ready (timeout: ${TIMEOUT}s)..."
ELAPSED=0
until oc get pod -n "${NAMESPACE}" -l app=gpu-operator --no-headers 2>/dev/null | grep -q .; do
  sleep 10
  ELAPSED=$(( ELAPSED + 10 ))
  CSV_STATE=$(oc get csv -n "${NAMESPACE}" "${STARTING_CSV}" --no-headers 2>/dev/null | awk '{print $1, $NF}')
  echo "  [${ELAPSED}s] pod not yet created - CSV: ${CSV_STATE:-pending}"
  if (( ELAPSED >= TIMEOUT )); then
    echo "[WARN] GPU Operator pod never appeared in ${NAMESPACE} after ${TIMEOUT}s, continuing."
    exit 0
  fi
done
REMAINING=$(( TIMEOUT - ELAPSED ))
echo "  Pod found after ${ELAPSED}s, waiting for Ready (up to ${REMAINING}s remaining)..."
oc wait pod \
  --namespace "${NAMESPACE}" \
  --for=condition=Ready \
  --selector=app=gpu-operator \
  --timeout="${REMAINING}s" || echo "[WARN] GPU Operator pod did not become Ready within timeout, continuing."

echo "NVIDIA GPU Operator installed successfully."
oc get pods --namespace "${NAMESPACE}"
