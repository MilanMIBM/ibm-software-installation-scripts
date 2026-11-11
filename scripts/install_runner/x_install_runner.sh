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

verb="${1:-}"
[[ -n "${verb}" ]] && shift
INSTALL="" SLOT=""
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

case "${verb}" in
    status|attach|stop|resume|collect|teardown|shell|preflight) ;;
    -h|--help|help|"") sed -n '5,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "[ERROR] Unknown command: ${verb} (see --help)" >&2; exit 2 ;;
esac

# The install decides which config, and so which cluster, this talks to.
if [[ -z "${INSTALL}" ]]; then
    ids=()
    for f in "${REPO_DIR}"/src/install_runner/installs/*.conf(N); do
        [[ "${f:t:r}" == _template ]] && continue
        target="$(awk -F= '$1=="INSTALL_ENV_TARGET"{gsub(/"/,"",$2);print $2}' "${f}")"
        found=("${REPO_DIR}"/configs/*/${target}_vars.sh(N))
        (( ${#found} )) && ids+=("${f:t:r}")
    done
    (( ${#ids} == 1 )) || { echo "[ERROR] Say which install: --install <${(j:|:)ids:-id}>" >&2; exit 2; }
    INSTALL="${ids[1]}"
fi
export ENV_TARGET="$(awk -F= '$1=="INSTALL_ENV_TARGET"{gsub(/"/,"",$2);print $2}' "${REPO_DIR}/src/install_runner/installs/${INSTALL}.conf")"

source "${REPO_DIR}/env_bootstrap.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/install_runner_helpers.sh"

[[ -n "${SLOT}" ]] || { ir_slot "${INSTALL}"; SLOT="${REPLY}"; }
ir_namespace "${SLOT}"; NS="${REPLY}"

eval "${OC_LOGIN}"

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
