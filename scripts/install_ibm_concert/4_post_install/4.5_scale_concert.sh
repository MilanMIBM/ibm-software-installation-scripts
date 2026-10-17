#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi

set -euo pipefail

SECONDS=0
trap '(( SECONDS >= 60 )) && echo "[TIMER] $(basename $0) completed in $((SECONDS/60))m $((SECONDS%60))s" || echo "[TIMER] $(basename $0) completed in ${SECONDS}s"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# --- Config target: only configs/concert_config/concert_vars.sh is in scope ---
export ENV_TARGET="${ENV_TARGET:-concert}"
# --- Universal env load: walk up to repo root (env_bootstrap.sh), source it once ---
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/concert_helpers.sh"
concert_require_config

# ==============================================================================
# 4.5 Scale Concert up or down without re-running the installer
# ------------------------------------------------------------------------------
#   ./4.5_scale_concert.sh status                         current level + pod sizes
#   ./4.5_scale_concert.sh <level> [--persist]            scale now
#   ./4.5_scale_concert.sh list                           scaling CronJobs
#   ./4.5_scale_concert.sh suspend|resume|delete <cronjob-name>
#   ./4.5_scale_concert.sh delete-all
#
# Levels (IBM's concert/k8s/etc/*.cfg): level_0 (all replicas 0 - shutdown),
# level_1, level_2, level_3, level_3_1, level_3_2, level_3_3,
# level_3_resilience, level_4. They set replicas and CPU/memory per component
# (ROJA_CORE, ROJA_UI, PORTAL_GW, INGESTION, ...).
#
# Scaling runs IBM's concert/k8s/deployment-scaler/deployment-scaler-utils.sh
# (the part that patches replicas + CPU/memory of the Deployments in
# PROJECT_CONCERT) directly in the runner - minutes, no helm/installer run.
# IBM's wrapper (deployment-scaler-k8s.sh) would run it in a Job on the
# ibm-roja-mgmt image instead, but that image ships no kubectl in 3.1.0, so
# the Job exits 2 at its prerequisite check. For the same reason --schedule
# (IBM's CronJobs use that image) is refused until IBM fixes the image.
# Only the Concert product has an IBM on-demand scaler - Hub and Data Apps
# keep the level from install.
#
# A later 3.2 run re-applies SCALE_CONFIG_CONCERT from params.ini and undoes
# an on-demand level. --persist also writes the level to concert_vars.sh
# (CONCERT_SCALE_CONCERT) and re-renders params.ini so the two stay in step;
# set the same value in the notebook before regenerating concert_vars.sh.
#
# CronJob management (list/suspend/resume/delete) is done here with oc: IBM's
# script prompts for confirmation on delete, which a runner Job cannot answer.
# ==============================================================================

usage() { sed -n '/^#   \.\/4\.5/,/^#   \.\/4\.5_scale_concert.sh delete-all/p' "$0" | sed 's/^# //'; exit "${1:-0}"; }

