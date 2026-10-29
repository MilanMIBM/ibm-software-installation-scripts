#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

# Full Software Hub + CPD install, run as a chain of steps.
#
# Steps, in order (names for --from / --skip):
#   registry-config   private registry: configure the cluster (CPD_IMAGE_SOURCE private | local)
#   certmanager       1.0  Red Hat cert-manager operator
#   pull-secret       1.1  global pull credential
#   preliminary       2.0  preliminary cluster setup
#   prereq-operators  2.2  prerequisite operators
#   softwarehub       3.1  IBM Software Hub
#   cpd               4.0  CPD components
#
#   full_swhub_x_cpd_installprocess.sh [options]
#     --from <step>               start at this step, e.g. to resume after a failure
#     --skip <step>[,<step>...]   leave these steps out (repeatable)
#     --list-steps                print the steps and whether this run would run them, then exit
#     -h, --help
# The DO_* toggles below still apply: a step runs only when its toggle is on
# and --from / --skip select it.

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

STEPS=(registry-config certmanager pull-secret preliminary prereq-operators softwarehub cpd)

usage() {
    sed -n '/^# Full Software Hub/,/^# and --from/p' "${CURRENT_DIR}/${ZSH_ARGZERO:t}" | sed 's/^# \{0,1\}//'
}

SKIP_STEPS=()
FROM_STEP=""
LIST_STEPS=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --from)       FROM_STEP="${2:?--from needs a step name}"; shift 2 ;;
        --from=*)     FROM_STEP="${1#--from=}"; shift ;;
        --skip)       SKIP_STEPS+=(${(s:,:)${2:?--skip needs step names}}); shift 2 ;;
        --skip=*)     SKIP_STEPS+=(${(s:,:)${1#--skip=}}); shift ;;
        --list-steps) LIST_STEPS=true; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            echo "[ERROR] Unknown option: $1 (see --help)" >&2; exit 1 ;;
    esac
done
for _s in "${SKIP_STEPS[@]}" ${FROM_STEP:+"${FROM_STEP}"}; do
    if (( ! ${STEPS[(Ie)${_s}]} )); then
        echo "[ERROR] Unknown step '${_s}'. Steps: ${STEPS[*]}" >&2
        exit 1
    fi
done
FROM_IDX=1
[[ -n "${FROM_STEP}" ]] && FROM_IDX=${STEPS[(Ie)${FROM_STEP}]}
step_selected() {
    local i=${STEPS[(Ie)$1]}
    (( i >= FROM_IDX && ! ${SKIP_STEPS[(Ie)$1]} ))
}

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

# A step runs when its DO_* toggle is on and --from / --skip select it.
typeset -A STEP_TOGGLE STEP_INFO
STEP_TOGGLE=(
    registry-config  "${DO_REGISTRY_CLUSTER_CONFIG}"
    certmanager      "${DO_PREP_CERT_MANAGER}"
    pull-secret      "${DO_GLOBAL_PULL_SECRET}"
    preliminary      "${DO_PRELIMINARY_SETUP}"
    prereq-operators "${DO_PREREQUISITE_OPERATORS}"
    softwarehub      "${DO_INSTALL_SOFTWAREHUB}"
    cpd              "${DO_INSTALL_CPD}"
)
STEP_INFO=(
    registry-config  "private registry: configure the cluster"
    certmanager      "1.0 Red Hat cert-manager operator"
    pull-secret      "1.1 global pull credential"
    preliminary      "2.0 preliminary cluster setup"
    prereq-operators "2.2 prerequisite operators"
    softwarehub      "3.1 IBM Software Hub"
    cpd              "4.0 CPD components"
)
step_on() {
    [[ "${STEP_TOGGLE[$1]}" == "true" ]] && step_selected "$1" && echo true || echo false
}

echo "[INFO] Steps:"
for _s in "${STEPS[@]}"; do
    if [[ "${STEP_TOGGLE[$_s]}" != "true" ]]; then _mark="off "
    elif step_selected "${_s}"; then _mark="run "
    else _mark="skip"; fi
    printf '[INFO]   [%s] %-17s %s\n' "${_mark}" "${_s}" "${STEP_INFO[$_s]}"
done
${LIST_STEPS} && exit 0

# --- Private registry: cluster configuration (CPD_IMAGE_SOURCE private | local) ---
h_run_step "$(step_on registry-config)" \
    "private registry: configure the cluster (scripts/private_registry_mirroring 3.x)" \
    "${SCRIPTS_ROOT}/../private_registry_mirroring/0_x_full_quick_mirror_script/full_registry_mirror_process.sh" \
    --cluster-only

# --- Step 0.0 - Install & set up openshift cert manager -------------------------------
h_run_step "$(step_on certmanager)" \
    "0.3 set up openshift certmanager.sh" \
    "${SCRIPTS_ROOT}/1_global_pull_secret_and_certmanager/1.0_set_up_openshift_certmanager.sh"

# --- Step 1.0 - Set up global pull credential -------------------------------
h_run_step "$(step_on pull-secret)" \
    "1.0 set up global pull credential" \
    "${SCRIPTS_ROOT}/1_global_pull_secret_and_certmanager/1.1_set_up_global_pull_credential.sh"

# --- Step 2.0 - Preliminary cluster setup -----------------------------------
h_run_step "$(step_on preliminary)" \
    "2.0 preliminary setup" \
    "${SCRIPTS_ROOT}/2_prepare_cluster/2.0-2.1_preliminary_setup/2.0_preliminary_setup.sh"

# --- Step 2.2 - Install prerequisite operators ------------------------------
h_run_step "$(step_on prereq-operators)" \
    "2.2 install prerequisite operators" \
    "${SCRIPTS_ROOT}/2_prepare_cluster/2.2_install_prerequisite_operators/2.2_install_prerequisite_operators.sh"

# --- Step 3.1 - Install IBM Software Hub -------------------------------------
h_run_step "$(step_on softwarehub)" \
    "3.1 install software hub" \
    "${SCRIPTS_ROOT}/3_install_softwarehub/3.1_full_step_3_installprocess-softwarehub.sh"

# --- Step 4.0 - Install CPD components ---------------------------------------
h_run_step "$(step_on cpd)" \
    "4.0 install cpd components" \
    "${SCRIPTS_ROOT}/4_install_components/4.0_full_step_4_installprocess-cpd.sh"
