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
Remove an instance from Control Center. The instance itself is not touched: Control
Center only stops tracking it.

  remove_instance.sh --url URL [--yes]

Options:
  --url URL  Web client URL of the instance, as list_control_center.sh shows it
  --yes      Do not ask for confirmation
USAGE
}

URL=""; YES=false
while (( $# )); do
    case "$1" in
        --url)     h_need_value "$1" "${2:-}"; URL="${2%/}"; shift 2 ;;
        --yes)     YES=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; h_die "Unknown option: $1" ;;
    esac
done
[[ -n "${URL}" ]] || { usage >&2; h_die "--url is required."; }

swhcc_api_login
swhcc_find_instance "${URL}" || h_die "${URL} is not registered."
INSTANCE_ID="${REPLY}"
if [[ "${YES}" != true ]]; then
    h_confirm "Remove ${URL} from Control Center?" || { h_info "Left as it is."; exit 0; }
fi
cpdapi DELETE "${SWHCC_PLATFORM}/namespaces/${INSTANCE_ID}"
swhcc_api_ok || h_die "Could not remove it ($(swhcc_api_error))."
h_info "Removed ${URL} from Control Center."
