#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/cpd_api_helpers.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"
ir_dispatch "$@"
# configs/cp4d_config/cpd_vars.sh sets its own SCRIPT_DIR, so keep this script's folder separately.
HERE="${0:A:h}"

# =============================================================================
# 5.x_full_streamsets_setup.sh
# -----------------------------------------------------------------------------
# Sets up StreamSets on Cloud Pak for Data end to end, so a fresh cluster needs
# no clicking in the UI:
#
#   1. Service ID the engines run as (SERVICE_ID), via
#      5.3_ensure_streamsets_service_id.sh: created and given an API key only
#      when configs/openshift_config/service_id_credentials.txt has no working
#      key for it. A working key is never rotated, and other service IDs are not touched.
#   2. Project (cp4d_general/5_create_cpd_project.sh), created and owned by
#      CPD_USERNAME, with the service ID as editor and PROJECT_ADMINS as admins.
#   3. StreamSets environment in it (5.0_create_streamsets_environment.sh), by
#      CPD_USERNAME: every stage library, ENGINE_CPUS per engine.
#   4. Engines on OpenShift (5.2_create_streamsets_engine.sh), registered as the
#      service ID so they don't depend on CPD_USERNAME's API key.
#
# Each step reuses what already exists, so re-running is safe. If the service
# ID's key was rotated, re-running moves the engines onto the new key.
#
# Usage:
#   ./5.x_full_streamsets_setup.sh [--project <name>] [--environment <name>] [--service-id <user>]
#                           [--admin <user>]... [--engine-version <id>] [--cpus <n>] [--replicas <n>]
#   --service-id ''   run the engines as CPD_USERNAME instead of a service ID
#
# Every setting below can also be set as an env var, e.g. in an optional
# configs/cp4d_config/streamsets_setup.sh (flags win).
# =============================================================================

# --- Edit these ---------------------------------------------------------------
PROJECT_NAME="${STREAMSETS_PROJECT_NAME:-data_platform}"
PROJECT_DESCRIPTION="${STREAMSETS_PROJECT_DESCRIPTION:-Shared data platform project. Created by 5.x_full_streamsets_setup.sh.}"
# Software Hub usernames added to the project as admins (CPD_USERNAME owns it already).
PROJECT_ADMINS=(${=STREAMSETS_PROJECT_ADMINS:-})
ENVIRONMENT_NAME="${STREAMSETS_ENVIRONMENT_NAME:-streamsets_environment}"
# Empty: the newest released Data Collector version.
ENGINE_VERSION="${STREAMSETS_ENGINE_VERSION:-}"
ENGINE_CPUS="${STREAMSETS_ENGINE_CPUS:-4}"
# Empty: keep the current number of engines (1 for a new deployment).
ENGINE_REPLICAS="${STREAMSETS_ENGINE_REPLICAS:-}"
# The engines' identity. Empty: CPD_USERNAME.
SERVICE_ID="${STREAMSETS_SERVICE_ID-svc-streamsets}"
# ------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)        PROJECT_NAME="$2"; shift 2 ;;
    --environment)    ENVIRONMENT_NAME="$2"; shift 2 ;;
    --service-id)     SERVICE_ID="$2"; shift 2 ;;
    --admin)          PROJECT_ADMINS+=("$2"); shift 2 ;;
    --engine-version) ENGINE_VERSION="$2"; shift 2 ;;
    --cpus)           ENGINE_CPUS="$2"; shift 2 ;;
    --replicas)       ENGINE_REPLICAS="$2"; shift 2 ;;
    *) echo "[ERROR] unknown argument: $1" >&2; exit 1 ;;
  esac
done

for var in CPD_URL CPD_USERNAME CPD_APIKEY; do
  if [[ -z "${(P)var:-}" ]]; then
    echo "[ERROR] ${var} is not set. Check configs/cp4d_config/cpd_instance_details.sh." >&2
    exit 1
  fi
