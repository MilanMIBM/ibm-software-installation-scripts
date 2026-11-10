#!/bin/zsh
# Make this script executable if it isn't already, then re-run it
if [ ! -x "$0" ]; then chmod +x "$0" && exec "$0" "$@"; fi
# =============================================================================
# multi_cluster_idle_watcher.sh - stops idle olm-utils containers (plan 5.7.1)
# -----------------------------------------------------------------------------
# One per machine, started detached by mcm_sync_containers while a managed container
# is up. Each wake (every 5 minutes) re-reads the state file. A container stops once
# nothing has used it for MCM_CONTAINER_IDLE_TIMEOUT_MINUTES (0 = never), judged in
# this order, stopping at the first sign of activity:
#
#   1. a live lease on its cluster
#   2. .last_activity (a cpd-cli manage through the shim) within the timeout
#   3. exec events from podman, and the time the container last started
#   4. the process scan inside the container
#   5. the lease again, under the .stopping marker, then podman stop -t 3
#
# When it has stopped the last managed container and podman ps shows nothing
# running at all, it also stops the podman VM, if MCM_STOP_IDLE_PODMAN_VM is true and
# the mode is on. A run that has no container yet keeps the VM up: a live lease on any
# cluster, or a cpd-cli manage within the timeout. The stop is decided under
# .vm-stopping, which sync waits for, and is tried again once those are gone.
#
# Mode off: delineated clusters stay per cluster for good, and a run pinned to one
# (--target-cluster, MCM_CLUSTER) still uses its own container. The watcher keeps
# watching the registered clusters' containers then, with the same idle rules. It
# leaves the flat containers and the VM alone: flat runs, the default while off, take
# no leases. Whoever turns the mode off stops the idle cluster containers at once
# (mcm_stop_idle_after_off: multi_cluster.sh off, the notebooks).
#
# Exits when the timeout is 0, no managed container runs and none is on its way (a
# live lease, a cpd-cli manage within the timeout), or podman stays unreachable or the
# state file invalid for 3 wakes. The next sync or cpd-cli manage starts a new one.
#
# Usage:
#   multi_cluster_idle_watcher.sh           run until there is nothing left to watch
#   multi_cluster_idle_watcher.sh --once    one pass now, in the foreground
#   multi_cluster_idle_watcher.sh --help
#
# Environment: MCM_IDLE_POLL_SECONDS overrides the 5 minutes between wakes.
# Log: ~/cpd-cli/clusters/.idle-watcher.log
# =============================================================================

set -uo pipefail

case "${1:-}" in
    -h|--help)
        sed -n '4,40p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    --once|"")
        ;;
    *)
        print -r -- "[ERROR] Unknown option: $1 (see --help)" >&2
        exit 1
        ;;
esac
_w_once=0
[[ "${1:-}" == --once ]] && _w_once=1

zmodload zsh/datetime || { print -r -- "[ERROR] zsh/datetime is not available" >&2; exit 1; }
zmodload -F zsh/stat b:zstat || { print -r -- "[ERROR] zsh/stat is not available" >&2; exit 1; }

source "${0:A:h}/multi_cluster_helpers.sh"

# The watcher serves every cluster, whatever the shell that launched it was pinned to.
unset MCM_CLUSTER MCM_RUN_TARGETS

_w_poll="${MCM_IDLE_POLL_SECONDS:-300}"
_w_home="$(_mcm_clusters_home)"
_w_pid_file="${_w_home}/.idle-watcher.pid"
_w_log_file="${_w_home}/.idle-watcher.log"
_w_unreachable=0
_w_invalid=0
# Set when this watcher stopped the last managed container but the VM had to wait.
_w_vm_due=0
# Longest gap between checks that the folders still exist.
_w_slice=30

