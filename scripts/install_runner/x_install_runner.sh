#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

# =============================================================================
# x_install_runner.sh - watch and control installs running in cluster
# -----------------------------------------------------------------------------
# A chain runs in cluster when its config sets INSTALL_RUN_MODE=cluster. Each
# install has a slot: its own namespace, pod, volume and copy of its config.
#
#   x_install_runner.sh status                  every slot on the cluster
#   x_install_runner.sh attach [--plain] [--from-start] [--last N]
#                                               the live terminal; Ctrl-C only detaches
#   x_install_runner.sh stop                    stop the chain, keep everything
#   x_install_runner.sh resume [--retry-warned] continue a failed or stopped run
#   x_install_runner.sh collect [--force] [--to <dir> | --to-loaded]
#                                               bring results back to this machine
#   x_install_runner.sh teardown [--discard]    delete the slot and its credentials
#   x_install_runner.sh shell                   debug shell in the pod
#   x_install_runner.sh preflight               check without changing anything
#
# Options for all of them:
#   --install <id>   which install (src/install_runner/installs/); needed when
#                    more than one has a config here
#   --slot <slot>    a slot other than the one the config points at
#
# collect puts results where the run's config came from (the flat configs/ or
# configs/clusters/<name>/). If that changed since the launch (a migration, a
# rename, another machine), it refuses. --to-loaded then puts each folder where
# the config loaded now has it (flat: configs/cp4d_config and service_instances);
# --to <dir> puts each under <dir> (<dir>/cp4d_config, <dir>/service_instances)
# and skips the follow-up that reads the loaded config. On another machine, the
# cluster's config must be there first.
#
# Logs in with OC_LOGIN only, never `cpd-cli manage`: that would recreate the local
# olm-utils container and kill whatever runs in it.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${SCRIPT_DIR:h:h}"
IR_VERBS=(status attach stop resume collect teardown shell preflight)

# The arguments stay in $@ for the env load: env_bootstrap.sh takes out the
# multi-cluster flags there, and a fan-out re-runs this script with the rest, verb
# included (gap X6). Only a look ahead here, at the verb and --install. The verb comes
# first; only the flags env_bootstrap.sh takes out may stand before it.
ir_argv=("$@")
pre=("$@")
while (( ${#pre} )) && [[ "${pre[1]}" == --* && "${pre[1]}" != --help ]]; do
    case "${pre[1]}" in
        --target-cluster|--target-clusters|--env-target|--run-mode) pre=("${(@)pre[3,-1]}") ;;
        *) pre=("${(@)pre[2,-1]}") ;;
    esac
done
verb="${pre[1]:-}"
case "${verb}" in
    -h|--help|help|"") sed -n '5,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
(( ${IR_VERBS[(Ie)${verb}]} )) || { echo "[ERROR] Unknown command: ${verb} (see --help)" >&2; exit 2; }
INSTALL=""
for (( i = 1; i <= ${#ir_argv}; i++ )); do
    case "${ir_argv[i]}" in
        --install)   INSTALL="${ir_argv[i+1]:-}" ;;
        --install=*) INSTALL="${ir_argv[i]#*=}" ;;
    esac
done
unset pre i

# How a multi-cluster run of each verb goes (gap X7): reading is fine on every target,
# a terminal or a resume (which grants cluster-admin again) is one cluster at a time,
# and stopping or deleting asks first. Fan-out children inherit it.
case "${verb}" in
    status|preflight|collect) export MCM_SCRIPT_POLICY=allow ;;
    attach|shell|resume)      export MCM_SCRIPT_POLICY=single-only ;;
    stop|teardown)            export MCM_SCRIPT_POLICY=confirm ;;
esac
# Every verb needs only oc: no local olm-utils container and no lease, so a watch of
# several hours leaves the idle watcher free to stop both (gap X8).
export MCM_SYNC_MODE=stop-only
# The auto-prep in env_bootstrap.sh would start the podman VM, which nothing here
# needs (gap X8c). Only its chmod part runs. The state file is data and stays 0600.
if [[ -z "${_CP4D_PREP_DONE:-}" ]]; then
    export _CP4D_PREP_DONE=1
    source "${REPO_DIR}/src/helpers/multi_cluster_helpers.sh"
    find "${REPO_DIR}" -name '*.sh' -not -path '*/.venv/*' -not -path "$(mcm_state_file)" ! -perm -u+x \
        -exec chmod +x {} + 2>/dev/null || true
fi

# The install decides which config, and so which cluster, this talks to.
ir_module_target() {   # <install id> -> stdout
    awk -F= '$1=="INSTALL_ENV_TARGET"{gsub(/"/,"",$2);print $2}' "${REPO_DIR}/src/install_runner/installs/$1.conf"
}
if [[ -n "${INSTALL}" ]]; then
    [[ -f "${REPO_DIR}/src/install_runner/installs/${INSTALL}.conf" ]] \
        || { echo "[ERROR] No install module: ${INSTALL} (src/install_runner/installs/)" >&2; exit 2; }
    export ENV_TARGET="$(ir_module_target "${INSTALL}")"
