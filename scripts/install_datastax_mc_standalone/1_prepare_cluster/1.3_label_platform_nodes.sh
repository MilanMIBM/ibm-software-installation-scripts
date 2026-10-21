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
# 1.3 Label the nodes Mission Control may run on
# ------------------------------------------------------------------------------
# DataStax's OpenShift values pin every Mission Control component (operators,
# UI, Dex, Vector, Loki, Mimir) to nodes labelled
#     mission-control.datastax.com/role=platform
# Without such a node the pods stay Pending. MC_PLATFORM_NODES picks them:
#   all-workers   every node with node-role.kubernetes.io/worker
#   existing      label nothing, just check one is labelled
#   n1,n2,...     exactly these nodes
#
#   1.3_label_platform_nodes.sh [--remove]   (--remove drops the label everywhere)
# Database pods are not affected by this label.
# ==============================================================================

LABEL_KEY="mission-control.datastax.com/role"
LABEL="${LABEL_KEY}=platform"

eval "${OC_LOGIN}"

if [[ "${1:-}" == --remove ]]; then
    if [[ -n "$(oc get nodes -l "${LABEL}" -o name 2>/dev/null)" ]]; then
        oc label nodes -l "${LABEL}" "${LABEL_KEY}-" >/dev/null
        mc_info "Removed ${LABEL} from all nodes."
    else
        mc_info "No node carries ${LABEL}."
    fi
    exit 0
fi

case "${MC_PLATFORM_NODES:-all-workers}" in
    existing)
        nodes=() ;;
    all-workers)
        nodes=("${(@f)$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')}")
        nodes=(${nodes:#}) ;;
    *)
        nodes=("${(@s:,:)MC_PLATFORM_NODES}") ;;
esac

for n in "${nodes[@]}"; do
    oc get node "${n}" >/dev/null 2>&1 || mc_die "Node '${n}' not found (MC_PLATFORM_NODES=${MC_PLATFORM_NODES})."
    if [[ "$(oc get node "${n}" -o jsonpath="{.metadata.labels.${LABEL_KEY//./\\.}}")" == platform ]]; then
        mc_info "${n}: already labelled"
    else
        oc label node "${n}" "${LABEL}" --overwrite >/dev/null
        mc_info "${n}: labelled ${LABEL}"
    fi
done

labelled=("${(@f)$(oc get nodes -l "${LABEL}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')}")
labelled=(${labelled:#})
(( ${#labelled} > 0 )) || mc_die "No node carries ${LABEL}; Mission Control pods would stay Pending."
mc_info "Platform nodes (${#labelled}): ${labelled[*]}"
