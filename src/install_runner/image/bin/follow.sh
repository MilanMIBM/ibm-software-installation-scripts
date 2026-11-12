#!/bin/bash
# =============================================================================
# follow.sh <terminal|plain> <start|last:N|offset:N> [resolve]
# -----------------------------------------------------------------------------
# Streams the current run's log, through `oc exec` for x_install_runner.sh attach.
# Read-only by construction: nothing a viewer does reaches the install. Ends once
# the run has stopped moving and the log is drained, so a viewer doesn't hang on a
# finished run. With "resolve" it only prints the byte offset the position means,
# so the viewer can count from there and reconnect exactly.
# =============================================================================
work="${IR_WORK:-/work}"
run="$(readlink -f "${work}/current" 2>/dev/null)"
[[ -n "${run}" && -d "${run}" ]] || { echo "[ERROR] No run in this slot." >&2; exit 10; }

case "${1:-terminal}" in
    plain) log="${run}/plain.log" ;;
    *)     log="${run}/terminal.log" ;;
esac
touch "${log}" 2>/dev/null

from="${2:-start}"
case "${from}" in
    start)    offset=1 ;;
    offset:*) offset=$(( ${from#offset:} + 1 )) ;;
    last:*)
        size="$(stat -c %s "${log}")"
        offset=$(( size - $(tail -n "${from#last:}" "${log}" | wc -c) + 1 )) ;;
    *) echo "[ERROR] Unknown start position: ${from}" >&2; exit 2 ;;
esac

if [[ "${3:-}" == resolve ]]; then
    echo $(( offset - 1 ))
    exit 0
fi

# A pending control.resume counts: the supervisor takes it on its next poll, so a
# viewer that attaches in between keeps following into the new attempt instead of
# ending on the old state (a false reconnect). supervisor.sh sets the new state
# before it removes the file, so there is no gap between the two.
active() {
    [[ -e "${run}/control.resume" ]] && return 0
    case "$(cat "${run}/state" 2>/dev/null)" in staged|running|interrupted) return 0 ;; esac
    return 1
}

# The supervisor writes runs/.heartbeat each time it reports (at least every
# IR_HEARTBEAT seconds). Three missed reports, while the log does not move either,
# mean it is stuck with a state that still reads active: this stream then ends,
# so the viewer can see why and give up in time (attach's INSTALL_RUNNER_ATTACH_LOST_MAX)
# instead of waiting for ever. No heartbeat file: an older supervisor, never judged.
beat="${work}/runs/.heartbeat"
stale_after=$(( ${IR_HEARTBEAT:-60} * 3 ))
supervisor_silent() {
    local b
    b="$(cat "${beat}" 2>/dev/null)"
    [[ "${b}" =~ ^[0-9]+$ ]] || return 1
    (( $(date +%s) - b > stale_after ))
}

tail -c "+${offset}" -f "${log}" &
tailer=$!
trap 'kill "${tailer}" 2>/dev/null' EXIT
# The tailer dies by itself when the viewer goes (SIGPIPE on its next write).
size_seen=-1 quiet_since=${SECONDS}
while kill -0 "${tailer}" 2>/dev/null && active; do
    sleep 2
    if supervisor_silent; then
        size="$(wc -c < "${log}" 2>/dev/null | tr -d ' ')"
        if [[ "${size}" != "${size_seen}" ]]; then
            size_seen="${size}" quiet_since=${SECONDS}
        elif (( SECONDS - quiet_since >= stale_after )); then
            break
        fi
    else
        size_seen=-1
    fi
done
sleep 2
