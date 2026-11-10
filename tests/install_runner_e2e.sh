#!/bin/zsh
# =============================================================================
# install_runner_e2e.sh <image> - the whole path, quickly, with a container as the pod
# -----------------------------------------------------------------------------
# The real launcher, snapshot, attach and collect against a real container running
# the real supervisor. Only `oc` is fake: its `exec` goes to that container. A
# throwaway repo and a demo install keep real configs out of it, and it has its own
# container name, so it never touches olm-utils-play-v4.
#
# One short run: launch, lose the pod, finish, watch again, collect. It stops at the
# first failure, prints [stage/total, %, elapsed] as it goes, and gives up after
# E2E_LIMIT seconds (default 90). The finer cases live in
# tests/install_runner_container_test.sh.
#
# install_runner_e2e.sh --prepare-only <empty dir> builds just the throwaway repo
# in <dir>/repo and stops: no podman, no image. tests/test_install_runner.py uses it
# to check that the copy still loads its env, since the full run needs a built image.
# =============================================================================
PREPARE_ONLY=""
if [[ "${1:-}" == --prepare-only ]]; then
    PREPARE_ONLY=1
    T="${2:?usage: install_runner_e2e.sh --prepare-only <empty dir>}"
    [[ -d "${T}" && -z "$(ls -A "${T}")" ]] || { print -r -- "need an existing empty folder: ${T}" >&2; exit 2; }
    IMAGE=""
else
    IMAGE="${1:?usage: install_runner_e2e.sh <image> | --prepare-only <empty dir>}"
    T="$(mktemp -d)"
fi
REPO="${0:A:h:h}"
NAME=ir-e2e-test
VOL=ir-e2e-test-work
REAL_HOME="${HOME}"   # the podman client finds its machine through HOME
LIMIT="${E2E_LIMIT:-90}"
TOTAL=6 STAGE=0 PASS=0
SECONDS=0

cleanup() {
    jobs -p | xargs -r kill -9 2>/dev/null
    HOME="${REAL_HOME}" podman rm -f "${NAME}" >/dev/null 2>&1
    HOME="${REAL_HOME}" podman volume rm -f "${VOL}" >/dev/null 2>&1
    rm -rf "${T}"
}
if [[ -z "${PREPARE_ONLY}" ]]; then
    trap cleanup EXIT
    trap 'exit 124' INT TERM
fi

stage() { (( ++STAGE )); printf '[%d/%d %3d%% %3ds] %s\n' ${STAGE} ${TOTAL} $(( (STAGE - 1) * 100 / TOTAL )) ${SECONDS} "$1"; }
die() {
    print -r -- "  FAIL $1"
    [[ -f "${T}/view1.out" ]] && { print -r -- "  --- last viewer output:"; tail -6 "${T}/view1.out" | cut -c1-120 | sed 's/^/  /'; }
    print -r -- "failed at stage ${STAGE}/${TOTAL} after ${SECONDS}s (${PASS} checks passed)"
    exit 1
}
check() { if eval "$2"; then (( ++PASS )); print -r -- "  ok   $1"; else die "$1"; fi; }
# Polls until true. Says so every 5 s, and stops at 30 s or the overall limit.
wait_for() {   # <what> <condition>
    local start=${SECONDS} said=${SECONDS}
    until eval "$2"; do
        (( SECONDS - start >= 30 )) && die "timed out: $1"
        (( SECONDS >= LIMIT )) && die "over the ${LIMIT}s limit: $1"
        (( SECONDS - said >= 5 )) && { print -r -- "  ...  waiting for $1 ($(( SECONDS - start ))s)"; said=${SECONDS}; }
        sleep 0.2
    done
}

# --- a throwaway repo with a demo install --------------------------------------
# The repo's code as the runner would stage it (tracked and new files, nothing
# git-ignored, so no configs/ or workspaces): a fixed list broke here each time the
# env load sourced a new helper.
root="${T}/repo"
mkdir -p "${root}"
( cd "${REPO}" && git ls-files -z -c -o --exclude-standard | while IFS= read -r -d '' f; do
      [[ -f "${f}" ]] && print -rn -- "${f}"$'\0'
  done | COPYFILE_DISABLE=1 tar --null -T - -cf - ) | tar -xf - -C "${root}" \
    || die "could not copy the repo"
