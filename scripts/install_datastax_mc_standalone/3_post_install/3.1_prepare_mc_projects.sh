#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: only configs/datastax_mc_config/datastax_mc_vars.sh is in scope ---
export ENV_TARGET="${ENV_TARGET:-datastax_mc}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/datastax_mc_helpers.sh"
mc_require_config

usage() {
    cat <<'EOF'
Prepare Mission Control project namespaces so the database clusters created in
them (from the UI or as MissionControlCluster YAML) can start on OpenShift.

Mission Control's operators cannot grant SCCs, and HCD/DSE/Cassandra pods run
with a fixed UID/GID 999, which OpenShift's default restricted-v2 SCC rejects.
For each project namespace this script:
  1. binds nonroot-v2 to every service account in it (a RoleBinding to the
     group system:serviceaccounts:<project>), which covers the database, cqlsh,
     Data API, Reaper and Medusa pods whichever account they use. It lives in
     the namespace, so deleting the project removes it too.
  2. copies the pull secret (MC_PULL_SECRET_NAME) from MC_NAMESPACE, in case
     the operator has not copied it into the project yet.
Safe to re-run.

  3.1_prepare_mc_projects.sh                 every existing project namespace
  3.1_prepare_mc_projects.sh SLUG ...        just these projects
  3.1_prepare_mc_projects.sh --create SLUG [--name "Display name"]
                                             also create the project (namespace
                                             labelled as a Mission Control
                                             project; it then shows in the UI)
  3.1_prepare_mc_projects.sh --remove SLUG   undo 1 and 2 for a project

  --auto         also install (or refresh) the auto-prepare reconciler: a small
                 Deployment in MC_NAMESPACE that applies 1 and 2 to every
                 project as soon as it appears - created in the UI or with
                 --create - so no manual run is needed. It uses the cluster's
                 own oc image (imagestream openshift/cli, part of the OpenShift
                 release, so also mirrored on air-gapped clusters). Re-run
                 --auto after an OpenShift upgrade to move it to the new image.
  --remove-auto  remove the reconciler (projects keep their preparation)

The full install runs: 3.1 --auto --create MC_BASE_PROJECT (see datastax_mc_vars.sh).
EOF
}

CREATE=""
DISPLAY_NAME=""
REMOVE=false
AUTO=false
REMOVE_AUTO=false
PROJECTS=()
while (( $# )); do
    case "$1" in
        --create)      CREATE="${2:?--create needs a project slug}"; shift 2 ;;
        --name)        DISPLAY_NAME="${2:?--name needs a value}"; shift 2 ;;
        --remove)      REMOVE=true; shift ;;
        --auto)        AUTO=true; shift ;;
        --remove-auto) REMOVE_AUTO=true; shift ;;
        -h|--help)     usage; exit 0 ;;
        -*)            mc_die "Unknown option: $1" ;;
        *)             PROJECTS+=("$1"); shift ;;
    esac
done

eval "${OC_LOGIN}"

BINDING="mission-control-db-nonroot-v2"
PROJECT_LABEL="mission-control.datastax.com/is-project"
# Auto-prepare reconciler: namespaced objects in MC_NAMESPACE, plus a
# ClusterRole/ClusterRoleBinding (cluster-scoped, so prefixed with the namespace).
AUTO_NAME="${MC_RELEASE_NAME}-project-prep"
AUTO_CLUSTER_NAME="${MC_NAMESPACE}-${AUTO_NAME}"

# --- Auto-prepare reconciler -------------------------------------------------------
remove_auto() {
    oc delete deployment,configmap,serviceaccount "${AUTO_NAME}" -n "${MC_NAMESPACE}" --ignore-not-found >/dev/null
    oc delete clusterrolebinding,clusterrole "${AUTO_CLUSTER_NAME}" --ignore-not-found >/dev/null
    mc_info "Auto-prepare reconciler removed (prepared projects keep their SCC binding and pull secret)."
}

