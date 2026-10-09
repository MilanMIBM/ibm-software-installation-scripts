#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; source "${_b}/env_bootstrap.sh"; unset _b
# configs/cp4d_config/cpd_vars.sh sets its own SCRIPT_DIR, so keep this script's folder separately.
HERE="${0:A:h}"

# =============================================================================
# 5_setup_streamsets.sh
# -----------------------------------------------------------------------------
# Sets up StreamSets on Cloud Pak for Data end to end, so a fresh cluster needs
# no clicking in the UI:
#
#   1. Service ID the engines run as (SERVICE_ID). Created with
#      set_service_id_user_proxies.sh and given an API key with
#      generate_service_id_cpd_apikeys.sh, but only when
#      configs/openshift_config/service_id_credentials.txt has no working key for
#      it. A working key is never rotated, and other service IDs are not touched.
#   2. Project (cp4d_general/5_create_cpd_project.sh), created and owned by
#      CPD_USERNAME, with the service ID as editor and PROJECT_ADMINS as admins.
#   3. StreamSets environment in it (5.0_create_streamsets_environment.sh), by
#      CPD_USERNAME: every stage library, ENGINE_CPUS per engine.
#   4. Engines on OpenShift (5_create_streamsets_engine.sh), registered as the
#      service ID so they don't depend on CPD_USERNAME's API key.
#
# Each step reuses what already exists, so re-running is safe. If the service
# ID's key was rotated, re-running moves the engines onto the new key.
#
# Usage:
#   ./5_setup_streamsets.sh [--project <name>] [--environment <name>] [--service-id <user>]
#                           [--admin <user>]... [--engine-version <id>] [--cpus <n>] [--replicas <n>]
#   --service-id ''   run the engines as CPD_USERNAME instead of a service ID
#
# Every setting below can also be set as an env var, e.g. in an optional
# configs/cp4d_config/streamsets_setup.sh (flags win).
# =============================================================================

# --- Edit these ---------------------------------------------------------------
PROJECT_NAME="${STREAMSETS_PROJECT_NAME:-data_platform}"
PROJECT_DESCRIPTION="${STREAMSETS_PROJECT_DESCRIPTION:-Shared data platform project. Created by 5_setup_streamsets.sh.}"
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

UTILS="${REPO_ROOT}/src/utilities/redhat_openshift_utils"
CREDENTIALS_FILE="${SERVICE_ID_CREDENTIALS_FILE:-${REPO_ROOT}/configs/openshift_config/service_id_credentials.txt}"

step() { echo; echo "[INFO] ===== $* ====="; }
# Runs a script with its output shown (on stderr), and prints the value of its last <key>=<value> line.
run_and_capture() {
  local _key="$1"; shift
  local _out
  _out="$("$@" | tee /dev/stderr)"
  print -r -- "$(sed -n "s/^${_key}=//p" <<< "${_out}" | tail -n 1)"
}

# The API key saved under a user in the credentials file (the last one, if several).
saved_key() {
  [[ -f "${CREDENTIALS_FILE}" ]] || return 0
  awk -v u="$1" '
    /^apikey=/   { if (mine) key = substr($0, 8); next }
    /^#/ || /^$/ { next }
    /:/          { mine = (substr($0, 1, index($0, ":") - 1) == u) }
    END          { if (key != "") print key }
  ' "${CREDENTIALS_FILE}"
}

# 0: the key signs in. 1: Software Hub rejected it. 2: couldn't tell (Software Hub unreachable or erroring).
key_works() {
  local _code
  _code="$(curl -sk -o /dev/null -w '%{http_code}' -X POST "${CPD_BASE}/icp4d-api/v1/authorize" \
    -H 'Content-Type: application/json' \
    -d "$(python3 -c 'import sys,json; print(json.dumps({"username": sys.argv[1], "api_key": sys.argv[2]}))' "$1" "$2")" || true)"
  [[ "${_code}" == 200 ]] && return 0
  [[ "${_code}" == 4* ]] && return 1
  return 2
}

# =============================================================================
# 1. Service ID
# =============================================================================
ENGINE_USER="${CPD_USERNAME}"
ENGINE_KEY="${CPD_APIKEY}"
if [[ -n "${SERVICE_ID}" ]]; then
  step "1/4 Service ID '${SERVICE_ID}'"
  ENGINE_KEY="$(saved_key "${SERVICE_ID}")"
  _status=1
  [[ -n "${ENGINE_KEY}" ]] && { key_works "${SERVICE_ID}" "${ENGINE_KEY}" && _status=0 || _status=$?; }

  if (( _status == 2 )); then
    echo "[ERROR] Could not check ${SERVICE_ID}'s key: ${CPD_BASE} is not answering sign-ins. Nothing was changed." >&2
    exit 1
  elif (( _status == 0 )); then
    echo "[INFO] Using the saved API key for ${SERVICE_ID} (it signs in; not rotated)."
  else
    if [[ -n "${ENGINE_KEY}" ]]; then
      echo "[WARN] The saved API key for ${SERVICE_ID} no longer signs in; generating a new one."
    fi
    if ! grep -q "^${SERVICE_ID}:" "${CREDENTIALS_FILE}" 2>/dev/null; then
      echo "[INFO] ${SERVICE_ID} has no saved password; creating it (or issuing a new password if it exists)."
      "${UTILS}/set_service_id_user_proxies.sh" "${SERVICE_ID}"
    fi
    # Named, so only this service ID's key is (re)generated.
    "${UTILS}/generate_service_id_cpd_apikeys.sh" -q "${SERVICE_ID}"
    ENGINE_KEY="$(saved_key "${SERVICE_ID}")"
    if [[ -z "${ENGINE_KEY}" ]] || ! key_works "${SERVICE_ID}" "${ENGINE_KEY}"; then
      echo "[ERROR] ${SERVICE_ID} still has no working API key in ${CREDENTIALS_FILE}." >&2
      exit 1
    fi
  fi
  ENGINE_USER="${SERVICE_ID}"
  unset _status
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
  "${HERE}/5_create_streamsets_engine.sh" "${ENVIRONMENT_NAME}" "${_engine_args[@]}"
unset _engine_args

echo
echo "[INFO] StreamSets is set up:"
echo "[INFO]   Project     : ${PROJECT_NAME} (${PROJECT_ID})"
echo "[INFO]   Environment : ${ENVIRONMENT_NAME} (${ENVIRONMENT_ID})"
echo "[INFO]   Engines run as ${ENGINE_USER}"
