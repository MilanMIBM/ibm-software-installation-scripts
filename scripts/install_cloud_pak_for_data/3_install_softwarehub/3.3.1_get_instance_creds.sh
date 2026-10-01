#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# (legacy hardcoded sourcing - replaced by universal crawl below)
# source "${SCRIPT_DIR}/../source_env_setup.sh"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# ---
eval "${CPDM_OC_LOGIN}"


CPD_INSTANCE_DETAILS="$(cpd-cli manage get-cpd-instance-details \
  --cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS} \
  --get_admin_initial_credentials=true)"

echo "${CPD_INSTANCE_DETAILS}"

CPD_URL="https://$(echo "${CPD_INSTANCE_DETAILS}" | grep 'CPD Url:'      | grep -oE '[^ ]+$' | tr -d '[:space:]')"
CPD_USERNAME="$(echo "${CPD_INSTANCE_DETAILS}"  | grep 'CPD Username:' | grep -oE '[^ ]+$' | tr -d '[:space:]')"
CPD_PASSWORD="$(echo "${CPD_INSTANCE_DETAILS}"  | grep 'CPD Password:' | grep -oE '[^ ]+$' | tr -d '[:space:]')"

REPO_ROOT="$(cd "${SCRIPT_DIR}" && while [[ ! -f pyproject.toml ]]; do cd ..; done && pwd)"
VARS_FILE="${REPO_ROOT}/cp4d_config/cpd_instance_details.sh"

cat > "${VARS_FILE}" <<EOF
# Written by $(basename $0) on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
export CPD_URL="${CPD_URL}"
export CPD_USERNAME="${CPD_USERNAME}"
export CPD_PASSWORD="${CPD_PASSWORD}"
EOF

echo "[INFO] Generating CPD bearer token..."
CPD_BEARER_TOKEN="$(curl -k -s -X POST \
  "${CPD_URL}/icp4d-api/v1/authorize" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${CPD_USERNAME}\",\"password\":\"${CPD_PASSWORD}\"}" \
  | tr ',' '\n' | grep '"token"' | grep -oE '"token":"[^"]+"' | cut -d'"' -f4 || true)"

if [[ -z "${CPD_BEARER_TOKEN}" ]]; then
  echo "[ERROR] Failed to retrieve CPD bearer token" >&2
  exit 1
fi

echo "[INFO] Generating CPD API key..."
CPD_APIKEY="$(curl -k -s -X GET \
  "${CPD_URL}/usermgmt/v1/user/apiKey" \
  -H "Authorization: Bearer ${CPD_BEARER_TOKEN}" \
  | tr ',' '\n' | grep '"apiKey"' | grep -oE '"apiKey":"[^"]+"' | cut -d'"' -f4 || true)"

if [[ -z "${CPD_APIKEY}" ]]; then
  echo "[ERROR] Failed to retrieve CPD API key" >&2
  exit 1
fi

echo "export CPD_APIKEY=\"${CPD_APIKEY}\"" >> "${VARS_FILE}"

# --- Optional: IBM License Service credentials ---
IBM_LICENSING_CREDENTIALS="${IBM_LICENSING_CREDENTIALS:-True}"

if [[ "${IBM_LICENSING_CREDENTIALS:l}" == "true" ]]; then
  LICENSING_NS="${PROJECT_LICENSE_SERVICE:-ibm-licensing}"
  echo "[INFO] Retrieving IBM License Service credentials from ${LICENSING_NS}..."

  IBM_LICENSING_TOKEN="$(oc get secret ibm-licensing-token -n "${LICENSING_NS}" \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)"

  IBM_LICENSING_SERVICE_INSTANCE="$(oc get route ibm-licensing-service-instance -n "${LICENSING_NS}" \
    -o jsonpath='{.spec.host}' 2>/dev/null || true)"

  if [[ -z "${IBM_LICENSING_TOKEN}" ]]; then
    echo "[WARN] Could not retrieve secret ibm-licensing-token in ${LICENSING_NS}" >&2
  fi
  if [[ -z "${IBM_LICENSING_SERVICE_INSTANCE}" ]]; then
    echo "[WARN] Could not retrieve route ibm-licensing-service-instance in ${LICENSING_NS}" >&2
  else
    IBM_LICENSING_SERVICE_INSTANCE="https://${IBM_LICENSING_SERVICE_INSTANCE}"
  fi

  cat >> "${VARS_FILE}" <<EOF
export IBM_LICENSING_TOKEN="${IBM_LICENSING_TOKEN}"
export IBM_LICENSING_SERVICE_INSTANCE="${IBM_LICENSING_SERVICE_INSTANCE}"
EOF
fi

echo "[INFO] CPD instance credentials written to ${VARS_FILE##*/}"