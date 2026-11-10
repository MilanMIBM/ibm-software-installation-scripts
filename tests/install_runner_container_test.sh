#!/bin/bash
# =============================================================================
# install_runner_container_test.sh - runner lifecycle tests, inside the real image
# -----------------------------------------------------------------------------
# Drives the supervisor through pod loss, SIGTERM, stop, failure, warnings and
# resume with a fake `oc`, so it never touches a cluster. `kill -9` of the whole
# process tree stands in for losing a pod; a new supervisor stands in for its
# replacement. Run it from the repo root (it needs a built image):
#
#   git ls-files -z | tar --null -T - -cf - | podman run -i --rm --platform linux/amd64 \
#       --user 54321:0 --tmpfs /work:mode=1777 --entrypoint bash <image> -c \
#       'mkdir -p /tmp/repo && tar -xf - -C /tmp/repo && bash /tmp/repo/tests/install_runner_container_test.sh'
#
# tests/test_install_runner_container.py does this when IR_TEST_IMAGE is set.
# =============================================================================
REPO=/tmp/repo
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; [[ -n "${2:-}" ]] && echo "       ${2}" | cut -c1-200; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }
SECTIONS="$(grep -c '^section "' "$0")" SECTION=0 SECONDS=0
section() { SECTION=$((SECTION+1)); echo; printf '[%d/%d %3d%% %3ds] %s\n' "${SECTION}" "${SECTIONS}" $(( (SECTION-1)*100/SECTIONS )) "${SECONDS}" "$1"; }

mkdir -p /work/cpd-work /tmp/fake /tmp/ctl
cat > /tmp/fake/oc <<'S'
#!/bin/bash
echo "oc $*" >> /tmp/fake/oc.log
case "$*" in
  whoami*) echo system:serviceaccount:ns:install-runner ;;
  create\ configmap*) printf 'kind: ConfigMap\n# %s\n' "$*" ;;
  label*) cat ;;
  apply*) cat >> /tmp/fake/applied.log ;;
esac
exit 0
S
chmod +x /tmp/fake/oc
export PATH=/tmp/fake:$PATH IR_WORK=/work IR_POLL=0.2 IR_HEARTBEAT=1 IR_STOP_GRACE=8 IR_SLOT=test IR_NAMESPACE=ns
export IR_ADMIN_BINDING=ir-test IR_MAX_RESUMES=2 TERM=xterm-256color

SUP=""
sup_start() { /opt/install-runner/bin/supervisor.sh >> /tmp/sup.log 2>&1 & SUP=$!; }
kill_all()  { pkill -9 -f supervisor.sh; pkill -9 -x script; pkill -9 -f run-attempt; pkill -9 -f 'chain.sh|sub.sh'; pkill -9 -f 'tail -c 0'; sleep 0.3; }
state()     { cat /work/current/state 2>/dev/null; }
wait_state() {  # <state>... (any of them), 25 s
    local i s
    for (( i = 0; i < 125; i++ )); do
        s="$(state)"; for w in "$@"; do [[ "${s}" == "${w}" ]] && return 0; done
        sleep 0.2
    done
    echo "       timed out in state '${s}', wanted: $*"; return 1
}
wait_file() { local i; for (( i = 0; i < 125; i++ )); do [[ -e "$1" ]] && return 0; sleep 0.2; done; return 1; }
journal_has() { grep -qP "\t$1\t$2#" /work/current/journal.tsv; }

