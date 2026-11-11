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
Debug workaround: add instances whose routes resolve to a private address.

Control Center refuses to register an instance when its URL resolves to a private IP
("Invalid instance URL: Access to private IP addresses is not allowed"). Inside a
bare-metal cluster, routes resolve to the private ingress address even when they are
public from outside. There is no setting for this, so the script briefly maps the
routes to their public IP on zen-core-api, registers the instances, and removes the
mapping. Unsupported by IBM. Registering again later needs it again.

  x_debug_register_private_route_instances.sh [--ip IP] [--check] [--remove] [--yes]

Each run restarts Control Center's API twice. The instances are not touched.

Options:
  --ip IP   Public IP for the routes (default: looked up from this workstation)
  --check   Show what each route resolves to, inside and out. Changes nothing.
  --remove  Only remove the mapping, for example after an interrupted run
  --yes     Do not ask for confirmation
USAGE
}

PUBLIC_IP=""; CHECK=false; REMOVE=false; YES=false
while (( $# )); do
    case "$1" in
        --ip)      h_need_value "$1" "${2:-}"; PUBLIC_IP="$2"; shift 2 ;;
        --check)   CHECK=true; shift ;;
        --remove)  REMOVE=true; shift ;;
        --yes)     YES=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; h_die "Unknown option: $1" ;;
    esac
done

# It needs this machine's view of the public IP, and asks before it changes
# anything; a runner pod has neither.
[[ -z "${IR_IN_RUNNER:-}" ]] \
    || h_die "This runs on a workstation only. After collect, run it locally: ${0:A:t}"

swhcc_oc_login
NS="${CONTROL_PROJECT_OPERANDS}"
DEPLOYMENT=zen-core-api
[[ "${CONTROL_CLUSTER_MODE}" == same ]] \
    || h_die "This is for a Control Center on the same cluster as its instances."

if [[ "${REMOVE}" == true ]]; then
    swhcc_remove_route_mapping
    exit 0
fi

# Routes of the Software Hub instances that were found on the cluster.
HOSTS=()
for line in "${(@f)$(swhcc_detect_instances)}"; do
    url="${line##*$'\t'}"
    [[ "${url}" == https://* ]] && HOSTS+=("${url#https://}")
done
(( ${#HOSTS} )) || h_die "No Software Hub instance routes found."

POD="$(oc get pods -n "${NS}" -o name --field-selector=status.phase=Running | grep "/${DEPLOYMENT}-" | head -1 || true)"
[[ -n "${POD}" ]] || h_die "No running ${DEPLOYMENT} pod in ${NS}. Is Control Center installed?"
for host in "${HOSTS[@]}"; do
    outside="$(dig +short "${host}" | tail -1)"
    inside="$(oc exec -n "${NS}" -c zen-core-api-container "${POD}" -- getent ahostsv4 "${host}" 2>/dev/null | awk 'NR==1 {print $1}')"
    h_info "${host}: outside ${outside:-unknown}, inside ${inside:-unknown}"
    : "${PUBLIC_IP:=${outside}}"
done
[[ "${CHECK}" == true ]] && exit 0

[[ -n "${PUBLIC_IP}" ]] || h_die "Could not look up a public IP. Use --ip."

if [[ "${YES}" != true ]]; then
    h_confirm "Map these routes to ${PUBLIC_IP} on ${DEPLOYMENT}, register, then remove it? This restarts Control Center's API twice." \
        || { h_info "Nothing changed."; exit 0; }
fi

swhcc_with_route_mapping "${PUBLIC_IP}" "${HOSTS[@]}" -- \
    "${_CP4D_REPO_ROOT}/src/utilities/softwarehub_utils/softwarehub_control_center/autodetect_instances.sh" \
    || h_die "Registering failed. The mapping has been removed."
h_info "Done. Metrics appear on the next zen-watchdog cycle, within 10 minutes."
