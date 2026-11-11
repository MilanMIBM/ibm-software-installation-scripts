"""Runner pod internals (phase I6): separate supervisor and chain kubeconfigs (X17), what an attempt records
when the pod goes down (live finding L-03), and the notice the supervisor publishes.

Design: .claude/plans/multi-cluster-management/in-cluster-install-addon/d4-control-center-in-pod-design.md,
section 3, build items 1-3 and 21, offline tests 5 and 11. The supervisor runs here outside the image with
fakes for oc, script and setsid (IR_WORK, IR_BIN, IR_SA_DIR point it at a temp folder). Nothing reaches a
cluster, podman, `cpd-cli manage`, the real configs/ or ~/cpd-cli.
"""

import hashlib
import os
import re
import shutil
import signal
import subprocess
import sys
import textwrap
import time
from pathlib import Path

import pytest
from mcm_harness import make_sandbox
from test_install_runner import SANDBOX_URL

REPO = Path(__file__).resolve().parents[1]
BIN = REPO / "src/install_runner/image/bin"
SUPERVISOR = BIN / "supervisor.sh"


def put(root, rel, text, mode=None):
    path = Path(root) / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    if mode is not None:
        path.chmod(mode)
    return path


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def wait_for(check, timeout=30):
    end = time.time() + timeout
    while time.time() < end:
        if check():
            return True
        time.sleep(0.1)
    raise AssertionError("timed out")


# --- the supervisor outside the image ------------------------------------------------------------------------
FAKE_OC = r"""#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_DIR/oc.log"
case "$1" in
  create) echo "kind: ConfigMap" ;;
  label) cat ;;
  apply) cat > /dev/null ;;
esac
exit 0
"""
# script(1) as the runner calls it: `script -q -f -e --append --log-out <log> -c <command>`. Like the real
# one when the pod goes down, a TERM kills the command and the footer still says COMMAND_EXIT_CODE="0".
FAKE_SCRIPT = r"""#!/bin/bash
log="" cmd=""
while (( $# )); do
  case "$1" in
    --log-out) log="$2"; shift 2 ;;
    -c) cmd="$2"; shift 2 ;;
    *) shift ;;
  esac
done
bash -c "$cmd" >> "$log" 2>&1 &
child=$!
trap 'kill -TERM "$child" 2>/dev/null; wait "$child"; printf "\nScript done [COMMAND_EXIT_CODE=\"0\"]\n" >> "$log"; exit 0' TERM
wait "$child"
rc=$?
printf '\nScript done [COMMAND_EXIT_CODE="%s"]\n' "$rc" >> "$log"
exit "$rc"
"""
FAKE_SETSID = f"#!{sys.executable}\nimport os, sys\nos.setsid()\nos.execvp(sys.argv[1], sys.argv[1:])\n"
# Stands in for run-attempt.sh: notes what env the chain got, then does what $FAKE_DIR/chain says.
FAKE_ATTEMPT = r"""#!/bin/bash
echo "KUBECONFIG=${KUBECONFIG:-unset}" > "$FAKE_DIR/attempt.env"
echo "K8S_AUTH_KUBECONFIG=${K8S_AUTH_KUBECONFIG:-unset}" >> "$FAKE_DIR/attempt.env"
echo started > "$FAKE_DIR/attempt.started"
case "$(cat "$FAKE_DIR/chain")" in
  # exec, so the TERM reaches the sleep itself and no orphan outlives the test.
  sleep) exec sleep 300 ;;
  fail)  exit 7 ;;
  *)     exit 0 ;;
esac
"""


