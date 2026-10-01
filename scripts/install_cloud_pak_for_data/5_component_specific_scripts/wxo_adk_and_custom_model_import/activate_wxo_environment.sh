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
# activate_wxo_environment.sh
# -----------------------------------------------------------------------------
# Activates the watsonx Orchestrate ADK environment named by WXO_ENV_NAME
# (persisted in cp4d_config/cpd_instance_details.sh by add_wxo_onprem_environment.sh).
#
# On-prem (CPD) activation is non-interactive using:
#   - Username : CPD_USERNAME
#   - API key  : WXO_APIKEY (falls back to CPD_APIKEY)
#
# Note: on-prem auth expires after ~2h, so this is safe (and intended) to run
# again before any batch of orchestrate commands.
#
# Optional override:
#   ENV_NAME / --name <name>   activate a specific environment instead of WXO_ENV_NAME
# =============================================================================

# --- Resolve environment name (CLI flag > ENV_NAME > persisted WXO_ENV_NAME) ---
ENV_NAME="${ENV_NAME:-${WXO_ENV_NAME:-}}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) ENV_NAME="$2"; shift 2 ;;
    *) echo "[WARN] unknown argument: $1" >&2; shift ;;
  esac
done

if [[ -z "${ENV_NAME}" ]]; then
  echo "[ERROR] WXO_ENV_NAME is not set. Run add_wxo_onprem_environment.sh first," >&2
  echo "        or pass --name <environment-name>." >&2
  exit 1
fi

WXO_KEY="${WXO_APIKEY:-${CPD_APIKEY:-}}"
WXO_USER="${CPD_USERNAME:-}"

if [[ -z "${WXO_KEY}" ]]; then
  echo "[ERROR] No api key available (WXO_APIKEY / CPD_APIKEY). Check cp4d_config/cpd_instance_details.sh." >&2
  exit 1
fi
if [[ -z "${WXO_USER}" ]]; then
  echo "[ERROR] CPD_USERNAME is not set. Check cp4d_config/cpd_instance_details.sh." >&2
  exit 1
fi

echo "[ENV] activating '${ENV_NAME}' (on-prem auth expires after ~2h)"
orchestrate env activate "${ENV_NAME}" --username "${WXO_USER}" --api-key "${WXO_KEY}"
echo "[DONE] environment '${ENV_NAME}' activated"
