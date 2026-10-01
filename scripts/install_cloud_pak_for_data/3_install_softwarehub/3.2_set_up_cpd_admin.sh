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
_SPARK_COMPONENTS=(analyticsengine dp dataproduct wkc ikc_premium ikc_standard datalineage watsonx_bi_assistant watsonx_data watsonx_data_premium watsonx_dataintelligence)
ENABLE_SPARK_AUTOSCALING=false
for _c in "${_SPARK_COMPONENTS[@]}"; do
    if [[ ",${CPD_COMPONENTS}," == *",${_c},"* ]]; then
        ENABLE_SPARK_AUTOSCALING=true
        break
    fi
done
unset _c _SPARK_COMPONENTS
# ---

eval "${CPDM_OC_LOGIN}"

# Create the user if they don't already exist
if ! oc get user "${CPD_ADMIN_USERNAME}" &>/dev/null; then
    oc create user "${CPD_ADMIN_USERNAME}"
fi

oc adm policy add-role-to-user admin ${CPD_ADMIN_USERNAME} \
    --namespace=${PROJECT_CPD_INST_OPERATORS} \
    --rolebinding-name="cpd-instance-admin-rbac"

oc adm policy add-role-to-user admin ${CPD_ADMIN_USERNAME} \
    --namespace=${PROJECT_CPD_INST_OPERANDS} \
    --rolebinding-name="cpd-instance-admin-rbac"

if [[ -n "${PROJECT_CPD_INSTANCE_TETHERED:-}" ]]; then
    oc adm policy add-role-to-user admin ${CPD_ADMIN_USERNAME} \
        --namespace=${PROJECT_CPD_INSTANCE_TETHERED} \
        --rolebinding-name="cpd-instance-admin-rbac"
fi

oc apply -f - << EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: cpd-instance-admin-apply-olm
  namespace: ${PROJECT_CPD_INST_OPERATORS}
rules:
- apiGroups:
  - operators.coreos.com
  resources:
  - catalogsources
  - operatorgroups
  - subscriptions
  - clusterserviceversions
  - installplans
  verbs:
  - create
  - update
  - patch
  - get
  - list
EOF

oc adm policy add-role-to-user cpd-instance-admin-apply-olm ${CPD_ADMIN_USERNAME} \
    --namespace=${PROJECT_CPD_INST_OPERATORS} \
    --role-namespace=${PROJECT_CPD_INST_OPERATORS} \
    --rolebinding-name="cpd-instance-admin-apply-olm-rbac"

# --- Enable Spark auto-scaling: pre-pull images to cluster nodes
if [[ "${ENABLE_SPARK_AUTOSCALING}" == "true" ]]; then

oc apply -f - << EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: prepull-operator
rules:
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list", "watch", "update"]
EOF

oc apply -f - << EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: prepull-operator
  namespace: ${PROJECT_CPD_INST_OPERANDS}
subjects:
  - kind: ServiceAccount
    name: spark-hb-prepull-operator
    namespace: ${PROJECT_CPD_INST_OPERANDS}
  - kind: ServiceAccount
    name: spark-hb-imageprepull-controller
    namespace: ${PROJECT_CPD_INST_OPERANDS}
roleRef:
  kind: ClusterRole
  name: prepull-operator
  apiGroup: rbac.authorization.k8s.io
EOF

fi