class Supervisor:
    def __init__(self, tmp_path, token=True):
        self.tmp = tmp_path
        self.work = tmp_path / "work"
        self.bin = tmp_path / "irbin"
        for name, text in (("oc", FAKE_OC), ("script", FAKE_SCRIPT), ("setsid", FAKE_SETSID)):
            put(tmp_path / "bin", name, text, mode=0o755)
        put(self.bin, "run-attempt.sh", FAKE_ATTEMPT, mode=0o755)
        shutil.copy(BIN / "swhcc-exec", self.bin / "swhcc-exec")
        if token:
            put(tmp_path, "sa/token", "tok\n")
            put(tmp_path, "sa/ca.crt", "ca\n")
        self.run = self.work / "runs/r1"
        put(self.run, "run.env", "IR_RUN_ID='r1'\nIR_CHAIN='x.sh'\n")
        put(self.run, "state", "staged\n")
        os.symlink(self.run, self.work / "current")
        self.proc = None

    def env(self, extra=None):
        return {"PATH": f"{self.tmp}/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(self.tmp), "FAKE_DIR": str(self.tmp),
                "IR_WORK": str(self.work), "IR_BIN": str(self.bin), "IR_SA_DIR": str(self.tmp / "sa"),
                "IR_POLL": "0.2", "IR_STOP_GRACE": "5", "IR_NAMESPACE": "install-runner-cpd-x", "IR_SLOT": "cpd-x",
                "IR_ADMIN_BINDING": "install-runner-cpd-x-admin", "IR_OCP_URL": "", **(extra or {})}

    def start(self, chain):
        (self.tmp / "chain").write_text(chain + "\n")
        self.log = open(self.tmp / "supervisor.log", "w")
        self.proc = subprocess.Popen(["zsh", str(SUPERVISOR)], env=self.env(), stdout=self.log, stderr=subprocess.STDOUT)

    def state(self):
        return (self.run / "state").read_text().strip() if (self.run / "state").exists() else ""

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
            self.proc.wait(timeout=60)
        return self.proc.returncode

    def oc_calls(self):
        path = self.tmp / "oc.log"
        return path.read_text().splitlines() if path.exists() else []


@pytest.fixture
def sup(tmp_path):
    s = Supervisor(tmp_path)
    yield s
    if s.proc and s.proc.poll() is None:
        s.proc.kill()


def test_pod_going_down_marks_the_attempt_interrupted_whatever_script_says(sup):
    """L-03: the PTY footer says COMMAND_EXIT_CODE="0", yet the chain was cut off."""
    q = sup.work / "swhcc/q"
    put(q / "r1-2-2", "rc", "0\n")
    (q / ".tmp").mkdir()
    sup.start("sleep")
    wait_for(lambda: (sup.tmp / "attempt.started").exists())
    assert sup.state() == "running"
    assert sup.stop() == 143
    assert sup.state() == "interrupted"
    assert not (sup.run / "rc").exists(), "an interrupted attempt has no result"
    terminal = (sup.run / "terminal.log").read_text()
    footer = terminal.index('COMMAND_EXIT_CODE="0"')
    assert terminal.index("[runner] Attempt 1 interrupted") > footer, "the note comes after script's footer"
    # attach --plain reads plain.log, which must explain the footer too.
    plain = (sup.run / "plain.log").read_text()
    assert "[runner] Attempt 1 interrupted: the pod is going down. Any exit code above is not its result" in plain
    assert "\x1b" not in plain and "\r" not in plain
    assert (sup.run / "attempts.log").read_text().split("\t")[:3] == ["1", "interrupted", "-"]
    assert sorted(p.name for p in q.iterdir()) == [".tmp"], "the sidecar's queue is cleared as the pod goes down"


def test_a_stopped_run_records_no_exit_code_either(sup):
    sup.start("sleep")
    wait_for(lambda: (sup.tmp / "attempt.started").exists())
    (sup.run / "control.stop").touch()
    wait_for(lambda: sup.state() == "stopped")
    assert not (sup.run / "rc").exists()
    wait_for(lambda: (sup.run / "attempts.log").exists())
    assert (sup.run / "attempts.log").read_text().split("\t")[:3] == ["1", "stopped", "-"]
    assert "(exit" not in (sup.run / "terminal.log").read_text().split("[runner] Run r1:")[-1]
    sup.stop()


@pytest.mark.parametrize("chain,state,rc", [("ok", "completed", "0"), ("fail", "failed", "7")])
def test_a_finished_run_keeps_its_real_exit_code(sup, chain, state, rc):
    sup.start(chain)
    wait_for(lambda: sup.state() == state)
    wait_for(lambda: (sup.run / "rc").exists())
    assert (sup.run / "rc").read_text().strip() == rc
    wait_for(lambda: (sup.run / "attempts.log").exists())
    assert (sup.run / "attempts.log").read_text().split("\t")[:3] == ["1", state, rc]
    wait_for(lambda: f"[runner] Run r1: {state} (exit {rc})" in (sup.run / "plain.log").read_text())
    sup.stop()


