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
Register the cluster where Software Hub runs with Control Center, or re-authenticate
it. Needs the OAuth client from 1.4_swhub_control_center_oauth_client.sh.

  register_cluster.sh [--name NAME] [--description TEXT] [--wait SECONDS]

Options:
  --name NAME         Display name (default: CONTROL_CLUSTER_DISPLAY_NAME, else the
                      name in the API address)
  --description TEXT  Description
  --wait SECONDS      How long to wait if it falls back to a browser (default:
                      CONTROL_AUTODETECT_VERIFY_WAIT_SECONDS, else 600; 0 only prints it)
  --reauthenticate    Refresh a registered cluster's capacity. IBM asks for this when
                      nodes are added or removed, and periodically without the
                      privileged monitoring service.

This runs with no browser, using the cluster username and password in the config. A
token-only login falls back to printing a page to approve.
USAGE
}

DESCRIPTION=""
WAIT="${CONTROL_AUTODETECT_VERIFY_WAIT_SECONDS:-600}"
REAUTH=false
while (( $# )); do
    case "$1" in
        --name)           h_need_value "$1" "${2:-}"; CONTROL_CLUSTER_DISPLAY_NAME="$2"; shift 2 ;;
        --description)    h_need_value "$1" "${2:-}"; DESCRIPTION="$2"; shift 2 ;;
        --wait)           h_need_value "$1" "${2:-}"; WAIT="$2"; shift 2 ;;
        --reauthenticate) REAUTH=true; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) usage >&2; h_die "Unknown option: $1" ;;
    esac
done

eval "${OC_LOGIN:-${CONTROL_OC_LOGIN}}"
swhcc_api_login
swhcc_cluster_facts

if [[ "${REAUTH}" == true ]]; then
    swhcc_find_cluster "${SWHCC_API_ENDPOINT}" || h_die "${SWHCC_API_ENDPOINT} is not registered yet."
    swhcc_cluster_auto_verify "${SWHCC_CLUSTER_ID}" && exit 0
    swhcc_cluster_oauth_url "${SWHCC_CLUSTER_ID}"
    h_info "Sign in to ${CONTROL_CENTER_URL}, then open this in the same browser:"
    h_info "  ${REPLY}"
    exit 1
fi

swhcc_ensure_cluster "${DESCRIPTION}"
if ! swhcc_wait_cluster_verified "${WAIT}"; then
    h_warn "Cluster '${SWHCC_CLUSTER_NAME}' is registered but not verified yet."
    exit 1
fi
h_info "Cluster '${SWHCC_CLUSTER_NAME}' is registered and verified (ID ${SWHCC_CLUSTER_ID})."
