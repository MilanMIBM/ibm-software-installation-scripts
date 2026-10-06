#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# (legacy hardcoded sourcing - replaced by universal crawl below)
# source "${SCRIPT_DIR}/../source_env_setup.sh"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# ---
eval "${OC_LOGIN}"

OP_NS="openshift-cert-manager-operator"
SUB_NAME="openshift-cert-manager-operator"
CM_LABEL="app.kubernetes.io/instance=cert-manager"
CM_COMPONENTS=(controller cainjector webhook)
INSTALL_TIMEOUT=900   # seconds, total budget for the whole install
POLL=5
TOTAL_STAGES=6
STAGE_NAMES=(
    "Resolving Subscription"
    "Running InstallPlan"
    "Creating ClusterServiceVersion"
    "Rolling out operator deployment"
    "Deploying cert-manager components"
    "Waiting for cert-manager components to become available"
)

_empty=""   # base string for the zsh padding flags that draw the progress bar
_get() { oc get "$@" 2>/dev/null || true; }

# Number of cert-manager components (controller/cainjector/webhook) that exist
# / are available in ANY namespace, so a cert-manager installed some other way
# is recognised too.
_cm_components() {
    _get deployment -A -l "${CM_LABEL}" \
        -o jsonpath='{range .items[*]}{.metadata.labels.app\.kubernetes\.io/component}{" "}{.status.availableReplicas}{"\n"}{end}'
}
_cm_counts() {   # prints "<existing> <available>"
    local rows existing=0 available=0 c
    rows="$(_cm_components)"
    for c in "${CM_COMPONENTS[@]}"; do
        grep -q "^${c} " <<<"${rows}" && (( existing += 1 ))
        grep -q "^${c} [1-9]" <<<"${rows}" && (( available += 1 ))
    done
    echo "${existing} ${available}"
}
_cm_healthy() {
    [[ -n "$(_get crd certificates.cert-manager.io -o name)" ]] || return 1
    [[ "$(_cm_counts)" == "${#CM_COMPONENTS} ${#CM_COMPONENTS}" ]]
}

# --- Already installed and running? Then there is nothing to do. ---
if _cm_healthy; then
    cm_ns="$(_get deployment -A -l "${CM_LABEL}" -o jsonpath='{.items[0].metadata.namespace}')"
    cm_ver="$(_get crd certificates.cert-manager.io -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}')"
    echo "[INFO] cert-manager ${cm_ver:-} is already installed and running in '${cm_ns}' - skipping install."
    exit 0
fi

# --- Partially installed? Reuse what exists instead of re-applying. ---
existing_sub="$(_get subscriptions.operators.coreos.com -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" "}{.spec.name}{"\n"}{end}' \
    | grep -i 'cert-manager' || true)"
if [[ -n "${existing_sub}" ]] && ! grep -q "^${OP_NS}/${SUB_NAME} " <<<"${existing_sub}"; then
    echo "[ERROR] A different cert-manager Subscription already exists, so installing a second one would conflict:"
    echo "${existing_sub}" | sed 's/^/    /'
    echo "[ERROR] Fix or remove it, or wait for it to finish, then re-run this script."
    exit 1
fi

if [[ -n "${existing_sub}" ]]; then
    echo "[INFO] Subscription ${OP_NS}/${SUB_NAME} already exists - not re-applying, waiting for it to finish."
else
    echo "[INFO] cert-manager not found - installing the cert-manager Operator for Red Hat OpenShift."
    oc create namespace "${OP_NS}" --dry-run=client -o yaml | oc apply -f -

    # Only create an OperatorGroup if the namespace has none (two break OLM).
    if [[ -z "$(_get operatorgroups.operators.coreos.com -n "${OP_NS}" -o name)" ]]; then
        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator-group
  namespace: ${OP_NS}
spec:
  targetNamespaces:
  - ${OP_NS}
EOF
    fi

    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${SUB_NAME}
  namespace: ${OP_NS}
spec:
  channel: stable-v1
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
fi