def test_a_stale_rc_never_stands_for_a_new_attempt(sup):
    (sup.run / "rc").write_text("0\n")
    sup.start("sleep")
    wait_for(lambda: (sup.tmp / "attempt.started").exists())
    assert not (sup.run / "rc").exists()
    sup.stop()


def test_a_restart_finds_a_run_cut_off_and_records_it(sup):
    (sup.run / "state").write_text("running\n")
    (sup.run / "attempts").write_text("2\n")
    sup.start("sleep")
    # It is interrupted, then resumed as attempt 3.
    wait_for(lambda: (sup.run / "attempts.log").exists())
    assert (sup.run / "attempts.log").read_text().splitlines()[0].split("\t")[:3] == ["2", "interrupted", "-"]
    sup.stop()


def test_supervisor_uses_its_own_kubeconfig_and_gives_the_chain_none(sup):
    """X17: the supervisor's file is under /work/runs, private, and every oc call of the supervisor names it;
    nothing it starts inherits KUBECONFIG (run-attempt.sh hands the chain a copy)."""
    sup.start("ok")
    wait_for(lambda: any(c.startswith("delete clusterrolebinding") for c in sup.oc_calls()))
    kubeconfig = sup.work / "runs/.supervisor.kubeconfig"
    assert kubeconfig.exists()
    assert oct(kubeconfig.stat().st_mode & 0o777) == "0o600"
    text = kubeconfig.read_text()
    assert f"tokenFile: {sup.tmp}/sa/token" in text and "server: https://kubernetes.default.svc" in text
    assert (sup.tmp / "attempt.env").read_text().splitlines() == ["KUBECONFIG=unset", "K8S_AUTH_KUBECONFIG=unset"]
    calls = sup.oc_calls()
    assert calls and all(c.endswith(f"--kubeconfig {kubeconfig}") for c in calls), calls
    assert any(c.startswith("create configmap ir-status") for c in calls)
    assert any(c.startswith("delete clusterrolebinding install-runner-cpd-x-admin") for c in calls)
    sup.stop()


def test_attempt_end_clears_the_sidecar_queue(sup):
    """A Control Center command left in the queue is cancelled when the attempt ends (no agent here, so
    only unclaimed and finished ones are dropped, at once)."""
    q = sup.work / "swhcc/q"
    put(q / "r1-1-1", "argv", "true\0")
    put(q / "r1-2-2", "rc", "0\n")
    (q / ".tmp").mkdir()
    sup.start("ok")
    wait_for(lambda: sup.state() == "completed")
    wait_for(lambda: sorted(p.name for p in q.iterdir()) == [".tmp"])
    sup.stop()


# --- publish_status carries the notice -----------------------------------------------------------------------
def status_functions():
    text = SUPERVISOR.read_text()
    return re.search(r"^current_run\(\).*?(?=^# --- one attempt)", text, re.S | re.M).group(0)


def test_status_publishes_the_notice(tmp_path):
    run = tmp_path / "runs/r1"
    put(run, "run.env", "IR_CHAIN='x.sh'\n")
    put(run, "state", "running\n")
    put(run, "notice", "Control Center cluster not verified: sign in to https://cc,\tthen open https://o\n")
    put(tmp_path, "bin/oc", FAKE_OC, mode=0o755)
    script = (f"typeset -g SIG_TERM='' LAST_STATUS='' LAST_PUBLISH=0 SUP_KUBECONFIG=''\nIR_HEARTBEAT=60\nsay() {{ :; }}\n"
              f"{status_functions()}\npublish_status {run}\nrm {run}/notice\npublish_status {run}\n")
    env = {"PATH": f"{tmp_path}/bin:/usr/bin:/bin", "FAKE_DIR": str(tmp_path), "IR_NAMESPACE": "ns", "HOME": str(tmp_path)}
    result = subprocess.run(["zsh", "-c", script], env=env, capture_output=True, text=True, timeout=60, check=False)
    assert result.returncode == 0, result.stderr
    creates = [l for l in (tmp_path / "oc.log").read_text().splitlines() if l.startswith("create configmap")]
    assert len(creates) == 2, "a changed notice is sent at once, not on the next heartbeat"
    assert "--from-literal=notice=Control Center cluster not verified: sign in to https://cc, then open https://o " in creates[0]
    assert "--from-literal=notice=- " in creates[1]
    assert "--kubeconfig" not in creates[0], "no supervisor file (no token): plain oc"