# A chain with a nested sub-chain. Steps count their runs; "gate" files hold them.
new_run() {   # <id> [chain args...]
    local id="$1"; shift
    local snap="/work/snapshots/${id}" run="/work/runs/${id}"
    mkdir -p "${snap}/src/helpers" "${snap}/chains" "${snap}/configs" "${run}"
    cp "${REPO}/src/helpers/common_helpers.sh" "${REPO}/src/helpers/install_runner_journal.sh" "${snap}/src/helpers/"
    cat > "${snap}/chains/step.sh" <<'S'
#!/bin/bash
# step.sh <name>: count the run, wait at a gate when one is set, exit as told.
n="$1"; echo "$n" >> /tmp/ctl/runs
echo "[$n] working"
while [[ -e "/tmp/ctl/hold.$n" ]]; do sleep 0.1; done
rc=0; [[ -e "/tmp/ctl/rc.$n" ]] && rc="$(cat "/tmp/ctl/rc.$n")"
echo "[$n] done rc=$rc"; exit "$rc"
S
    cat > "${snap}/chains/sub.sh" <<'S'
#!/bin/zsh
set -euo pipefail
export _CP4D_REPO_ROOT="${PWD}"
source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"
h_steps_parse --strict "$@"
h_step s1 true "sub one" /bin/bash chains/step.sh s1
h_step s2 true "sub two" /bin/bash chains/step.sh s2
h_steps_plan
h_steps_run
S
    cat > "${snap}/chains/chain.sh" <<'S'
#!/bin/zsh
set -euo pipefail
export _CP4D_REPO_ROOT="${PWD}"
source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"
h_steps_parse --strict "$@"
h_step a true "top a" /bin/bash chains/step.sh a
h_step sub true "nested chain" /bin/zsh chains/sub.sh
h_step --warn w true "warn step" /bin/bash chains/step.sh w
h_step z true "top z" /bin/bash chains/step.sh z
h_steps_plan
h_steps_run
print -P "%F{green}chain-finished%f"
S
    {
        echo "IR_RUN_ID=${id}"
        echo "IR_CHAIN=chains/chain.sh"
        printf 'IR_ARGS=(%s)\n' "$*"
    } > "${run}/run.env"
    echo 'seed' > "${snap}/configs/kept.sh"
    echo 'seed' > "${snap}/configs/changed.sh"
    /opt/install-runner/bin/finalize-stage.sh "${id}"
    rm -f /tmp/ctl/*
}

section "Identity"
check "not the image user" '[[ "$(id -u)" != 1001 ]]'
check "group 0" '[[ "$(id -g)" == 0 ]]'

section "Happy path, nested chain"
new_run r1
sup_start
wait_state completed
check "state completed" '[[ "$(state)" == completed ]]'
check "steps ran once each" '[[ "$(sort /tmp/ctl/runs | tr "\n" " ")" == "a s1 s2 w z " ]]'
check "top and nested steps journalled" 'journal_has done chains/chain.sh && journal_has done chains/sub.sh'
check "sub step key" 'grep -q "chains/sub.sh#s2" /work/current/journal.tsv'
check "terminal.log has colour" 'grep -q $'"'"'\x1b\[32mchain-finished'"'"' /work/current/terminal.log'
check "stdout was a tty" 'grep -q "Running:  top a" /work/current/terminal.log'
check "plain.log has no escape codes" '! grep -q $'"'"'\x1b'"'"' /work/current/plain.log && grep -q chain-finished /work/current/plain.log'
check "exit code recorded" '[[ "$(cat /work/current/rc)" == 0 ]]'
check "status published" 'grep -q "from-literal=state=completed" /tmp/fake/oc.log'
check "cluster-admin removed at the end" 'grep -q "delete clusterrolebinding ir-test" /tmp/fake/oc.log'
kill_all

section "Pod lost during a nested step: resume skips what finished"
new_run r2
touch /tmp/ctl/hold.s2
sup_start
wait_file /tmp/ctl/runs; sleep 1
kill_all                     # the pod is gone: no chance to record anything
check "state still says running" '[[ "$(state)" == running ]]'
rm -f /tmp/ctl/hold.s2
sup_start
wait_state completed
check "run completed after the restart" '[[ "$(state)" == completed ]]'
check "a ran once" '[[ "$(grep -c "^a$" /tmp/ctl/runs)" == 1 ]]'
check "s1 ran once" '[[ "$(grep -c "^s1$" /tmp/ctl/runs)" == 1 ]]'
check "interrupted s2 ran twice" '[[ "$(grep -c "^s2$" /tmp/ctl/runs)" == 2 ]]'
check "attempt counted" '[[ "$(cat /work/current/attempts)" == 2 ]]'
check "resume shown in the log" 'grep -q "Already finished: top a" /work/current/terminal.log'
check "log kept across the pod loss" 'grep -q "\[a\] working" /work/current/terminal.log'
kill_all

section "SIGTERM (drain): marked interrupted, nothing left running"
new_run r3
touch /tmp/ctl/hold.a
sup_start
wait_file /tmp/ctl/runs; sleep 0.5
kill -TERM "${SUP}"; wait "${SUP}"; rc=$?
check "supervisor exits 143" '[[ "${rc}" == 143 ]]'
check "state interrupted" '[[ "$(state)" == interrupted ]]'
check "chain gone" '! pgrep -f "chains/chain.sh" >/dev/null'
check "step gone" '! pgrep -f "chains/step.sh" >/dev/null'
rm -f /tmp/ctl/hold.a
sup_start
wait_state completed
check "completes on the next pod" '[[ "$(state)" == completed ]]'
kill_all

section "Stop request"
new_run r4
touch /tmp/ctl/hold.a
sup_start
wait_file /tmp/ctl/runs; sleep 0.5
touch /work/current/control.stop
wait_state stopped
check "state stopped" '[[ "$(state)" == stopped ]]'
check "nothing left running" '! pgrep -f "chains/step.sh" >/dev/null'
sleep 1.5
check "stays stopped" '[[ "$(state)" == stopped ]]'
kill_all

section "Real failure: no automatic retry, resume continues"
new_run r5
echo 7 > /tmp/ctl/rc.s1
sup_start
wait_state failed
check "state failed" '[[ "$(state)" == failed ]]'
check "exit code kept" '[[ "$(cat /work/current/rc)" == 7 ]]'
check "journal says failed" 'journal_has failed chains/sub.sh'
sleep 1.5
check "not retried by itself" '[[ "$(grep -c "^s1$" /tmp/ctl/runs)" == 1 ]]'
rm -f /tmp/ctl/rc.s1
touch /work/current/control.resume
wait_state completed
check "resume completes the run" '[[ "$(state)" == completed ]]'
check "a not repeated" '[[ "$(grep -c "^a$" /tmp/ctl/runs)" == 1 ]]'
check "s1 re-ran" '[[ "$(grep -c "^s1$" /tmp/ctl/runs)" == 2 ]]'
kill_all

section "Failure in a pod restart stays failed"
new_run r6
echo 3 > /tmp/ctl/rc.a
sup_start
wait_state failed
kill_all
sup_start
sleep 1.5
check "a new pod does not retry a failed run" '[[ "$(state)" == failed && "$(grep -c "^a$" /tmp/ctl/runs)" == 1 ]]'
kill_all

section "Warned step"
new_run r7
echo 5 > /tmp/ctl/rc.w
sup_start
wait_state completed-with-warnings
check "state completed-with-warnings" '[[ "$(state)" == completed-with-warnings ]]'
check "chain went on past the warning" '[[ "$(grep -c "^z$" /tmp/ctl/runs)" == 1 ]]'
check "status names the step" 'grep -q "from-literal=warned=chains/chain.sh#w" /tmp/fake/oc.log'
rm -f /tmp/ctl/rc.w
echo retry-warned > /work/current/control.resume
wait_state completed
check "resume with retry-warned clears it" '[[ "$(state)" == completed && "$(grep -c "^w$" /tmp/ctl/runs)" == 2 ]]'
kill_all

section "Interrupted too often"
new_run r8
: > /tmp/fake/oc.log
touch /tmp/ctl/hold.a
sup_start
for n in 1 2 3; do
    wait_file /tmp/ctl/runs; sleep 0.7
    kill_all
    rm -f /tmp/ctl/runs
    sup_start
done
wait_file /tmp/ctl/runs; sleep 0.7
kill_all
sup_start
wait_state failed
check "gives up after the limit" '[[ "$(state)" == failed ]]'
check "attempts within the limit" '[[ "$(cat /work/current/attempts)" -le 4 ]]'
sleep 0.5
check "cluster-admin removed when it gives up" 'grep -q "delete clusterrolebinding ir-test" /tmp/fake/oc.log'
kill_all

section "Tap-in"
new_run r9
touch /tmp/ctl/hold.z
sup_start
wait_file /tmp/ctl/runs
sleep 1.5
F=/opt/install-runner/bin/follow.sh
timeout 3 "$F" terminal start > /tmp/v1.out
check "late viewer gets the whole run so far" 'grep -q "\[a\] working" /tmp/v1.out'
size=$(stat -c %s /tmp/v1.out)
timeout 3 "$F" terminal last:2 > /tmp/v2.out
check "last:N gives less" '[[ "$(stat -c %s /tmp/v2.out)" -lt "${size}" ]]'
timeout 6 "$F" terminal start > /tmp/v3a.out & v1=$!
timeout 6 "$F" terminal start > /tmp/v3b.out & v2=$!
wait "${v1}" "${v2}"
echo "       viewer sizes: $(stat -c %s /tmp/v3a.out) $(stat -c %s /tmp/v3b.out), log $(stat -c %s /work/current/terminal.log)"
check "two viewers see the same" '[[ -s /tmp/v3a.out && "$(sha256sum < /tmp/v3a.out)" == "$(sha256sum < /tmp/v3b.out)" ]]'
rm -f /tmp/ctl/hold.z
( "$F" terminal "offset:${size}" > /tmp/v4.out; echo "rc=$?" > /tmp/v4.rc ) &
wait_state completed
wait_file /tmp/v4.rc
check "viewer ends by itself after the run" '[[ "$(cat /tmp/v4.rc)" == rc=0 ]]'
check "offset resumes with no repeat" 'grep -q chain-finished /tmp/v4.out && ! grep -q "\[a\] working" /tmp/v4.out'
timeout 3 "$F" plain start > /tmp/v5.out
check "plain stream has no escapes" '! grep -q $'"'"'\x1b'"'"' /tmp/v5.out && [[ -s /tmp/v5.out ]]'
kill_all

section "Collect list"
snap=/work/snapshots/r9
echo changed > "${snap}/configs/changed.sh"
echo new > "${snap}/configs/new.sh"
out="$(/opt/install-runner/bin/collect-list.sh configs missing-dir)"
check "changed file listed with baseline" 'grep -qP "^[0-9a-f]{64}\t[0-9a-f]{64}\tconfigs/changed.sh$" <<<"${out}"'
check "new file listed with no baseline" 'grep -qP "^-\t[0-9a-f]{64}\tconfigs/new.sh$" <<<"${out}"'
check "unchanged file left out" '! grep -q kept.sh <<<"${out}"'

section "Shims"
C=/opt/ansible/cpd-cli/cpd-cli
"$C" manage get-cr-status --help >/dev/null 2>&1; rc=$?; check "manage reaches the IBM command" '[[ ${rc} != 127 ]]'
"$C" manage restart-container >/dev/null; check "restart-container is a no-op" '[[ $? == 0 ]]'
"$C" manage login-to-ocp --server=x >/dev/null; check "login-to-ocp is a no-op" '[[ $? == 0 ]]'
"$C" manage save-image --from=x >/dev/null 2>&1; rc=$?; check "host-only verb refused" '[[ ${rc} == 3 ]]'
"$C" manage deploy-noobaa-backing-store >/dev/null 2>&1; rc=$?; check "unknown command fails like podman exec" '[[ ${rc} == 127 ]]'
check "real binary answers" '"$C" version 2>&1 | grep -q "Version"'
check "podman exec runs the command" '[[ "$(podman exec -it olm-utils-play-v4 sh -c "echo inside")" == inside ]]'
check "podman exec -e" '[[ "$(podman exec -e FOO=bar x sh -c "echo \$FOO")" == bar ]]'
check "podman inspect image name" '[[ "$(OLM_UTILS_IMAGE=img:1 podman inspect -f "{{.ImageName}}" x)" == img:1 ]]'
check "podman cp from the image" 'podman cp c:/opt/ansible/ansible-play/config-vars /tmp/cv && [[ -d /tmp/cv ]]'
podman build . >/dev/null 2>&1; rc=$?; check "unknown podman verb fails loudly" '[[ ${rc} == 125 ]]'

section "Environment"
check "ansible config found from HOME" 'ansible --version 2>/dev/null | grep -q "config file = /opt/ansible/.ansible.cfg"'
check "work dirs are one directory" '[[ "$(readlink -f /tmp/work)" == /work/cpd-work && "$(readlink -f /opt/ansible/cpd-cli/work)" == /work/cpd-work ]]'
check "shim wins on PATH with HOME/cpd-cli first" '[[ "$(export PATH=$HOME/cpd-cli:$PATH; command -v cpd-cli)" == /opt/ansible/cpd-cli/cpd-cli ]]'

section "Real cpd-cli config, as step 4.2 uses it"
cd /tmp
"$C" config users set tester --apikey=abc --username=tester >/tmp/cfg.out 2>&1; rc=$?
check "users set works here" '[[ ${rc} == 0 ]]' ; [[ ${rc} == 0 ]] || head -5 /tmp/cfg.out
"$C" config profiles set tester-profile --user=tester --url=https://cpd.example >>/tmp/cfg.out 2>&1; rc=$?
check "profiles set works here" '[[ ${rc} == 0 ]]'
check "profile can be read back" '"$C" config profiles list 2>&1 | grep -q tester-profile'
echo "       cpd-cli wrote: $(find / -xdev -type f -newer /tmp/fake/oc -user "$(id -u)" 2>/dev/null | grep -v -E '^/(proc|sys|tmp|work/(runs|snapshots))' | head -6 | tr "\n" " ")"
cd - >/dev/null

section "Real chain and real env loading, through the supervisor"
id=real1
snap="/work/snapshots/${id}" run="/work/runs/${id}"
mkdir -p "${snap}" "${run}"
cp -R "${REPO}/." "${snap}/"
mkdir -p "${snap}/configs/cp4d_config"
cat > "${snap}/configs/cp4d_config/cpd_vars.sh" <<'S'
export OCP_URL="https://api.fake.invalid:6443"
export OC_LOGIN="echo must-not-run; exit 9"
export CPDM_OC_LOGIN="echo must-not-run; exit 9"
export VERSION="5.4.0"; export PATCH_ID="8"
export OLM_UTILS_IMAGE="icr.io/cpopen/cpd/olm-utils-v4:5.4.0.8"
S
cat > "${snap}/scripts/install_cloud_pak_for_data/x_probe_runner.sh" <<'S'
#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
_b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
eval "${OC_LOGIN}"
eval "${CPDM_OC_LOGIN}"
echo "PROBE cpd-cli=$(command -v cpd-cli)"
echo "PROBE home=${HOME}"
echo "PROBE work=$(cd "${CPD_CLI_WORK_PATH}" && pwd -P)"
echo "PROBE config-copy=$(ls /tmp/work/cp4d_config/cpd_vars.sh)"
echo "PROBE tty=$([ -t 2 ] && echo yes || echo no)"
echo "PROBE podman-exec=$(podman exec olm-utils-play-v4 sh -c 'echo ok')"
cpd-cli manage restart-container
S
{ echo "IR_RUN_ID=${id}"
  echo "IR_CHAIN=scripts/install_cloud_pak_for_data/x_probe_runner.sh"
  echo 'IR_ARGS=()'
  echo 'export ENV_TARGET=cpd'; } > "${run}/run.env"
/opt/install-runner/bin/finalize-stage.sh "${id}"
sup_start
wait_state completed failed
check "probe finished" '[[ "$(state)" == completed ]]'; [[ "$(state)" == completed ]] || tail -12 /work/current/plain.log
P=/work/current/plain.log
check "login was a session check" '! grep -q must-not-run "${P}"'
check "shim wins in the real env" 'grep -q "PROBE cpd-cli=/opt/ansible/cpd-cli/cpd-cli" "${P}"'
check "HOME unchanged" 'grep -q "PROBE home=/opt/ansible" "${P}"'
check "work path lands on the volume" 'grep -q "PROBE work=/work/cpd-work" "${P}"'
check "config copied into the shared work dir" 'grep -q "PROBE config-copy=/tmp/work/cp4d_config/cpd_vars.sh" "${P}"'
check "stderr is the PTY" 'grep -q "PROBE tty=yes" "${P}"'
check "podman shim in the real env" 'grep -q "PROBE podman-exec=ok" "${P}"'
check "no podman machine prep" '! grep -q make_executable "${P}"'
kill_all

id=real2
snap="/work/snapshots/${id}" run="/work/runs/${id}"
mkdir -p "${run}"
cp -R /work/snapshots/real1 "${snap}"
{ echo "IR_RUN_ID=${id}"
  echo "IR_CHAIN=scripts/install_cloud_pak_for_data/0_x_full_quick_install_script/full_swhub_x_cpd_installprocess.sh"
  echo 'IR_ARGS=(--list-steps)'
  echo 'export ENV_TARGET=cpd'; } > "${run}/run.env"
/opt/install-runner/bin/finalize-stage.sh "${id}"
sup_start
wait_state completed failed
check "real full chain loads and plans" '[[ "$(state)" == completed ]] && grep -q "softwarehub" /work/current/plain.log'
[[ "$(state)" == completed ]] || tail -12 /work/current/plain.log
kill_all

echo
echo "passed ${PASS}, failed ${FAIL}"
(( FAIL == 0 ))
