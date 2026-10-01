#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# =============================================================================
# watsonx.ai model gateway - model import
# -----------------------------------------------------------------------------
# Registers a model with the watsonx.ai model gateway in a CPD_VARS-based
# environment. The gateway exposes an OpenAI-compatible API and forwards
# inference to an upstream foundation-model provider. Importing a model is two
# REST calls against /ml/gateway:
#
#   1. Create (or reuse) a PROVIDER:  POST /ml/gateway/v1/providers/<type>
#   2. Add the MODEL to it:           POST /ml/gateway/v1/providers/<uuid>/models
#
# You can describe what to import in TWO ways:
#
#   A) INLINE  - fill in the variables in the "INLINE CONFIG" block below and run
#                the script with no arguments.
#   B) SPEC    - point at a model-spec YAML (like models/openai/gpt-4o.yaml) with:
#                   ./5_wxai_model_gateway_model_import.sh --spec models/openai/gpt-4o.yaml
#                Values present in the spec override the inline defaults; values
#                missing from the spec fall back to the inline defaults. This lets
#                you keep one script and many small per-model spec files.
#
# Credentials are read from the environment (sourced via cpd_vars.sh): set e.g.
#   export OPENAI_APIKEY="sk-..."
# and reference it inline/in-spec as ${OPENAI_APIKEY}. The CPD bearer token used
# to call the gateway is minted from CPD_URL / CPD_USERNAME / CPD_PASSWORD
# (written by 3.3.1_get_instance_creds.sh into cpd_instance_details.sh).
# =============================================================================

# =============================================================================
# INLINE CONFIG  (used when no --spec is given, or as fallback for spec gaps)
# =============================================================================

# --- Provider ----------------------------------------------------------------
# PROVIDER_TYPE selects the gateway endpoint + which credential args are valid:
#   openai | watsonxai | azure_openai | anthropic | bedrock | cerebras | nim | gemini
PROVIDER_TYPE="openai"
# Custom display name for the provider instance. Re-running with the same name
# reuses the existing provider (idempotent) instead of creating a duplicate.
PROVIDER_NAME="my-openai-provider"
PROVIDER_DESCRIPTION="Configured via the watsonx.ai model gateway import script"

# --- Provider credentials / arguments ----------------------------------------
# Fill in only the fields relevant to PROVIDER_TYPE (see the table below). Leave
# the rest empty. Values may be literals or ${ENV_VAR} references (expanded at
# runtime so secrets can stay in the environment, not in this file).
#
#   Provider       Required                                  Optional
#   -------------- ----------------------------------------- ----------------------------------
#   openai         apiKey                                    base_url
#   watsonxai      apiKey, (project_id OR space_id)          base_url, auth_url, api_version
#   azure_openai   apiKey, resource_name                     subscription_id, resource_group_name,
#                                                            account_name, api_version
#   anthropic      apiKey                                    -
#   bedrock        access_key_id, secret_access_key, region  -
#   cerebras       apiKey                                    -
#   nim            apiKey                                    -
#   gemini         apiKey                                    -

# Common single-key providers (openai/anthropic/cerebras/nim/gemini/watsonxai/azure):
APIKEY='${OPENAI_APIKEY}'

# OpenAI / watsonx.ai (optional):
BASE_URL=""

# watsonx.ai:
PROJECT_ID=""
SPACE_ID=""
AUTH_URL=""
API_VERSION=""

# Azure OpenAI:
RESOURCE_NAME=""
SUBSCRIPTION_ID=""
RESOURCE_GROUP_NAME=""
ACCOUNT_NAME=""

# AWS Bedrock:
ACCESS_KEY_ID=""
SECRET_ACCESS_KEY=""
REGION=""

# --- Model -------------------------------------------------------------------
# MODEL_ID: official provider-side model identifier (required).
# MODEL_ALIAS: friendly name clients use to call it (optional; defaults to id).
MODEL_ID="gpt-4o"
MODEL_ALIAS="gpt-4o"
MODEL_DESCRIPTION=""

