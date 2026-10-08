#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b

# =============================================================================
# 5_create_cpd_project.sh
# -----------------------------------------------------------------------------
# Creates a Software Hub (Cloud Pak for Data) project, or reuses the one that
# already has this name, and adds members to it. The last line printed is
# PROJECT_ID=<id>, for scripts that chain on to this one.
#
#   - Auth    : CPD_URL + CPD_USERNAME + CPD_APIKEY (cpd_instance_details.sh),
#               unless --cpd-url / --username / --api-key are passed. That user
#               creates the project and is its owner.
#   - Members : --member <user>[:<role>], repeatable. Role is admin, editor or
#               viewer (default editor). Users must already exist in Software Hub.
#               Someone who is already a member keeps their current role.
#
# Only projects the authenticating user is a member of can be found by name;
# Software Hub hides the rest, even from administrators.
#
# Usage:
#   ./5_create_cpd_project.sh <project_name> [--description <text>] [--member <user>[:<role>]]...
#   --no-create   only add members; fail if the project doesn't exist
#
# Env vars (flags win): CPD_PROJECT_DESCRIPTION, CPD_PROJECT_MEMBERS (space-separated
# <user>[:<role>] entries, added to any --member flags)
# =============================================================================

PROJECT_NAME=""
DESCRIPTION="${CPD_PROJECT_DESCRIPTION:-}"
MEMBERS=(${=CPD_PROJECT_MEMBERS:-})
CREATE=true
API_URL=""
API_USER=""
API_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --description) DESCRIPTION="$2"; shift 2 ;;
    --member)      MEMBERS+=("$2"); shift 2 ;;
    --no-create)   CREATE=false; shift ;;
    --cpd-url)     API_URL="$2"; shift 2 ;;
    --username)    API_USER="$2"; shift 2 ;;
    --api-key)     API_KEY="$2"; shift 2 ;;
    -*) echo "[WARN] unknown argument: $1" >&2; shift ;;
    *)  PROJECT_NAME="$1"; shift ;;
  esac
done

if [[ -z "${PROJECT_NAME}" ]]; then
  echo "Usage: $(basename $0) <project_name> [--description <text>] [--member <user>[:<role>]]..." >&2
  exit 1
fi

for _m in "${MEMBERS[@]}"; do
  _role="${_m#*:}"; [[ "${_role}" == "${_m}" ]] && _role=editor
  if [[ "${_role}" != (admin|editor|viewer) ]]; then
    echo "[ERROR] Unknown role '${_role}' in '${_m}' (expected admin, editor or viewer)." >&2
    exit 1
  fi
done
unset _m _role

API_URL="${API_URL:-${CPD_URL:-}}"
API_USER="${API_USER:-${CPD_USERNAME:-}}"
API_KEY="${API_KEY:-${CPD_APIKEY:-}}"
if [[ -z "${API_URL}" || -z "${API_USER}" || -z "${API_KEY}" ]]; then
  echo "[ERROR] No CPD URL or credentials. Pass --cpd-url / --username / --api-key, or set" >&2
  echo "        CPD_URL / CPD_USERNAME / CPD_APIKEY in configs/cp4d_config/cpd_instance_details.sh." >&2
  exit 1
fi
CPD_BASE="${API_URL%/}"

# --- Authenticate against CPD ---
echo "[INFO] Authenticating to ${CPD_BASE} as ${API_USER}..."
TOKEN="$(curl -sk -X POST "${CPD_BASE}/icp4d-api/v1/authorize" \
  -H 'Content-Type: application/json' \
  -d "$(python3 -c 'import sys,json; print(json.dumps({"username": sys.argv[1], "api_key": sys.argv[2]}))' "${API_USER}" "${API_KEY}")" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))' 2>/dev/null || true)"
if [[ -z "${TOKEN}" ]]; then
  echo "[ERROR] Failed to get a bearer token from ${CPD_BASE}/icp4d-api/v1/authorize." >&2
  exit 1
fi