# --- 5. kubeconfig separation through run-attempt.sh ---------------------------------------------------------
# oc for the chain: `login` writes the server into $KUBECONFIG, as oc does; whoami reads it back.
CHAIN_OC = r"""#!/bin/bash
echo "oc $* KUBECONFIG=${KUBECONFIG:-}" >> "$FAKE_DIR/chain_oc.log"
case "$1" in
  login)
      server=""; for a in "$@"; do case "$a" in --server=*) server="${a#--server=}" ;; esac; done
      printf 'server: %s\nuser: logged-in\n' "$server" > "$KUBECONFIG" ;;
  whoami)
      [ -f "$KUBECONFIG" ] || exit 1
      [ "${2:-}" = --show-server ] && sed -n 's/^ *server: //p' "$KUBECONFIG" | head -1 ;;
esac
exit 0
"""
SUPERVISOR_FILE = "apiVersion: v1\nclusters:\n- cluster:\n    server: {server}\n  name: c\nusers:\n- user:\n    tokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token\n"
CONTROL_VARS = {"CONTROL_CLUSTER_MODE": "{mode}", "CONTROL_OCP_URL": "https://api.cc.example.com:6443",
                "CONTROL_SERVER_ARGUMENTS": "--server=https://api.cc.example.com:6443",
                "CONTROL_OC_LOGIN": "oc login --server=https://api.cc.example.com:6443 --username=u --password=p",
                "CONTROL_OLM_UTILS_IMAGE": "cp.icr.io/cp/cpd/olm-utils-premium-v4:5.4.0.amd64",
                "CONTROL_OLM_UTILS_CONTAINER": "olm-utils-swhub-control-center"}
CHAIN = """\
#!/bin/zsh
set -euo pipefail
source "${0:A:h}/env_bootstrap.sh"
source "${_CP4D_REPO_ROOT}/src/helpers/swhub_control_center_helpers.sh"
print -r -- "START=${KUBECONFIG}|${IR_CHAIN_KUBECONFIG}|${K8S_AUTH_KUBECONFIG:-unset}"
# As toggle_cluster_admins.sh does: no swhcc_activate first, so no IR_SWHCC_KUBECONFIG.
swhcc_oc_login
print -r -- "CONTROL=${KUBECONFIG}|${K8S_AUTH_KUBECONFIG}"
eval "${OC_LOGIN}"
print -r -- "BACK=${KUBECONFIG}|${K8S_AUTH_KUBECONFIG}"
"""


