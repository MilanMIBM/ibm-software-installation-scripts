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

# Everything below uses the local oc client only, so OC_LOGIN (CPDM_OC_LOGIN
# would also log in the cpd-cli container).
eval "${OC_LOGIN}"

# ---------------------------------------------------------------------------
# Block itz-deployer from being recreated.
#
# On TechZone clusters the deployer is pushed by the TechZone hub ArgoCD, not by
# anything running on this cluster: it reaches the API through the ACM
# cluster-proxy addon, impersonating
#   system:serviceaccount:open-cluster-management-agent-addon:application-manager
# (field manager "argocd-controller"; there is no local Application CR to
# suspend). With self-heal on, it recreates the CatalogSource, Subscription and
# the techzone Installation CR within a second of them being deleted, and OLM
# then reinstalls the operator, which recreates the console banner.
#
# Do not remove that service account or its RBAC: the same path manages the
# TechZone compliance agents (uptycs). Instead, deny CREATE of the itz-deployer
# objects for every user with a ValidatingAdmissionPolicy (GA on OCP 4.15+).
#
# Only CREATE is denied, so the delete script can still strip finalizers from
# objects that already exist. Run this BEFORE x_force_delete_itzdeployer.sh
# (that script calls it first).
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
        apiVersions: ["*"]
        resources: ["catalogsources", "subscriptions"]
        operations: ["CREATE"]
      # Installation (and older Deployment) CRs that drive cloud-pak-deployer
      - apiGroups: ["techzone.techzone.ibm.com"]
        apiVersions: ["*"]
        resources: ["*"]
        operations: ["CREATE"]
  validations:
    - expression: >
        request.resource.group != "techzone.techzone.ibm.com" &&
        !((has(object.metadata.name) && object.metadata.name.contains("itz-deployer")) ||
          (has(object.spec) && (
            (has(object.spec.name) && object.spec.name.contains("itz-deployer")) ||
            (has(object.spec.image) && object.spec.image.contains("itz-deployer")) ||
            (has(object.spec.displayName) && object.spec.displayName.lowerAscii().contains("technology zone deployer")))))
      message: "itz-deployer (IBM Technology Zone Deployer) is blocked on this cluster"
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

# Server-side dry-run: an itz-deployer Subscription must be denied, an unrelated
# one must still be allowed. The binding can take a few seconds to take effect.
# Returns 0 when the dry-run create is denied by this policy. (Output is captured
# first: piping into grep -q would SIGPIPE oc and fail the pipe under pipefail.)
_sub_denied() {
    local out
    out=$(oc create --dry-run=server -o name -f - 2>&1 <<EOF || true
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: $1
  namespace: openshift-operators
spec:
  name: $1
  source: does-not-exist
  sourceNamespace: openshift-marketplace
EOF
)
    [[ "${out}" == *"is blocked on this cluster"* ]]
}
BLOCKED=false
for _i in 1 2 3 4 5 6; do
    if _sub_denied itz-deployer-operator; then
        BLOCKED=true
        break
    fi
    sleep 5
done
if [[ "${BLOCKED}" != "true" ]]; then
    echo "[ERROR] Dry-run create of an itz-deployer Subscription was not denied." >&2
    exit 1
fi
echo "[OK] itz-deployer Subscription create is denied."
if _sub_denied admission-policy-selftest; then
    echo "[ERROR] An unrelated Subscription is denied too - removing the policy binding." >&2
    oc delete validatingadmissionpolicybinding "${BINDING_NAME}" --ignore-not-found
    exit 1
fi
echo "[OK] Unrelated Subscriptions are still allowed."

echo ""
echo "[DONE] itz-deployer reinstall is now blocked."
echo "[INFO] TechZone's ArgoCD will report sync errors for these objects from now on; that is expected."
echo "[INFO] To remove the block: oc delete validatingadmissionpolicybinding ${BINDING_NAME} && oc delete validatingadmissionpolicy ${POLICY_NAME}"