# api <method> <path> [json body] -> API_CODE, API_BODY
api() {
  local -a _args=(-sk -X "$1" -H "Authorization: Bearer ${TOKEN}" -H 'Accept: application/json' -w $'\n%{http_code}')
  (( $# >= 3 )) && _args+=(-H 'Content-Type: application/json' --data "$3")
  local _resp
  _resp="$(curl "${_args[@]}" "${CPD_BASE}$2" || true)"
  API_CODE="${_resp##*$'\n'}"
  API_BODY="${_resp%$'\n'*}"
}
urlencode() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

# --- Find or create the project ---
api GET "/v2/projects?name=$(urlencode "${PROJECT_NAME}")&limit=100"
if [[ "${API_CODE}" != 200 ]]; then
  echo "[ERROR] Listing projects failed (HTTP ${API_CODE}): ${API_BODY}" >&2
  exit 1
fi
# The name filter also matches partial names, so pick out exact matches.
MATCHES=("${(@f)$(python3 -c '
import sys, json
for r in json.loads(sys.argv[1]).get("resources", []):
    if r["entity"]["name"] == sys.argv[2]:
        print(r["metadata"]["guid"])
' "${API_BODY}" "${PROJECT_NAME}")}")
MATCHES=(${MATCHES:#})

if (( ${#MATCHES} > 1 )); then
  echo "[ERROR] ${#MATCHES} projects are named '${PROJECT_NAME}': ${MATCHES[*]}. Rename or delete the extras." >&2
  exit 1
elif (( ${#MATCHES} == 1 )); then
  PROJECT_ID="${MATCHES[1]}"
  echo "[INFO] Project '${PROJECT_NAME}' already exists, reusing it."
elif [[ "${CREATE}" != true ]]; then
  echo "[ERROR] No project named '${PROJECT_NAME}' that ${API_USER} is a member of." >&2
  exit 1
else
  echo "[INFO] Creating project '${PROJECT_NAME}'..."
  # storage.guid names the new project's file storage; any fresh UUID will do.
  api POST "/transactional/v2/projects" "$(python3 -c '
import sys, json, uuid
print(json.dumps({
    "name": sys.argv[1],
    "description": sys.argv[2],
    "generator": "ibm-software-installation-scripts",
    "public": False,
    "storage": {"type": "assetfiles", "guid": str(uuid.uuid4())},
}))' "${PROJECT_NAME}" "${DESCRIPTION}")"
  if [[ "${API_CODE}" != 201 ]]; then
    echo "[ERROR] Creating the project failed (HTTP ${API_CODE}): ${API_BODY}" >&2
    exit 1
  fi
  PROJECT_ID="$(python3 -c 'import sys,json; print(json.loads(sys.argv[1])["location"].rstrip("/").split("/")[-1])' "${API_BODY}")"
  # The project can take a moment to become readable after the create returns.
  for _i in {1..12}; do
    api GET "/v2/projects/${PROJECT_ID}"
    [[ "${API_CODE}" == 200 ]] && break
    sleep 5
  done
  if [[ "${API_CODE}" != 200 ]]; then
    echo "[ERROR] Project ${PROJECT_ID} was created but is not readable yet (HTTP ${API_CODE})." >&2
    exit 1
  fi
  unset _i
fi
echo "[INFO] Project id : ${PROJECT_ID}"

# --- Members ---
if (( ${#MEMBERS} > 0 )); then
  api GET "/v2/projects/${PROJECT_ID}/members"
  if [[ "${API_CODE}" != 200 ]]; then
    echo "[ERROR] Reading the project's members failed (HTTP ${API_CODE}): ${API_BODY}" >&2
    exit 1
  fi
  CURRENT_MEMBERS="${API_BODY}"

  for _m in "${MEMBERS[@]}"; do
    _user="${_m%%:*}"
    _role="${_m#*:}"; [[ "${_role}" == "${_m}" ]] && _role=editor
    _current="$(python3 -c '
import sys, json
for m in json.loads(sys.argv[1]).get("members", []):
    if m.get("user_name") == sys.argv[2]:
        print(m.get("role", "")); break
' "${CURRENT_MEMBERS}" "${_user}")"
    if [[ -n "${_current}" ]]; then
      echo "[INFO] '${_user}' is already a member (${_current}), left as is."
      continue
    fi

    # The members API takes any id without checking it, so look up the real one.
    api GET "/usermgmt/v1/user/$(urlencode "${_user}")"
    if [[ "${API_CODE}" != 200 ]]; then
      echo "[ERROR] '${_user}' is not a Software Hub user (HTTP ${API_CODE}); add them to Software Hub first." >&2
      exit 1
    fi
    _uid="$(python3 -c 'import sys,json; print(json.loads(sys.argv[1]).get("uid",""))' "${API_BODY}")"

    api POST "/v2/projects/${PROJECT_ID}/members" "$(python3 -c '
import sys, json
print(json.dumps({"members": [{"user_name": sys.argv[1], "id": sys.argv[2], "role": sys.argv[3],
                               "type": "user", "state": "ACTIVE"}]}))' "${_user}" "${_uid}" "${_role}")"
    if [[ "${API_CODE}" != 200 ]]; then
      echo "[ERROR] Adding '${_user}' as ${_role} failed (HTTP ${API_CODE}): ${API_BODY}" >&2
      exit 1
    fi
    echo "[INFO] Added '${_user}' as ${_role}."
  done
  unset _m _user _role _current _uid
fi

echo "PROJECT_ID=${PROJECT_ID}"
