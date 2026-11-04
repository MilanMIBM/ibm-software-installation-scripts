#!/bin/zsh
# =============================================================================
# supervisor.sh - PID 1 of an in-cluster install runner pod
# -----------------------------------------------------------------------------
# Owns one slot's run state on the /work volume and stays up after the chain
# ends, so attach, status and collect keep working. A run moves through:
#
#   staged -> running -> completed | completed-with-warnings | failed | stopped
#                  \--> interrupted (pod lost) -> running   (auto, up to a limit)
#
# A pod that dies leaves "running" on disk: that is an interruption and it is
# retried automatically. A chain that exits non-zero is a real failure and waits
# for a person (`x_install_runner.sh resume`).
#
# Env (from the StatefulSet): IR_SLOT, IR_NAMESPACE, IR_OCP_URL, IR_AUTO_RESUME,
# IR_MAX_RESUMES, IR_KEEP_ADMIN, IR_ADMIN_BINDING, IR_TTY_SIZE. IR_WORK and
# IR_BIN exist so tests can run this outside the image.
# =============================================================================
setopt no_nomatch

IR_WORK="${IR_WORK:-/work}"
IR_BIN="${IR_BIN:-/opt/install-runner/bin}"
IR_TTY_SIZE="${IR_TTY_SIZE:-120x50}"
IR_POLL="${IR_POLL:-2}"
IR_HEARTBEAT="${IR_HEARTBEAT:-60}"
IR_STOP_GRACE="${IR_STOP_GRACE:-60}"
export IR_WORK IR_TTY_SIZE IR_MAX_RESUMES="${IR_MAX_RESUMES:-3}"
export TERM="${TERM:-xterm-256color}"

typeset -g SIG_TERM="" LAST_STATUS="" LAST_PUBLISH=0

say() { print -r -- "[supervisor] $*"; }

# --- run state ----------------------------------------------------------------
current_run() { [[ -e "${IR_WORK}/current" ]] && print -r -- "${IR_WORK}/current"(:A); }
state_get() { cat "$1/state" 2>/dev/null; }
state_set() { print -r -- "$2" > "$1/state.new" && mv -f "$1/state.new" "$1/state"; }
attempts_get() { cat "$1/attempts" 2>/dev/null || print 0; }

# Last step that began and has not ended; "-" when none.
current_step() {
    awk -F'\t' '$2=="begin"{s=$3} $2=="done"||$2=="warned"||$2=="failed"{if($3==s)s=""} END{print (s==""?"-":s)}' \
        "$1/journal.tsv" 2>/dev/null || print -- -
}

# Steps whose last record is a warning. A later success clears them.
warned_steps() {
    awk -F'\t' '$2=="warned"||$2=="done"||$2=="failed"{last[$3]=$2} END{for(k in last) if(last[k]=="warned") print k}' \
        "$1/journal.tsv" 2>/dev/null | sort
}

# --- cluster side -------------------------------------------------------------
# A kubeconfig on the pod's projected token: it rotates by itself and dies with
# the pod. The server stays OCP_URL so `oc whoami --show-server` reads as it does
# on a workstation; the in-cluster service is the fallback when the API's public
# name isn't reachable from pods.
write_kubeconfig() {
    local sa=/var/run/secrets/kubernetes.io/serviceaccount
    [[ -r "${sa}/token" ]] || { say "No service account token here; leaving KUBECONFIG alone."; return 0; }
    local server="${IR_OCP_URL%/}" tls="insecure-skip-tls-verify: true"
    if [[ -z "${server}" ]] || ! curl -sk --max-time 10 -o /dev/null "${server}/version"; then
        server="https://kubernetes.default.svc"
        tls="certificate-authority: ${sa}/ca.crt"
        say "API not reachable at ${IR_OCP_URL:-(unset)}; using ${server}."
    fi
    export KUBECONFIG="${KUBECONFIG:-/opt/ansible/.kubeconfig}"
    export K8S_AUTH_KUBECONFIG="${KUBECONFIG}"
    cat > "${KUBECONFIG}" <<KUBE
apiVersion: v1
kind: Config
clusters:
- name: cluster
  cluster:
    server: ${server}
    ${tls}
users:
- name: install-runner
  user:
    tokenFile: ${sa}/token
contexts:
- name: install-runner
  context:
    cluster: cluster
    user: install-runner
    namespace: ${IR_NAMESPACE:-default}
current-context: install-runner
KUBE
    chmod 600 "${KUBECONFIG}"
}