@pytest.mark.parametrize("mode,server", [("different", "https://api.x:6443"), ("same", "https://kubernetes.default.svc")])
def test_chain_logins_never_touch_the_supervisor_file(mode, server):
    """A different-mode login writes only the control kubeconfig; OC_LOGIN switches back to the chain's copy;
    same mode never runs CONTROL_OC_LOGIN, even after the supervisor fell back to kubernetes.default.svc."""
    with make_sandbox() as box:
        box.write_config("cpd", ocp_url=SANDBOX_URL)
        (box.bin / "oc").write_text(CHAIN_OC)
        put(box.repo, "chain.sh", CHAIN)
        work = box.root / "work"
        snap, run = work / "snapshots/r1", work / "runs/r1"
        shutil.copytree(box.repo, snap)
        run.mkdir(parents=True)
        (run / "run.env").write_text("IR_RUN_ID=r1\nIR_INSTALL_ID=cpd\nIR_CHAIN=chain.sh\nIR_ARGS=()\nexport ENV_TARGET='cpd'\n")
        supervisor_file = put(work, "runs/.supervisor.kubeconfig", SUPERVISOR_FILE.format(server=server), mode=0o600)
        before = sha(supervisor_file)
        kube_dir = box.root / "swhcc-kube"
        kube_dir.mkdir()
        env = {k: v.format(mode=mode) for k, v in CONTROL_VARS.items()}
        if mode == "same":
            env["CONTROL_OC_LOGIN"] = f"touch {box.root}/control-login-ran"
            env["CONTROL_OCP_URL"] = SANDBOX_URL
        result = subprocess.run(
            ["zsh", str(BIN / "run-attempt.sh"), str(run)],
            env=box.env({"IR_WORK": work, "IR_SWHCC_KUBE_DIR": kube_dir, "FAKE_DIR": box.root, **env}),
            capture_output=True, text=True, timeout=120, check=False)
        assert result.returncode == 0, result.stdout + result.stderr
        chain_file = run / "chain.kubeconfig"
        control = kube_dir / "control.kubeconfig"
        lines = dict(l.split("=", 1) for l in result.stdout.splitlines() if re.match(r"^(START|CONTROL|BACK)=", l))
        assert lines["START"] == f"{chain_file}|{chain_file}|{chain_file}", "ansible reads K8S_AUTH_KUBECONFIG"
        assert lines["CONTROL"] == f"{control}|{control}"
        assert lines["BACK"] == f"{chain_file}|{chain_file}"
        assert sha(supervisor_file) == before, "the supervisor's file never changes"
        assert oct(chain_file.stat().st_mode & 0o777) == "0o600"
        logins = [l for l in (box.root / "chain_oc.log").read_text().splitlines() if l.startswith("oc login")]
        if mode == "different":
            assert len(logins) == 1 and logins[0].endswith(f"KUBECONFIG={control}")
            assert "--insecure-skip-tls-verify=true" in logins[0], "no TTY for oc's certificate question"
            assert chain_file.read_text() == supervisor_file.read_text(), "the chain's copy is untouched too"
        else:
            assert logins == [] and not (box.root / "control-login-ran").exists()
            assert control.read_text() == supervisor_file.read_text(), "same mode copies the chain's file (tokenFile)"


def test_run_attempt_without_a_supervisor_file_leaves_kubeconfig_alone(tmp_path):
    work = tmp_path / "work"
    snap, run = work / "snapshots/r1", work / "runs/r1"
    put(snap, "chain.sh", 'print -r -- "K=${KUBECONFIG:-unset}|${IR_CHAIN_KUBECONFIG:-unset}|$IR_RUN_ID|$IR_INSTALL_ID"\n')
    put(snap, "src/helpers/multi_cluster_helpers.sh", "")
    run.mkdir(parents=True)
    (run / "run.env").write_text("IR_RUN_ID=r1\nIR_INSTALL_ID=cpd\nIR_CHAIN=chain.sh\nIR_ARGS=()\n")
    result = subprocess.run(["zsh", str(BIN / "run-attempt.sh"), str(run)],
                            env={"PATH": "/usr/bin:/bin", "HOME": str(tmp_path), "IR_WORK": str(work), "KUBECONFIG": "/given"},
                            capture_output=True, text=True, timeout=60, check=False)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "K=/given|unset|r1|cpd"


def test_run_attempt_cancels_orphans_before_the_chain(tmp_path):
    work = tmp_path / "work"
    snap, run = work / "snapshots/r1", work / "runs/r1"
    put(snap, "chain.sh", f'ls "{work}/swhcc/q"\n')
    put(snap, "src/helpers/multi_cluster_helpers.sh", "")
    run.mkdir(parents=True)
    (run / "run.env").write_text("IR_RUN_ID=r1\nIR_CHAIN=chain.sh\nIR_ARGS=()\n")
    put(work, "swhcc/q/r0-1-1/argv", "true\0")
    (work / "swhcc/q/.tmp").mkdir()
    put(tmp_path, "bin/swhcc-exec", (BIN / "swhcc-exec").read_text(), mode=0o755)
    result = subprocess.run(["zsh", str(BIN / "run-attempt.sh"), str(run)],
                            env={"PATH": f"{tmp_path}/bin:/usr/bin:/bin", "HOME": str(tmp_path), "IR_WORK": str(work)},
                            capture_output=True, text=True, timeout=60, check=False)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "", "the chain finds the queue empty"
