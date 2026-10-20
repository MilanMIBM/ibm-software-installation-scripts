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
# 2.3 Mission Control status
# ------------------------------------------------------------------------------
#   2.3_mission_control_status.sh                 one snapshot
#   2.3_mission_control_status.sh --wait [SECS]   poll until every pod is ready
#                                                 (default 1800s), exit 1 on timeout
# Shows the Helm release, pods that are not ready (with the SCC each pod was
# admitted under), Pending PVCs and recent warning events.
# ==============================================================================

WAIT=false
TIMEOUT=1800
while (( $# )); do
    case "$1" in
        --wait) WAIT=true; shift
                if [[ "${1:-}" == <-> ]]; then TIMEOUT="$1"; shift; fi ;;
        -h|--help) sed -n '/^# 2.3/,/^# ====/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) mc_die "Unknown option: $1" ;;
    esac
done

eval "${OC_LOGIN}"
mc_ensure_helm
NS="${MC_NAMESPACE}"

# Pods that count: everything except Job pods. Jobs (MinIO bucket setup, CRD
# upgrade hooks) retry, leaving Failed pods behind even when the Job succeeds;
# failed Jobs are reported separately instead.
JQ_WORKLOAD_PODS='[.items[] | select(([.metadata.ownerReferences[]?.kind] | index("Job")) | not)]'

# Prints "<ready> <total>" for the namespace's workload pods.
pod_counts() {
    oc get pods -n "${NS}" -o json 2>/dev/null | jq -r "${JQ_WORKLOAD_PODS}"' as $p
        | ([$p[] | select(.status.phase == "Running" and ([.status.containerStatuses[]?.ready] | all))] | length | tostring)
          + " " + ($p | length | tostring)'
}

show() {
    echo "--- Helm release ${MC_RELEASE_NAME} ---"
    "${MC_HELM}" status "${MC_RELEASE_NAME}" -n "${NS}" -o json 2>/dev/null \
        | jq -r '"  status: \(.info.status)   chart: \(.chart.metadata.version)   revision: \(.version)   updated: \(.info.last_deployed)"' \
        || echo "  not installed"

    echo "--- Pods not ready ---"
    oc get pods -n "${NS}" -o json | jq -r "${JQ_WORKLOAD_PODS}"'[]
        | select(.status.phase != "Running" or ([.status.containerStatuses[]?.ready] | all | not))
        | "  \(.metadata.name)  phase=\(.status.phase)  scc=\(.metadata.annotations["openshift.io/scc"] // "-")  " +
          ([.status.containerStatuses[]? | select(.ready | not) | (.state.waiting.reason // .state.terminated.reason // "starting")] | unique | join(","))' \
        | sed '/^$/d' | { grep . || echo "  none"; }

    echo "--- Failed Jobs ---"
    oc get jobs -n "${NS}" -o json 2>/dev/null \
        | jq -r '.items[] | select(any(.status.conditions[]?; .type == "Failed" and .status == "True")) | "  \(.metadata.name)"' \
        | { grep . || echo "  none"; }

    echo "--- SCC per workload pod (MC_SCC_MODE=${MC_SCC_MODE}) ---"
    oc get pods -n "${NS}" -o json | jq -r "${JQ_WORKLOAD_PODS}"'
        | group_by(.metadata.annotations["openshift.io/scc"] // "-")
        | map("  \(.[0].metadata.annotations["openshift.io/scc"] // "-"): \(length)") | .[]' \
        | { grep . || echo "  no pods"; }

    echo "--- PVCs not Bound ---"
    oc get pvc -n "${NS}" --no-headers 2>/dev/null | awk '$2 != "Bound" {print "  " $1 "  " $2}' | { grep . || echo "  none"; }

    echo "--- Recent warning events ---"
    oc get events -n "${NS}" --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null \
        | tail -n 8 | sed 's/^/  /' | { grep -v '^  LAST SEEN' || echo "  none"; }

    read ready total <<<"$(pod_counts)"
    echo "--- ${ready}/${total} pods ready ---"
    if [[ "${MC_PLANE}" == control ]]; then
        host="$(mc_ui_route_host)"
        [[ -n "${host}" ]] && echo "UI: https://${host}" || echo "UI: no Route yet (2.2_create_ui_route.sh)"
    fi
}

if ! ${WAIT}; then
    show
    exit 0
fi

start=${SECONDS}
while true; do
    read ready total <<<"$(pod_counts)"
    if (( total > 0 && ready == total )); then
        show
        mc_info "All ${total} Mission Control pods are ready."
        exit 0
    fi
    if (( SECONDS - start >= TIMEOUT )); then
        show
        mc_die "Not all pods ready after ${TIMEOUT}s (${ready}/${total})."
    fi
    echo "  [$(( SECONDS - start ))s] ${ready}/${total} pods ready"
    sleep 20
done
