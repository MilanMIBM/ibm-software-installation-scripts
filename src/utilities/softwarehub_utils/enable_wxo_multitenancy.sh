#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

# =============================================================================
# enable_wxo_multitenancy.sh - set up watsonx Orchestrate multitenancy
# -----------------------------------------------------------------------------
# watsonx Orchestrate has no enable switch of its own: it needs Software Hub
# multitenancy on, at 5.4.0 Patch 5 or later. This script:
#
#   1. Checks that Orchestrate is ready and declares multitenancy support.
#   2. Checks Software Hub multitenancy, and runs
#      enable_softwarehub_multitenancy.sh first if it is not on.
#   3. Checks that Orchestrate is still healthy afterwards.
#   4. Prints what is left to do by hand (accounts are web client only).
#
# All accounts share the same pods and databases, so this separates data,
# administrators and tokens, not compute.
#
# Usage:
#   ./enable_wxo_multitenancy.sh --status
#   ./enable_wxo_multitenancy.sh --dry-run
#   ./enable_wxo_multitenancy.sh --accept-license
#
# Options:
#   --status               Print the state and exit (reads the cluster only);
#                          exit codes as enable_softwarehub_multitenancy.sh
#   --dry-run              Run the checks and print the plan; changes nothing
#   --timeout=<seconds>    Wait limit for Software Hub and for each Orchestrate
#                          check afterwards
#   --accept-license, --skip-premium-check, --image=<image>
#                          Passed to enable_softwarehub_multitenancy.sh
# =============================================================================

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# cpd_vars.sh reassigns SCRIPT_DIR when sourced, so keep our own copy.
UTILS_DIR="${SCRIPT_DIR}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/progress_panel_helpers.sh"

# --- Edit these ---------------------------------------------------------------
MIN_PATCH=5
WAIT_TIMEOUT=1800
# ------------------------------------------------------------------------------

SWH_SCRIPT="${UTILS_DIR}/enable_softwarehub_multitenancy.sh"
EXIT_ENABLING=10
EXIT_NOT_ENABLED=11

STATUS_ONLY=false
DRY_RUN=false
SWH_ARGS=()

for arg in "$@"; do
    case "${arg}" in
        --status)                               STATUS_ONLY=true ;;
        --dry-run)                              DRY_RUN=true; SWH_ARGS+=("${arg}") ;;
        --accept-license|--skip-premium-check)  SWH_ARGS+=("${arg}") ;;
        --image=*)                              SWH_ARGS+=("${arg}") ;;
        --timeout=<->)                          WAIT_TIMEOUT="${arg#--timeout=}"; SWH_ARGS+=("${arg}") ;;
        -h|--help)                              sed -n '6,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                                      h_die "Unknown argument: ${arg} (see --help)" ;;
    esac
done

: "${PROJECT_CPD_INST_OPERANDS:?PROJECT_CPD_INST_OPERANDS is not set, check cpd_vars.sh}"
NS="${PROJECT_CPD_INST_OPERANDS}"
WO_RESOURCE="watsonxorchestrates.wo.watsonx.ibm.com"

wo_is_ready() {
    [[ "$(oc get "${WO_RESOURCE}" "${WO_NAME}" -n "${NS}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == True ]]
}

# The service Software Hub calls when an account is created.
tenant_service_is_ready() {
    local want have
    want="$(oc get deploy wo-tenant-data-service -n "${NS}" -o jsonpath='{.spec.replicas}' 2>/dev/null)" || return 1
    have="$(oc get deploy wo-tenant-data-service -n "${NS}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" || return 1
    [[ -n "${want}" && "${want}" != 0 && "${have}" == "${want}" ]]
}

# ppanel_watch probes: real counts, so the bar and time left come from the work.
wo_wait_probe() {
    local verified message
    verified="$(oc get "${WO_RESOURCE}" "${WO_NAME}" -n "${NS}" -o jsonpath='{.status.componentStatus.verifiedComponents.display}' 2>/dev/null)" || return 0
    message="$(oc get "${WO_RESOURCE}" "${WO_NAME}" -n "${NS}" -o jsonpath='{.status.deployingStatus.status}' 2>/dev/null)" || message=""
    [[ "${verified}" == <->/<-> ]] || return 0
    PPANEL_DONE="${verified%/*}" PPANEL_TOTAL="${verified#*/}" PPANEL_DETAIL="${message}"
}

tenant_service_probe() {
    PPANEL_DONE="$(oc get deploy wo-tenant-data-service -n "${NS}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)" || PPANEL_DONE=0
    PPANEL_TOTAL="$(oc get deploy wo-tenant-data-service -n "${NS}" -o jsonpath='{.spec.replicas}' 2>/dev/null)" || PPANEL_TOTAL=0
}