# Status for `x_install_runner.sh status`, readable even when this pod is gone.
# Sent on change and on a heartbeat, so a stale time means a dead supervisor.
publish_status() {
    local run="${1:-}" state="idle" step="-" attempts=0 chain="-" id="-" warned="-" collected=no
    if [[ -n "${run}" ]]; then
        state="$(state_get "${run}")"
        step="$(current_step "${run}")"
        attempts="$(attempts_get "${run}")"
        id="${run:t}"
        chain="$(sed -n 's/^IR_CHAIN=//p' "${run}/run.env" 2>/dev/null | tr -d "'\"")"
        warned="$(warned_steps "${run}" | paste -sd, -)"
        [[ -e "${run}/collected" ]] && collected=yes
    fi
    local now="${EPOCHSECONDS:-$(date +%s)}" sig="${state}|${step}|${attempts}|${id}|${warned}|${collected}"
    [[ "${sig}" == "${LAST_STATUS}" ]] && (( now - LAST_PUBLISH < IR_HEARTBEAT )) && return 0
    LAST_STATUS="${sig}" LAST_PUBLISH="${now}"
    [[ -n "${IR_NAMESPACE:-}" ]] || return 0
    oc create configmap ir-status -n "${IR_NAMESPACE}" \
        --from-literal=slot="${IR_SLOT:-}" --from-literal=state="${state}" --from-literal=step="${step}" \
        --from-literal=attempts="${attempts}" --from-literal=run="${id}" --from-literal=chain="${chain:--}" \
        --from-literal=warned="${warned:--}" --from-literal=collected="${collected}" \
        --from-literal=heartbeat="${now}" \
        --dry-run=client -o yaml 2>/dev/null \
        | oc label --local -f - app.kubernetes.io/managed-by=install-runner --dry-run=client -o yaml 2>/dev/null \
        | oc apply -f - >/dev/null 2>&1 || say "Could not publish status (will retry)."
}

# cluster-admin only lasts as long as a run needs it. `resume` grants it again.
revoke_admin() {
    [[ "${IR_KEEP_ADMIN:-false}" == true || -z "${IR_ADMIN_BINDING:-}" ]] && return 0
    oc delete clusterrolebinding "${IR_ADMIN_BINDING}" --ignore-not-found >/dev/null 2>&1 \
        && say "Removed cluster-admin (${IR_ADMIN_BINDING})." \
        || say "Could not remove ${IR_ADMIN_BINDING}; teardown will."
}

# --- one attempt --------------------------------------------------------------
# script's child sits in its own session, so the signal goes to script, which
# passes it on; closing the PTY then hangs up whatever is left.
stop_chain() {
    local pid="$1" waited=0
    kill -TERM "${pid}" 2>/dev/null
    while kill -0 "${pid}" 2>/dev/null && (( waited < IR_STOP_GRACE )); do sleep 1; (( waited++ )); done
    kill -0 "${pid}" 2>/dev/null && kill -KILL "${pid}" 2>/dev/null
}