# =============================================================================
# ARGUMENT PARSING  (--spec <file> selects the SPEC path)
# =============================================================================
SPEC_FILE=""
while (( $# > 0 )); do
  case "$1" in
    --spec) SPEC_FILE="${2:-}"; shift 2 ;;
    --spec=*) SPEC_FILE="${1#*=}"; shift ;;
    -h|--help)
      sed -n '14,52p' "$0"; exit 0 ;;
    *) echo "[ERROR] Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# --- yq-free YAML scalar reader (flat 'a.b.c' dotted paths, 2-space indent) ---
# Minimal extractor for the simple, fixed shape of our model-spec files. Returns
# the scalar at the given dotted path, or empty if absent. Strips inline quotes.
_yaml_get() {
  local file="$1" path="$2"
  awk -v target="$path" '
    function indent(s,  n){ n=0; while (substr(s,n+1,1)==" ") n++; return n }
    {
      raw=$0
      sub(/#.*$/,"",raw)                              # drop comments
      if (raw ~ /^[[:space:]]*$/) next
      ind=indent(raw)
      line=raw; sub(/^[[:space:]]+/,"",line); sub(/[[:space:]]+$/,"",line)
      if (line !~ /:/) next
      key=line; sub(/:.*/,"",key)
      val=line; sub(/^[^:]*:[[:space:]]*/,"",val)
      lvl=ind/2
      stack[lvl]=key
      # build dotted path for current depth
      p=stack[0]; for(i=1;i<=lvl;i++) p=p"."stack[i]
      if (p==target && val!="") {
        gsub(/^["'\'']|["'\'']$/,"",val)
        print val; exit
      }
    }' "$file"
}

if [[ -n "${SPEC_FILE}" ]]; then
  # Allow paths relative to the script dir.
  [[ -f "${SPEC_FILE}" ]] || SPEC_FILE="${CURRENT_DIR}/${SPEC_FILE}"
  if [[ ! -f "${SPEC_FILE}" ]]; then
    echo "[ERROR] Spec file not found: ${SPEC_FILE}" >&2; exit 1
  fi
  echo "[SPEC] loading ${SPEC_FILE}"
  _ov() { local v; v="$(_yaml_get "${SPEC_FILE}" "$1")"; [[ -n "$v" ]] && echo "$v"; }

  [[ -n "$(_ov provider.type)" ]]        && PROVIDER_TYPE="$(_ov provider.type)"
  [[ -n "$(_ov provider.name)" ]]        && PROVIDER_NAME="$(_ov provider.name)"
  [[ -n "$(_ov provider.description)" ]] && PROVIDER_DESCRIPTION="$(_ov provider.description)"

  [[ -n "$(_ov provider.data.apiKey)" ]]              && APIKEY="$(_ov provider.data.apiKey)"
  [[ -n "$(_ov provider.data.base_url)" ]]            && BASE_URL="$(_ov provider.data.base_url)"
  [[ -n "$(_ov provider.data.project_id)" ]]          && PROJECT_ID="$(_ov provider.data.project_id)"
  [[ -n "$(_ov provider.data.space_id)" ]]            && SPACE_ID="$(_ov provider.data.space_id)"
  [[ -n "$(_ov provider.data.auth_url)" ]]            && AUTH_URL="$(_ov provider.data.auth_url)"
  [[ -n "$(_ov provider.data.api_version)" ]]         && API_VERSION="$(_ov provider.data.api_version)"
  [[ -n "$(_ov provider.data.resource_name)" ]]       && RESOURCE_NAME="$(_ov provider.data.resource_name)"
  [[ -n "$(_ov provider.data.subscription_id)" ]]     && SUBSCRIPTION_ID="$(_ov provider.data.subscription_id)"
  [[ -n "$(_ov provider.data.resource_group_name)" ]] && RESOURCE_GROUP_NAME="$(_ov provider.data.resource_group_name)"
  [[ -n "$(_ov provider.data.account_name)" ]]        && ACCOUNT_NAME="$(_ov provider.data.account_name)"
  [[ -n "$(_ov provider.data.access_key_id)" ]]       && ACCESS_KEY_ID="$(_ov provider.data.access_key_id)"
  [[ -n "$(_ov provider.data.secret_access_key)" ]]   && SECRET_ACCESS_KEY="$(_ov provider.data.secret_access_key)"
  [[ -n "$(_ov provider.data.region)" ]]              && REGION="$(_ov provider.data.region)"

  [[ -n "$(_ov model.id)" ]]          && MODEL_ID="$(_ov model.id)"
  [[ -n "$(_ov model.alias)" ]]       && MODEL_ALIAS="$(_ov model.alias)"
  [[ -n "$(_ov model.description)" ]] && MODEL_DESCRIPTION="$(_ov model.description)"
fi

# --- Expand ${ENV_VAR} references in all credential/config values ------------
# 'eval echo' lets a value like '${OPENAI_APIKEY}' resolve against the sourced
# environment. Literal values pass through unchanged.
_expand() { eval "echo \"$1\""; }
APIKEY="$(_expand "${APIKEY}")"
BASE_URL="$(_expand "${BASE_URL}")"
PROJECT_ID="$(_expand "${PROJECT_ID}")"
SPACE_ID="$(_expand "${SPACE_ID}")"
AUTH_URL="$(_expand "${AUTH_URL}")"
API_VERSION="$(_expand "${API_VERSION}")"
RESOURCE_NAME="$(_expand "${RESOURCE_NAME}")"
SUBSCRIPTION_ID="$(_expand "${SUBSCRIPTION_ID}")"
RESOURCE_GROUP_NAME="$(_expand "${RESOURCE_GROUP_NAME}")"
ACCOUNT_NAME="$(_expand "${ACCOUNT_NAME}")"
ACCESS_KEY_ID="$(_expand "${ACCESS_KEY_ID}")"
SECRET_ACCESS_KEY="$(_expand "${SECRET_ACCESS_KEY}")"
REGION="$(_expand "${REGION}")"

[[ -z "${MODEL_ALIAS}" ]] && MODEL_ALIAS="${MODEL_ID}"

# =============================================================================
# VALIDATION
# =============================================================================
command -v jq >/dev/null 2>&1 || { echo "[ERROR] 'jq' is required but not found in PATH." >&2; exit 1; }

# Provider type must be one we know how to build a body for.
typeset -A _VALID_TYPES=(
  openai 1 watsonxai 1 azure_openai 1 anthropic 1 bedrock 1 cerebras 1 nim 1 gemini 1
)
if [[ -z "${_VALID_TYPES[${PROVIDER_TYPE}]:-}" ]]; then
  echo "[ERROR] Unsupported PROVIDER_TYPE '${PROVIDER_TYPE}'. Valid: ${(k)_VALID_TYPES}" >&2
  exit 1
fi
[[ -n "${PROVIDER_NAME}" ]] || { echo "[ERROR] PROVIDER_NAME is required." >&2; exit 1; }
[[ -n "${MODEL_ID}" ]]      || { echo "[ERROR] MODEL_ID is required." >&2; exit 1; }

# Build the provider 'data' JSON object and validate required args per type.
_missing() { echo "[ERROR] PROVIDER_TYPE '${PROVIDER_TYPE}' requires: $1" >&2; exit 1; }

case "${PROVIDER_TYPE}" in
  openai)
    [[ -n "${APIKEY}" ]] || _missing "apiKey"
    DATA_JSON="$(jq -n --arg k "${APIKEY}" --arg b "${BASE_URL}" \
      '{apikey:$k} + (if $b!="" then {base_url:$b} else {} end)')"
    ;;
  anthropic|cerebras|nim|gemini)
    [[ -n "${APIKEY}" ]] || _missing "apiKey"
    DATA_JSON="$(jq -n --arg k "${APIKEY}" '{apikey:$k}')"
    ;;
  watsonxai)
    [[ -n "${APIKEY}" ]] || _missing "apiKey"
    [[ -n "${PROJECT_ID}" || -n "${SPACE_ID}" ]] || _missing "project_id or space_id"
    DATA_JSON="$(jq -n \
      --arg k "${APIKEY}" --arg p "${PROJECT_ID}" --arg s "${SPACE_ID}" \
      --arg b "${BASE_URL}" --arg a "${AUTH_URL}" --arg v "${API_VERSION}" \
      '{apikey:$k}
        + (if $p!="" then {project_id:$p} else {} end)
        + (if $s!="" then {space_id:$s}   else {} end)
        + (if $b!="" then {base_url:$b}    else {} end)
        + (if $a!="" then {auth_url:$a}    else {} end)
        + (if $v!="" then {api_version:$v} else {} end)')"
    ;;
  azure_openai)
    [[ -n "${APIKEY}" ]]        || _missing "apiKey"
    [[ -n "${RESOURCE_NAME}" ]] || _missing "resource_name"
    DATA_JSON="$(jq -n \
      --arg k "${APIKEY}" --arg r "${RESOURCE_NAME}" --arg sub "${SUBSCRIPTION_ID}" \
      --arg rg "${RESOURCE_GROUP_NAME}" --arg ac "${ACCOUNT_NAME}" --arg v "${API_VERSION}" \
      '{apikey:$k, resource_name:$r}
        + (if $sub!="" then {subscription_id:$sub}      else {} end)
        + (if $rg!=""  then {resource_group_name:$rg}   else {} end)
        + (if $ac!=""  then {account_name:$ac}          else {} end)
        + (if $v!=""   then {api_version:$v}            else {} end)')"
    ;;
  bedrock)
    [[ -n "${ACCESS_KEY_ID}" ]]     || _missing "access_key_id"
    [[ -n "${SECRET_ACCESS_KEY}" ]] || _missing "secret_access_key"
    [[ -n "${REGION}" ]]            || _missing "region"
    DATA_JSON="$(jq -n \
      --arg a "${ACCESS_KEY_ID}" --arg s "${SECRET_ACCESS_KEY}" --arg r "${REGION}" \
      '{access_key_id:$a, secret_access_key:$s, region:$r}')"
    ;;
