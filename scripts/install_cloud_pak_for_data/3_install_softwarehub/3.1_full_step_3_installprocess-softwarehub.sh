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
CURRENT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Run each step; a non-zero exit warns but does not abort the chain, so a
# benign "already installed" failure in one step still lets the rest proceed.
run_step() {
    local rc=0
    "$@" || rc=$?
    (( rc != 0 )) && echo "[WARN] $(basename "$1") exited ${rc}; continuing chain."
    return 0
}

run_step "${CURRENT_DIR}/3.2_set_up_cpd_admin.sh"
run_step "${CURRENT_DIR}/3.3_install_ibm_softwarehub.sh"
run_step "${CURRENT_DIR}/3.3.1_get_instance_creds.sh"
run_step "${CURRENT_DIR}/3.3.2_softwarehub_admission_controller.sh"
run_step "${CURRENT_DIR}/3.4_apply_entitlements.sh"

# Optional: create ccs-cr only when ccs is listed as a component. Exact match on
# the comma-separated list, so e.g. "ccs_foo" does not trigger it.
_components=",${SOFTWARE_HUB:-},${CPD_COMPONENTS:-},"
if [[ "${_components// /}" == *",ccs,"* ]]; then
    run_step "${CURRENT_DIR}/3.5_create_ccs_cr_if_missing.sh"
else
    echo "[INFO] ccs not in SOFTWARE_HUB or CPD_COMPONENTS; skipping 3.5_create_ccs_cr_if_missing.sh."
fi
unset _components