(( $# )) || usage 1
CMD="$1"; shift
NS="${PROJECT_CONCERT:-}"
[[ -n "${NS}" ]] || concert_die "PROJECT_CONCERT is not set."
concert_product_enabled concert || concert_die "Concert is not selected in concert_vars.sh - nothing to scale."
LEVEL_DIR="$(concert_local_install_dir)/concert/k8s/etc"

# Lists IBM's levels from the local installer copy when it is there (the runner
# validates again either way).
valid_levels() {
    local f
    for f in "${LEVEL_DIR}"/level_*.cfg(N); do
        [[ "${f:t:r}" == level_minicpureq ]] || print -r -- "${f:t:r}"
    done
}

check_level() {
    local lvl="$1" levels
    [[ "${lvl}" =~ '^level_[a-z0-9_]+$' ]] || concert_die "Not a scale level: ${lvl} (expected level_<n>)."
    levels=(${(f)"$(valid_levels)"})
    if (( ${#levels} )) && ! (( ${levels[(Ie)${lvl}]} )); then
        concert_die "Unknown level ${lvl}. IBM ${CONCERT_VERSION} levels: ${levels[*]}"
    fi
}

scale_cronjobs() {
    oc get cronjob -n "${NS}" -o name 2>/dev/null | sed 's|^cronjob.batch/||' | grep '^scale-to-' || true
}

show_status() {
    local cur
    cur="$(oc get configmap scaler-config -n "${NS}" -o jsonpath='{.metadata.labels.current-scale-level}' 2>/dev/null || true)"
    if [[ -n "${cur}" ]]; then
        concert_info "Current level (last scaler run): ${cur}"
    else
        concert_info "Current level: install level from params.ini (SCALE_CONFIG_CONCERT=${CONCERT_SCALE_CONCERT:-IBM default}) - scaler never run"
    fi
    print -r -- ""
    oc get deployments -n "${NS}" -o json | jq -r '
        ["DEPLOYMENT","READY","CPU REQ/LIM","MEM REQ/LIM"],
        (.items[] | .spec.template.spec.containers[0].resources as $r |
          [ .metadata.name,
            "\(.status.readyReplicas // 0)/\(.spec.replicas)",
            "\($r.requests.cpu // "-")/\($r.limits.cpu // "-")",
            "\($r.requests.memory // "-")/\($r.limits.memory // "-")" ])
        | @tsv' | column -t -s $'\t'
    local crons
    crons="$(scale_cronjobs)"
    if [[ -n "${crons}" ]]; then
        print -r -- ""
        concert_info "Scheduled scaling:"
        oc get cronjob ${(f)crons} -n "${NS}" -o custom-columns='NAME:.metadata.name,SCHEDULE:.spec.schedule,SUSPENDED:.spec.suspend,LAST RUN:.status.lastScheduleTime' --no-headers | sed 's/^/    /'
    fi
}

# Writes the level to concert_vars.sh and re-renders params.ini.
persist_level() {
    local lvl="$1" vars="${CONCERT_CONFIG_DIR}/concert_vars.sh"
    grep -q '^export CONCERT_SCALE_CONCERT=' "${vars}" \
        || concert_die "No 'export CONCERT_SCALE_CONCERT=' line in ${vars} - set it in the notebook instead."
    cp -p "${vars}" "${vars}.$(date +%Y%m%d-%H%M%S).bak"
    sed -i.tmp "s/^export CONCERT_SCALE_CONCERT=.*/export CONCERT_SCALE_CONCERT=\"${lvl}\"/" "${vars}" && rm -f "${vars}.tmp"
    concert_info "concert_vars.sh: CONCERT_SCALE_CONCERT=\"${lvl}\" - re-rendering params.ini"
    CONCERT_SCALE_CONCERT="${lvl}" zsh "${_CP4D_REPO_ROOT}/scripts/install_ibm_concert/3_install_concert/3.0_render_params_ini.sh" >/dev/null
    concert_info "Also set this level in ibm_concert_vars_generation.py before regenerating concert_vars.sh."
}

eval "${OC_LOGIN}"
oc get namespace "${NS}" >/dev/null 2>&1 || concert_die "Namespace ${NS} does not exist - is Concert installed?"

case "${CMD}" in
    -h|--help) usage 0 ;;
    status)
        show_status
        ;;
    list)
        crons="$(scale_cronjobs)"
        [[ -n "${crons}" ]] || { concert_info "No scaling CronJobs in ${NS}."; exit 0; }
        oc get cronjob ${(f)crons} -n "${NS}" -o custom-columns='NAME:.metadata.name,SCHEDULE:.spec.schedule,SUSPENDED:.spec.suspend,LAST RUN:.status.lastScheduleTime'
        ;;
    suspend|resume)
        name="${1:?usage: $0 ${CMD} <cronjob-name>}"
        [[ "${name}" == scale-to-* ]] || concert_die "${name} is not a scaling CronJob (scale-to-*)."
        oc get cronjob "${name}" -n "${NS}" >/dev/null || concert_die "CronJob ${name} not found in ${NS} - see '$0 list'."
        [[ "${CMD}" == suspend ]] && s=true || s=false
        oc patch cronjob "${name}" -n "${NS}" --type=merge -p "{\"spec\":{\"suspend\":${s}}}" >/dev/null
        concert_info "${(C)CMD}d ${name}."
        ;;
    delete)
        name="${1:?usage: $0 delete <cronjob-name>}"
        [[ "${name}" == scale-to-* ]] || concert_die "${name} is not a scaling CronJob (scale-to-*)."
        oc delete cronjob "${name}" -n "${NS}"
        ;;
    delete-all)
        crons="$(scale_cronjobs)"
        [[ -n "${crons}" ]] || { concert_info "No scaling CronJobs in ${NS}."; exit 0; }
        oc delete cronjob ${(f)crons} -n "${NS}"
        ;;
    level_*)
        LEVEL="${CMD}"
        check_level "${LEVEL}"
        SCHEDULE="" PERSIST=false
        while (( $# )); do
            case "$1" in
                --schedule) SCHEDULE="${2:?--schedule needs a cron expression}"; shift 2 ;;
                --persist)  PERSIST=true; shift ;;
                *)          concert_die "Unknown option: $1" ;;
            esac
        done
        [[ -n "${SCHEDULE}" && "${PERSIST}" == true ]] && concert_die "--persist applies to an immediate scale, not a schedule."

        oc get configmap app-build-cfg-cm -n "${NS}" >/dev/null 2>&1 \
            || concert_die "app-build-cfg-cm missing in ${NS} - Concert is not (fully) installed."
        if concert_is_true "${CONCERT_ENABLE_HPA:-false}"; then
            concert_warn "ENABLE_HPA is on: the HPAs keep managing replica counts; the level's CPU/memory still applies."
        fi
        if [[ "${LEVEL}" == level_0 ]]; then
            concert_warn "level_0 sets every Concert Deployment to 0 replicas - Concert is unavailable until you scale back up."
        fi

        if [[ -n "${SCHEDULE}" ]]; then
            img="$(oc get configmap app-build-cfg-cm -n "${NS}" -o jsonpath='{.data.IMG_PREFIX}/ibm-roja-mgmt:{.data.IMG_TAG}')"
            concert_die "--schedule is not usable: IBM's scaling CronJobs run on ${img}, which has no kubectl (IBM ${CONCERT_VERSION} defect). Scale on demand instead."
        fi

        # In the runner: IBM's utils script with its /config/ volume pointed at
        # a copy of the level files and kubectl pinned to PROJECT_CONCERT (the
        # runner's own namespace would be the default). The scaler-config
        # ConfigMap is kept up to date because the script records the current
        # level as a label on it.
        inner="$(cat <<EOF
