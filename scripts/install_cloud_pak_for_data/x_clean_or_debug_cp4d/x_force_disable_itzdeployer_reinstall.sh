#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# Re-exec under zsh if running under a different shell (e.g. bash)
if [ -z "${ZSH_VERSION:-}" ]; then exec /bin/zsh "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# (legacy hardcoded sourcing - replaced by universal crawl below)
# source "${SCRIPT_DIR}/../source_env_setup.sh"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

eval "${CPDM_OC_LOGIN}"

# ---------------------------------------------------------------------------
# Block itz-deployer from being reinstalled via OLM (CatalogSource/Subscription)
# Uses ValidatingAdmissionPolicy (GA on OCP 4.15+) - no backing service needed.
# Covers both ArgoCD re-syncs and manual oc apply.
# ---------------------------------------------------------------------------

POLICY_NAME="block-itz-deployer"
BINDING_NAME="block-itz-deployer-binding"

echo ""
echo "=== Applying ValidatingAdmissionPolicy: ${POLICY_NAME} ==="

oc apply -f - <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: block-itz-deployer
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: ["operators.coreos.com"]
        apiVersions: ["v1alpha1"]
        resources: ["catalogsources", "subscriptions"]
        operations: ["CREATE", "UPDATE"]
  validations:
    - expression: >
        !(object.metadata.name.contains("itz-deployer") ||
          (has(object.spec.name) && object.spec.name.contains("itz-deployer")))
      message: "itz-deployer operator is blocked on this cluster"
EOF

echo ""
echo "=== Applying ValidatingAdmissionPolicyBinding: ${BINDING_NAME} ==="

oc apply -f - <<'EOF'
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: block-itz-deployer-binding
spec:
  policyName: block-itz-deployer
  validationActions: [Deny]
EOF

echo ""
echo "=== Verifying ==="
oc get validatingadmissionpolicy "${POLICY_NAME}"
oc get validatingadmissionpolicybinding "${BINDING_NAME}"

echo ""
echo "[DONE] itz-deployer reinstall is now blocked."
echo "[INFO] To remove the block: oc delete validatingadmissionpolicybinding ${BINDING_NAME} && oc delete validatingadmissionpolicy ${POLICY_NAME}"
