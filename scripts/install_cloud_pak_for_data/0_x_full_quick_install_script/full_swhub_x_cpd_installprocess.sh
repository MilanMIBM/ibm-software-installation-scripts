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

# This script lives in scripts/install_cloud_pak_for_data/0_x_full_quick_install_script/,
# so the numbered step folders are one level up, in scripts/install_cloud_pak_for_data/.
SCRIPTS_ROOT="$(cd "${CURRENT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Step toggles - set to true to run a step, false to skip it.
# Override any of these at runtime, e.g.:
#   DO_GLOBAL_PULL_SECRET=false ./full_swhub_x_cpd_installprocess.sh
# ---------------------------------------------------------------------------
# DO_PREP_CERT_MANAGER=${DO_PREP_CERT_MANAGER:-true}"                   # 0.0 set up openshift cert manager
# DO_GLOBAL_PULL_SECRET="${DO_GLOBAL_PULL_SECRET:-true}"                # 1.0 set up global pull credential
# DO_PRELIMINARY_SETUP="${DO_PRELIMINARY_SETUP:-true}"                  # 2.0 preliminary setup
# DO_PREREQUISITE_OPERATORS="${DO_PREREQUISITE_OPERATORS:-true}"        # 2.2 install prerequisite operators
# DO_INSTALL_SOFTWAREHUB="${DO_INSTALL_SOFTWAREHUB:-true}"              # 3.1 install software hub
# DO_INSTALL_CPD="${DO_INSTALL_CPD:-true}"                              # 4.0 install cpd components

DO_PREP_CERT_MANAGER=true                  # 0.0 set up openshift cert manager
DO_GLOBAL_PULL_SECRET=true                 # 1.0 set up global pull credential
DO_PRELIMINARY_SETUP=true                  # 2.0 preliminary setup
DO_PREREQUISITE_OPERATORS=true             # 2.2 install prerequisite operators
DO_INSTALL_SOFTWAREHUB=true                # 3.1 install software hub
DO_INSTALL_CPD=true                        # 4.0 install cpd components

run_step() {
    local enabled="$1"
    local label="$2"
    local script="$3"

    if [[ "${enabled}" != "true" ]]; then
        echo ""
        echo "==> Skipping: ${label}"
        return 0
    fi

    echo ""
    echo "==> Running:  ${label}"
    "${script}"
}

# --- Step 0.0 - Install & set up openshift cert manager -------------------------------
run_step "${DO_PREP_CERT_MANAGER}" \
    "0.3 set up openshift certmanager.sh" \
    "${SCRIPTS_ROOT}/1_global_pull_secret_and_certmanager/1.0_set_up_openshift_certmanager.sh"

# --- Step 1.0 - Set up global pull credential -------------------------------
run_step "${DO_GLOBAL_PULL_SECRET}" \
    "1.0 set up global pull credential" \
    "${SCRIPTS_ROOT}/1_global_pull_secret_and_certmanager/1.1_set_up_global_pull_credential.sh"

# --- Step 2.0 - Preliminary cluster setup -----------------------------------
run_step "${DO_PRELIMINARY_SETUP}" \
    "2.0 preliminary setup" \
    "${SCRIPTS_ROOT}/2_prepare_cluster/2.0-2.1_preliminary_setup/2.0_preliminary_setup.sh"

# --- Step 2.2 - Install prerequisite operators ------------------------------
run_step "${DO_PREREQUISITE_OPERATORS}" \
    "2.2 install prerequisite operators" \
    "${SCRIPTS_ROOT}/2_prepare_cluster/2.2_install_prerequisite_operators/2.2_install_prerequisite_operators.sh"

# --- Step 3.1 - Install IBM Software Hub -------------------------------------
run_step "${DO_INSTALL_SOFTWAREHUB}" \
    "3.1 install software hub" \
    "${SCRIPTS_ROOT}/3_install_softwarehub/3.1_full_step_3_installprocess-softwarehub.sh"

# --- Step 4.0 - Install CPD components ---------------------------------------
run_step "${DO_INSTALL_CPD}" \
    "4.0 install cpd components" \
    "${SCRIPTS_ROOT}/4_install_components/4.0_full_step_4_installprocess-cpd.sh"
