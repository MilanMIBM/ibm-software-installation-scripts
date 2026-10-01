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

# This script lives in src/scripts/5_component_specific_scripts/wxo_custom_model_import/,
# so the numbered step folders are a couple of levels up, in src/scripts/.
SCRIPTS_ROOT="$(cd "${CURRENT_DIR}/../.." && pwd)"

# =============================================================================
# add_wxo_onprem_environment.sh
# -----------------------------------------------------------------------------
# Creates (and activates) a watsonx Orchestrate ADK environment pointing at the
# on-prem (Cloud Pak for Data) instance defined in cp4d_config/cpd_instance_details.sh.
#
#   - Endpoint (URL) : WXO_URL
#   - API key        : WXO_APIKEY (falls back to CPD_APIKEY)
#   - Username       : CPD_USERNAME
#
# Both WXO_URL and the api key are sourced automatically via env_bootstrap.sh,
# which sources cp4d_config/cpd_instance_details.sh.
#
# Optional overrides via environment / flags:
#   ENV_NAME            name to register the environment under (default: cpd-onprem)
#   --name <name>       same as ENV_NAME
#   --no-activate       add the environment but don't activate it
#   --secure            verify SSL (default is --insecure for self-signed certs)
# =============================================================================

# --- Defaults ---
# Prefer an explicit ENV_NAME, then any previously-persisted WXO_ENV_NAME
# (sourced from cpd_instance_details.sh), otherwise fall back to cpd-onprem.
ENV_NAME="${ENV_NAME:-${WXO_ENV_NAME:-cpd-onprem}}"
ACTIVATE=1
INSECURE=1

# --- Parse flags ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)        ENV_NAME="$2"; shift 2 ;;
    --no-activate) ACTIVATE=0; shift ;;
    --secure)      INSECURE=0; shift ;;
    *) echo "[WARN] unknown argument: $1" >&2; shift ;;
  esac
done

# --- Resolve required values ---
WXO_ENDPOINT="${WXO_URL:-}"
# Reuse a dedicated WXO key if set, otherwise fall back to the CPD api key.
WXO_KEY="${WXO_APIKEY:-${CPD_APIKEY:-}}"
WXO_USER="${CPD_USERNAME:-}"

if [[ -z "${WXO_ENDPOINT}" ]]; then
  echo "[ERROR] WXO_URL is not set. Check cp4d_config/cpd_instance_details.sh." >&2
  exit 1
fi
if [[ -z "${WXO_KEY}" ]]; then
  echo "[ERROR] No api key available (WXO_APIKEY / CPD_APIKEY). Check cp4d_config/cpd_instance_details.sh." >&2
  exit 1
fi
if [[ -z "${WXO_USER}" ]]; then
  echo "[ERROR] CPD_USERNAME is not set. Check cp4d_config/cpd_instance_details.sh." >&2
  exit 1
fi

echo "[ENV] name     : ${ENV_NAME}"
echo "[ENV] url      : ${WXO_ENDPOINT}"
echo "[ENV] username : ${WXO_USER}"
echo "[ENV] insecure : $([[ ${INSECURE} -eq 1 ]] && echo yes || echo no)"
echo "[ENV] activate : $([[ ${ACTIVATE} -eq 1 ]] && echo yes || echo no)"

# --- Build the `env add` command ---
# --type cpd marks this as an on-premises (Cloud Pak for Data) environment.
add_args=(env add -n "${ENV_NAME}" -u "${WXO_ENDPOINT}" -t cpd)
(( INSECURE == 1 )) && add_args+=(--insecure)

# If the environment already exists, remove it so we add a clean definition.
if orchestrate env list 2>/dev/null | grep -qw "${ENV_NAME}"; then
  echo "[ENV] '${ENV_NAME}' already exists - removing it before re-adding"
  orchestrate env remove -n "${ENV_NAME}" || true
fi

echo "[ENV] adding environment '${ENV_NAME}'"
orchestrate "${add_args[@]}"

# --- Persist the env name to cpd_instance_details.sh so later scripts can
#     activate the same environment (e.g. before importing models). ---
REPO_ROOT="$(cd "${CURRENT_DIR}" && while [[ "${PWD}" != "/" && ! -f pyproject.toml ]]; do cd ..; done && pwd)"
VARS_FILE="${REPO_ROOT}/cp4d_config/cpd_instance_details.sh"

if [[ -f "${VARS_FILE}" ]]; then
  # Drop any previous WXO_ENV_NAME export so re-runs don't pile up duplicates.
  if grep -q '^export WXO_ENV_NAME=' "${VARS_FILE}"; then
    _tmp="$(mktemp)"
    grep -v '^export WXO_ENV_NAME=' "${VARS_FILE}" > "${_tmp}"
    mv "${_tmp}" "${VARS_FILE}"
  fi
  WXO_ENV_BLOCK="
# Written by $(basename $0) on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
#--- watsonx Orchestrate ADK environment name (added via 'orchestrate env add')
export WXO_ENV_NAME=\"${ENV_NAME}\""
  echo "${WXO_ENV_BLOCK}" >> "${VARS_FILE}"
  echo "[INFO] WXO_ENV_NAME='${ENV_NAME}' written to ${VARS_FILE##*/}"
else
  echo "[WARN] ${VARS_FILE} not found; skipped persisting WXO_ENV_NAME" >&2
fi

# --- Activate (non-interactive) using on-prem username + api key ---
if (( ACTIVATE == 1 )); then
  echo "[ENV] activating '${ENV_NAME}' (auth expires after ~2h; re-run to refresh)"
  orchestrate env activate "${ENV_NAME}" --username "${WXO_USER}" --api-key "${WXO_KEY}"
  echo "[DONE] environment '${ENV_NAME}' added and activated"
else
  echo "[DONE] environment '${ENV_NAME}' added (not activated)"
fi
