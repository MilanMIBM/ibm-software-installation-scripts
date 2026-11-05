#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

# Full Software Hub + CPD install, run as a chain of steps. Steps, in order
# (names for --from / --skip):
#   registry-config   private registry: configure the cluster (CPD_IMAGE_SOURCE private | local)
#   certmanager       1.0  Red Hat cert-manager operator
#   pull-secret       1.1  global pull credential
#   preliminary       2.0  preliminary cluster setup
#   prereq-operators  2.2  prerequisite operators
#   softwarehub       3.1  IBM Software Hub
#   cpd               4.0  CPD components
#   swhub-control-center-config  writes its vars file if there is none yet
#   swhub-control-center         optional sub-install, last, when cpd_vars.sh has
#                                INSTALL_SWHUB_CONTROL_CENTER="true"
# --from <step> resumes at a step, --skip leaves steps out, --list-steps shows
# the plan (h_steps_parse in src/helpers/common_helpers.sh). The DO_* toggles
# below still apply.

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# (legacy hardcoded sourcing - replaced by universal crawl below)
# source "${SCRIPT_DIR}/../source_env_setup.sh"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"
CURRENT_DIR="$(cd "$(dirname "$0")" && pwd)"

# This script lives in scripts/install_cloud_pak_for_data/0_x_full_quick_install_script/,
# so the numbered step folders are one level up, in scripts/install_cloud_pak_for_data/.
SCRIPTS_ROOT="$(cd "${CURRENT_DIR}/.." && pwd)"

h_steps_parse --strict "$@"

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

# Private registry (CPD_IMAGE_SOURCE private | local): configure the cluster for
# it first - pull secret, CA trust, image mirror sets (IBM's apply-icsp + ours),
# mirrored operator catalogs, and this install's registry_overrides.sh - with
# scripts/private_registry_mirroring/ (mirroring itself is not chained here: run
# that track's 0-2 segments first). auto = on when CPD_IMAGE_SOURCE is not
# entitled and the mirror config exists.
DO_REGISTRY_CLUSTER_CONFIG="${DO_REGISTRY_CLUSTER_CONFIG:-auto}"
if [[ "${DO_REGISTRY_CLUSTER_CONFIG}" == auto ]]; then
    if [[ "${CPD_IMAGE_SOURCE:-entitled}" != entitled && -f "${CONFIGS_ROOT}/registry_mirror_config/registry_mirror_vars.sh" ]]; then
        DO_REGISTRY_CLUSTER_CONFIG=true
    else
        DO_REGISTRY_CLUSTER_CONFIG=false
    fi
fi

h_step registry-config "${DO_REGISTRY_CLUSTER_CONFIG}" \
    "private registry: configure the cluster (scripts/private_registry_mirroring 3.x)" \
    "${SCRIPTS_ROOT}/../private_registry_mirroring/0_x_full_quick_mirror_script/full_registry_mirror_process.sh" \
    --cluster-only
h_step certmanager "${DO_PREP_CERT_MANAGER}" \
    "1.0 set up openshift certmanager" \
    "${SCRIPTS_ROOT}/1_global_pull_secret_and_certmanager/1.0_set_up_openshift_certmanager.sh"
h_step pull-secret "${DO_GLOBAL_PULL_SECRET}" \
    "1.1 set up global pull credential" \
    "${SCRIPTS_ROOT}/1_global_pull_secret_and_certmanager/1.1_set_up_global_pull_credential.sh"
h_step preliminary "${DO_PRELIMINARY_SETUP}" \
    "2.0 preliminary setup" \
    "${SCRIPTS_ROOT}/2_prepare_cluster/2.0-2.1_preliminary_setup/2.0_preliminary_setup.sh"
h_step prereq-operators "${DO_PREREQUISITE_OPERATORS}" \
    "2.2 install prerequisite operators" \
    "${SCRIPTS_ROOT}/2_prepare_cluster/2.2_install_prerequisite_operators/2.2_install_prerequisite_operators.sh"
h_step softwarehub "${DO_INSTALL_SOFTWAREHUB}" \
    "3.1 install software hub" \
    "${SCRIPTS_ROOT}/3_install_softwarehub/3.1_full_step_3_installprocess-softwarehub.sh"
h_step cpd "${DO_INSTALL_CPD}" \
    "4.0 install cpd components" \
    "${SCRIPTS_ROOT}/4_install_components/4.0_full_step_4_installprocess-cpd.sh"


# Optional Software Hub Control Center sub-install, once everything else is done.
# It runs in its own container and workspace, and a failure here only warns: the
# main install is already finished, and it can be re-run on its own.
DO_SWHUB_CONTROL_CENTER="${DO_SWHUB_CONTROL_CENTER:-${INSTALL_SWHUB_CONTROL_CENTER:-false}}"
SWHCC_DIR="${SCRIPTS_ROOT}/optional_install_swhub_control_center"
if [[ "${DO_SWHUB_CONTROL_CENTER}" == true && ! -f "${CONFIG_DIR}/swhub_control_center/swhub_control_center_vars.sh" ]]; then
    DO_SWHUB_CONTROL_CENTER_CONFIG=true
else
    DO_SWHUB_CONTROL_CENTER_CONFIG=false
fi
h_step --warn swhub-control-center-config "${DO_SWHUB_CONTROL_CENTER_CONFIG}" \
    "derive swhub_control_center_vars.sh from cpd_vars.sh" \
    "${SWHCC_DIR}/0_swhub_control_center_generate_config.sh" --from-cpd
h_step --warn swhub-control-center "${DO_SWHUB_CONTROL_CENTER}" \
    "optional Software Hub Control Center (INSTALL_SWHUB_CONTROL_CENTER in cpd_vars.sh)" \
    env ENV_TARGET=swhub_control_center "${SWHCC_DIR}/full_installprocess-swhub_control_center.sh"

h_steps_plan
h_steps_run