# Without pipefail the check above sees only the last tar: a failed `git ls-files` (no checkout, no
# git) gives an empty copy that would die later at env load with a less clear error.
[[ -f "${root}/env_bootstrap.sh" && -f "${root}/src/helpers/common_helpers.sh" ]] \
    || die "could not copy the repo (is ${REPO} a git checkout?)"
mkdir -p "${root}/scripts/e2e" "${root}/configs/e2e_config"
cat > "${root}/src/install_runner/installs/e2e.conf" <<'S'
INSTALL_ID="e2e"
INSTALL_LABEL="End-to-end demo"
INSTALL_ENV_TARGET="e2e"
RUNNER_ENTRYPOINTS="scripts/e2e/chain.sh"
RUNNER_STAGE_PATHS="configs/e2e_config"
RUNNER_COLLECT_PATHS="configs/e2e_config"
RUNNER_STORAGE_CLASS_VAR="E2E_SC"
RUNNER_PVC_SIZE="1Gi"
RUNNER_CPU_REQUEST="1m"
RUNNER_MEMORY_REQUEST="1Mi"
RUNNER_MEMORY_LIMIT="1Gi"
S
cat > "${root}/configs/e2e_config/e2e_vars.sh" <<'S'
export OCP_URL="https://api.fake.invalid:6443"
export OC_LOGIN="true"
export E2E_SC=demo
export INSTALL_RUN_MODE=cluster
S
# A flat checkout always has a CP4D config, and the workstation's env load keeps its
# error for an empty configs/cp4d_config; the demo install never reads it.
mkdir -p "${root}/configs/cp4d_config"
print -r -- '# placeholder: the e2e demo install has its own config' > "${root}/configs/cp4d_config/cpd_vars.sh"
print -r -- 'local edit stays' > "${root}/configs/e2e_config/edited.txt"
print -r -- 'seed' > "${root}/configs/e2e_config/plain.txt"
cat > "${root}/scripts/e2e/chain.sh" <<'S'
#!/bin/zsh
set -euo pipefail
export ENV_TARGET=e2e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"
ir_dispatch "$@"
h_steps_parse --strict "$@"
h_step one true "step one" /bin/sh -c 'echo one >> /work/ran; echo ONE-OUTPUT'
h_step two true "step two" /bin/sh -c 'echo two >> /work/ran; echo TWO-START; while [ -e /work/hold ]; do sleep 0.2; done; echo TWO-END'
h_step three true "step three" /bin/sh -c 'echo three >> /work/ran; print_it() { echo "$1" > "configs/e2e_config/$2"; }; print_it from-pod result.sh; print_it from-pod edited.txt; print_it from-pod plain.txt; printf "\033[32mCOLOURED\033[0m\n"'
h_steps_plan
h_steps_run
S
chmod +x "${root}/scripts/e2e/chain.sh"
print -r -- 'configs/*' > "${root}/.gitignore"
( cd "${root}" && git init -q && git add -A >/dev/null )
if [[ -n "${PREPARE_ONLY}" ]]; then
    print -r -- "prepared ${root}"
    exit 0
fi

# --- fake oc: everything canned, except that exec reaches the real container ---
mkdir "${T}/bin"
cat > "${T}/bin/oc" <<S
#!/bin/bash
echo "oc \$*" >> "${T}/oc.log"
case "\$*" in
  "auth can-i"*) echo yes ;;
  whoami*) echo tester ;;
  exec*)
    shift; interactive=""
    while [[ "\$1" != -- ]]; do [[ "\$1" == -i ]] && interactive=-i; shift; done
    shift
    HOME="${REAL_HOME}" exec podman exec \${interactive} ${NAME} "\$@" ;;
  "apply -f -"*) cat >/dev/null ;;
  "get pvc"*) exit 1 ;;
  "get configmap"*) ;;
esac
exit 0
S
chmod +x "${T}/bin/oc"

stage "Start the pod"
podman rm -f "${NAME}" >/dev/null 2>&1
podman volume create "${VOL}" >/dev/null
podman run -d --name "${NAME}" --platform linux/amd64 --user 54321:0 -v "${VOL}:/work:U" \
    -e IR_SLOT=e2e -e IR_POLL=0.2 -e IR_AUTO_RESUME=true -e IR_MAX_RESUMES=3 -e IR_TTY_SIZE=120x50 \
    "${IMAGE}" >/dev/null || die "container did not start"