set -euo pipefail
ns=${(q)NS}; level=${(q)LEVEL}
d="\$(mktemp -d)"; mkdir -p "\$d/cfg" "\$d/bin"
cp concert/k8s/etc/*.cfg "\$d/cfg/"
# The shim restores PATH: the runner's kubectl wrapper looks up the real
# binary on PATH and would otherwise find (and loop into) this shim.
real="\$(command -v kubectl)"
printf '#!/bin/sh\nPATH=%s exec %s -n %s "\$@"\n' "\$PATH" "\$real" "\$ns" > "\$d/bin/kubectl"; chmod +x "\$d/bin/kubectl"
sed 's#/config/#'"\$d"'/cfg/#g' concert/k8s/deployment-scaler/deployment-scaler-utils.sh > "\$d/scaler.sh"
kubectl -n "\$ns" create configmap scaler-config --from-file="\$d/cfg" --dry-run=client -o yaml \
    | kubectl -n "\$ns" apply -f - >/dev/null
PATH="\$d/bin:\$PATH" bash "\$d/scaler.sh" --scale-level="\$level"
EOF
)"
        concert_info "Scaling ${NS} to ${LEVEL}"
        concert_run --name scale --timeout 3600 -- __shell__ "${inner}" \
            || concert_die "IBM's scaler failed - see the log above (rerun '$0 status' to see what changed)."

        if [[ -z "${SCHEDULE}" ]]; then
            [[ "${PERSIST}" == true ]] && persist_level "${LEVEL}"
            if [[ "${LEVEL}" != level_0 ]]; then
                concert_info "Waiting for the Concert Deployments to roll out"
                for d in $(oc get deployments -n "${NS}" -o name); do
                    oc rollout status "${d}" -n "${NS}" --timeout=900s >/dev/null || concert_warn "${d} did not finish rolling out."
                done
            fi
            show_status
            [[ "${PERSIST}" == true || "${LEVEL}" == "${CONCERT_SCALE_CONCERT:-}" ]] \
                || concert_warn "params.ini still says ${CONCERT_SCALE_CONCERT:-<default>}: the next 3.2 run reverts this. Use --persist to keep ${LEVEL}."
        fi
        ;;
    *)
        concert_error "Unknown command: ${CMD}"
        usage 1
        ;;
esac
