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
  2. copies the pull secret (MC_PULL_SECRET_NAME) from MC_NAMESPACE. The
     operator references it on database pods, but with the OpenShift values it
     does not copy it into projects itself.
Safe to re-run.

  3.1_prepare_mc_projects.sh                 every existing project namespace
  3.1_prepare_mc_projects.sh SLUG ...        just these projects
  3.1_prepare_mc_projects.sh --create SLUG [--name "Display name"]
                                             also create the project (namespace
                                             labelled as a Mission Control
                                             project; it then shows in the UI)
  3.1_prepare_mc_projects.sh --remove SLUG   undo 1 and 2 for a project

Typical UI flow: create the project in the UI, run this script, then create
the database cluster in that project.
EOF
}

CREATE=""
DISPLAY_NAME=""
REMOVE=false
PROJECTS=()
while (( $# )); do
    case "$1" in
        --create)  CREATE="${2:?--create needs a project slug}"; shift 2 ;;
        --name)    DISPLAY_NAME="${2:?--name needs a value}"; shift 2 ;;
        --remove)  REMOVE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        -*)        mc_die "Unknown option: $1" ;;
        *)         PROJECTS+=("$1"); shift ;;
    esac
done

eval "${OC_LOGIN}"

BINDING="mission-control-db-nonroot-v2"
PROJECT_LABEL="mission-control.datastax.com/is-project"

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
        mc_info "No Mission Control projects yet. Create one in the UI (Projects -> New Project)"
        mc_info "or with --create SLUG, then run this script again."
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
