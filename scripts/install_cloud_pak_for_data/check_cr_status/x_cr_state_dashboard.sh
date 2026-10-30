#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

# =============================================================================
# x_cr_state_dashboard.sh - live terminal dashboard of the CP4D component CRs
# -----------------------------------------------------------------------------
# Shows every component CR of the CP4D install configured in cpd_vars.sh as a
# glowing dot (healthy / in progress / scaling / stuck / failing / inactive),
# the chains they wait on and own, % progress and the step the operator is on.
# Works on whatever the CRs are doing right now: an install, a scale change, a
# crashed service, a shut-down instance or an idle platform.
#
# Read-only: it never changes the cluster and writes no files. It never runs
# `cpd-cli manage` (that would recreate the olm-utils container); global.yml is
# read with `podman exec <container> cat`.
#
# Components: COMPLETE_COMPONENT_LIST; when it is empty the fallback list is
# cpfs,cpd_platform,ccs,${CPD_COMPONENTS}. Entries that can't be resolved show
# as gray rows instead of stopping the dashboard.
#
# Usage:
#   ./x_cr_state_dashboard.sh                         # the configured install
#   ./x_cr_state_dashboard.sh --components watsonx_dataintelligence
#   ./x_cr_state_dashboard.sh DataStage/datastage     # add a CR by kind/name
#   ./x_cr_state_dashboard.sh --once                  # print the state and exit
#   ./x_cr_state_dashboard.sh --exit-when-settled     # exit once all green/gray for 5m
#   ./x_cr_state_dashboard.sh --help                  # every option
# Keys: q quit · f problems only · t tree mode · s sort · l operator log · ? legend
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# The dashboard reads the local kubeconfig only. Never CPDM_OC_LOGIN here: it runs next to
# install-components, and a cpd-cli login can recreate the container and kill that job.
eval "${OC_LOGIN}"

COMPONENT_LIST_STRING="${COMPLETE_COMPONENT_LIST:-}"
FALLBACK_COMPONENTS="cpfs,cpd_platform,ccs,${CPD_COMPONENTS:-}"

DASH_ARGS=(
    cpd
    --components "${COMPONENT_LIST_STRING}"
    --fallback-components "${FALLBACK_COMPONENTS}"
    --instance-ns "${PROJECT_CPD_INST_OPERANDS}"
    --operator-ns "${PROJECT_CPD_INST_OPERATORS}"
)
for _ns in "${PROJECT_SCHEDULING_SERVICE:-}" "${PROJECT_LICENSE_SERVICE:-}"; do
    [[ -n "${_ns}" ]] && DASH_ARGS+=(--cluster-component-ns "${_ns}")
done
unset _ns

cd "${_CP4D_REPO_ROOT}"
export PYTHONPATH="${_CP4D_REPO_ROOT}/src${PYTHONPATH:+:${PYTHONPATH}}"
# VERSION / PATCH_ID / OLM_UTILS_CONTAINER / CPD_CLI_WORK_PATH come from the env (expected CR versions)
exec uv run --quiet python -m tui.cr_dashboard "${DASH_ARGS[@]}" "$@"
