#!/bin/zsh
# =============================================================================
# full_smoke_chain.sh - test-only chain for the in-cluster install runner
# -----------------------------------------------------------------------------
# Walks the runner path on a real cluster without installing anything. It only
# reads the cluster (oc whoami / get / auth can-i, helm list, ansible k8s_info)
# and only writes files in its own snapshot, on the runner pod's volume. It runs
# in a runner pod only: a local run (INSTALL_RUN_MODE=local) stops before its
# first step, so it never reaches this machine's podman or cpd-cli.
#
# The runner finds it only with IR_MODULE_DIRS=tests/install_runner_smoke
# (README.md here). Offline test: tests/test_install_runner_smoke.py.
#
# Steps: identity, tools, panel, long, write, warn (a --warn step that fails on
# purpose, so the run ends completed-with-warnings). Each has a DO_SMOKE_<STEP>
# toggle. SMOKE_LONG_SECONDS sets the long step's length (default 240).
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export ENV_TARGET="${ENV_TARGET:-smoke}"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"
ir_dispatch "$@"

# Who the pod runs as, and which session it has.
s_identity() {
    oc whoami
    oc whoami --show-server
    print -r -- "cluster-admin: $(oc auth can-i '*' '*' 2>/dev/null || true)"
    print -r -- "KUBECONFIG=${KUBECONFIG:-}"
    id
    print -r -- "HOME=${HOME}"
}

# The image's tools and the shims, read-only. No head: under pipefail a closed
# pipe would fail the step.
s_tools() {
    helm version --short
    helm list -A 2>&1 | sed -n '1,3p'
    print -r -- "namespaces: $(oc get namespaces -o name | wc -l | tr -d ' ')"
    ansible localhost -m kubernetes.core.k8s_info -a "kind=Namespace name=${IR_NAMESPACE:-default}" 2>&1 \
        | grep -E '"name"|SUCCESS|FAILED' | sed -n '1,3p' || true
    # The podman shim runs it here; in the pod there is no container to reach.
    podman exec "${OLM_UTILS_CONTAINER:-olm-utils-play-v4}" oc version --client 2>&1 | sed -n '1p'
    # The cpd-cli shim: nothing to restart in a pod.
    cpd-cli manage restart-container
}

# A progress bar with carriage returns, as the real chains draw them.
s_panel() {
    local i bar="" ticks="${SMOKE_PANEL_TICKS:-20}"
    for (( i = 1; i <= ticks; i++ )); do
        bar+="#"
        printf '\r[%-*s] %3d%%' "${ticks}" "${bar}" $(( i * 100 / ticks ))
        sleep "${SMOKE_PANEL_TICK_SECONDS:-0.5}"
    done
    print
    print -r -- "cols: $(tput cols 2>/dev/null || print -r -- unknown)"
    print -r -- "tty: $([[ -t 1 ]] && print yes || print no)"
}

# Long enough to detach, kill the pod or drain its node in the middle.
s_long() {
    local -i n=0 total="${SMOKE_LONG_SECONDS:-240}" every="${SMOKE_LONG_INTERVAL:-10}" left
    (( every > 0 )) || every=1
    while (( n < total )); do
        print -r -- "[long] ${n}/${total}s ($(( n * 100 / total ))%)"
        left=$(( total - n ))
        sleep $(( left < every ? left : every ))
        n+=$(( left < every ? left : every ))
    done
    print -r -- "[long] ${total}/${total}s (100%)"
}

# Results for collect: one file in each collect root, both inside the snapshot.
s_write() {
    local config="${SMOKE_CONFIG_DIR:?SMOKE_CONFIG_DIR is not set}" instances="${SERVICE_INSTANCE_FILE_DIR:?}"
    [[ "${config:A}/" == "${_CP4D_REPO_ROOT:A}/"* && "${instances:A}/" == "${_CP4D_REPO_ROOT:A}/"* ]] \
        || h_die "The smoke chain writes only inside its snapshot (${_CP4D_REPO_ROOT}); got ${config} and ${instances}."
    date -u +%Y-%m-%dT%H:%M:%SZ > "${config}/result.txt"
    mkdir -p "${instances}/install_runner_smoke"
    print -r -- '{"smoke": true}' > "${instances}/install_runner_smoke/result.json"
    print -r -- "written: ${config#${_CP4D_REPO_ROOT}/}/result.txt, ${instances#${_CP4D_REPO_ROOT}/}/install_runner_smoke/result.json"
}

s_warn() {
    print -r -- "this step warns on purpose"
    return 3
}

h_steps_parse --strict "$@"
h_step        identity "${DO_SMOKE_IDENTITY:-true}" "s1 identity and kubeconfig" s_identity
h_step        tools    "${DO_SMOKE_TOOLS:-true}"    "s2 helm, ansible, shims"    s_tools
h_step        panel    "${DO_SMOKE_PANEL:-true}"    "s3 progress panel"          s_panel
h_step        long     "${DO_SMOKE_LONG:-true}"     "s4 long step"               s_long
h_step        write    "${DO_SMOKE_WRITE:-true}"    "s5 write results"           s_write
h_step --warn warn     "${DO_SMOKE_WARN:-true}"     "s6 warning step"            s_warn
h_steps_plan
# Past the hand-off with no pod: a local run, which this test chain never does.
[[ -n "${IR_IN_RUNNER:-}" ]] \
    || h_die "The smoke chain runs only in a runner pod (INSTALL_RUN_MODE=cluster). Run on this machine it would reach the local podman and cpd-cli."
h_steps_run
