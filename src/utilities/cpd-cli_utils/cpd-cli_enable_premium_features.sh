#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

# =============================================================================
# cpd-cli_enable_premium_features.sh - enable IBM Software Hub Premium features
# -----------------------------------------------------------------------------
# Wraps:
#   cpd-cli manage enable-premium-features
#   cpd-cli manage get-premium-feature-status
#
# Both commands only exist in the Premium olm-utils image. In the standard
# image they are stubs that print a notice and exit 1. Switch variants with:
#
#   ./cpd-cli_toggle_olm_image.sh premium
#
# Features and the namespaces each one needs (SWH 5.4.0):
#
#   argo-cd             Argo CD                              (no namespace)
#   ai-assistant        IBM Software Hub AI assistant        operator_ns + instance_ns
#   physical-locations  Remote physical locations/data planes operator_ns + instance_ns
#   adv-workload-mgr    Advanced workload management          scheduler_ns
#   multi-tenancy       Multitenancy on IBM Software Hub      operator_ns
#
# This script passes only the namespace flags the selected features actually
# require, so enabling just argo-cd does not drag in unrelated projects.
#
# Usage:
#   ./cpd-cli_enable_premium_features.sh                       # enable FEATURES below
#   ./cpd-cli_enable_premium_features.sh --status              # show current status
#   ./cpd-cli_enable_premium_features.sh --dry-run             # print the command only
#   ./cpd-cli_enable_premium_features.sh --features=argo-cd,ai-assistant
#   ./cpd-cli_enable_premium_features.sh --all                 # every feature
# =============================================================================

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# cpd_vars.sh reassigns SCRIPT_DIR when sourced, so keep our own copy.
UTILS_DIR="${SCRIPT_DIR}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

#-------------------------------------------------------------------------------
# Edit this list, or override it with --features= / --all
#-------------------------------------------------------------------------------
FEATURES=(
    "argo-cd"
    # "ai-assistant"
    # "physical-locations"
    # "adv-workload-mgr"
    # "multi-tenancy"
)

LICENSE_ACCEPTANCE=true
#-------------------------------------------------------------------------------

ALL_FEATURES=(argo-cd ai-assistant physical-locations adv-workload-mgr multi-tenancy)

MODE="enable"
DRY_RUN=false