export PATH="${T}/bin:${PATH}" HOME="${T}/home" INSTALL_RUNNER_IMAGE=fake:1 _CP4D_PREP_DONE=1 NO_COLOR=1 TERM=xterm-256color
unset ENV_TARGET
mkdir -p "${HOME}"
pm() { HOME="${REAL_HOME}" podman "$@"; }
in_pod() { pm exec "${NAME}" sh -c "$1" 2>/dev/null; }
wait_for "the pod" 'in_pod "touch /work/hold"'

stage "Launch from the workstation"
( cd "${root}" && exec zsh scripts/e2e/chain.sh ) > "${T}/view1.out" 2>&1 &
launcher=$!
wait_for "chain output on the workstation" 'grep -q TWO-START "${T}/view1.out"'
check "output reached the workstation" 'grep -q ONE-OUTPUT "${T}/view1.out"'
check "chain did not run here" '[[ ! -e "${root}/configs/e2e_config/result.sh" ]]'
check "state is running, in the pod" '[[ "$(in_pod "cat /work/current/state")" == running ]]'

tool="${root}/scripts/install_runner/x_install_runner.sh"
# Its own process group with SIGINT on, as a foreground job in a terminal has, so
# signalling the group is what Ctrl-C does.
perl -e '$SIG{INT}="DEFAULT"; setpgrp(0,0); exec @ARGV' "${tool}" attach --install e2e --last 5 > "${T}/detach.out" 2>&1 &
viewer=$!
wait_for "a second viewer" 'grep -q TWO-START "${T}/detach.out"'
perl -e 'kill "-INT", shift' ${viewer}
wait_for "the viewer to detach" 'grep -q Detached "${T}/detach.out"'
check "Ctrl-C left the run alone" '[[ "$(in_pod "cat /work/current/state")" == running ]]'

stage "Lose the pod mid-step"
pm restart -t 10 "${NAME}" >/dev/null
wait_for "a new attempt" '[[ "$(in_pod "cat /work/current/attempts")" == 2 ]]'
check "new pod resumed by itself" 'true'
in_pod 'rm -f /work/hold'

stage "Finish, with the viewer still attached"
wait_for "the run to finish" '! kill -0 ${launcher} 2>/dev/null'
wait ${launcher}; rc=$?
check "viewer ended with the run, exit 0" '[[ ${rc} == 0 ]]'
check "state completed" '[[ "$(in_pod "cat /work/current/state")" == completed ]]'
check "finished step not repeated" '[[ "$(in_pod "grep -c ^one$ /work/ran")" == 1 ]]'
check "interrupted step ran again" '[[ "$(in_pod "grep -c ^two$ /work/ran")" == 2 ]]'
check "viewer survived the pod loss" 'grep -q TWO-END "${T}/view1.out"'
check "colour came through" 'grep -qF $'"'"'\x1b[32mCOLOURED'"'"' "${T}/view1.out"'
check "nothing shown twice" '[[ "$(grep -c ONE-OUTPUT "${T}/view1.out")" == 1 ]]'

stage "Come back later with a fresh viewer"
"${root}/scripts/install_runner/x_watch_install.sh" --install e2e --from-start > "${T}/view2.out" 2>&1; rc=$?
check "x_watch_install.sh replays the whole run" '[[ ${rc} == 0 ]] && grep -q ONE-OUTPUT "${T}/view2.out" && grep -q TWO-END "${T}/view2.out"'

stage "Bring the results home"
print -r -- 'changed here during the run' > "${root}/configs/e2e_config/edited.txt"
"${tool}" collect --install e2e > "${T}/collect.out" 2>&1; rc=$?
(( rc == 0 )) || tail -5 "${T}/collect.out" | cut -c1-130
check "collect succeeds" '[[ ${rc} == 0 ]]'
check "new file arrived" '[[ "$(cat "${root}/configs/e2e_config/result.sh")" == from-pod ]]'
check "untouched file updated" '[[ "$(cat "${root}/configs/e2e_config/plain.txt")" == from-pod ]]'
check "local edit kept" '[[ "$(cat "${root}/configs/e2e_config/edited.txt")" == "changed here during the run" ]]'
check "pod copy saved beside it" '[[ -n "$(print -r -- ${root}/configs/e2e_config/edited.txt.in-cluster-*(N))" ]]'

printf '[%d/%d 100%% %3ds] all %d checks passed\n' ${TOTAL} ${TOTAL} ${SECONDS} ${PASS}