# Runs in the reconciler pod (bash + oc; the cli image has no jq).
reconcile_script() {
    cat <<'EOF'
#!/bin/bash
# Rendered by 3.1_prepare_mc_projects.sh --auto - do not edit, re-run 3.1 --auto.
# Gives every Mission Control project the same preparation as a manual 3.1 run:
# nonroot-v2 for its service accounts, and a copy of the pull secret.
set -uo pipefail

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

bind_scc() {
    oc apply -f - >/dev/null <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${BINDING}
  namespace: $1
  labels:
    app.kubernetes.io/managed-by: datastax-mc-scripts
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:openshift:scc:nonroot-v2
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: system:serviceaccounts:$1
YAML
}

copy_secret() {
    oc apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
type: kubernetes.io/dockerconfigjson
metadata:
  name: ${PULL_SECRET}
  namespace: $1
  labels:
    app.kubernetes.io/managed-by: datastax-mc-scripts
data:
  .dockerconfigjson: $2
YAML
}

secret_data() {
    oc get secret "${PULL_SECRET}" -n "$1" -o go-template='{{index .data ".dockerconfigjson"}}' 2>/dev/null || true
}

log "Preparing namespaces labelled ${PROJECT_LABEL}=true (every ${INTERVAL}s)"
warned_source=false
while true; do
    source_data="$(secret_data "${SOURCE_NS}")"
    if [[ -z "${source_data}" ]] && ! ${warned_source}; then
        log "WARN ${SOURCE_NS}/${PULL_SECRET} not found - projects rely on the global pull secret"
        warned_source=true
    fi
    [[ -n "${source_data}" ]] && warned_source=false
    for ns in $(oc get namespaces -l "${PROJECT_LABEL}=true" \
                  -o go-template='{{range .items}}{{if not .metadata.deletionTimestamp}}{{.metadata.name}} {{end}}{{end}}' 2>/dev/null); do
        if ! oc get rolebinding "${BINDING}" -n "${ns}" >/dev/null 2>&1; then
            if bind_scc "${ns}"; then log "${ns}: nonroot-v2 bound to its service accounts"
            else log "${ns}: binding nonroot-v2 FAILED - retrying next round"; fi
        fi
        if [[ -n "${source_data}" && "$(secret_data "${ns}")" != "${source_data}" ]]; then
            if copy_secret "${ns}" "${source_data}"; then log "${ns}: pull secret ${PULL_SECRET} copied"
            else log "${ns}: copying pull secret FAILED - retrying next round"; fi
        fi
    done
    sleep "${INTERVAL}"
done
EOF
}