run_attempt() {
    local run="$1" attempt pid rc=0 stopping=false filter
    attempt=$(( $(attempts_get "${run}") + 1 ))
    print -r -- "${attempt}" > "${run}/attempts"
    state_set "${run}" running
    publish_status "${run}"
    say "Run ${run:t}: attempt ${attempt}"
    (( attempt > 1 )) && print -r -- $'\r\n[runner] Attempt '"${attempt}"$' of this run: finished steps are skipped.\r' >> "${run}/terminal.log"

    # A stripped copy for --plain and grep: no colour, no cursor moves.
    touch "${run}/terminal.log"
    tail -c 0 -F "${run}/terminal.log" 2>/dev/null \
        | sed -u -E $'s/\x1b\\[[0-9;?]*[A-Za-z]//g; s/\r$//' >> "${run}/plain.log" &
    filter=$!

    setsid script -q -f -e --append --log-out "${run}/terminal.log" \
        -c "${IR_BIN}/run-attempt.sh ${(q)run}" </dev/null &
    pid=$!

    while kill -0 "${pid}" 2>/dev/null; do
        if [[ -n "${SIG_TERM}" ]]; then
            stop_chain "${pid}"
            break
        fi
        if [[ -e "${run}/control.stop" ]]; then
            rm -f "${run}/control.stop"
            stopping=true
            say "Stop requested."
            stop_chain "${pid}"
            break
        fi
        publish_status "${run}"
        sleep "${IR_POLL}"
    done
    wait "${pid}" 2>/dev/null
    rc=$?
    sleep 1
    kill "${filter}" 2>/dev/null
    pkill -f "tail -c 0 -F ${run}/terminal.log" 2>/dev/null

    if [[ -n "${SIG_TERM}" ]]; then
        state_set "${run}" interrupted
        publish_status "${run}"
        say "Pod is going down; run ${run:t} marked interrupted."
        exit 143
    fi

    local state
    if ${stopping}; then state=stopped
    elif (( rc != 0 )); then state=failed
    elif [[ -n "$(warned_steps "${run}")" ]]; then state=completed-with-warnings
    else state=completed
    fi
    print -r -- "${rc}" > "${run}/rc"
    state_set "${run}" "${state}"
    print -r -- $'\r\n[runner] Run '"${run:t}"": ${state} (exit ${rc})"$'\r' >> "${run}/terminal.log"
    say "Run ${run:t}: ${state} (exit ${rc})"
    publish_status "${run}"
    revoke_admin
}

# --- main loop ----------------------------------------------------------------
trap 'SIG_TERM=1' TERM INT

mkdir -p "${IR_WORK}/runs" "${IR_WORK}/snapshots" "${IR_WORK}/cpd-work" \
         "${IR_WORK}/cpd-cli-workspace" "${IR_WORK}/airgap" "${IR_WORK}/tmp"
write_kubeconfig
say "Slot ${IR_SLOT:-?} ready."

# A run still marked running was cut off with no chance to record it.
_r="$(current_run)"
if [[ -n "${_r}" && "$(state_get "${_r}")" == running ]]; then
    state_set "${_r}" interrupted
    say "Run ${_r:t} was cut off by a pod restart."
fi
unset _r

while [[ -z "${SIG_TERM}" ]]; do
    run="$(current_run)"
    if [[ -n "${run}" ]]; then
        case "$(state_get "${run}")" in
            staged)
                run_attempt "${run}"
                ;;
            interrupted)
                if [[ "${IR_AUTO_RESUME:-true}" != true ]]; then
                    state_set "${run}" stopped
                    say "Run ${run:t} interrupted; auto-resume is off."
                    revoke_admin
                elif (( $(attempts_get "${run}") > IR_MAX_RESUMES )); then
                    state_set "${run}" failed
                    say "Run ${run:t} interrupted too many times ($(attempts_get "${run}") attempts); waiting for resume."
                    revoke_admin
                else
                    run_attempt "${run}"
                fi
                ;;
            *)
                if [[ -e "${run}/control.resume" ]]; then
                    # Its content picks which steps run again: "retry-warned" or nothing.
                    cat "${run}/control.resume" > "${run}/retry-warned"
                    rm -f "${run}/control.resume"
                    print 0 > "${run}/attempts"
                    run_attempt "${run}"
                fi
                ;;
        esac
    fi
    publish_status "${run:-}"
    sleep "${IR_POLL}"
done
say "Stopping."
