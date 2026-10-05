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
# Confluent Platform - full install
# ------------------------------------------------------------------------------
# Runs the platform install end to end:
#   1.0_confluent_prep.sh -> 1.1_confluent_install.sh -> 1.2_confluent_status.sh
#   -> 1.3_confluent_get_instance_details.sh
#
# Step 0 is NOT run here: configs/confluent_platform_config/confluent_vars.sh
# must already exist. Create it with 0_confluent_prepare_template_config.sh, or
# generate it with the confluent_platform_vars_generation.py notebook.
#
# Prep or install failing stops the chain. A status report of components not
# yet ready only warns, so the instance details are still collected.
#
# Flink addon: when DO_FLINK_ADDON is true and confluent_vars.sh holds the Flink
# settings (written by 0_flink_prepare_template_config.sh or the notebook), the
# addon's full_installprocess-confluent_flink.sh runs once the platform is up.
# Set DO_FLINK_ADDON=false to skip it even when the settings are present.
#
# Step toggles - override any of them at runtime, e.g.:
#   DO_CONFLUENT_PREP=false ./full_installprocess-confluent_platform.sh
# ==============================================================================

DO_CONFLUENT_PREP="${DO_CONFLUENT_PREP:-true}"                 # 1.0 prepare the cluster
DO_CONFLUENT_INSTALL="${DO_CONFLUENT_INSTALL:-true}"           # 1.1 install the platform
DO_CONFLUENT_STATUS="${DO_CONFLUENT_STATUS:-true}"             # 1.2 report component health
DO_CONFLUENT_INSTANCE_DETAILS="${DO_CONFLUENT_INSTANCE_DETAILS:-true}" # 1.3 write instance details
DO_FLINK_ADDON="${DO_FLINK_ADDON:-true}"                       # Flink addon full install, if configured

# Fail before touching the cluster if the config was never created.
if [[ -z "${PROJECT_CONFLUENT_SERVER:-}" ]]; then
    echo "[ERROR] PROJECT_CONFLUENT_SERVER is not set - create configs/confluent_platform_config/confluent_vars.sh" >&2
    echo "[ERROR] with 0_confluent_prepare_template_config.sh or the confluent_platform_vars_generation.py notebook." >&2
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
echo " Confluent Platform full install - project '${PROJECT_CONFLUENT_SERVER}'"
echo "=============================================================================="
echo "[INFO] Version: ${CONFLUENT_VERSION:-?}  Control Center: ${CONFLUENT_C3_VERSION:-?}"

# --- Step 1.0 - Prepare the cluster -------------------------------------------
run_step "${DO_CONFLUENT_PREP}" \
    "1.0 confluent prep" stop \
    "${SCRIPT_DIR}/1.0_confluent_prep.sh"

# --- Step 1.1 - Install the platform ------------------------------------------
run_step "${DO_CONFLUENT_INSTALL}" \
    "1.1 confluent install" stop \
    "${SCRIPT_DIR}/1.1_confluent_install.sh"

# --- Step 1.2 - Status report (non-zero = a component is not ready yet) -------
run_step "${DO_CONFLUENT_STATUS}" \
    "1.2 confluent status" warn \
    "${SCRIPT_DIR}/1.2_confluent_status.sh"

# --- Step 1.3 - Write confluent_instance_details.sh ---------------------------
run_step "${DO_CONFLUENT_INSTANCE_DETAILS}" \
    "1.3 confluent get instance details" stop \
    "${SCRIPT_DIR}/1.3_confluent_get_instance_details.sh"

echo ""
echo "[INFO] Confluent Platform full install complete."

# --- Flink addon - autodetected from confluent_vars.sh ------------------------
# Both the managed sizing block (PROJECT_CONFLUENT_FLINK) and the unmanaged
# settings (FLINK_CMF_CHART_VERSION) must be present for the addon to install.
if [[ -n "${PROJECT_CONFLUENT_FLINK:-}" && -n "${FLINK_CMF_CHART_VERSION:-}" ]]; then
    _flink_detected=true
else
    _flink_detected=false
fi

if [[ "${DO_FLINK_ADDON}" != "true" ]]; then
    echo ""
    echo "==> Skipping: flink addon full install (DO_FLINK_ADDON=${DO_FLINK_ADDON}, detected in config: ${_flink_detected})"
elif [[ "${_flink_detected}" != "true" ]]; then
    echo ""
    echo "==> Skipping: flink addon full install (no Flink settings in confluent_vars.sh -"
    echo "    add them with 0_flink_prepare_template_config.sh or the notebook)"
else
    run_step true \
        "flink addon full install" stop \
        "${SCRIPT_DIR}/install_confluent_platform_flink_addon/full_installprocess-confluent_flink.sh"
fi
unset _flink_detected