install_auto() {
    local image
    image="${MC_PROJECT_PREP_IMAGE:-$(oc get istag cli:latest -n openshift -o jsonpath='{.image.dockerImageReference}' 2>/dev/null || true)}"
    [[ -n "${image}" ]] \
        || mc_die "Imagestream tag openshift/cli:latest not found - set MC_PROJECT_PREP_IMAGE to an image with bash and oc."
    local script checksum
    script="$(reconcile_script)"
    checksum="$(print -r -- "${script}${image}" | shasum -a 256 | cut -c1-16)"

    {
        cat <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${AUTO_NAME}
  namespace: ${MC_NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: datastax-mc-scripts
---
# Least privilege: list namespaces, and create/update only the one RoleBinding
# and pull secret name, binding only nonroot-v2.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${AUTO_CLUSTER_NAME}
  labels:
    app.kubernetes.io/managed-by: datastax-mc-scripts
rules:
  - apiGroups: [""]
    resources: [namespaces]
    verbs: [get, list, watch]
  - apiGroups: [rbac.authorization.k8s.io]
    resources: [rolebindings]
    verbs: [create]
  - apiGroups: [rbac.authorization.k8s.io]
    resources: [rolebindings]
    resourceNames: [${BINDING}]
    verbs: [get, update, patch]
  - apiGroups: [rbac.authorization.k8s.io]
    resources: [clusterroles]
    resourceNames: ["system:openshift:scc:nonroot-v2"]
    verbs: [bind]
  - apiGroups: [""]
    resources: [secrets]
    verbs: [create]
  - apiGroups: [""]
    resources: [secrets]
    resourceNames: [${MC_PULL_SECRET_NAME}]
    verbs: [get, update, patch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${AUTO_CLUSTER_NAME}
  labels:
    app.kubernetes.io/managed-by: datastax-mc-scripts
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${AUTO_CLUSTER_NAME}
subjects:
  - kind: ServiceAccount
    name: ${AUTO_NAME}
    namespace: ${MC_NAMESPACE}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${AUTO_NAME}
  namespace: ${MC_NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: datastax-mc-scripts
data:
  reconcile.sh: |
EOF
        print -r -- "${script}" | sed 's/^/    /'
        cat <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${AUTO_NAME}
  namespace: ${MC_NAMESPACE}
  labels:
    app.kubernetes.io/name: ${AUTO_NAME}
    app.kubernetes.io/managed-by: datastax-mc-scripts
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: ${AUTO_NAME}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${AUTO_NAME}
      annotations:
        datastax-mc-scripts/checksum: "${checksum}"
    spec:
      serviceAccountName: ${AUTO_NAME}
      nodeSelector:
        mission-control.datastax.com/role: platform
      containers:
        - name: reconciler
          image: ${image}
          command: [/bin/bash, /scripts/reconcile.sh]
          env:
            - { name: PROJECT_LABEL, value: "${PROJECT_LABEL}" }
            - { name: BINDING,       value: "${BINDING}" }
            - { name: PULL_SECRET,   value: "${MC_PULL_SECRET_NAME}" }
            - { name: SOURCE_NS,     value: "${MC_NAMESPACE}" }
            - { name: INTERVAL,      value: "10" }
            - { name: HOME,          value: /tmp }
          resources:
            requests: { cpu: 10m, memory: 64Mi }
            limits: { memory: 256Mi }
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            capabilities: { drop: [ALL] }
            seccompProfile: { type: RuntimeDefault }
          volumeMounts:
            - { name: scripts, mountPath: /scripts, readOnly: true }
      volumes:
        - name: scripts
          configMap:
            name: ${AUTO_NAME}
EOF
    } | oc apply -f - >/dev/null

    if oc rollout status deployment "${AUTO_NAME}" -n "${MC_NAMESPACE}" --timeout=180s >/dev/null 2>&1; then
        mc_info "Auto-prepare reconciler running (${MC_NAMESPACE}/${AUTO_NAME}): new projects are prepared within ~10s."
        mc_info "  Log: oc logs -n ${MC_NAMESPACE} deploy/${AUTO_NAME}"
    else
        mc_warn "Auto-prepare reconciler not ready after 3m - check: oc get pods -n ${MC_NAMESPACE} -l app.kubernetes.io/name=${AUTO_NAME}"
    fi
}

if ${REMOVE_AUTO}; then
    remove_auto
    (( ${#PROJECTS} )) || [[ -n "${CREATE}" ]] || exit 0
fi
${AUTO} && install_auto

# --- Optional: create the project namespace ---------------------------------
if [[ -n "${CREATE}" ]]; then
    [[ "${CREATE}" =~ '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$' ]] \
        || mc_die "Project slug '${CREATE}' is not a valid namespace name (lowercase letters, digits, '-')."
    if oc get namespace "${CREATE}" >/dev/null 2>&1; then
        [[ "$(oc get namespace "${CREATE}" -o jsonpath="{.metadata.labels.${PROJECT_LABEL//./\\.}}")" == true ]] \
            || mc_die "Namespace ${CREATE} exists but is not a Mission Control project - not touching it."
        mc_info "Project ${CREATE} already exists."
    else
        oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${CREATE}
  labels:
    ${PROJECT_LABEL}: "true"
  annotations:
    mission-control.datastax.com/project-name: $(mc_yaml_str "${DISPLAY_NAME:-${CREATE}}")
EOF
        mc_info "Created project ${CREATE} (${DISPLAY_NAME:-${CREATE}})."
    fi
    PROJECTS+=("${CREATE}")
fi

# --- Which projects ----------------------------------------------------------------
if (( ${#PROJECTS} == 0 )); then
    ${REMOVE} && mc_die "--remove needs the project slug(s) to clean up."
    PROJECTS=("${(@f)$(oc get namespaces -l "${PROJECT_LABEL}=true" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')}")
    PROJECTS=(${PROJECTS:#})
    if (( ${#PROJECTS} == 0 )); then
        if ${AUTO}; then
            mc_info "No Mission Control projects yet - the reconciler prepares them as they are created."
        else
            mc_info "No Mission Control projects yet. Create one in the UI (Projects -> New Project)"
            mc_info "or with --create SLUG, then run this script again (or install the reconciler with --auto)."
        fi
        exit 0
    fi
fi
PROJECTS=(${(u)PROJECTS})

# --- Prepare / clean up each project ---------------------------------------------
for ns in "${PROJECTS[@]}"; do
    if ! oc get namespace "${ns}" >/dev/null 2>&1; then
        mc_warn "${ns}: namespace not found - skipped."
        continue
    fi
    if ${REMOVE}; then
        oc delete rolebinding "${BINDING}" -n "${ns}" --ignore-not-found >/dev/null
        oc delete secret "${MC_PULL_SECRET_NAME}" -n "${ns}" --ignore-not-found >/dev/null
        mc_info "${ns}: SCC binding and pull secret removed."
        oc get deployment "${AUTO_NAME}" -n "${MC_NAMESPACE}" >/dev/null 2>&1 \
            && [[ "$(oc get namespace "${ns}" -o jsonpath="{.metadata.labels.${PROJECT_LABEL//./\\.}}")" == true ]] \
            && mc_warn "${ns}: the auto-prepare reconciler will re-add them while ${ns} is a project (3.1 --remove-auto first)."
        continue
    fi
    [[ "$(oc get namespace "${ns}" -o jsonpath="{.metadata.labels.${PROJECT_LABEL//./\\.}}")" == true ]] \
        || mc_warn "${ns}: not labelled as a Mission Control project - preparing it anyway."

    oc apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${BINDING}
  namespace: ${ns}
  labels:
    app.kubernetes.io/managed-by: datastax-mc-scripts
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:openshift:scc:nonroot-v2
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: system:serviceaccounts:${ns}
EOF

    if oc get secret "${MC_PULL_SECRET_NAME}" -n "${MC_NAMESPACE}" >/dev/null 2>&1; then
        oc get secret "${MC_PULL_SECRET_NAME}" -n "${MC_NAMESPACE}" -o json \
            | jq --arg ns "${ns}" '{apiVersion, kind, type, data, metadata: {name: .metadata.name, namespace: $ns, labels: {"app.kubernetes.io/managed-by": "datastax-mc-scripts"}}}' \
            | oc apply -f - >/dev/null
        mc_info "${ns}: nonroot-v2 for its service accounts, pull secret ${MC_PULL_SECRET_NAME} copied."
    else
        mc_warn "${ns}: nonroot-v2 bound, but ${MC_NAMESPACE}/${MC_PULL_SECRET_NAME} is missing (run 1.2) - relying on the global pull secret."
    fi
done

${REMOVE} || mc_info "Ready: create database clusters in ${PROJECTS[*]} (UI -> project -> Create Cluster)."