done
CPD_BASE="${CPD_URL%/}"

step() { echo; echo "[INFO] ===== $* ====="; }
# Runs a script with its output shown (on stderr), and prints the value of its last <key>=<value> line.
run_and_capture() {
  local _key="$1"; shift
  local _out
  _out="$("$@" | tee /dev/stderr)"
  print -r -- "$(sed -n "s/^${_key}=//p" <<< "${_out}" | tail -n 1)"
}

# =============================================================================
# 1. Service ID
# =============================================================================
ENGINE_USER="${CPD_USERNAME}"
ENGINE_KEY="${CPD_APIKEY}"
if [[ -n "${SERVICE_ID}" ]]; then
  step "1/4 Service ID '${SERVICE_ID}'"
  ENGINE_KEY="$("${HERE}/5.3_ensure_streamsets_service_id.sh" "${SERVICE_ID}" --cpd-url "${CPD_BASE}" --print-key)"
  [[ -n "${ENGINE_KEY}" ]] || { echo "[ERROR] The service ID script printed no API key." >&2; exit 1; }
  ENGINE_USER="${SERVICE_ID}"
else
  step "1/4 Service ID: none, engines run as ${CPD_USERNAME}"
fi

# =============================================================================
# 2. Project
# =============================================================================
step "2/4 Project '${PROJECT_NAME}'"
_members=()
[[ -n "${SERVICE_ID}" ]] && _members+=(--member "${SERVICE_ID}:editor")
for _a in "${PROJECT_ADMINS[@]}"; do _members+=(--member "${_a}:admin"); done
PROJECT_ID="$(run_and_capture PROJECT_ID "${HERE}/../cp4d_general/5_create_cpd_project.sh" \
  "${PROJECT_NAME}" --description "${PROJECT_DESCRIPTION}" "${_members[@]}")"
[[ -n "${PROJECT_ID}" ]] || { echo "[ERROR] The project script printed no PROJECT_ID." >&2; exit 1; }
unset _members _a

# =============================================================================
# 3. StreamSets environment
# =============================================================================
step "3/4 StreamSets environment '${ENVIRONMENT_NAME}'"
_env_args=(--project "${PROJECT_ID}" --cpus "${ENGINE_CPUS}")
[[ -n "${ENGINE_VERSION}" ]] && _env_args+=(--engine-version "${ENGINE_VERSION}")
ENVIRONMENT_ID="$(run_and_capture ENVIRONMENT_ID "${HERE}/5.0_create_streamsets_environment.sh" \
  "${ENVIRONMENT_NAME}" "${_env_args[@]}")"
[[ -n "${ENVIRONMENT_ID}" ]] || { echo "[ERROR] The environment script printed no ENVIRONMENT_ID." >&2; exit 1; }
unset _env_args

# =============================================================================
# 4. Engines
# =============================================================================
step "4/4 Engines, running as ${ENGINE_USER}"
_engine_args=(--project-id "${PROJECT_ID}" --environment-id "${ENVIRONMENT_ID}")
[[ -n "${ENGINE_REPLICAS}" ]] && _engine_args+=(--replicas "${ENGINE_REPLICAS}")
# Passed as env vars rather than flags so the key doesn't show up in ps.
SSET_API_USER="${ENGINE_USER}" SSET_API_KEY="${ENGINE_KEY}" SSET_BASE_URL="${CPD_BASE}" \
  "${HERE}/5.2_create_streamsets_engine.sh" "${ENVIRONMENT_NAME}" "${_engine_args[@]}"
unset _engine_args

echo
echo "[INFO] StreamSets is set up:"
echo "[INFO]   Project     : ${PROJECT_NAME} (${PROJECT_ID})"
echo "[INFO]   Environment : ${ENVIRONMENT_NAME} (${ENVIRONMENT_ID})"
echo "[INFO]   Engines run as ${ENGINE_USER}"