_w_log() {
    local stamp line
    strftime -s stamp '%Y-%m-%dT%H:%M:%S%z' "${EPOCHSECONDS}"
    line="${stamp} [${$}] $*"
    { print -r -- "${line}" >> "${_w_log_file}" } 2>/dev/null
    (( _w_once )) && print -r -- "${line}"
    return 0
}

# Owner only, created that way: a run's command lines can reach it.
_w_secure_log() {
    [[ -d "${_w_home}" ]] || return 0
    { ( umask 077; : >> "${_w_log_file}" ); chmod 600 "${_w_log_file}" } 2>/dev/null
    return 0
}

# Keeps the log from growing without limit.
_w_trim_log() {
    local -a size
    [[ -f "${_w_log_file}" ]] || return 0
    zstat -A size +size "${_w_log_file}" 2>/dev/null || return 0
    if (( size[1] > 1048576 )); then
        tail -n 2000 "${_w_log_file}" > "${_w_log_file}.tmp" 2>/dev/null \
            && mv -f "${_w_log_file}.tmp" "${_w_log_file}" 2>/dev/null
    fi
    chmod 600 "${_w_log_file}" 2>/dev/null
    return 0
}

# A busy process's arguments can hold a password (login-private-registry, skopeo
# --dest-creds), and the log outlives the run: it gets the pid and the program name.
_w_safe_reason() {   # REASON
    local reason="$1" pid rest
    if [[ "${reason}" == "process "<->": "* ]]; then
        pid="${${reason#process }%%:*}"
        rest="${reason#process ${pid}: }"
        print -r -- "process ${pid}: ${${rest%% *}:t}"
    else
        print -r -- "${reason}"
    fi
}

# One watcher per machine: the pid file is created exclusively. A leftover from a
# dead watcher is replaced.
_w_claim_pid() {
    local attempt other
    mkdir -p "${_w_home}" 2>/dev/null || return 1
    for attempt in 1 2 3; do
        if ( setopt noclobber; print -r -- "$$" > "${_w_pid_file}" ) 2>/dev/null; then
            return 0
        fi
        other="$(<"${_w_pid_file}")" 2>/dev/null || other=""
        if [[ -n "${other}" ]] && _mcm_watcher_alive "${other}"; then
            return 1
        fi
        rm -f "${_w_pid_file}" 2>/dev/null
    done
    return 1
}

_w_release_pid() {
    [[ -f "${_w_pid_file}" && "$(<"${_w_pid_file}")" == "$$" ]] && rm -f "${_w_pid_file}" 2>/dev/null
    return 0
}

# Wall-clock wait, so a laptop that slept past the wake counts the time as idle. It
# wakes often enough to notice that its folders are gone, and gives up then.
_w_sleep() {
    local -i wake=$(( EPOCHSECONDS + _w_poll )) left
    while (( EPOCHSECONDS < wake )); do
        left=$(( wake - EPOCHSECONDS ))
        (( left > _w_slice )) && left=${_w_slice}
        sleep "${left}"
        [[ -d "${_w_home}" ]] || return 1
    done
    # Lost the pid file to a newer watcher.
    [[ "$(<"${_w_pid_file}")" == "$$" ]] 2>/dev/null || return 1
    return 0
}

# Prints the names of the running containers. Fails when podman cannot be reached.
_w_running_names() {
    podman ps --format '{{.Names}}' 2>/dev/null
}

