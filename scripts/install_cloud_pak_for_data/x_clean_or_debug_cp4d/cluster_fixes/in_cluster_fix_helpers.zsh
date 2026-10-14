# Shared helpers for installing the cluster_fixes/*.py scripts as in-cluster
# automation (watcher Deployments / CronJobs). Sourced by the x_fix_* scripts.
#
# Everything lives in one namespace (CLUSTER_FIXES_NS, default cpd-cluster-fixes)
# with its own ServiceAccount per fix; access to the target namespaces is granted
# through namespaced Roles only. Remove everything with:
#   oc delete ns cpd-cluster-fixes
#   oc delete role,rolebinding -l cluster-fixes.ibm-install-scripts/fix -A

CLUSTER_FIXES_NS="${CLUSTER_FIXES_NS:-cpd-cluster-fixes}"
CLUSTER_FIXES_LABEL="cluster-fixes.ibm-install-scripts/fix"

# openshift/cli ships oc + python3 and is already in the internal registry.
cluster_fix_image() {
    local repo
    repo=$(oc -n openshift get imagestream cli -o jsonpath='{.status.dockerImageRepository}' 2>/dev/null || true)
    echo "${repo:-image-registry.openshift-image-registry.svc:5000/openshift/cli}:latest"
}

# Usage: cluster_fix_base <fix-name> <python-file>
# Creates the namespace, the fix's ServiceAccount and a ConfigMap holding the script.
cluster_fix_base() {
    local fix="$1" pyfile="$2"
    oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${CLUSTER_FIXES_NS}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${fix}
  namespace: ${CLUSTER_FIXES_NS}
  labels: {${CLUSTER_FIXES_LABEL}: ${fix}}
EOF
    oc -n "${CLUSTER_FIXES_NS}" create configmap "${fix}-script" \
        --from-file="$(basename "${pyfile}")=${pyfile}" --dry-run=client -o yaml \
        | oc label --local -f - "${CLUSTER_FIXES_LABEL}=${fix}" -o yaml \
        | oc apply -f -
}

# Usage: cluster_fix_role <fix-name> <target-namespace> <rules-yaml>
# <rules-yaml> is the indented body of a Role's `rules:` list.
cluster_fix_role() {
    local fix="$1" ns="$2" rules="$3"
    oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${fix}
  namespace: ${ns}
  labels: {${CLUSTER_FIXES_LABEL}: ${fix}}
rules:
${rules}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${fix}
  namespace: ${ns}
  labels: {${CLUSTER_FIXES_LABEL}: ${fix}}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${fix}
subjects:
  - kind: ServiceAccount
    name: ${fix}
    namespace: ${CLUSTER_FIXES_NS}
EOF
}

# Usage: cluster_fix_pod_spec <indent> <fix-name> <python-file> <args...>
# Prints a pod spec indented by <indent> spaces (6 under a Deployment template,
# 10 under a CronJob) that runs the script from its ConfigMap as the fix's
# ServiceAccount.
cluster_fix_pod_spec() {
    local pad="${(l:$1:: :)}" fix="$2" pyfile="$3"; shift 3
    local arg args_yaml=""
    for arg in "$@"; do args_yaml+="  - \"${arg}\""$'\n'; done
    sed "s/^/${pad}/" <<EOF
serviceAccountName: ${fix}
restartPolicy: ${CLUSTER_FIX_RESTART_POLICY:-Always}
containers:
- name: fix
  image: $(cluster_fix_image)
  env:
  - {name: HOME, value: /tmp}
  command: ["python3", "-I", "/fix/$(basename "${pyfile}")"]
  args:
${args_yaml%$'\n'}
  volumeMounts:
  - {name: script, mountPath: /fix, readOnly: true}
  resources:
    requests: {cpu: 10m, memory: 64Mi}
    limits: {cpu: 200m, memory: 256Mi}
  securityContext:
    allowPrivilegeEscalation: false
    runAsNonRoot: true
    capabilities: {drop: ["ALL"]}
    seccompProfile: {type: RuntimeDefault}
volumes:
- name: script
  configMap: {name: ${fix}-script}
EOF
}
