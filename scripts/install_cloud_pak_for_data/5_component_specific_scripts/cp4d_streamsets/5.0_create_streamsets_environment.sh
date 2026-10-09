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
# 5.0_create_streamsets_environment.sh
# -----------------------------------------------------------------------------
# Creates a StreamSets (Data Collector) environment in a project, or reuses the
# one that already has this name. The last lines printed are PROJECT_ID=<id>
# and ENVIRONMENT_ID=<id>, for 5_create_streamsets_engine.sh.
#
# A new environment gets every stage library its engine version offers and 4
# CPUs per engine. The UI caps CPUs at 2, which is too few: engines stop
# answering within minutes of flow-editor use (see 5_create_streamsets_engine.sh).
# An existing environment is left as it is.
#
#   - Auth : CPD_URL + CPD_USERNAME + CPD_APIKEY (cpd_instance_details.sh),
#            unless --cpd-url / --username / --api-key are passed. That user
#            creates the environment and must be an editor or admin of the project.
#
# Usage:
#   ./5.0_create_streamsets_environment.sh <environment_name> --project <name|id> [options]
#
# Options:
#   --project <name|id>       project to create the environment in (required)
#   --engine-version <id>     e.g. JDK17_7.7.0 (default: newest released version)
#   --cpus <n>                CPUs per engine (default: 4)
#   --description <text>      environment description
#   --cpd-url / --username / --api-key   as in 5_create_streamsets_engine.sh
#
# Env vars (flags win): SSET_PROJECT, SSET_ENGINE_VERSION, SSET_ENV_CPUS
# =============================================================================

ENV_NAME=""
PROJECT="${SSET_PROJECT:-}"
ENGINE_VERSION="${SSET_ENGINE_VERSION:-}"
CPUS="${SSET_ENV_CPUS:-4}"
DESCRIPTION="Created by $(basename $0): every stage library for its engine version."
API_URL=""
API_USER=""
API_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)        PROJECT="$2"; shift 2 ;;
    --engine-version) ENGINE_VERSION="$2"; shift 2 ;;
    --cpus)           CPUS="$2"; shift 2 ;;
    --description)    DESCRIPTION="$2"; shift 2 ;;
    --cpd-url)        API_URL="$2"; shift 2 ;;
    --username)       API_USER="$2"; shift 2 ;;
    --api-key)        API_KEY="$2"; shift 2 ;;
    -*) echo "[WARN] unknown argument: $1" >&2; shift ;;
    *)  ENV_NAME="$1"; shift ;;
  esac
done

if [[ -z "${ENV_NAME}" || -z "${PROJECT}" ]]; then
  echo "Usage: $(basename $0) <environment_name> --project <name|id> [--engine-version <id>] [--cpus <n>]" >&2
  exit 1
fi

API_URL="${API_URL:-${CPD_URL:-}}"
API_USER="${API_USER:-${CPD_USERNAME:-}}"
API_KEY="${API_KEY:-${CPD_APIKEY:-}}"
if [[ -z "${API_URL}" || -z "${API_USER}" || -z "${API_KEY}" ]]; then
  echo "[ERROR] No CPD URL or credentials. Pass --cpd-url / --username / --api-key, or set" >&2
  echo "        CPD_URL / CPD_USERNAME / CPD_APIKEY in configs/cp4d_config/cpd_instance_details.sh." >&2
  exit 1
fi
CPD_BASE="${API_URL%/}"
EM="/sset/engine_manager"

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
api_ok() {
  if [[ "${API_CODE}" != 2* ]]; then
    echo "[ERROR] $1 failed (HTTP ${API_CODE}): ${API_BODY}" >&2
    exit 1
  fi
}
urlencode() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

