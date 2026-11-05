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
Show what Control Center knows: clusters, accounts and instances. Changes nothing.

  list_control_center.sh
USAGE
}
[[ "${1:-}" == (-h|--help) ]] && { usage; exit 0; }

swhcc_api_login

echo "Clusters:"
cpdapi GET "${SWHCC_PLATFORM}/clusters?include_unverified=true&include_resource_group_info=true"
swhcc_api_ok || h_die "Could not list clusters ($(swhcc_api_error))."
print -r -- "${API_BODY}" | jq -r '.clusters[]?
    | "  \(.cluster_name)  \(.verification_status // "?")  \(.cluster_connection.api_endpoint // "?")  accounts: \([.resource_groups[]?.resource_group_name] | join(", "))"'

echo "Accounts:"
cpdapi GET "${SWHCC_PLATFORM}/resource_groups?include_clusters=true"
swhcc_api_ok || h_die "Could not list accounts ($(swhcc_api_error))."
print -r -- "${API_BODY}" | jq -r '.resource_groups[]?
    | "  \(.resource_group_name)  clusters: \([.clusters[]?.cluster_name] | join(", "))"'

echo "Instances:"
cpdapi GET "${SWHCC_PLATFORM}/namespaces?limit=1000"
swhcc_api_ok || h_die "Could not list instances ($(swhcc_api_error))."
print -r -- "${API_BODY}" | jq -r '.namespaces[]?
    | "  \(.namespace_name)  \(.instance_connection.url // "?")  account: \(.resource_group_id // "?")"'
