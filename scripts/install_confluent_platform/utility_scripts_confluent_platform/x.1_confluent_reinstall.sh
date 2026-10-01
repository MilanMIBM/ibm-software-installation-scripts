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
# Confluent Platform - reinstall
# ------------------------------------------------------------------------------
# Tears the platform down and builds it back up:
#   x.0_confluent_uninstall.sh -> 1.0_confluent_prep.sh -> 1.1_confluent_install.sh
# then reports with 1.2_confluent_status.sh.
#
# This is the script to reach for after changing anything immutable in the
# broker StatefulSet - the image, log dirs, podManagementPolicy, securityContext
# - since `oc apply` cannot update those fields in place.
#
# DESTRUCTIVE: deletes all Kafka topic data unless --keep-data is passed.
#
# Usage:
#   ./x.1_confluent_reinstall.sh [--keep-data] [--keep-project] [--yes] [--no-status]
#
#   --keep-data      preserve the broker PVCs across the cycle. Only valid when
#                    CONFLUENT_CLUSTER_ID is unchanged, or the brokers will
#                    reject the on-disk KRaft metadata.
#   --keep-project   reuse the namespace instead of deleting and recreating it
#   --yes            skip the uninstall confirmation prompt
#   --no-status      skip the closing status report
#
# Every flag except --no-status is forwarded to the uninstall script.
# ==============================================================================

PASSTHRU=()
RUN_STATUS=true

for _arg in "$@"; do
    case "${_arg}" in
        --no-status)  RUN_STATUS=false ;;
        --keep-data|--keep-project|--yes|-y)
                      PASSTHRU+=("${_arg}") ;;
        --dry-run)
            echo "[ERROR] --dry-run is not meaningful here: it would tear nothing down" >&2
            echo "[ERROR] and then reinstall over a live platform. Run" >&2
            echo "[ERROR]   ./x.0_confluent_uninstall.sh --dry-run" >&2
            echo "[ERROR] directly to preview the deletion." >&2
            exit 1 ;;
        -h|--help)
            sed -n '19,40p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "[ERROR] Unknown argument '${_arg}'. Try --help." >&2
            exit 1 ;;
    esac
done

UNINSTALL="${SCRIPT_DIR}/x.0_confluent_uninstall.sh"
PREP="${SCRIPT_DIR}/1.0_confluent_prep.sh"
INSTALL="${SCRIPT_DIR}/1.1_confluent_install.sh"
STATUS="${SCRIPT_DIR}/1.2_confluent_status.sh"

for _s in "${UNINSTALL}" "${PREP}" "${INSTALL}"; do
    if [[ ! -f "${_s}" ]]; then
        echo "[ERROR] Required script not found: ${_s}" >&2
        exit 1
    fi
done

# Fail before tearing anything down if the config is unusable. Otherwise a bad
# variable leaves the platform deleted and the reinstall unable to proceed.
if [[ -z "${PROJECT_CONFLUENT_SERVER:-}" ]]; then
    echo "[ERROR] PROJECT_CONFLUENT_SERVER is not set - check cp4d_config/confluent_vars.sh." >&2
    exit 1
fi

echo "=============================================================================="
echo " Confluent Platform reinstall - project '${PROJECT_CONFLUENT_SERVER}'"
echo "=============================================================================="
echo "[INFO] Version: ${CONFLUENT_VERSION:-?}  Control Center: ${CONFLUENT_C3_VERSION:-?}"
echo ""

echo "------------------------------------------------------------------------------"
echo " Step 1/3: uninstall"
echo "------------------------------------------------------------------------------"
"${UNINSTALL}" "${PASSTHRU[@]}"

echo ""
echo "------------------------------------------------------------------------------"
echo " Step 2/3: prepare"
echo "------------------------------------------------------------------------------"
"${PREP}"

echo ""
echo "------------------------------------------------------------------------------"
echo " Step 3/3: install"
echo "------------------------------------------------------------------------------"
"${INSTALL}"

if [[ "${RUN_STATUS}" == "true" && -f "${STATUS}" ]]; then
    echo ""
    echo "------------------------------------------------------------------------------"
    echo " Status"
    echo "------------------------------------------------------------------------------"
    # Status exits non-zero when a component is not ready. That is information,
    # not a reinstall failure, so it must not trip `set -e` here.
    "${STATUS}" || echo "[WARN] Status reported one or more components not ready (see above)."
fi

echo ""
echo "[INFO] Reinstall complete."
