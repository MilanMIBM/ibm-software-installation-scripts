#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" >&2 || echo "[TIMER] $(basename $0) completed in ${SECONDS}s" >&2' EXIT

# With --print-key, stdout carries only the key: send everything else to stderr.
# Done before the env load, since it (and the configs it sources) can print.
PRINT_KEY=0
(( ${@[(Ie)--print-key]} )) && { PRINT_KEY=1; exec 3>&1 1>&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; REPO_ROOT="${_b}"; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/cpd_api_helpers.sh"

# =============================================================================
# 5.3_ensure_streamsets_service_id.sh
# -----------------------------------------------------------------------------
# Makes sure the service ID that StreamSets engines run as exists and has a
# working Software Hub API key in the credentials file. Step 1 of
# 5.x_full_streamsets_setup.sh, and runnable on its own.
#
#   - Saved key signs in : reused as is (a working key is never rotated, since
#                          rotating revokes the key the running engines use).
#   - No key / rejected  : the account is created (or its password reissued) with
#                          set_service_id_user_proxies.sh, and a new key generated
#                          with generate_service_id_cpd_apikeys.sh. Only this
#                          service ID is touched.
#   - Auth check         : CPD_URL (cpd_instance_details.sh), unless --cpd-url.
#   - Credentials file   : configs/openshift_config/service_id_credentials.txt,
#                          unless SERVICE_ID_CREDENTIALS_FILE is set.
#
# Usage:
#   ./5.3_ensure_streamsets_service_id.sh [<service_id>] [--cpd-url <url>] [--print-key]
#
#   <service_id>   default: STREAMSETS_SERVICE_ID, else svc-streamsets
#   --print-key    print only the API key on stdout (everything else goes to
#                  stderr), for handing it to another script, e.g. running the
#                  engines as the service ID:
#
#     SSET_API_USER=svc-streamsets \
#     SSET_API_KEY="$(./5.3_ensure_streamsets_service_id.sh svc-streamsets --print-key)" \
#       ./5.2_create_streamsets_engine.sh <environment_name> --replicas 3
#
# Without --print-key the last line printed is SERVICE_ID=<user>.
# =============================================================================

SERVICE_ID="${STREAMSETS_SERVICE_ID:-svc-streamsets}"
API_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cpd-url)   API_URL="$2"; shift 2 ;;
    --print-key) shift ;;
    -*) echo "[ERROR] unknown argument: $1" >&2; exit 1 ;;
    *)  SERVICE_ID="$1"; shift ;;
  esac
done

API_URL="${API_URL:-${CPD_URL:-}}"
if [[ -z "${API_URL}" ]]; then
  echo "[ERROR] No CPD URL. Pass --cpd-url, or set CPD_URL in configs/cp4d_config/cpd_instance_details.sh." >&2
  exit 1
fi
CPD_BASE="${API_URL%/}"

UTILS="${REPO_ROOT}/src/utilities/redhat_openshift_utils"
CREDENTIALS_FILE="${SERVICE_ID_CREDENTIALS_FILE:-${CONFIGS_ROOT:-${REPO_ROOT}/configs}/openshift_config/service_id_credentials.txt}"

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
  cpdapi_authorize "${CPD_BASE}" "$1" api_key "$2"
  [[ "${API_CODE}" == 200 ]] && return 0
  [[ "${API_CODE}" == 4* ]] && return 1
  return 2
}

echo "[INFO] Service ID '${SERVICE_ID}' on ${CPD_BASE}"
KEY="$(saved_key "${SERVICE_ID}")"
_status=1
if [[ -n "${KEY}" ]]; then
  key_works "${SERVICE_ID}" "${KEY}" && _status=0 || _status=$?
else
  # No key to try: probe sign-in anyway, so an unreachable Software Hub stops
  # here instead of after the account was created on the cluster.
  key_works "${SERVICE_ID}" "not-a-key" && _status=0 || _status=$?
  (( _status == 0 )) && _status=1
fi

if (( _status == 2 )); then
  echo "[ERROR] Could not check ${SERVICE_ID}'s key: ${CPD_BASE} is not answering sign-ins. Nothing was changed." >&2
  exit 1
elif (( _status == 0 )); then
  echo "[INFO] Using the saved API key for ${SERVICE_ID} (it signs in; not rotated)."
else
  if [[ -n "${KEY}" ]]; then
    echo "[WARN] The saved API key for ${SERVICE_ID} no longer signs in; generating a new one."
  fi
  if ! grep -q "^${SERVICE_ID}:" "${CREDENTIALS_FILE}" 2>/dev/null; then
    echo "[INFO] ${SERVICE_ID} has no saved password; creating it (or issuing a new password if it exists)."
    "${UTILS}/set_service_id_user_proxies.sh" "${SERVICE_ID}"
  fi
  # Named, so only this service ID's key is (re)generated. --cpd-url, so a URL
  # recorded in the file by a run against another cluster isn't used.
  if ! "${UTILS}/generate_service_id_cpd_apikeys.sh" -q --cpd-url "${CPD_BASE}" "${SERVICE_ID}"; then
    # Usually a 401: the saved password is from another cluster, or the user is
    # missing here. This creates the user or issues a new password if so.
    echo "[WARN] ${SERVICE_ID} could not sign in with its saved password; repairing the account and retrying."
    "${UTILS}/set_service_id_user_proxies.sh" "${SERVICE_ID}"
    "${UTILS}/generate_service_id_cpd_apikeys.sh" -q --cpd-url "${CPD_BASE}" "${SERVICE_ID}"
  fi
  KEY="$(saved_key "${SERVICE_ID}")"
  if [[ -z "${KEY}" ]] || ! key_works "${SERVICE_ID}" "${KEY}"; then
    echo "[ERROR] ${SERVICE_ID} still has no working API key in ${CREDENTIALS_FILE}." >&2
    exit 1
  fi
fi

echo "[INFO] ${SERVICE_ID} has a working API key in ${CREDENTIALS_FILE}."
if (( PRINT_KEY )); then
  print -r -- "${KEY}" >&3
else
  echo "SERVICE_ID=${SERVICE_ID}"
fi
