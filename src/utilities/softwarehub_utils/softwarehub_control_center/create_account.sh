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
Create a Control Center account on the registered cluster, or add that cluster to an
existing one. Accounts split cluster resources between groups, and an instance has
to belong to one. The signed-in user becomes its administrator.

  create_account.sh --name NAME [--cpu CORES] [--memory-gi GI] [--gpu N] [--description TEXT]

Options:
  --name NAME         Account name
  --cpu CORES         vCPU to allocate (default: all worker allocatable capacity)
  --memory-gi GI      Memory to allocate (default: all worker allocatable capacity)
  --gpu N             GPUs to allocate (default: 0)
  --description TEXT  Description

Needs a verified cluster: run register_cluster.sh first.
USAGE
}

NAME=""; CPU=""; MEMORY=""; GPU=0; DESCRIPTION=""
while (( $# )); do
    case "$1" in
        --name)        h_need_value "$1" "${2:-}"; NAME="$2"; shift 2 ;;
        --cpu)         h_need_value "$1" "${2:-}"; CPU="$2"; shift 2 ;;
        --memory-gi)   h_need_value "$1" "${2:-}"; MEMORY="$2"; shift 2 ;;
        --gpu)         h_need_value "$1" "${2:-}"; GPU="$2"; shift 2 ;;
        --description) h_need_value "$1" "${2:-}"; DESCRIPTION="$2"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *) usage >&2; h_die "Unknown option: $1" ;;
    esac
done
[[ -n "${NAME}" ]] || { usage >&2; h_die "--name is required."; }

eval "${OC_LOGIN:-${CONTROL_OC_LOGIN}}"
swhcc_api_login
swhcc_cluster_facts
swhcc_cluster_verified || h_die "${SWHCC_API_ENDPOINT} is not a verified cluster yet. Run register_cluster.sh first."

if [[ -z "${CPU}" || -z "${MEMORY}" ]]; then
    swhcc_worker_capacity
    : "${CPU:=${SWHCC_CPU}}"
    : "${MEMORY:=${SWHCC_MEMORY_GI}}"
fi
swhcc_ensure_account "${NAME}" "${DESCRIPTION}" "${SWHCC_CLUSTER_ID}" "${CPU}" "${MEMORY}" "${GPU}"
h_info "Account '${NAME}' is ready (ID ${SWHCC_ACCOUNT_ID})."