# 0 when this pass stopped the container.
_w_check_container() {
    local container="$1" now="$2" since="$3" cluster="" activity="" stamp="" events="" started="" started_epoch=0 stop_rc=0
    local -i mtime=0 count=0 own=0

    cluster="$(_mcm_container_cluster "${container}")" || cluster=""
    if [[ -n "${cluster}" ]]; then
        if _mcm_lease_live "${cluster}"; then
            return 1
        fi
        activity="${_w_home}/${cluster}/.last_activity"
        if [[ -f "${activity}" ]]; then
            mtime="$(zstat +mtime "${activity}" 2>/dev/null)" || mtime=0
            if (( mtime >= since )); then
                return 1
            fi
        fi
    fi

    # An exec event may be our own scan of a busy container, which must not count.
    events="$(podman events --since "${since}" --until "$(( now + 1 ))" --filter event=exec --filter "container=${container}" --format '{{.Time}}' 2>/dev/null)" || events=""
    for stamp in "${(@f)events}"; do
        [[ -n "${stamp}" ]] && count+=1
    done
    own="$(_mcm_own_scans_since "${container}" "${since}")" || own=0
    if (( count > own )); then
        return 1
    fi

    started="$(podman inspect --format '{{.State.StartedAt}}' "${container}" 2>/dev/null)" || started=""
    if ! started_epoch="$(_mcm_epoch_from_timestamp "${started}")"; then
        _w_log "${container}: unreadable start time '${started}', leaving it running"
        return 1
    fi
    if (( started_epoch >= since )); then
        return 1
    fi

    if _mcm_scan_container "${container}"; then
        _w_log "${container}: timeout reached but busy ($(_w_safe_reason "${REPLY}"))"
        return 1
    fi

    _w_log "${container}: idle for the whole timeout, stopping"
    _mcm_stop_container "${container}" "${cluster}" || stop_rc=$?
    case "${stop_rc}" in
        0)
            _w_log "${container}: stopped"
            return 0
            ;;
        2)
            _w_log "${container}: a run started on cluster ${cluster}, left running"
            ;;
        *)
            _w_log "${container}: podman stop failed"
            ;;
    esac
    return 1
}

