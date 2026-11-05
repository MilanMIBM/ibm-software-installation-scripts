#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/swhub_control_center_api_helpers.sh"

usage() {
    cat <<'USAGE'
Add one Software Hub instance to a Control Center account.

  register_instance.sh --url URL [--name NAME] [--account ACCOUNT]
                       [--username USER] [--api-key-env VAR]

Options:
  --url URL          Web client URL of the instance, https://cpd-<project>.apps.<domain>
  --name NAME        Display name (default: the project in the URL)
  --account ACCOUNT  Account name (default: CONTROL_AUTODETECT_ACCOUNT_NAME)
  --username USER    Instance user the key belongs to (default: CPD_USERNAME, else cpadmin)
  --api-key-env VAR  Environment variable holding that user's API key, so the key
                     stays out of the process list. Without it you are prompted, or
                     CPD_APIKEY is used when --url is the instance in cpd_vars.sh.

Control Center keeps using this key, so regenerating it later breaks monitoring.
USAGE
}

URL=""; NAME=""; ACCOUNT="${CONTROL_AUTODETECT_ACCOUNT_NAME:-}"; USERNAME_ARG=""; KEY_VAR=""
while (( $# )); do
    case "$1" in
        --url)         h_need_value "$1" "${2:-}"; URL="${2%/}"; shift 2 ;;
        --name)        h_need_value "$1" "${2:-}"; NAME="$2"; shift 2 ;;
        --account)     h_need_value "$1" "${2:-}"; ACCOUNT="$2"; shift 2 ;;
        --username)    h_need_value "$1" "${2:-}"; USERNAME_ARG="$2"; shift 2 ;;
        --api-key-env) h_need_value "$1" "${2:-}"; KEY_VAR="$2"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *) usage >&2; h_die "Unknown option: $1" ;;
    esac
done
[[ -n "${URL}" && "${URL}" == https://* ]] || { usage >&2; h_die "--url https://... is required."; }
[[ -n "${ACCOUNT}" ]] || h_die "--account is required (CONTROL_AUTODETECT_ACCOUNT_NAME is not set)."

[[ -f "${ENV_TARGET_FILE:h:h}/cpd_instance_details.sh" ]] && source "${ENV_TARGET_FILE:h:h}/cpd_instance_details.sh"
: "${NAME:=${${${URL#https://}%%.*}#cpd-}}"
USER_NAME="${USERNAME_ARG:-${CPD_USERNAME:-cpadmin}}"

API_KEY=""
if [[ -n "${KEY_VAR}" ]]; then
    API_KEY="${(P)KEY_VAR:-}"
    [[ -n "${API_KEY}" ]] || h_die "${KEY_VAR} is empty."
elif [[ "${URL}" == "${CPD_URL%/}" && -n "${CPD_APIKEY:-}" ]]; then
    API_KEY="${CPD_APIKEY}"
elif [[ -t 0 ]]; then
    read -rs "API_KEY?API key for ${USER_NAME} on ${URL}: "
    echo ""
fi
[[ -n "${API_KEY}" ]] || h_die "No API key: use --api-key-env VAR."

swhcc_api_login
swhcc_ensure_instance_rights
swhcc_find_account "${ACCOUNT}" || h_die "Account '${ACCOUNT}' not found. Create it with create_account.sh."
if swhcc_find_instance "${URL}"; then
    h_info "${URL} is already registered (ID ${REPLY})."
    exit 0
fi
swhcc_register_instance "${NAME}" "${URL}" "${USER_NAME}" "${API_KEY}" "${SWHCC_ACCOUNT_ID}"
h_info "Instance '${NAME}' added to account '${ACCOUNT}'."
