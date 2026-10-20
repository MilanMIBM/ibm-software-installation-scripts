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

# ==============================================================================
# 1.4 Security Context Constraints for the Mission Control service accounts
# ------------------------------------------------------------------------------
# MC_SCC_MODE (DataStax "Configure Security Context Constraints"):
#   nonroot-v2     oc adm policy add-scc-to-user nonroot-v2 for every service account
#   restricted-v2  nothing for the operators/UI/Dex/aggregator (2.0 renders the
#                  null UID overrides); nonroot-v2 only for the components that
#                  pin UIDs regardless (Loki, Mimir, MinIO, kube-state-metrics)
#   custom         DataStax's example SCC "<release>" listing the service accounts.
#                  Note: that example allows hostNetwork.
#
# In every mode the grant to <release>-loki is what lets Loki start: the chart's
# own SCC binding names a "loki" service account that its Loki pods do not use.
# Chart 1.21.2 also grants anyuid (SCC priority 10) to its other service
# accounts, which outranks restricted-v2 and the custom SCC - see the warning
# at the end and the per-pod SCCs in 2.3_mission_control_status.sh.
#
# Granting before the install avoids a round of pods failing admission; granting
# to service accounts that do not exist yet is fine. Switching modes revokes what
# the other modes granted. Safe to re-run.
#
#   1.4_configure_scc.sh [--remove]   (--remove revokes everything, for uninstall)
# ==============================================================================

NS="${MC_NAMESPACE}"
CUSTOM_SCC="${MC_RELEASE_NAME}"
ALL_SAS=("${(@f)$(mc_service_accounts)}")
FIXED_SAS=("${(@f)$(mc_fixed_uid_service_accounts)}")

eval "${OC_LOGIN}"

grant_nonroot() {
    local sa
    for sa in "$@"; do
        oc adm policy add-scc-to-user nonroot-v2 -z "${sa}" -n "${NS}" >/dev/null
    done
    mc_info "nonroot-v2 granted to: $*"
}

revoke_nonroot() {
    local sa
    for sa in "$@"; do
        oc adm policy remove-scc-from-user nonroot-v2 -z "${sa}" -n "${NS}" >/dev/null 2>&1 || true
    done
}

delete_custom_scc() {
    if oc get scc "${CUSTOM_SCC}" >/dev/null 2>&1 \
       && [[ "$(oc get scc "${CUSTOM_SCC}" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')" == datastax-mc-scripts ]]; then
        oc delete scc "${CUSTOM_SCC}" >/dev/null
        mc_info "Deleted custom SCC ${CUSTOM_SCC}."
    fi
}

if [[ "${1:-}" == --remove ]]; then
    revoke_nonroot "${ALL_SAS[@]}"
    delete_custom_scc
    mc_info "SCC grants for ${NS} removed."
    exit 0
fi

case "${MC_SCC_MODE}" in
    nonroot-v2)
        delete_custom_scc
        grant_nonroot "${ALL_SAS[@]}" ;;

    restricted-v2)
        delete_custom_scc
        revoke_nonroot "${ALL_SAS[@]:|FIXED_SAS}"
        grant_nonroot "${FIXED_SAS[@]}"
        uid_range="$(oc get namespace "${NS}" -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.uid-range}' 2>/dev/null || true)"
        mc_info "Namespace UID range: ${uid_range:-<namespace not created yet>} (operators, UI, Dex and the aggregator get UIDs from it)" ;;

    custom)
        if oc get scc "${CUSTOM_SCC}" >/dev/null 2>&1 \
           && [[ "$(oc get scc "${CUSTOM_SCC}" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')" != datastax-mc-scripts ]]; then
            mc_die "An SCC named ${CUSTOM_SCC} exists and was not created by these scripts - not overwriting it."
        fi
        revoke_nonroot "${ALL_SAS[@]}"
        {
            cat <<EOF
kind: SecurityContextConstraints
apiVersion: security.openshift.io/v1
metadata:
  name: ${CUSTOM_SCC}
  labels:
    app.kubernetes.io/managed-by: datastax-mc-scripts
runAsUser:
  type: MustRunAsNonRoot
seLinuxContext:
  type: RunAsAny
fsGroup:
  type: RunAsAny
supplementalGroups:
  type: RunAsAny
volumes:
- '*'
requiredDropCapabilities:
- ALL
allowedCapabilities:
- NET_BIND_SERVICE
allowHostNetwork: true
allowHostDirVolumePlugin: false
users:
EOF
            for sa in "${ALL_SAS[@]}"; do
                echo "- system:serviceaccount:${NS}:${sa}"
            done
        } | oc apply -f - >/dev/null
        mc_info "Custom SCC ${CUSTOM_SCC} applied for ${#ALL_SAS} service accounts in ${NS}." ;;
esac

# The chart binds its own ClusterRole <release>-openshift-scc (anyuid + nonroot-v2)
# to most of its service accounts. anyuid has SCC priority 10 and OpenShift tries
# higher-priority SCCs first, so it wins over restricted-v2 and over the custom SCC.
if [[ "${MC_SCC_MODE}" != nonroot-v2 ]]; then
    chart_sccs="$(oc get clusterrole "${MC_RELEASE_NAME}-openshift-scc" -o jsonpath='{.rules[*].resourceNames[*]}' 2>/dev/null || true)"
    if [[ -z "${chart_sccs}" || " ${chart_sccs} " == *" anyuid "* ]]; then
        mc_warn "MC_SCC_MODE=${MC_SCC_MODE}: the chart grants anyuid (priority 10) to its operator, UI, Dex, aggregator,"
        mc_warn "Mimir and MinIO service accounts${chart_sccs:+ (ClusterRole ${MC_RELEASE_NAME}-openshift-scc: ${chart_sccs})}${chart_sccs:- (chart 1.21.2 does)},"
        mc_warn "so those pods are likely admitted under anyuid, not ${MC_SCC_MODE}. Check with 2.3_mission_control_status.sh."
    fi
fi

mc_info "SCC changes take effect for pods created from now on; allow a few minutes for scheduling."
