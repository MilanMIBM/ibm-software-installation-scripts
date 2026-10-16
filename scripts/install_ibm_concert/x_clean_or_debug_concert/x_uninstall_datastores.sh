#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: only configs/concert_config/concert_vars.sh is in scope ---
export ENV_TARGET="${ENV_TARGET:-concert}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/concert_helpers.sh"
concert_require_config

# ==============================================================================
# DESTROY the provisioned data stores (all Concert data)
# ------------------------------------------------------------------------------
# Deletes what 2.3.x created in PROJECT_CONCERT_DATASTORES: the PostgreSQL
# cluster, MySQL/Redis/Neo4j StatefulSets with their PVCs, the bucket claims
# (the NooBaa class deletes the buckets and their objects), the generated
# credentials, and then the namespace. Uninstall the products first
# (x_uninstall_concert.sh) - they cannot run without their stores.
# Operators (CloudNativePG, ODF/MCG) stay; --operators removes the CloudNativePG
# Subscription too (ODF is left: other workloads may use it).
#   ./x_uninstall_datastores.sh [--operators] [--yes]
# ==============================================================================

OPERATORS=false
YES=false
for _arg in "$@"; do
    case "${_arg}" in
        --operators) OPERATORS=true ;;
        --yes|-y)    YES=true ;;
        *) concert_die "Unknown argument: ${_arg}" ;;
    esac
done

eval "${OC_LOGIN}"
NS="${PROJECT_CONCERT_DATASTORES}"
oc get namespace "${NS}" >/dev/null 2>&1 || { concert_info "${NS} does not exist - nothing to do."; exit 0; }

for p in $(concert_product_namespaces); do
    if [[ -n "$(oc get deployments,statefulsets -n "${p}" --no-headers 2>/dev/null | head -1)" ]]; then
        concert_warn "${p} still has workloads - uninstall the products first or they lose their data stores."
    fi
done

concert_warn "This permanently deletes ALL data in ${NS} on $(oc whoami --show-server): databases, buckets, graph, cache."
if ! ${YES}; then
    read -r "reply?Type the namespace name (${NS}) to continue: "
    [[ "${reply}" == "${NS}" ]] || concert_die "Aborted."
fi

oc delete cluster.postgresql.cnpg.io --all -n "${NS}" --ignore-not-found 2>/dev/null || true
oc delete statefulset concert-mysql concert-redis concert-neo4j -n "${NS}" --ignore-not-found
oc delete objectbucketclaim --all -n "${NS}" --ignore-not-found 2>/dev/null || true
oc delete pvc --all -n "${NS}" --ignore-not-found
oc delete namespace "${NS}" --ignore-not-found --wait=false

if ${OPERATORS}; then
    csv="$(oc get subscriptions.operators.coreos.com cloudnative-pg -n openshift-operators -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
    oc delete subscriptions.operators.coreos.com cloudnative-pg -n openshift-operators --ignore-not-found
    [[ -n "${csv}" ]] && oc delete clusterserviceversion "${csv}" -n openshift-operators --ignore-not-found
fi
concert_info "Data stores removed."
