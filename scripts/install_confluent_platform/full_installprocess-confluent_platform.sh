#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_iceberg_setup_override="${DO_ICEBERG_WATSONX_SETUP-}"
# --- Config target: source confluent_vars.sh LAST so its cluster/storage values
# win over the CP4D ones defined in cpd_vars.sh. Override to point these
# scripts at a different config:  ENV_TARGET=<name|path> ./<script>.sh
: "${ENV_TARGET:=confluent}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"

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
# Iceberg/watsonx.data: DO_ICEBERG_WATSONX_SETUP=true runs the optional integration
# setup after the platform is ready. Requires a configured external catalog and
# configs/confluent_platform_config/iceberg_watsonx_setup.sh. The setup utility
# can also be run separately after installing watsonx.data.
#
# Step toggles - override any of them at runtime, e.g.:
#   DO_CONFLUENT_PREP=false ./full_installprocess-confluent_platform.sh
# Or pick steps by name: --from <step> resumes there, --skip <step>[,...] leaves
# steps out, --list-steps shows the plan.
# ==============================================================================

h_steps_parse --strict "$@"

DO_CONFLUENT_PREP="${DO_CONFLUENT_PREP:-true}"                 # 1.0 prepare the cluster
DO_CONFLUENT_INSTALL="${DO_CONFLUENT_INSTALL:-true}"           # 1.1 install the platform
DO_CONFLUENT_STATUS="${DO_CONFLUENT_STATUS:-true}"             # 1.2 report component health
DO_CONFLUENT_INSTANCE_DETAILS="${DO_CONFLUENT_INSTANCE_DETAILS:-true}" # 1.3 write instance details
DO_FLINK_ADDON="${DO_FLINK_ADDON:-true}"                       # Flink addon full install, if configured
DO_ICEBERG_WATSONX_SETUP="${_iceberg_setup_override:-${DO_ICEBERG_WATSONX_SETUP:-false}}"
unset _iceberg_setup_override

case "${DO_ICEBERG_WATSONX_SETUP}" in
    true|false) ;;
    *) echo "[ERROR] DO_ICEBERG_WATSONX_SETUP must be true or false." >&2; exit 1 ;;
esac

if [[ "${DO_ICEBERG_WATSONX_SETUP}" == true ]]; then
    _iceberg_config="${ICEBERG_WATSONX_CONFIG_FILE:-${_CP4D_REPO_ROOT}/configs/confluent_platform_config/iceberg_watsonx_setup.sh}"
    if [[ ! -f "${_iceberg_config}" ]]; then
        echo "[ERROR] Iceberg setup enabled but its config is missing: ${_iceberg_config}" >&2
        echo "[ERROR] Copy connector_configs/iceberg-watsonx.example.sh into the ignored configs directory first." >&2
        exit 1
    fi
    unset _iceberg_config
fi

# Fail before touching the cluster if the config was never created.
if [[ -z "${PROJECT_CONFLUENT_SERVER:-}" ]]; then
    echo "[ERROR] PROJECT_CONFLUENT_SERVER is not set - create configs/confluent_platform_config/confluent_vars.sh" >&2
    echo "[ERROR] with 0_confluent_prepare_template_config.sh or the confluent_platform_vars_generation.py notebook." >&2
    exit 1
fi

echo "=============================================================================="
echo " Confluent Platform full install - project '${PROJECT_CONFLUENT_SERVER}'"
echo "=============================================================================="
echo "[INFO] Version: ${CONFLUENT_VERSION:-?}  Control Center: ${CONFLUENT_C3_VERSION:-?}"

# Flink addon - autodetected from confluent_vars.sh: both the managed sizing
# block (PROJECT_CONFLUENT_FLINK) and the unmanaged settings
# (FLINK_CMF_CHART_VERSION) must be present for the addon to install.
if [[ -n "${PROJECT_CONFLUENT_FLINK:-}" && -n "${FLINK_CMF_CHART_VERSION:-}" ]]; then
    _flink_note="detected in confluent_vars.sh"
else
    _flink_note="no Flink settings in confluent_vars.sh - add them with 0_flink_prepare_template_config.sh or the notebook"
    DO_FLINK_ADDON=false
fi

# Status (non-zero = a component is not ready yet) only warns.
h_step         prep             "${DO_CONFLUENT_PREP}"             "1.0 confluent prep" \
    "${SCRIPT_DIR}/1.0_confluent_prep.sh"
h_step         install          "${DO_CONFLUENT_INSTALL}"          "1.1 confluent install" \
    "${SCRIPT_DIR}/1.1_confluent_install.sh"
h_step --warn  status           "${DO_CONFLUENT_STATUS}"           "1.2 confluent status" \
    "${SCRIPT_DIR}/1.2_confluent_status.sh"
h_step         instance-details "${DO_CONFLUENT_INSTANCE_DETAILS}" "1.3 confluent get instance details" \
    "${SCRIPT_DIR}/1.3_confluent_get_instance_details.sh"
h_step         iceberg          "${DO_ICEBERG_WATSONX_SETUP}"      "iceberg watsonx.data integration" \
    "${SCRIPT_DIR}/utility_scripts_confluent_platform/x.6_confluent_setup_iceberg_watsonx.sh"
h_step         flink            "${DO_FLINK_ADDON}"                "flink addon full install (${_flink_note})" \
    "${SCRIPT_DIR}/install_confluent_platform_flink_addon/full_installprocess-confluent_flink.sh"
unset _flink_note

h_steps_plan
h_steps_run

echo ""
echo "[INFO] Confluent Platform full install complete."
