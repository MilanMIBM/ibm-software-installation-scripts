#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# (legacy hardcoded sourcing - replaced by universal crawl below)
# source "${SCRIPT_DIR}/../source_env_setup.sh"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
CURRENT_DIR="$(cd "$(dirname "$0")" && pwd)"

# This script lives in src/scripts/x_full_quick_install_script/, so the numbered
# step folders are one level up, in src/scripts/.
SCRIPTS_ROOT="$(cd "${CURRENT_DIR}/.." && pwd)"

# --- Activate the watsonx Orchestrate environment before any orchestrate calls ---
# Use CURRENT_DIR (re-derived after env load): sourcing cpd_vars.sh clobbers SCRIPT_DIR.
"${CURRENT_DIR}/activate_wxo_environment.sh"

# ---
# Expand the real key from the environment (sourced via cpd_vars.sh -> ICA_APIKEY).
# NOTE: must be double-quoted/unquoted expansion - single quotes would store the
# literal string '${ICA_APIKEY}', which ICA rejects with "Invalid icaKey".
# May be empty for a personal/member connection (each user supplies their own).
APIKEY="${ICA_APIKEY:-}"

# --- Connection scope: team-wide vs personal/member ---
# true  -> '-t team'   : one shared credential set by the builder for all users.
# false -> '-t member' : each user supplies their own credential; the builder's
#                        value (even if empty) just seeds the api_key field so it
#                        is visible/known to the team.
TEAM_CONNECTION=true
if [[ "${TEAM_CONNECTION}" == true ]]; then
  CONN_TYPE=team
else
  CONN_TYPE=member
fi
echo "[CONN] scope: -t ${CONN_TYPE}"

# A team connection with no api_key would leave ICA with an "Invalid icaKey".
if [[ "${CONN_TYPE}" == team && -z "${APIKEY}" ]]; then
  echo "[ERROR] TEAM_CONNECTION=true but ICA_APIKEY is empty - check cp4d_config/cpd_vars.sh." >&2
  exit 1
fi

# --- Which connection environment(s) to configure credentials for ---
# Set both true to push credentials to draft and live; set one false to skip it.
DRAFT_CONFIG=true
LIVE_CONFIG=true

typeset -a CONFIG_ENVS
[[ "${DRAFT_CONFIG}" == true ]] && CONFIG_ENVS+=(draft)
[[ "${LIVE_CONFIG}" == true ]] && CONFIG_ENVS+=(live)
if (( ${#CONFIG_ENVS} == 0 )); then
  echo "[ERROR] Both DRAFT_CONFIG and LIVE_CONFIG are false - nothing to configure." >&2
  exit 1
fi
echo "[CONN] target env(s): ${CONFIG_ENVS[*]}"

# Show a truncated APIKEY so the user can confirm which value is in use without
# leaking the full secret to the terminal/logs.
_ak="${(e)APIKEY}"
if [[ -z "${_ak}" ]]; then
  echo "[APIKEY] (empty)"
elif (( ${#_ak} <= 8 )); then
  echo "[APIKEY] **** (${#_ak} chars)"
else
  echo "[APIKEY] ${_ak[1,4]}...${_ak[-4,-1]} (${#_ak} chars)"
fi
unset _ak

# Add the connection; if one with this app-id already exists, delete it and re-add.
if ! orchestrate connections add -a openai_credentials; then
  echo "[CONN] 'openai_credentials' already exists - removing and re-adding"
  orchestrate connections remove -a openai_credentials
  orchestrate connections add -a openai_credentials
fi
for _env in "${CONFIG_ENVS[@]}"; do
  orchestrate connections configure -a openai_credentials --env "${_env}" -k key_value -t "${CONN_TYPE}"
  # Always seed the api_key field so it exists in the connection - even when empty
  # (personal/member connections: teammates then see the field, just blank).
  orchestrate connections set-credentials -a openai_credentials --env "${_env}" -e "api_key=${APIKEY}"
done
MODEL_FILE="${CURRENT_DIR}/models/ica/claude-haiku-4-5.yaml"

# Import the model; if it already exists (409 conflict), remove it and re-import.
# The 'name:' field in the spec is e.g. 'openai/claude-haiku-4-5', but the model
# is registered (and must be removed) under the 'virtual-model/' prefix.
_model_name="$(awk -F': *' '/^name:/{print $2; exit}' "${MODEL_FILE}")"
_registered_name="virtual-model/${_model_name}"
_import_ok=0
if orchestrate models import --file "${MODEL_FILE}" --app-id openai_credentials; then
  _import_ok=1
else
  echo "[MODEL] import failed (likely already exists) - removing '${_registered_name}' and re-importing"
  orchestrate models remove -n "${_registered_name}" || true
  if orchestrate models import --file "${MODEL_FILE}" --app-id openai_credentials; then
    _import_ok=1
  fi
fi

echo "----------------------------------------------------------------------"
if (( _import_ok == 1 )); then
  echo "[SUCCESS] model '${_registered_name}' imported (connection 'openai_credentials', env(s): ${CONFIG_ENVS[*]})"
else
  echo "[FAILURE] model '${_registered_name}' could NOT be imported - see errors above" >&2
fi
echo "----------------------------------------------------------------------"
unset _model_name _registered_name
(( _import_ok == 1 )) || exit 1