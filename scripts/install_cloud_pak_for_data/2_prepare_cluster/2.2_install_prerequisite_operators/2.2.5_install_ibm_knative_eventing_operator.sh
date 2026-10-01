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

[[ -n "${PROJECT_IBM_EVENTS}" ]] || { echo "[INFO] PROJECT_IBM_EVENTS is not set - skipping IBM Knative Eventing install."; exit 0; }

eval "${OC_LOGIN}"

# Skip if the IBM Events Operator CSV is already Succeeded and KnativeEventing is
# Ready. Scope the CSV lookup to ibm-events-operator by name: an unscoped grep
# for "Succeeded" matches any other operator sharing this namespace and would
# report a never-installed Events Operator as present.
EVENTS_PHASE="$(cp4d_csv_phase "${PROJECT_IBM_EVENTS}" "ibm-events-operator")"

if [[ "${EVENTS_PHASE}" == "Succeeded" ]]; then
  KE_READY=$(oc get knativeeventing -n "${PROJECT_IBM_EVENTS}" -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [[ "${KE_READY}" == "True" ]]; then
    echo "[INFO] IBM Knative Eventing already installed and Ready in ${PROJECT_IBM_EVENTS}, skipping."
    exit 0
  fi
  echo "[INFO] IBM Events Operator is Succeeded but KnativeEventing is not Ready; reconciling."
fi

# ---
# Set CASE_DOWNLOAD_FROM to one of: github | oci
CASE_DOWNLOAD_FROM="oci"
# ---

TIMEOUT=300

# Step 1: Download the IBM Events CASE package
eval "${CPDM_OC_LOGIN}"

case "${CASE_DOWNLOAD_FROM}" in
  github)
    cpd-cli manage case-download \
      --release=${VERSION} \
      --components=ibm_events_operator
    ;;
  oci)
    cpd-cli manage case-download \
      --release=${VERSION} \
      --components=ibm_events_operator \
      --from_oci=true
    ;;
  *)
    echo "[ERROR] Unknown CASE_DOWNLOAD_FROM value: ${CASE_DOWNLOAD_FROM}" >&2
    exit 1
    ;;
esac

# Step 2: Generate the IBM Events Operator CRDs
cpd-cli manage deploy-events-operator \
  --release=${VERSION} \
  --cluster_resources=true

# Step 3: Apply the CRDs
eval "${OC_LOGIN}"

oc apply \
  -f "${CPD_CLI_WORK_PATH}/ibm-events-operator-crds.yaml" \
  --server-side \
  --force-conflicts

# Step 4: Install Red Hat OpenShift Serverless Knative Eventing
eval "${CPDM_OC_LOGIN}"

if [[ "${STG_CLASS_BLOCK:-}" == *"portworx"* || "${STORAGE_VENDOR:-}" == "portworx" ]]; then
  cpd-cli manage deploy-knative-eventing \
    --release=${VERSION} \
    --storage_vendor=portworx \
    --events_operator_ns=${PROJECT_IBM_EVENTS}
else
  cpd-cli manage deploy-knative-eventing \
    --release=${VERSION} \
    --block_storage_class=${STG_CLASS_BLOCK} \
    --events_operator_ns=${PROJECT_IBM_EVENTS}
fi

echo "[INFO] IBM Knative Eventing Operator installation complete."