# 0 when something is on its way that needs podman: a live run on any cluster (it may
# have no container yet), or a cpd-cli manage within the timeout (it may still be
# pulling the image). REPLY says what.
_w_work_pending() {   # SINCE
    local since="$1" folder
    local -i mtime=0
    REPLY=""
    for folder in "${_w_home}"/*(N/); do
        if _mcm_lease_live "${folder:t}"; then
            REPLY="a live run on cluster ${folder:t}"
            return 0
        fi
        [[ -f "${folder}/.last_activity" ]] || continue
        mtime="$(zstat +mtime "${folder}/.last_activity" 2>/dev/null)" || mtime=0
        if (( mtime >= since )); then
            REPLY="a recent cpd-cli manage on cluster ${folder:t}"
            return 0
        fi
    done
    return 1
}

# Only after this watcher stopped the last managed container, and only with nothing
# at all running. 1 when work on its way keeps the VM up for now: the caller retries.
# Writes the marker first, then checks, the same order as _mcm_stop_container: a run
# that writes its lease after this check finds the marker and waits for it.
_w_maybe_stop_vm() {
    local remaining="$1" since="$2" state="" marker="${_w_home}/.vm-stopping"
    if [[ -n "${remaining}" ]]; then
        _w_log "VM stays up, still running: ${${(f)remaining}[*]}"
        return 0
    fi
    if [[ "${MCM_STOP_IDLE_PODMAN_VM}" != true ]]; then
        _w_log "VM stays up: MCM_STOP_IDLE_PODMAN_VM is false"
        return 0
    fi
    # A flat run, the default while the mode is off, may need the VM without any lease.
    if [[ "${MULTI_CLUSTER_MANAGEMENT}" != true ]]; then
        _w_log "VM stays up: multi-cluster mode is off"
        return 0
    fi
    state="$(podman machine inspect --format '{{.State}}' 2>/dev/null)" || state=""
    if [[ "${state}" != running ]]; then
        return 0
    fi
    { print -r -- "$$" > "${marker}" } 2>/dev/null
    if _w_work_pending "${since}"; then
        rm -f "${marker}" 2>/dev/null
        _w_log "VM stays up for now: ${REPLY}"
        return 1
    fi
    if ! remaining="$(_w_running_names)" || [[ -n "${remaining}" ]]; then
        rm -f "${marker}" 2>/dev/null
        _w_log "VM stays up: a container came up, or podman stopped answering"
        return 0
    fi
    _w_log "nothing is running, stopping the podman VM"
    podman machine stop >/dev/null 2>&1 || _w_log "podman machine stop failed"
    rm -f "${marker}" 2>/dev/null
    return 0
}

# The containers this pass may stop. Mode off: the registered clusters' only, since a
# flat run (the default then) uses the flat pair and takes no lease.
_w_managed() {
    local -a all flat
    all=("${(@f)$(mcm_managed_containers)}")
    if [[ "${MULTI_CLUSTER_MANAGEMENT}" != true ]]; then
        flat=("${(@f)$(mcm_container_names)}")
        all=("${(@)all:|flat}")
    fi
    all=("${(@)all:#}")
    (( ${#all} )) && print -rl -- "${all[@]}"
    return 0
}

# 1 when the watcher should exit.
_w_pass() {
    local running="" remaining="" name
    local -a running_names managed active
    local -i timeout now since stopped=0 left=0

    # Never call mcm_load_state on a missing file: it would create it, and its folder.
    if [[ ! -f "$(mcm_state_file)" ]]; then
        _w_log "state file is gone, exiting"
        return 1
    fi
    if ! mcm_load_state >>"${_w_log_file}" 2>&1; then
        _w_invalid=$(( _w_invalid + 1 ))
        if (( _w_invalid >= 3 )); then
            _w_log "state file invalid for 3 wakes, exiting"
            return 1
        fi
        _w_log "state file is invalid (${_w_invalid}/3), nothing done this wake"
        return 0
    fi
    _w_invalid=0
    timeout=$(( MCM_CONTAINER_IDLE_TIMEOUT_MINUTES * 60 ))
    if (( timeout <= 0 )); then
        _w_log "the idle timeout is 0, nothing to watch, exiting"
        return 1
    fi
    now=${EPOCHSECONDS}
    since=$(( now - timeout ))

    if ! running="$(_w_running_names)"; then
        _w_unreachable=$(( _w_unreachable + 1 ))
        if (( _w_unreachable >= 3 )); then
            _w_log "podman unreachable for 3 wakes, exiting"
            return 1
        fi
        _w_log "podman unreachable (${_w_unreachable}/3)"
        return 0
    fi
    _w_unreachable=0

    running_names=("${(@f)running}")
    managed=("${(@f)$(_w_managed)}")
    for name in "${managed[@]}"; do
        [[ -n "${name}" ]] || continue
        (( ${running_names[(Ie)${name}]} )) && active+=("${name}")
    done
    if (( ${#active} == 0 )); then
        if _w_work_pending "${since}"; then
            _w_log "no managed container is running yet, waiting: ${REPLY}"
            return 0
        fi
        if (( _w_vm_due )); then
            _w_maybe_stop_vm "${running}" "${since}" || return 0
        fi
        _w_log "no managed container is running, exiting"
        return 1
    fi
    _w_vm_due=0

    for name in "${active[@]}"; do
        if _w_check_container "${name}" "${now}" "${since}"; then
            stopped=$(( stopped + 1 ))
        fi
    done
    (( stopped > 0 )) || return 0

    if ! remaining="$(_w_running_names)"; then
        return 0
    fi
    running_names=("${(@f)remaining}")
    for name in "${managed[@]}"; do
        [[ -n "${name}" ]] || continue
        (( ${running_names[(Ie)${name}]} )) && left=$(( left + 1 ))
    done
    if (( left > 0 )); then
        return 0
    fi
    _w_vm_due=1
    _w_maybe_stop_vm "${remaining}" "${since}" || return 0
    return 1
}

if (( _w_once )); then
    _w_secure_log
    _w_pass
    exit 0
fi

cd / 2>/dev/null
_w_claim_pid || exit 0
trap '_w_release_pid' EXIT
_w_secure_log
_w_trim_log
_w_log "watcher started"
while _w_sleep; do
    _w_pass || break
done
_w_log "watcher finished"
