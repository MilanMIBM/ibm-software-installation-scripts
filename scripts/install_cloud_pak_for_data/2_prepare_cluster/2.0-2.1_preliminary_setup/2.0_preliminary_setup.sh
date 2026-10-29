#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# (legacy hardcoded sourcing - replaced by universal crawl below)
# source "${SCRIPT_DIR}/../../source_env_setup.sh"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"
CURRENT_DIR="$(cd "$(dirname "$0")" && pwd)"

h_steps_parse --strict "$@"
h_step projects           true "2.0.1 preliminary project setup"       "${CURRENT_DIR}/2.0.1_preliminary_project_setup.sh"
h_step case-download      true "2.0.2 cluster component CASE download" "${CURRENT_DIR}/2.0.2_cluster_component_case_download.sh"
h_step cluster-components true "2.1 apply shared cluster CASE packages" "${CURRENT_DIR}/2.1_apply_shared_cluster_CASE_packages.sh"
h_steps_plan
h_steps_run
