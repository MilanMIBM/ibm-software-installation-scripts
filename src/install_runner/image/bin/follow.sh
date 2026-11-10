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

active() { case "$(cat "${run}/state" 2>/dev/null)" in staged|running|interrupted) return 0 ;; esac; return 1; }

tail -c "+${offset}" -f "${log}" &
tailer=$!
trap 'kill "${tailer}" 2>/dev/null' EXIT
# The tailer dies by itself when the viewer goes (SIGPIPE on its next write).
while kill -0 "${tailer}" 2>/dev/null && active; do sleep 2; done
sleep 2
