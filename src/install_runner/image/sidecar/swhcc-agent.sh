#!/bin/bash
# =============================================================================
# swhcc-agent.sh - PID 1 of the Control Center sidecar in a runner pod
# -----------------------------------------------------------------------------
# The sidecar runs the premium olm-utils image as it comes from IBM, so this is
# bash with coreutils only: no zsh, jq or python. It plays the part of the local
# side container: the runner's swhcc-exec drops a request into a queue on the
# shared volume, and this runs it here and leaves its output and exit code there.
#
# No `oc exec`: nothing needs exec rights, arguments never reach API audit logs,
# and a command keeps running whatever happens to a connection. One request at a
# time, so two setup-control-center runs can never overlap.
#
# A request is a folder <root>/q/<id>/ holding
#   argv       the command, NUL-separated          env        K=V pairs, NUL-separated
#   env.extra  names of `podman exec -e` keys      cwd        working folder (default /opt/ansible)
# and gets from here: claimed/ (taken), pid, out (stdout and stderr), rc, reason.
# The runner writes `cancel` to stop it: TERM to its process group, KILL later.
#
# Env: SWHCC_ROOT (/swhcc), SWHCC_POLL (1 s), SWHCC_KILL_AFTER (30 s), SWHCC_CWD
# (/opt/ansible, the default folder). The last three exist so tests can run this
# outside the image.
# Design: .claude/plans/multi-cluster-management/in-cluster-install-addon/
# d4-control-center-in-pod-design.md, section 3 item 5.
# =============================================================================
shopt -s nullglob

root="${SWHCC_ROOT:-/swhcc}"
q="${root}/q"
hb="${root}/agent.heartbeat"
poll="${SWHCC_POLL:-1}"
kill_after="${SWHCC_KILL_AFTER:-30}"
stopping=""

# Only these reach a command, whatever a request carries; `podman exec -e` keys
# come on top, by name. The rest of the runner's env never crosses over.
allow=" KUBECONFIG K8S_AUTH_KUBECONFIG EXTERNAL_WORK_ROOT CMD_PREFIX OLM_UTILS_IMAGE HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy "

say() { echo "[swhcc-agent] $*"; }

beat() { date +%s > "${hb}.new" 2>/dev/null && mv -f "${hb}.new" "${hb}"; }

write_rc() {   # <request> <rc> [reason]
    [[ -n "${3:-}" ]] && printf '%s\n' "$3" > "$1/reason"
    printf '%s\n' "$2" > "$1/rc.new" && mv -f "$1/rc.new" "$1/rc"
}

# A short sleep that a TERM cuts short.
nap() { sleep "${poll}" & wait $! 2>/dev/null; }

signal_group() {   # <signal> <pid>: the whole process group, else the process
    kill "-$1" -- "-$2" 2>/dev/null || kill "-$1" "$2" 2>/dev/null
}

run_request() {   # <request folder>
    local d="$1" a kv key cwd child rc cancel_at=""
    local -a argv=() envs=()
    while IFS= read -r -d '' a; do argv+=("${a}"); done < "${d}/argv"
    local extra=" " seen=""
    if [[ -f "${d}/env.extra" ]]; then
        while IFS= read -r key; do extra+="${key} "; done < "${d}/env.extra"
    fi
    if [[ -f "${d}/env" ]]; then
        while IFS= read -r -d '' kv; do
            key="${kv%%=*}"
            [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
            # The client writes the Control Center kubeconfig first; a later one
            # (a hand-written request) must not replace it.
            if [[ "${key}" == KUBECONFIG || "${key}" == K8S_AUTH_KUBECONFIG ]]; then
                [[ " ${seen} " == *" ${key} "* ]] && continue
                seen+=" ${key}"
            fi
            [[ "${allow}" == *" ${key} "* || "${extra}" == *" ${key} "* ]] && envs+=("${kv}")
        done < "${d}/env"
    fi
    cwd="$(cat "${d}/cwd" 2>/dev/null)"
    cwd="${cwd:-${SWHCC_CWD:-/opt/ansible}}"
    if (( ${#argv[@]} == 0 )); then
        write_rc "${d}" 2 "empty request"
        return 0
    fi
    say "Running $(basename "${d}"): ${argv[0]}"

    # Its own session, so a cancel reaches everything it started. A background
    # subshell is no group leader, so setsid execs in place: the pid is the group.
    (
        for kv in "${envs[@]}"; do export "${kv}"; done
        cd "${cwd}" || exit 126
        if command -v setsid >/dev/null 2>&1; then exec setsid "${argv[@]}"; fi
        exec "${argv[@]}"
    ) >> "${d}/out" 2>&1 < /dev/null &
    child=$!
    printf '%s\n' "${child}" > "${d}/pid"

    while kill -0 "${child}" 2>/dev/null; do
        beat
        if [[ -z "${cancel_at}" && ( -e "${d}/cancel" || -n "${stopping}" ) ]]; then
            say "Cancelling $(basename "${d}")."
            signal_group TERM "${child}"
            cancel_at="${SECONDS}"
        fi
        if [[ -n "${cancel_at}" ]] && (( SECONDS - cancel_at >= kill_after )); then
            signal_group KILL "${child}"
        fi
        nap
    done
    wait "${child}" 2>/dev/null
    rc=$?
    if [[ -n "${cancel_at}" ]]; then
        if [[ -n "${stopping}" ]]; then write_rc "${d}" 143 "sidecar stopping"
        else write_rc "${d}" 143 "cancelled"
        fi
    else
        write_rc "${d}" "${rc}"
    fi
    say "Finished $(basename "${d}") (exit $(cat "${d}/rc"))."
}

trap 'stopping=1' TERM INT

mkdir -p "${q}/.tmp"
beat
# A request taken before a restart has lost its process with the old container.
for d in "${q}"/*/; do
    d="${d%/}"
    if [[ -d "${d}/claimed" && ! -e "${d}/rc" ]]; then
        echo "[swhcc-agent] The sidecar restarted while this ran; it did not finish." >> "${d}/out"
        write_rc "${d}" 137 "agent restarted"
    fi
done
say "Ready (queue ${q})."

while [[ -z "${stopping}" ]]; do
    beat
    next=""
    # Ids start with the run and a nanosecond time, so the first in glob order is the oldest.
    for d in "${q}"/*/; do
        d="${d%/}"
        [[ -e "${d}/claimed" || ! -f "${d}/argv" ]] && continue
        next="${d}"
        break
    done
    # mkdir is atomic: a request the runner withdrew at the same moment is not run.
    if [[ -n "${next}" ]] && mkdir "${next}/claimed" 2>/dev/null; then
        run_request "${next}"
        continue
    fi
    nap
done
say "Stopping."
exit 0
