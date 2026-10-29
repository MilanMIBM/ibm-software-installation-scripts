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
Uninstall the standalone Mission Control release (DataStax "Uninstall", Helm).

  x_uninstall_mission_control.sh [options]

Always:  helm uninstall, the UI Route, the SCC grants (1.4 --remove), the
         project auto-prepare reconciler (3.1 --remove-auto), the
         certificate secrets cert-manager leaves behind on OpenShift, and the
         pull/object-storage secrets these scripts created.
Options:
  --keep-pvcs          Keep the PersistentVolumeClaims (Loki, Mimir, MinIO,
                       Vector data). Deleted by default.
  --delete-namespace   Also delete MC_NAMESPACE.
  --delete-crds        Also delete CRD clusterconfigs.datastax.com, as DataStax's
                       guide does. Other DataStax/k8ssandra CRDs are left alone:
                       they are cluster-wide and may serve another install (CP4D).
  --unlabel-nodes      Remove mission-control.datastax.com/role=platform from nodes.
  --force              Proceed even though MissionControlCluster resources exist.
  -y, --yes            Do not ask for confirmation.
  -h, --help           Show this help

The cluster-wide pull secret and cert-manager are left in place (shared).
Database clusters are NOT deleted by this script: without --force it refuses
while any MissionControlCluster exists - delete them (and their project
namespaces) first, from the UI or with oc.
EOF
}

KEEP_PVCS=false DELETE_NS=false DELETE_CRDS=false UNLABEL=false FORCE=false YES=false
while (( $# )); do
    case "$1" in
        --keep-pvcs)        KEEP_PVCS=true ;;
        --delete-namespace) DELETE_NS=true ;;
        --delete-crds)      DELETE_CRDS=true ;;
        --unlabel-nodes)    UNLABEL=true ;;
        --force)            FORCE=true ;;
        -y|--yes)           YES=true ;;
        -h|--help)          usage; exit 0 ;;
        *) mc_die "Unknown option: $1" ;;
    esac
    shift
done

eval "${OC_LOGIN}"
mc_ensure_helm
NS="${MC_NAMESPACE}"

# --- Database clusters still around? ------------------------------------------
if oc get crd missioncontrolclusters.missioncontrol.datastax.com >/dev/null 2>&1; then
    clusters="$(oc get missioncontrolclusters.missioncontrol.datastax.com -A --no-headers 2>/dev/null | awk '{print "    " $1 "/" $2}' || true)"
    if [[ -n "${clusters}" ]]; then
        echo "[WARN] MissionControlCluster resources still exist:"
        echo "${clusters}"
        ${FORCE} || mc_die "Delete them first (their data is not backed up by this script), or pass --force."
    fi
fi

echo "[INFO] Cluster:   $(oc whoami --show-server)"
echo "[INFO] Release:   ${MC_RELEASE_NAME} in ${NS}"
echo "[INFO] PVCs:      $(${KEEP_PVCS} && echo kept || echo DELETED)   namespace: $(${DELETE_NS} && echo DELETED || echo kept)   CRD: $(${DELETE_CRDS} && echo DELETED || echo kept)"
if ! ${YES}; then
    read -r "reply?This permanently deletes Mission Control data. Continue? [y/N] "
    [[ "${reply}" == [Yy]* ]] || { echo "[INFO] Aborted, nothing changed."; exit 0; }
fi

# --- Release ----------------------------------------------------------------------
if "${MC_HELM}" status "${MC_RELEASE_NAME}" -n "${NS}" >/dev/null 2>&1; then
    "${MC_HELM}" uninstall "${MC_RELEASE_NAME}" -n "${NS}" --wait --timeout "${MC_HELM_TIMEOUT:-15m}"
else
    mc_info "Release ${MC_RELEASE_NAME} not found in ${NS} - continuing with the cleanup."
fi

oc delete route "${MC_UI_ROUTE_NAME:-${MC_RELEASE_NAME}-ui}" -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true
"${SCRIPT_DIR}/../1_prepare_cluster/1.4_configure_scc.sh" --remove
"${SCRIPT_DIR}/../3_post_install/3.1_prepare_mc_projects.sh" --remove-auto

if oc get namespace "${NS}" >/dev/null 2>&1; then
    # The OpenShift cert-manager operator keeps a Certificate's secret after the
    # Certificate is gone (unless --enable-certificate-owner-ref is set).
    certs=("${(@f)$(oc get secrets -n "${NS}" -o json | jq -r '.items[] | select(.metadata.annotations["cert-manager.io/certificate-name"]) | .metadata.name')}")
    certs=(${certs:#})
    if (( ${#certs} )); then
        oc delete secret -n "${NS}" "${certs[@]}" >/dev/null
        mc_info "Deleted ${#certs} leftover certificate secret(s)."
    fi
    oc delete secret -n "${NS}" --ignore-not-found \
        "${MC_PULL_SECRET_NAME}" "${MC_S3_SECRET_NAME:-${MC_RELEASE_NAME}-observability-s3}" >/dev/null

    if ! ${KEEP_PVCS}; then
        oc delete pvc --all -n "${NS}" --wait=false
    fi
    if ${DELETE_NS}; then
        oc delete namespace "${NS}" --wait=false
        mc_info "Namespace ${NS} deletion started."
    fi
fi

if ${DELETE_CRDS}; then
    oc delete crd clusterconfigs.datastax.com --ignore-not-found
fi
if ${UNLABEL}; then
    "${SCRIPT_DIR}/../1_prepare_cluster/1.3_label_platform_nodes.sh" --remove
fi

rm -f "${MC_CONFIG_DIR}/datastax_mc_instance_details.sh"
mc_info "Mission Control uninstalled."
