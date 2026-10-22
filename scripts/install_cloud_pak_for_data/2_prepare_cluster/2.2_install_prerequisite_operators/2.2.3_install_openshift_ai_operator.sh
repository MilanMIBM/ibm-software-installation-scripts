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

# --- Switches ------------------------------------------------------------------
# SKIP_RHOAI_INSTALL=true skips this script entirely: no RHOAI operator and no
# Service Mesh. Off by default.
# RHOAI_CREATE_DSC controls the DataScienceCluster (the RHOAI operator itself is
# always installed unless SKIP_RHOAI_INSTALL=true):
#   auto  (default) - create it only when CPD_COMPONENTS has a service that needs
#                     RHOAI with its install options (or IBM's defaults for them)
#   true / false    - always / never create it
SKIP_RHOAI_INSTALL="${SKIP_RHOAI_INSTALL:-false}"
RHOAI_CREATE_DSC="${RHOAI_CREATE_DSC:-auto}"

if [[ "${SKIP_RHOAI_INSTALL}" == "true" ]]; then
  echo "[INFO] SKIP_RHOAI_INSTALL=true - skipping Red Hat OpenShift AI and Service Mesh."
  exit 0
fi

# --- Does any service need the DataScienceCluster? ----------------------------
# Rules from IBM's "Installing Red Hat OpenShift AI" (Software Hub 5.4) table.
# Options are read from the install-options file the component install passes as
# --param-file; a service with no options there is judged on IBM's defaults.
# Prints one "[needed]" / "[not needed]" line per relevant component; exits 2 if
# the options file cannot be read.
rhoai_dsc_verdicts() {
  CPD_COMPONENTS="${CPD_COMPONENTS:-}" OPTIONS_FILE="$1" python3 - <<'PYEOF'
import os, sys
try:
    import yaml
except ImportError:
    print("PyYAML is not available to python3", file=sys.stderr)
    sys.exit(2)

components = [c.strip() for c in os.environ["CPD_COMPONENTS"].split(",") if c.strip()]
path = os.environ["OPTIONS_FILE"]

# Merge every document's per-service blocks: the file is one YAML document per
# service, each under non_olm (or override_components_meta / custom_spec).
opts = {}
if path:
    try:
        with open(path) as f:
            for doc in yaml.safe_load_all(f):
                if not isinstance(doc, dict):
                    continue
                for section in ("non_olm", "override_components_meta", "custom_spec"):
                    for svc, cfg in (doc.get(section) or {}).items():
                        if isinstance(cfg, dict):
                            opts.setdefault(svc, {}).update(cfg)
    except (OSError, yaml.YAMLError) as e:
        print(f"cannot read {path}: {e}", file=sys.stderr)
        sys.exit(2)

def block(*names):
    for n in names:
        if n in opts:
            return opts[n]
    return None

def get(cfg, key, default):
    v = (cfg or {}).get(key)
    return default if v is None else v

def text(v):
    return str(v).strip().lower()

def on(v):
    return text(v) in ("true", "yes", "1")

def enrichments_on(node, under=False):
    # IBM documents no exact key for Speech enrichments, so match any key
    # containing "enrich" that is switched on.
    if isinstance(node, dict):
        return any(enrichments_on(v, under or "enrich" in str(k).lower()) for k, v in node.items())
    if isinstance(node, list):
        return under and bool(node)
    return under and on(node)

# Always need RHOAI. watsonx_ai_ifm serves the Inference foundation models, and
# the wca_z family runs models too, so those are kept here to fail safe.
ALWAYS = {
    "watsonx_ai", "watsonx_ai_ifm", "watsonx_bi_assistant",
    "wca", "wca_ansible", "wca_z", "wca_z_agentic", "wca_z_ce", "wca_z_cg", "wca_z_understand",
}

def verdict(c):
    if c in ALWAYS:
        return True, "always requires Red Hat OpenShift AI"
    if c in ("ikc_premium", "ikc_standard"):
        key = "ikcPremium" if c == "ikc_premium" else "ikcStandard"
        m = text(get(block(key), "enableModelsOn", "cpu"))
        return m == "gpu", f"{key}.enableModelsOn={m} (needed only for gpu)"
    if c == "watson_speech":
        e = enrichments_on(block("watsonSpeech") or {})
        return e, f"watsonSpeech enrichments {'on' if e else 'off'} (needed only for enrichments)"
    if c == "watson_assistant":
        t = text(get(block("watsonAssistant"), "watsonxAiType", "none"))
        return t == "embedded", f"watsonAssistant.watsonxAiType={t} (needed only for embedded/GPU features)"
    if c == "watsonx_data_premium":
        cfg = block("watsonxDataPremium")
        if cfg is None:
            return True, "no watsonxDataPremium options - assuming all features"
        comps = get(cfg, "component", [])
        comps = [text(x) for x in (comps if isinstance(comps, list) else [comps])]
        gpu = text(get(cfg, "wxd_premium_enable_models_on", "")) == "gpu"
        if "premium" in comps or gpu:
            return True, "watsonxDataPremium all features (component premium / models on gpu)"
        if not comps:
            return True, "watsonxDataPremium.component not set - assuming all features"
        return False, f"watsonxDataPremium.component={','.join(comps)} (limited features)"
    if c == "watsonx_dataintegration":
        u = on(get(block("watsonxDataintegration", "watsonx_dataintegration"),
                   "enableUnstructuredDataIntegration", True))
        return u, f"enableUnstructuredDataIntegration={str(u).lower()} (IBM default true)"
    if c == "watsonx_dataintelligence":
        cfg = block("watsonxDataintelligence")
        m = text(get(cfg, "enableModelsOn", "cpu"))
        u = on(get(cfg, "enableUnstructuredDataIntegration", False))
        return m == "gpu" or u, f"watsonxDataintelligence.enableModelsOn={m}, enableUnstructuredDataIntegration={str(u).lower()}"
    if c == "watsonx_orchestrate":
        ai = get(block("watsonxOrchestrate"), "watsonxAI", {}) or {}
        f = on(get(ai, "watsonxaiifm", False))
        return f, f"watsonxOrchestrate.watsonxAI.watsonxaiifm={str(f).lower()} (needed only for local models)"
    return None

for c in components:
    v = verdict(c)
    if v is not None:
        print(f"[{'needed' if v[0] else 'not needed'}] {c}: {v[1]}")
PYEOF
}