else
    # Found below, from this run's configs: a target left in the shell must not decide it.
    unset ENV_TARGET
fi

# The installs with a config in this configs folder -> reply.
ir_installs_here() {   # <configs root>
    local f target
    local -a found
    reply=()
    for f in "${REPO_DIR}"/src/install_runner/installs/*.conf(N); do
        [[ "${f:t:r}" == _template ]] && continue
        target="$(ir_module_target "${f:t:r}")"
        [[ -n "${target}" ]] || continue
        found=("$1"/*/${target}_vars.sh(N))
        (( ${#found} )) && reply+=("${f:t:r}")
    done
}
# No --install: the one install with a config in this run's configs folder -> INSTALL.
ir_discover_install() {   # <configs root>
    ir_installs_here "$1"
    (( ${#reply} == 1 )) || { echo "[ERROR] Say which install: --install <${(j:|:)reply:-id}>" >&2; exit 2; }
    INSTALL="${reply[1]}"
}
# The configs folder is known only once env_bootstrap.sh has pinned the cluster, so it
# calls this then, before it loads the config (gap X6).
env_bootstrap_target_hook() {   # <configs root>
    ir_installs_here "$1"
    # A cluster with no install config (Concert-only, mirror-only) is skipped, as the
    # env load skips one with no config for --install's target: a status or collect
    # over every cluster must not fail on it. A step nested in a fan-out gets 1 there.
    if (( ${#reply} == 0 )) && [[ -n "${MCM_CLUSTER:-}" ]]; then
        if [[ "${MCM_SKIP_EXIT_CODE}" == 1 ]]; then
            echo "[ERROR] A step of this run needs an install config, which cluster '${MCM_CLUSTER}' does not have (looked in $1)." >&2
        else
            echo "[WARN] Cluster '${MCM_CLUSTER}' has no install config (looked in $1) - skipped." >&2
        fi
        mcm_exit_no_trap "${MCM_SKIP_EXIT_CODE}"
    fi
    ir_discover_install "$1"
    export ENV_TARGET="$(ir_module_target "${INSTALL}")"
    _CP4D_ENV_TARGET_WHY="install ${INSTALL}, the one with a config here"
}

set -- "${ir_argv[@]}"
unset ir_argv
source "${REPO_DIR}/env_bootstrap.sh"
unset -f env_bootstrap_target_hook
# The policy is this script's, for this verb: a script that a hook runs from here has its own.
unset MCM_SCRIPT_POLICY
source "${_CP4D_REPO_ROOT}/src/helpers/install_runner_helpers.sh"
# An --env-target with no --install skipped the hook: find the install in what loaded.
[[ -n "${INSTALL}" ]] || ir_discover_install "${CONFIGS_ROOT}"

# Parsed from what env_bootstrap.sh left, so --target-cluster and friends are gone.
verb="${1:-}"
[[ -n "${verb}" ]] && shift
(( ${IR_VERBS[(Ie)${verb}]} )) || { echo "[ERROR] Unknown command: ${verb} (see --help)" >&2; exit 2; }
SLOT=""
rest=()
while (( $# )); do
    case "$1" in
        --install)   INSTALL="${2:?--install needs an id}"; shift 2 ;;
        --install=*) INSTALL="${1#*=}"; shift ;;
        --slot)      SLOT="${2:?--slot needs a name}"; shift 2 ;;
        --slot=*)    SLOT="${1#*=}"; shift ;;
        *)           rest+=("$1"); shift ;;
    esac
done

[[ -n "${SLOT}" ]] || { ir_slot "${INSTALL}"; SLOT="${REPLY}"; }
ir_namespace "${SLOT}"; NS="${REPLY}"

eval "${OC_LOGIN}"

# Before a change, say where it goes: slot names do not carry the cluster (gap X14).
case "${verb}" in
    resume|stop|collect|teardown)
        if [[ -n "${MCM_CLUSTER:-}" ]]; then
            ir_info "Slot ${SLOT} on cluster ${MCM_CLUSTER}, ${OCP_URL:-no OCP_URL}"
        else
            ir_info "Slot ${SLOT} on ${OCP_URL:-no OCP_URL}"
        fi
        ;;
esac

case "${verb}" in
    status)    ir_status ;;
    attach)    ir_attach "${SLOT}" "${rest[@]}" ;;
    stop)      ir_stop "${SLOT}" ;;
    resume)    ir_resume "${SLOT}" "${rest[@]}"; ir_attach "${SLOT}" ;;
    collect)   ir_collect "${INSTALL}" "${SLOT}" "${rest[@]}" ;;
    teardown)  ir_teardown "${SLOT}" "${rest[@]}" ;;
    shell)     oc exec -it -n "${NS}" "${IR_POD}" -- zsh ;;
    # The hand-off's local refusals too (wrong cluster's config, roots, ENV_TARGET).
    # No chain: only the install's own config is checked.
    preflight) _ir_stage_plan "${INSTALL}" ""; ir_preflight "${INSTALL}" ;;
esac
