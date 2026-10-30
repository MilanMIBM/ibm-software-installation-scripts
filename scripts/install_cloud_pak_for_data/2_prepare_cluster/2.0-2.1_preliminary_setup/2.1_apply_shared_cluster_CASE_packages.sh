#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# (legacy hardcoded sourcing - replaced by universal crawl below)
# source "${SCRIPT_DIR}/../../source_env_setup.sh"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"

# ==============================================================================
# 2.1 - apply the shared cluster components, one named step each:
#   authorize-topology   authorize-instance-topology (operator + operand projects)
#   cluster-components   apply-cluster-components (License Service; ibm-licensing)
#   scheduler            apply-scheduler (scheduling service; scheduler)
#   scheduler-scale      apply-cluster-component-scale-config (SCHEDULER_SCALE)
# Pick steps with --from <step>, --skip <step>[,...], --only <step>[,...], or
# --<step> to run just that one (e.g. --authorize-topology); --list-steps / --help.
# A step listed as "off" is off by its toggle (see below) and never runs.
# ==============================================================================


PARAM_FILE_FLAG=()
if [[ -n "${INSTALL_OPTIONS:-}" ]]; then
    PARAM_FILE_FLAG=(--param-file="${CPD_CONFIG_PATH_CONTAINER}/${INSTALL_OPTIONS_FILE}")
fi

PATCH_FLAG=()
if [[ -n "${PATCH_ID:-}" ]]; then
    PATCH_FLAG=(--patch_id="${PATCH_ID}")
fi

# ---
# Run a cpd-cli command but tolerate the benign "already installed at a newer/equal
# version" condition that some apply-* subcommands return as a hard exit 1.
# Genuine failures still propagate (non-zero exit with no benign marker -> we re-exit).
run_tolerate_already_installed() {
    local label="$1"; shift
    local _out _rc _tmp

    # Capture combined output to a temp file while still streaming it to the
    # console. We deliberately avoid `tee /dev/tty`, which fails when there is
    # no controlling terminal (e.g. when the installer is run non-interactively
    # or piped), and would otherwise sink the whole pipeline.
    _tmp="$(mktemp -t apply_output.XXXXXX)"

    # `|| _rc=$?` keeps `set -e` from aborting before we can inspect the result.
    _rc=0
    "$@" > >(tee "${_tmp}") 2>&1 || _rc=$?
    _out="$(cat "${_tmp}")"
    rm -f "${_tmp}"

    if [[ "${_rc}" -eq 0 ]]; then
        return 0
    fi

    # Benign cases: component already present at an equal or newer version.
    if echo "${_out}" | grep -Eqi \
        "is already installed|won't be installed because it is older|higher than or equal to the expected version|will be skipped"; then
        echo "[WARN] ${label}: component already installed at an equal/newer version; treating as success and continuing."
        return 0
    fi

    echo "[ERROR] ${label}: failed with exit status ${_rc}."
    return "${_rc}"
}

# Split SOFTWARE_HUB into cluster-scoped and instance-scoped components
HAS_LICENSING=false
HAS_SCHEDULER=false
INSTANCE_COMPONENTS=()

IFS=',' read -rA _all_components <<< "${SOFTWARE_HUB}"
for _c in "${_all_components[@]}"; do
    case "${_c}" in
        ibm-licensing) HAS_LICENSING=true ;;
        scheduler)     HAS_SCHEDULER=true ;;
        *)             INSTANCE_COMPONENTS+=("${_c}") ;;
    esac
done

# level_2 ("small") is the scheduler's default size, so only level_3 / level_4
# (or an invalid value, which the step reports) need the scale-config call.
DO_SCHEDULER_SCALE=false
[[ "${HAS_SCHEDULER}" == true && "${SCHEDULER_SCALE:-level_2}" != (|level_2) ]] && DO_SCHEDULER_SCALE=true

# Set AUTHORIZE_INSTANCE_TOPOLOGY=false to skip it: it works in the instance
# projects, which a tenant restore onto a fresh cluster brings back (with this
# RBAC in them) and which must not exist before it.
step_authorize_topology() {
    cpd-cli manage authorize-instance-topology \
        --operator_ns=${PROJECT_CPD_INST_OPERATORS} \
        --instance_ns=${PROJECT_CPD_INST_OPERANDS} \
        --verbose
}

# Cluster-wide components (License Service + cert-manager), when ibm-licensing is listed
step_cluster_components() {
    run_tolerate_already_installed "apply-cluster-components" \
        cpd-cli manage apply-cluster-components \
        --release=${VERSION} \
        --license_acceptance=true \
        --licensing_ns=${PROJECT_LICENSE_SERVICE} \
        ${PATCH_FLAG[@]+"${PATCH_FLAG[@]}"}
}

# The scheduling service, when scheduler is listed
step_scheduler() {
    run_tolerate_already_installed "apply-scheduler" \
        cpd-cli manage apply-scheduler \
        --release=${VERSION} \
        --license_acceptance=true \
        --scheduler_ns=${PROJECT_SCHEDULING_SERVICE} \
        --image_pull_prefix=${IMAGE_PULL_PREFIX} \
        --image_pull_secret=${IMAGE_PULL_SECRET} \
        ${PATCH_FLAG[@]+"${PATCH_FLAG[@]}"}
}

# Scale up the scheduling service (SCHEDULER_SCALE=level_3 / level_4)
step_scheduler_scale() {
    case "${SCHEDULER_SCALE:-}" in
        level_3|level_4)
            echo "[INFO] Applying scheduler scale ${SCHEDULER_SCALE} in ${PROJECT_SCHEDULING_SERVICE}"
            cpd-cli manage apply-cluster-component-scale-config \
                --cluster_component_ns=${PROJECT_SCHEDULING_SERVICE} \
                --component=scheduler \
                --release=${VERSION} \
                --scale=${SCHEDULER_SCALE}
            ;;
        *)
            echo "Error: SCHEDULER_SCALE='${SCHEDULER_SCALE:-}' is invalid. Use level_2, level_3 or level_4 in ./cpd_vars.sh."
            return 1
            ;;
    esac
}

h_steps_parse --strict "$@"
h_step authorize-topology "${AUTHORIZE_INSTANCE_TOPOLOGY:-true}" "authorize-instance-topology"                   step_authorize_topology
h_step cluster-components "${HAS_LICENSING}"                      "apply-cluster-components (ibm-licensing)"     step_cluster_components
h_step scheduler          "${HAS_SCHEDULER}"                      "apply-scheduler (scheduler)"                  step_scheduler
h_step scheduler-scale    "${DO_SCHEDULER_SCALE}"                 "scheduler scale ${SCHEDULER_SCALE:-level_2}"  step_scheduler_scale
h_steps_plan

eval "${CPDM_OC_LOGIN}"
h_steps_run