esac

# =============================================================================
# AUTH - mint a CPD bearer token to call the gateway
# =============================================================================
: "${CPD_URL:?CPD_URL not set - run 3.3.1_get_instance_creds.sh first}"
: "${CPD_USERNAME:?CPD_USERNAME not set - run 3.3.1_get_instance_creds.sh first}"
: "${CPD_PASSWORD:?CPD_PASSWORD not set - run 3.3.1_get_instance_creds.sh first}"

echo "[AUTH] requesting CPD bearer token from ${CPD_URL}"
TOKEN="$(curl -k -sS -X POST \
  "${CPD_URL}/icp4d-api/v1/authorize" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg u "${CPD_USERNAME}" --arg p "${CPD_PASSWORD}" '{username:$u, password:$p}')" \
  | jq -r '.token // empty')"

if [[ -z "${TOKEN}" ]]; then
  echo "[ERROR] Failed to retrieve CPD bearer token" >&2
  exit 1
fi

GW="${CPD_URL}/ml/gateway/v1"

# Small helper: show a truncated secret so the user can confirm without leaking.
_redact() {
  local s="$1"
  if [[ -z "$s" ]]; then echo "(empty)"
  elif (( ${#s} <= 8 )); then echo "**** (${#s} chars)"
  else echo "${s[1,4]}...${s[-4,-1]} (${#s} chars)"; fi
}
echo "[CONFIG] provider type : ${PROVIDER_TYPE}"
echo "[CONFIG] provider name : ${PROVIDER_NAME}"
echo "[CONFIG] model id      : ${MODEL_ID}"
echo "[CONFIG] model alias   : ${MODEL_ALIAS}"
[[ -n "${APIKEY}" ]] && echo "[CONFIG] apiKey        : $(_redact "${APIKEY}")"

# =============================================================================
# STEP 1 - create or reuse the provider
# =============================================================================
echo "[PROVIDER] searching for existing provider named '${PROVIDER_NAME}'..."
SEARCH="$(curl -k -sS -G "${GW}/providers/search" \
  -H "Authorization: Bearer ${TOKEN}" \
  --data-urlencode "name=${PROVIDER_NAME}")"

PROVIDER_UUID="$(echo "${SEARCH}" | jq -r --arg n "${PROVIDER_NAME}" \
  '.data // [] | map(select(.name==$n)) | (.[0].uuid // empty)')"

if [[ -n "${PROVIDER_UUID}" ]]; then
  echo "[PROVIDER] reusing existing provider uuid=${PROVIDER_UUID}"
else
  echo "[PROVIDER] creating new ${PROVIDER_TYPE} provider '${PROVIDER_NAME}'..."
  BODY="$(jq -n \
    --arg name "${PROVIDER_NAME}" \
    --arg desc "${PROVIDER_DESCRIPTION}" \
    --argjson data "${DATA_JSON}" \
    '{name:$name, data:$data} + (if $desc!="" then {description:$desc} else {} end)')"

  RESP="$(curl -k -sS -w $'\n%{http_code}' -X POST \
    "${GW}/providers/${PROVIDER_TYPE}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${BODY}")"
  HTTP="${RESP##*$'\n'}"; PAYLOAD="${RESP%$'\n'*}"

  if [[ "${HTTP}" != "201" ]]; then
    echo "[ERROR] provider creation failed (HTTP ${HTTP}):" >&2
    echo "${PAYLOAD}" | jq . 2>/dev/null >&2 || echo "${PAYLOAD}" >&2
    exit 1
  fi
  PROVIDER_UUID="$(echo "${PAYLOAD}" | jq -r '.uuid // empty')"
  [[ -n "${PROVIDER_UUID}" ]] || { echo "[ERROR] provider created but no uuid returned" >&2; exit 1; }
  echo "[PROVIDER] created uuid=${PROVIDER_UUID}"
fi

# =============================================================================
# STEP 2 - add the model to the provider (idempotent: skip/replace if present)
# =============================================================================
# Check whether a model with this alias (or id) already exists on the provider.
EXISTING_MODELS="$(curl -k -sS "${GW}/providers/${PROVIDER_UUID}/models" \
  -H "Authorization: Bearer ${TOKEN}")"
EXISTING_UUID="$(echo "${EXISTING_MODELS}" | jq -r \
  --arg id "${MODEL_ID}" --arg al "${MODEL_ALIAS}" \
  '(.data // []) | map(select(.id==$id or .alias==$al)) | (.[0].uuid // empty)')"

if [[ -n "${EXISTING_UUID}" ]]; then
  echo "[MODEL] '${MODEL_ALIAS}' already exists (uuid=${EXISTING_UUID}) - removing and re-adding"
  curl -k -sS -o /dev/null -X DELETE \
    "${GW}/providers/${PROVIDER_UUID}/models/${EXISTING_UUID}" \
    -H "Authorization: Bearer ${TOKEN}" || true
fi

echo "[MODEL] adding model id='${MODEL_ID}' alias='${MODEL_ALIAS}'..."
MODEL_BODY="$(jq -n \
  --arg id "${MODEL_ID}" --arg al "${MODEL_ALIAS}" --arg desc "${MODEL_DESCRIPTION}" \
  '{id:$id, alias:$al} + (if $desc!="" then {description:$desc} else {} end)')"

RESP="$(curl -k -sS -w $'\n%{http_code}' -X POST \
  "${GW}/providers/${PROVIDER_UUID}/models" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${MODEL_BODY}")"
HTTP="${RESP##*$'\n'}"; PAYLOAD="${RESP%$'\n'*}"

echo "----------------------------------------------------------------------"
if [[ "${HTTP}" == "201" ]]; then
  MODEL_UUID="$(echo "${PAYLOAD}" | jq -r '.uuid // empty')"
  OWNED_BY="$(echo "${PAYLOAD}"  | jq -r '.owned_by // empty')"
  echo "[SUCCESS] model imported"
  echo "          alias    : ${MODEL_ALIAS}"
  echo "          id       : ${MODEL_ID}"
  echo "          uuid     : ${MODEL_UUID}"
  echo "          owned_by : ${OWNED_BY}"
  echo "          provider : ${PROVIDER_NAME} (${PROVIDER_UUID})"
  echo "----------------------------------------------------------------------"
else
  echo "[FAILURE] model import failed (HTTP ${HTTP}):" >&2
  echo "${PAYLOAD}" | jq . 2>/dev/null >&2 || echo "${PAYLOAD}" >&2
  echo "----------------------------------------------------------------------"
  exit 1
fi