# Track the real OLM install chain instead of a single `oc wait`, which fails
# immediately with "no matching resources found" before OLM creates the CSV.
# Stages are checked newest-first, so a finished (or garbage-collected)
# InstallPlan can never hold the loop back once the CSV/operands are done.
echo "[INFO] Waiting for cert-manager (timeout ${INSTALL_TIMEOUT}s)..."
start=${SECONDS}
last_line=""
while true; do
    elapsed=$(( SECONDS - start ))

    csv_name="$(_get subscriptions.operators.coreos.com "${SUB_NAME}" -n "${OP_NS}" -o jsonpath='{.status.installedCSV}')"
    [[ -z "${csv_name}" ]] && csv_name="$(_get subscriptions.operators.coreos.com "${SUB_NAME}" -n "${OP_NS}" -o jsonpath='{.status.currentCSV}')"
    csv_phase=""
    [[ -n "${csv_name}" ]] && csv_phase="$(_get clusterserviceversions.operators.coreos.com "${csv_name}" -n "${OP_NS}" -o jsonpath='{.status.phase}')"

    if [[ "${csv_phase}" == "Succeeded" ]]; then
        read existing available <<<"$(_cm_counts)"
        if (( existing < ${#CM_COMPONENTS} )); then
            stage=5; detail="${existing}/${#CM_COMPONENTS} components created"
        elif (( available < ${#CM_COMPONENTS} )); then
            stage=6; detail="${available}/${#CM_COMPONENTS} components available"
        else
            printf '\r\033[K[%s] %d/%d done (%ds)\n' "${(l:TOTAL_STAGES::#:)_empty}" "${TOTAL_STAGES}" "${TOTAL_STAGES}" "${elapsed}"
            break
        fi
    elif [[ "${csv_phase}" == "Failed" ]]; then
        echo "\n[ERROR] CSV ${csv_name} failed: $(_get clusterserviceversions.operators.coreos.com "${csv_name}" -n "${OP_NS}" -o jsonpath='{.status.message}')"
        exit 1
    elif [[ "${csv_phase}" == "Installing" ]]; then
        stage=4
        detail="CSV Installing: $(_get clusterserviceversions.operators.coreos.com "${csv_name}" -n "${OP_NS}" -o jsonpath='{.status.message}')"
    elif [[ -n "${csv_phase}" ]]; then
        stage=3; detail="CSV ${csv_name}: ${csv_phase}"
    else
        ip_name="$(_get subscriptions.operators.coreos.com "${SUB_NAME}" -n "${OP_NS}" -o jsonpath='{.status.installPlanRef.name}')"
        ip_phase=""
        [[ -n "${ip_name}" ]] && ip_phase="$(_get installplans.operators.coreos.com "${ip_name}" -n "${OP_NS}" -o jsonpath='{.status.phase}')"
        if [[ "${ip_phase}" == "Failed" ]]; then
            echo "\n[ERROR] InstallPlan ${ip_name} failed:"
            _get installplans.operators.coreos.com "${ip_name}" -n "${OP_NS}" -o jsonpath='{.status.conditions}'; echo
            exit 1
        elif [[ "${ip_phase}" == "Complete" ]]; then
            stage=3; detail="CSV ${csv_name:-<pending>}: not created yet"
        elif [[ -n "${ip_phase}" ]]; then
            stage=2; detail="InstallPlan ${ip_name}: ${ip_phase}"
        else
            stage=1; detail="waiting for OLM"
        fi
    fi

    bar="${(l:stage-1::#:)_empty}${(l:TOTAL_STAGES-stage+1::-:)_empty}"
    line="$(printf '[%s] %d/%d %s - %s' "${bar}" "${stage}" "${TOTAL_STAGES}" "${STAGE_NAMES[stage]}" "${detail}")"
    if [[ -t 1 ]]; then
        printf '\r\033[K%s (%ds)' "${line}" "${elapsed}"
    elif [[ "${line}" != "${last_line}" ]]; then
        echo "${line} (${elapsed}s)"
    fi
    last_line="${line}"

    if (( elapsed >= INSTALL_TIMEOUT )); then
        echo "\n[ERROR] cert-manager install stuck at stage ${stage}/${TOTAL_STAGES} (${STAGE_NAMES[stage]}) after ${INSTALL_TIMEOUT}s."
        _get subscriptions.operators.coreos.com "${SUB_NAME}" -n "${OP_NS}" -o jsonpath='{.status.conditions}'; echo
        exit 1
    fi
    sleep "${POLL}"
done

echo "[INFO] cert-manager Operator for Red Hat OpenShift installed successfully."