# --- Resolve the project ---
if [[ "${PROJECT}" =~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' ]]; then
  PROJECT_ID="${PROJECT}"
  api GET "/v2/projects/${PROJECT_ID}"
  api_ok "Reading project ${PROJECT_ID}"
else
  api GET "/v2/projects?name=$(urlencode "${PROJECT}")&limit=100"
  api_ok "Listing projects"
  PROJECT_ID="$(python3 -c '
import sys, json
ids = [r["metadata"]["guid"] for r in json.loads(sys.argv[1]).get("resources", [])
       if r["entity"]["name"] == sys.argv[2]]
print(ids[0] if len(ids) == 1 else "")
' "${API_BODY}" "${PROJECT}")"
  if [[ -z "${PROJECT_ID}" ]]; then
    echo "[ERROR] No single project named '${PROJECT}' that ${API_USER} is a member of." >&2
    exit 1
  fi
fi
echo "[INFO] Project id     : ${PROJECT_ID}"

# --- Reuse an environment with this name ---
api GET "${EM}/v1/streamsets_environments?project_id=${PROJECT_ID}&limit=200"
api_ok "Listing StreamSets environments"
EXISTING="$(python3 -c '
import sys, json
for e in json.loads(sys.argv[1]).get("streamsets_environments", []):
    m = e.get("metadata", {})
    if m.get("name") == sys.argv[2]:
        s = e.get("entity", {}).get("streamsets_environment", {})
        print(m.get("asset_id", ""), s.get("engine_version", ""), s.get("cpus_to_allocate", ""), len(s.get("stage_libs", [])))
        break
' "${API_BODY}" "${ENV_NAME}")"

if [[ -n "${EXISTING}" ]]; then
  read -r ENVIRONMENT_ID _ver _cpus _libs <<< "${EXISTING}"
  echo "[INFO] Environment '${ENV_NAME}' already exists (${_ver}, ${_cpus} CPUs, ${_libs} stage libraries), reusing it as is."
  echo "PROJECT_ID=${PROJECT_ID}"
  echo "ENVIRONMENT_ID=${ENVIRONMENT_ID}"
  exit 0
fi

# --- Pick the engine version ---
api GET "${EM}/v2/streamsets_engine_versions/data_collector"
api_ok "Listing engine versions"
ENGINE_VERSION="$(python3 -c '
import sys, json, re
want = sys.argv[2]
usable = [v["engine_version_id"] for v in json.loads(sys.argv[1]).get("streamsets_engine_versions", [])
          if not v.get("disabled") and v.get("release", True)]
if want:
    print(want if want in usable else "")
elif usable:
    # Newest by the version after the last "_", e.g. JDK17_7.7.0 -> (7, 7, 0).
    print(max(usable, key=lambda i: [int(n) for n in re.findall(r"\d+", i.rsplit("_", 1)[-1])]))
' "${API_BODY}" "${ENGINE_VERSION}")"
if [[ -z "${ENGINE_VERSION}" ]]; then
  echo "[ERROR] Engine version not available (or none released). Available: $(python3 -c '
import sys, json
print(" ".join(v["engine_version_id"] for v in json.loads(sys.argv[1]).get("streamsets_engine_versions", []) if not v.get("disabled")))
' "${API_BODY}")" >&2
  exit 1
fi
echo "[INFO] Engine version : ${ENGINE_VERSION}"

api GET "${EM}/v2/streamsets_engine_versions/data_collector/${ENGINE_VERSION}"
api_ok "Reading engine version ${ENGINE_VERSION}"
VERSION_JSON="${API_BODY}"

api GET "${EM}/v1/streamsets_environments/defaults"
api_ok "Reading environment defaults"
DEFAULTS_JSON="${API_BODY}"

# --- Create it: the platform defaults, plus this version, all its libraries and the CPUs ---
BODY="$(python3 -c '
import sys, json
env = json.loads(sys.argv[1])
libs = [l["stage_lib_id"] for l in json.loads(sys.argv[2]).get("stage_libs", [])]
env.update(engine_type="data_collector", engine_version=sys.argv[3],
           stage_libs=libs, cpus_to_allocate=float(sys.argv[4]))
print(json.dumps({"name": sys.argv[5], "description": sys.argv[6], "streamsets_environment": env}))
' "${DEFAULTS_JSON}" "${VERSION_JSON}" "${ENGINE_VERSION}" "${CPUS}" "${ENV_NAME}" "${DESCRIPTION}")"

echo "[INFO] Creating environment '${ENV_NAME}' ($(python3 -c 'import sys,json; print(len(json.loads(sys.argv[1])["streamsets_environment"]["stage_libs"]))' "${BODY}") stage libraries, ${CPUS} CPUs)..."
api POST "${EM}/v1/streamsets_environments?project_id=${PROJECT_ID}" "${BODY}"
api_ok "Creating the environment"
ENVIRONMENT_ID="$(python3 -c 'import sys,json; print(json.loads(sys.argv[1])["metadata"]["asset_id"])' "${API_BODY}")"
echo "[INFO] Environment id : ${ENVIRONMENT_ID}"

echo "PROJECT_ID=${PROJECT_ID}"
echo "ENVIRONMENT_ID=${ENVIRONMENT_ID}"