case "${RHOAI_CREATE_DSC}" in
  true|false)
    CREATE_DSC="${RHOAI_CREATE_DSC}"
    echo "[INFO] RHOAI_CREATE_DSC=${RHOAI_CREATE_DSC} - DataScienceCluster creation set explicitly."
    ;;
  auto)
    # Same file the component install passes as --param-file, read from the host side.
    OPTIONS_FILE=""
    if [[ "${INSTALL_OPTIONS:-}" == "true" && -n "${INSTALL_OPTIONS_FILE:-}" ]]; then
      OPTIONS_FILE="${CONFIG_DIR}/${INSTALL_OPTIONS_FILE}"
      if [[ ! -f "${OPTIONS_FILE}" ]]; then
        echo "[WARN] ${OPTIONS_FILE} not found - judging on IBM's default install options." >&2
        OPTIONS_FILE=""
      fi
    fi
    echo "[INFO] Checking whether CPD_COMPONENTS needs a DataScienceCluster (options: ${OPTIONS_FILE:-IBM defaults})..."
    if DSC_VERDICTS="$(rhoai_dsc_verdicts "${OPTIONS_FILE}")"; then
      [[ -n "${DSC_VERDICTS}" ]] && print -r -- "${DSC_VERDICTS}" | sed 's/^/[INFO]   /'
      if grep -q '^\[needed\]' <<< "${DSC_VERDICTS}"; then
        CREATE_DSC=true
      else
        CREATE_DSC=false
        echo "[INFO] No component in CPD_COMPONENTS needs Red Hat OpenShift AI with these options -"
        echo "[INFO] installing the operator without a DataScienceCluster."
      fi
    else
      echo "[WARN] Could not evaluate the install options - creating the DataScienceCluster to be safe." >&2
      CREATE_DSC=true
    fi
    ;;
  *)
    echo "[ERROR] RHOAI_CREATE_DSC must be auto, true or false (got '${RHOAI_CREATE_DSC}')." >&2
    exit 1
    ;;
esac

eval "${OC_LOGIN}"

NAMESPACE="redhat-ods-operator"
# Service Mesh version to install: 2 or 3. Defaults to 3 for CP4D 5.4.0+ and 2 for
# earlier releases; export SERVICE_MESH_VERSION to override.
SERVICE_MESH_VERSION="${SERVICE_MESH_VERSION:-$(cp4d_default_service_mesh_version)}"
TIMEOUT=300

# Map CP4D VERSION to the corresponding RHOAI channel.
# Channel names are OLM channel identifiers (e.g. "2.25"), not CSV version strings.
# For unmapped versions, the default channel is resolved from the marketplace.
case "${VERSION}" in
  # Software Hub 5.4.0 still pins RHOAI 2.25 (IBM docs, prep-cluster-openshift-ai);
  # the marketplace default is now stable-3.x, which is a major-version jump.
  5.3.0|5.3.1|5.4.0) CHANNEL_VERSION="stable-2.25" ;;
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
  # Without a DataScienceCluster to create, a Ready DSCInitialization is the finished state.
  if [[ "${CREATE_DSC}" == "true" ]]; then
    HEALTHY_DESC="DataScienceCluster is Ready"
  else
    HEALTHY_DESC="DSCInitialization is Ready (no DataScienceCluster needed)"
    DSC_READY="True"
  fi

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
        echo "[INFO] RHOAI already installed on channel ${CHANNEL_VERSION} and ${HEALTHY_DESC}, skipping."
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

if [[ "${CREATE_DSC}" != "true" ]]; then
  # An existing DataScienceCluster may carry user workloads, so it is never removed here.
  if oc get datasciencecluster default-dsc &>/dev/null; then
    echo "[INFO] DataScienceCluster default-dsc already exists - leaving it in place."
  fi
  echo "[INFO] Skipping the DataScienceCluster. To create it later: RHOAI_CREATE_DSC=true $0"
  echo "Red Hat OpenShift AI Operator installation complete."
  exit 0
fi

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

SELECTORS=("control-plane=kubeflow-training-operator" "app=odh-model-controller")
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
