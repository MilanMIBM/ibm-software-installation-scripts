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
source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"
ir_dispatch "$@"
source "${_CP4D_REPO_ROOT}/src/helpers/confluent_helpers.sh"

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
# Or pick steps by name: --from <step> resumes there, --skip <step>[,...] leaves
# steps out, --list-steps shows the plan.
# ==============================================================================

# Operator mode (FLINK_OPERATOR_SOURCE olm|existing, contract 2.7 / 8 D21): --autoselect-latest and
# --persist are taken out of "$@" before the strict parse and handed to the steps through the
# environment; with the Helm Flink operator they stay in "$@" and are rejected as today. Every [BLOCKED]
# banner of the steps is collected in CFO_BANNER_FILE and repeated when the chain ends.
if cf_flink_is_olm; then
    source "${_CP4D_REPO_ROOT}/src/helpers/confluent_operator_helpers.sh"
    _cfo_args=()
    for _cfo_a in "$@"; do
        case "${_cfo_a}" in
            --autoselect-latest) export CFO_AUTOSELECT_LATEST=1 ;;
            --persist)           export CFO_AUTOSELECT_PERSIST=1 ;;
            *)                   _cfo_args+=("${_cfo_a}") ;;
        esac
    done
    set -- "${_cfo_args[@]}"
    unset _cfo_args _cfo_a
    if [[ -n "${CFO_AUTOSELECT_PERSIST:-}" && -z "${CFO_AUTOSELECT_LATEST:-}" ]]; then
        echo "[ERROR] --persist needs --autoselect-latest." >&2
        exit 1
    fi
    # CONTRACT-DEVIATION (2.7 passes the flags on without this check): the steps run as separate processes,
    # so a choice that is not saved reaches only the operator step,
    # and 1.1 would then install the pinned CMF chart next to a newer cp-fko (the CMF/FKO lock, plan O7).
    if [[ -n "${CFO_AUTOSELECT_LATEST:-}" && -z "${CFO_AUTOSELECT_PERSIST:-}" ]]; then
        echo "[ERROR] --autoselect-latest in the full installer needs --persist: the chosen cp-fko line and the" >&2
        echo "[ERROR] CMF chart that pairs with it must reach every step (they run as separate processes)." >&2
        echo "[ERROR] Report only: ./operator/1.0o_flink_operator_olm.sh --autoselect-latest --dry-run" >&2
        exit 1
    fi
    CFO_BANNER_FILE="$(mktemp "${TMPDIR:-/tmp}/cfo-banner.XXXXXX")" || CFO_BANNER_FILE=""
    export CFO_BANNER_FILE
    trap 'cfo_banner_replay; rm -f "${CFO_BANNER_FILE}"; (( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT
    H_STEPS_USAGE="Operator mode (FLINK_OPERATOR_SOURCE=$(cf_flink_operator_source)):
$(printf '  %-28s%s\n' "--autoselect-latest" "choose the newest compatible cp-fko line + CMF chart (new installs only; needs --persist)" \
    "--persist" "with --autoselect-latest: save the chosen versions to the vars file")"
fi

h_steps_parse --strict "$@"

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

echo "=============================================================================="
echo " Confluent Platform for Apache Flink full install - project '${PROJECT_CONFLUENT_FLINK}'"
echo "=============================================================================="
if cf_flink_is_olm; then
    echo "[INFO] CMF chart: ${FLINK_CMF_CHART_VERSION:-?}  Flink operator: cp-fko via OLM ($(cf_flink_operator_source), channel ${FLINK_OLM_CHANNEL:-derived from the CMF chart})"
else
    echo "[INFO] CMF chart: ${FLINK_CMF_CHART_VERSION:-?}  Operator chart: ${FLINK_OPERATOR_CHART_VERSION:-?}"
fi

# Operator mode: cp-fko (and, for CMF resources as CFK CRs, CFK) through OLM, first in the chain (contract
# 8 D20): its bundle creates the flink / flink-operator service accounts 1.0 relies on, and its guard stops
# the chain before 1.0 writes anything when the namespace holds a scripts-mode Flink install.
if cf_flink_is_olm; then
    DO_FLINK_OPERATOR="${DO_FLINK_OPERATOR:-true}"                 # 1.0o cp-fko through OLM
    h_step     operator         "${DO_FLINK_OPERATOR}"         "1.0o flink operator (cp-fko via OLM)" \
        "${SCRIPT_DIR}/operator/1.0o_flink_operator_olm.sh"
fi
# 1.1 runs with --no-status because 1.2 follows it; a failing status only warns.
h_step         prep             "${DO_FLINK_PREP}"             "1.0 flink prep" \
    "${SCRIPT_DIR}/1.0_flink_prep.sh"
h_step         install          "${DO_FLINK_INSTALL}"          "1.1 flink install" \
    "${SCRIPT_DIR}/1.1_flink_install.sh" --no-status
h_step --warn  status           "${DO_FLINK_STATUS}"           "1.2 flink status" \
    "${SCRIPT_DIR}/1.2_flink_status.sh"
h_step         instance-details "${DO_FLINK_INSTANCE_DETAILS}" "1.3 flink get instance details" \
    "${SCRIPT_DIR}/1.3_flink_get_instance_details.sh"

h_steps_plan
h_steps_run

echo ""
echo "[INFO] Confluent Platform for Apache Flink full install complete."