# wxo_wait <check> <probe> <title> <units>: returns at once if the check passes.
wxo_wait() {
    local check="$1" deadline=$(( EPOCHSECONDS + WAIT_TIMEOUT )) rc=0
    "${check}" && return 0
    ppanel_watch_start -p "$2" -t "$3" -u "$4" -i 5
    until "${check}"; do
        if (( EPOCHSECONDS >= deadline )); then rc=1; break; fi
        sleep 10
    done
    ppanel_watch_stop
    return ${rc}
}

eval "${OC_LOGIN}"

# --- 1. Orchestrate ------------------------------------------------------------
WO_NAME="$(oc get "${WO_RESOURCE}" -n "${NS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "${WO_NAME}" ]] || h_die "No watsonx Orchestrate CR in ${NS}. Install it first."

wo_is_ready || h_die "watsonx Orchestrate '${WO_NAME}' is not Ready. IBM requires a successful install or upgrade first."
h_info "watsonx Orchestrate '${WO_NAME}' is Ready."

WO_VERSION="$(oc get "${WO_RESOURCE}" "${WO_NAME}" -n "${NS}" -o jsonpath='{.status.versionStatus.status}')"
WO_PATCH_TEXT="$(oc get "${WO_RESOURCE}" "${WO_NAME}" -n "${NS}" -o jsonpath='{.status.patchVersionStatus.status}')"
if [[ "${WO_VERSION}" == 5.4.0 ]]; then
    [[ "${WO_PATCH_TEXT}" =~ 'Patch ([0-9]+)' ]] && WO_PATCH="${match[1]}" || WO_PATCH=0
    (( WO_PATCH >= MIN_PATCH )) \
        || h_die "Multitenancy needs 5.4.0 Patch ${MIN_PATCH} or later; this is ${WO_VERSION} ${WO_PATCH_TEXT:-with no patch}."
fi
h_info "Version ${WO_VERSION} ${WO_PATCH_TEXT} supports multitenancy."

SUPPORTED="$(oc get cm "${WO_NAME}-watson-orchestrate-zen-service" -n "${NS}" -o json 2>/dev/null \
    | jq -r '.data["add-ons.json"] | fromjson | [.. | objects | .multitenancy? | select(. != null)][0].is_supported // false' 2>/dev/null || true)"
[[ "${SUPPORTED}" == true ]] \
    || h_die "The add-on registration of '${WO_NAME}' does not declare multitenancy support (ConfigMap ${WO_NAME}-watson-orchestrate-zen-service)."
h_info "The add-on registration declares multitenancy support."

tenant_service_is_ready || h_die "wo-tenant-data-service is not fully available in ${NS}."
h_info "wo-tenant-data-service is available."

# --- 2. Software Hub -----------------------------------------------------------
SWH_STATE=0
"${SWH_SCRIPT}" --status || SWH_STATE=$?

if [[ "${STATUS_ONLY}" == true ]]; then
    exit "${SWH_STATE}"
fi

# Also when it reads Enabled: the operator may still be applying the change,
# and the script returns at once if it has finished.
case "${SWH_STATE}" in
    0) ;;
    "${EXIT_ENABLING}"|"${EXIT_NOT_ENABLED}") h_info "Running $(basename "${SWH_SCRIPT}") first." ;;
    *) h_die "Could not read the Software Hub multitenancy state." ;;
esac
"${SWH_SCRIPT}" "${SWH_ARGS[@]}"

if [[ "${DRY_RUN}" == true ]]; then
    h_info "Dry run: afterwards this script would check that Orchestrate and wo-tenant-data-service stay healthy, then list the manual steps."
    exit 0
fi

# --- 3. Orchestrate afterwards -------------------------------------------------
SWH_STATE=0
"${SWH_SCRIPT}" --status || SWH_STATE=$?
(( SWH_STATE == 0 )) || h_die "Software Hub multitenancy is not on yet, so Orchestrate was not checked. Re-run this script."

wxo_wait wo_is_ready wo_wait_probe "watsonx Orchestrate" "components verified" \
    || h_die "watsonx Orchestrate '${WO_NAME}' did not return to Ready."
wxo_wait tenant_service_is_ready tenant_service_probe "wo-tenant-data-service" "replicas" \
    || h_die "wo-tenant-data-service did not become available."

# --- 4. Manual steps -----------------------------------------------------------
h_info "watsonx Orchestrate is ready for multitenancy. Left to do by hand:"
h_info "  1. Web client: navigation menu > Accounts > New Account, and select watsonx Orchestrate."
h_info "  2. Create watsonx Orchestrate service instances in that account (needs Account Admin, Create Instance or Manage Instance)."
h_info "  3. Use account-specific tokens: add account_id to POST /icp4d-api/v1/authorize. Existing ZenApiKeys only work for the default account."