for arg in "$@"; do
    case "${arg}" in
        --status)      MODE="status" ;;
        --dry-run)     DRY_RUN=true ;;
        --all)         FEATURES=("${ALL_FEATURES[@]}") ;;
        --features=*)  FEATURES=(${(s:,:)${arg#--features=}}) ;;
        -h|--help)
            sed -n '6,35p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "[ERROR] Unknown argument: ${arg}"
            echo "        Valid: --status | --dry-run | --all | --features=<list>"
            exit 1
            ;;
    esac
done

if (( ${#FEATURES[@]} == 0 )); then
    echo "[ERROR] No features selected. Edit FEATURES in this script or pass --features=<list>."
    exit 1
fi

# -----------------------------------------------------------------------------
# Validate the requested features against the known set
# -----------------------------------------------------------------------------
for f in "${FEATURES[@]}"; do
    if [[ " ${ALL_FEATURES[*]} " != *" ${f} "* ]]; then
        echo "[ERROR] Unknown feature: ${f}"
        echo "        Valid: ${ALL_FEATURES[*]}"
        exit 1
    fi
done

FEATURES_STRING=$(IFS=,; echo "${FEATURES[*]}")

# -----------------------------------------------------------------------------
# Work out which namespace flags these features actually need
# -----------------------------------------------------------------------------
NEED_OPERATOR_NS=false
NEED_INSTANCE_NS=false
NEED_SCHEDULER_NS=false

for f in "${FEATURES[@]}"; do
    case "${f}" in
        ai-assistant|physical-locations)
            NEED_OPERATOR_NS=true; NEED_INSTANCE_NS=true ;;
        multi-tenancy)
            NEED_OPERATOR_NS=true ;;
        adv-workload-mgr)
            NEED_SCHEDULER_NS=true ;;
        argo-cd)
            : ;;
    esac
done

# get-premium-feature-status always wants instance_ns.
if [[ "${MODE}" == "status" ]]; then
    NEED_INSTANCE_NS=true
fi

NS_FLAGS=()
if [[ "${NEED_OPERATOR_NS}" == true ]]; then
    if [[ -z "${PROJECT_CPD_INST_OPERATORS:-}" ]]; then
        echo "[ERROR] PROJECT_CPD_INST_OPERATORS is not set but is required by: ${FEATURES_STRING}"
        exit 1
    fi
    NS_FLAGS+=(--operator_ns="${PROJECT_CPD_INST_OPERATORS}")
fi
if [[ "${NEED_INSTANCE_NS}" == true ]]; then
    if [[ -z "${PROJECT_CPD_INST_OPERANDS:-}" ]]; then
        echo "[ERROR] PROJECT_CPD_INST_OPERANDS is not set but is required by: ${FEATURES_STRING}"
        exit 1
    fi
    NS_FLAGS+=(--instance_ns="${PROJECT_CPD_INST_OPERANDS}")
fi
if [[ "${NEED_SCHEDULER_NS}" == true ]]; then
    if [[ -z "${PROJECT_SCHEDULING_SERVICE:-}" ]]; then
        echo "[ERROR] PROJECT_SCHEDULING_SERVICE is not set but is required by: adv-workload-mgr"
        exit 1
    fi
    NS_FLAGS+=(--scheduler_ns="${PROJECT_SCHEDULING_SERVICE}")
fi

# -----------------------------------------------------------------------------
# Warn early if the standard image is active
# -----------------------------------------------------------------------------
if [[ "${OLM_UTILS_VARIANT:-standard}" != "premium" ]]; then
    echo "[WARN] Active olm-utils variant is '${OLM_UTILS_VARIANT:-standard}', not 'premium'."
    echo "[WARN] Image: ${OLM_UTILS_IMAGE:-<unset>}"
    echo "[WARN] In the standard image these commands are stubs that exit 1."
    echo "[WARN] Switch first:  ${UTILS_DIR}/cpd-cli_toggle_olm_image.sh premium"
fi

# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------
if [[ "${MODE}" == "status" ]]; then
    echo "[INFO] Premium feature status for: ${FEATURES_STRING}"

    if [[ "${DRY_RUN}" == true ]]; then
        echo "cpd-cli manage get-premium-feature-status --features=${FEATURES_STRING} ${NS_FLAGS[*]}"
        exit 0
    fi

    eval "${CPDM_OC_LOGIN}"

    cpd-cli manage get-premium-feature-status \
        --features="${FEATURES_STRING}" \
        "${NS_FLAGS[@]}"
    exit 0
fi

echo "[INFO] Enabling premium features: ${FEATURES_STRING}"
(( ${#NS_FLAGS[@]} )) && echo "[INFO] Namespace flags: ${NS_FLAGS[*]}"

if [[ "${DRY_RUN}" == true ]]; then
    echo "cpd-cli manage enable-premium-features --license_acceptance=${LICENSE_ACCEPTANCE} --features=${FEATURES_STRING} ${NS_FLAGS[*]}"
    exit 0
fi

if [[ "${LICENSE_ACCEPTANCE}" != true ]]; then
    echo "[ERROR] LICENSE_ACCEPTANCE is not true. These features require IBM Software Hub Premium"
    echo "[ERROR] and acceptance of the license terms."
    exit 1
fi

eval "${CPDM_OC_LOGIN}"

cpd-cli manage enable-premium-features \
    --license_acceptance="${LICENSE_ACCEPTANCE}" \
    --features="${FEATURES_STRING}" \
    "${NS_FLAGS[@]}"

echo "[INFO] Enablement finished. Verify with:"
echo "       $(basename $0) --status --features=${FEATURES_STRING}"
