#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: source confluent_vars.sh LAST so its cluster/storage values
# win over the CP4D ones defined in cpd_vars.sh. Override to point these
# scripts at a different config:  ENV_TARGET=<name|path> ./<script>.sh
: "${ENV_TARGET:=confluent}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# ==============================================================================
# Confluent Platform for Apache Flink - full install
# ------------------------------------------------------------------------------
# Runs the Flink addon install end to end:
#   1.0_flink_prep.sh -> 1.1_flink_install.sh -> 1.2_flink_status.sh
#   -> 1.3_flink_get_instance_details.sh
#
# Step 0 is NOT run here: the Flink settings must already be in
# configs/confluent_platform_config/confluent_vars.sh. Add them with
# 0_flink_prepare_template_config.sh, or generate the file with the
# confluent_platform_vars_generation.py notebook (Flink addon enabled).
#
# Prep or install failing stops the chain. 1.1 runs with --no-status because
# 1.2 follows it here; a failing status report only warns.
#
# Step toggles - override any of them at runtime, e.g.:
#   DO_FLINK_PREP=false ./full_installprocess-confluent_flink.sh
# ==============================================================================

DO_FLINK_PREP="${DO_FLINK_PREP:-true}"                         # 1.0 prepare the cluster
DO_FLINK_INSTALL="${DO_FLINK_INSTALL:-true}"                   # 1.1 install operator + CMF
DO_FLINK_STATUS="${DO_FLINK_STATUS:-true}"                     # 1.2 report Flink health
DO_FLINK_INSTANCE_DETAILS="${DO_FLINK_INSTANCE_DETAILS:-true}" # 1.3 write instance details

# Fail before touching the cluster if the Flink config was never created.
if [[ -z "${PROJECT_CONFLUENT_FLINK:-}" ]]; then
    echo "[ERROR] PROJECT_CONFLUENT_FLINK is not set - add the Flink settings to configs/confluent_platform_config/confluent_vars.sh" >&2
    echo "[ERROR] with 0_flink_prepare_template_config.sh or the confluent_platform_vars_generation.py notebook." >&2
    exit 1
fi

# run_step <enabled> <label> <on_failure: stop|warn> <script> [args...]
run_step() {
    local enabled="$1"
    local label="$2"
    local on_failure="$3"
    local script="$4"
    shift 4

    if [[ "${enabled}" != "true" ]]; then
        echo ""
        echo "==> Skipping: ${label}"
        return 0
    fi

    echo ""
    echo "==> Running:  ${label}"
    local rc=0
    "${script}" "$@" || rc=$?
    if (( rc != 0 )); then
        if [[ "${on_failure}" == "stop" ]]; then
            echo "[ERROR] ${label} exited ${rc}; stopping the install chain." >&2
            exit "${rc}"
        fi
        echo "[WARN] ${label} exited ${rc}; continuing chain."
    fi
    return 0
}

echo "=============================================================================="
echo " Confluent Platform for Apache Flink full install - project '${PROJECT_CONFLUENT_FLINK}'"
echo "=============================================================================="
echo "[INFO] CMF chart: ${FLINK_CMF_CHART_VERSION:-?}  Operator chart: ${FLINK_OPERATOR_CHART_VERSION:-?}"

# --- Step 1.0 - Prepare the cluster -------------------------------------------
run_step "${DO_FLINK_PREP}" \
    "1.0 flink prep" stop \
    "${SCRIPT_DIR}/1.0_flink_prep.sh"

# --- Step 1.1 - Install the Flink operator, CMF and default resources ---------
run_step "${DO_FLINK_INSTALL}" \
    "1.1 flink install" stop \
    "${SCRIPT_DIR}/1.1_flink_install.sh" --no-status

# --- Step 1.2 - Status report -------------------------------------------------
run_step "${DO_FLINK_STATUS}" \
    "1.2 flink status" warn \
    "${SCRIPT_DIR}/1.2_flink_status.sh"

# --- Step 1.3 - Write confluent_flink_instance_details.sh ---------------------
run_step "${DO_FLINK_INSTANCE_DETAILS}" \
    "1.3 flink get instance details" stop \
    "${SCRIPT_DIR}/1.3_flink_get_instance_details.sh"

echo ""
echo "[INFO] Confluent Platform for Apache Flink full install complete."
