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

# --- Pull secret options
SET_DEFAULT_PULL_SECRET="${SET_DEFAULT_PULL_SECRET:-true}"
OVERWRITE_CURRENT_SECRET="${OVERWRITE_CURRENT_SECRET:-true}"
PULL_SECRET_NAME="${PULL_SECRET_NAME:-pull-secret}"
PULL_SECRET_NAMESPACE="${PULL_SECRET_NAMESPACE:-openshift-config}"

# --- Create projects in the cluster
eval "${OC_LOGIN}"

create_project_if_not_exists() {
    local ns="$1"
    if oc get project "${ns}" &>/dev/null; then
        local phase
        phase=$(oc get project "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [[ "${phase}" == "Terminating" ]]; then
            echo "[INFO] Project '${ns}' is terminating - force-deleting and recreating."
            # Strip finalizers from all resources inside the namespace that may be blocking termination
            for resource in $(oc api-resources --verbs=list --namespaced -o name 2>/dev/null); do
                oc get "${resource}" -n "${ns}" -o name 2>/dev/null \
                    | xargs -r -I{} oc patch {} -n "${ns}" \
                        -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
            done
            # Remove finalizers from the namespace itself
            oc patch namespace "${ns}" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
            oc delete project "${ns}" --ignore-not-found --wait=false 2>/dev/null || true
            echo "[INFO] Waiting for project '${ns}' to fully terminate..."
            local timeout=30
            local elapsed=0
            while oc get project "${ns}" &>/dev/null && (( elapsed < timeout )); do
                sleep 5
                (( elapsed += 5 ))
            done
            if oc get project "${ns}" &>/dev/null; then
                echo "[ERROR] Project '${ns}' still exists after ${timeout}s - giving up."
                return 1
            fi
            echo "[INFO] Project '${ns}' terminated. Recreating..."
            oc new-project "${ns}"
        else
            echo "[INFO] Project '${ns}' already exists, skipping."
        fi
    else
        oc new-project "${ns}"
    fi
}

set_default_pull_secret() {
    local ns="$1"
    [[ "${SET_DEFAULT_PULL_SECRET}" == "true" ]] || return 0

    local existing
    existing=$(oc get serviceaccount default -n "${ns}" -o jsonpath='{.imagePullSecrets[*].name}' 2>/dev/null || true)

    if echo "${existing}" | grep -qw "${PULL_SECRET_NAME}"; then
        if [[ "${OVERWRITE_CURRENT_SECRET}" != "true" ]]; then
            echo "[INFO] Project '${ns}' already has pull secret '${PULL_SECRET_NAME}' as default, skipping (set OVERWRITE_CURRENT_SECRET=true to overwrite)."
            return 0
        fi
        echo "[INFO] Pull secret '${PULL_SECRET_NAME}' already set on '${ns}', overwriting as requested."
    fi

    if ! oc get secret "${PULL_SECRET_NAME}" -n "${PULL_SECRET_NAMESPACE}" &>/dev/null; then
        echo "[ERROR] Source secret '${PULL_SECRET_NAME}' not found in namespace '${PULL_SECRET_NAMESPACE}', skipping project '${ns}'."
        return 1
    fi

    oc get secret "${PULL_SECRET_NAME}" -n "${PULL_SECRET_NAMESPACE}" -o json \
        | jq 'del(.metadata.namespace, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.annotations, .metadata.ownerReferences)' \
        | oc apply -n "${ns}" -f -

    oc secrets link default "${PULL_SECRET_NAME}" --for=pull -n "${ns}"
    echo "[INFO] Default pull secret '${PULL_SECRET_NAME}' set on project '${ns}'."
}

setup_project() {
    local ns="$1"
    [[ -n "${ns}" ]] || return 0
    create_project_if_not_exists "${ns}"
    set_default_pull_secret "${ns}"
}

setup_project "${PROJECT_LICENSE_SERVICE:-}"
setup_project "${PROJECT_SCHEDULING_SERVICE:-}"

setup_project "${PROJECT_IBM_EVENTS:-}"
setup_project "${PROJECT_PRIVILEGED_MONITORING_SERVICE:-}"

setup_project "${PROJECT_CPD_INST_OPERATORS:-}"
setup_project "${PROJECT_CPD_INST_OPERANDS:-}"

# --- Additional non-standard projects
# Add any extra namespaces here that are not covered by the standard CPD variables above.
# Example:
#   setup_project "my-custom-namespace"
#   setup_project "another-project"

# setup_project "cpd"
