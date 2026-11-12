"""The runner smoke module (tests/install_runner_smoke/, decision D-b), offline.

The module is test-only: the runner finds it only through IR_MODULE_DIRS, so without that variable it is never
listed, offered or auto-detected as an install. The end-to-end test launches the smoke chain from a sandbox repo
with the runner's fake oc (the hand-off, staging and the watch), then runs what was staged the way the pod would:
the real supervisor and run-attempt.sh, outside the image, on a temp /work, with fakes for oc, helm, ansible,
script and setsid, and the image's own podman and cpd-cli shims. Nothing reaches a cluster, the real podman,
`cpd-cli manage`, the real configs/ or ~/cpd-cli.
"""

import os
import shutil
import signal
import subprocess
import sys
from pathlib import Path

import pytest
from mcm_harness import make_sandbox
from test_install_runner import FAKE_OC, SANDBOX_EXTRA, SANDBOX_URL, out, zsh
from test_install_runner_pod_internals import FAKE_SCRIPT, put, wait_for

REPO = Path(__file__).resolve().parents[1]
SMOKE = "tests/install_runner_smoke"
CHAIN = f"{SMOKE}/full_smoke_chain.sh"
IMAGE = REPO / "src/install_runner/image"
WITH_SMOKE = {"IR_MODULE_DIRS": SMOKE}


# --- hidden unless asked for ---------------------------------------------------------------------------------------
def test_the_smoke_module_is_no_install_without_ir_module_dirs():
    assert "smoke" not in out(zsh("ir_install_ids")).split()
    assert zsh(f"ir_install_for_chain {CHAIN}").returncode != 0
    assert zsh("ir_conf smoke INSTALL_LABEL").returncode != 0
    mode = f'source "{REPO}/src/helpers/install_runner_mode.sh"\nir_is_runner_entrypoint "{REPO}" {CHAIN}'
    assert subprocess.run(["zsh", "-c", mode], env={"PATH": os.environ["PATH"]}, check=False).returncode == 1


def test_ir_module_dirs_adds_the_smoke_module_after_the_real_installs():
    ids = out(zsh("ir_install_ids", env=WITH_SMOKE)).split()
    assert ids[-1] == "smoke" and "cpd" in ids, ids
    assert out(zsh(f'ir_install_for_chain {CHAIN}; print -r -- "$REPLY"', env=WITH_SMOKE)) == "smoke"
    assert out(zsh("ir_conf smoke RUNNER_PVC_SIZE", env=WITH_SMOKE)) == "2Gi"
    # A real install keeps its own module: a test folder cannot shadow it.
    assert out(zsh("ir_conf cpd INSTALL_ID", env={"IR_MODULE_DIRS": f"{SMOKE}:{SMOKE}"})) == "cpd"
    mode = f'source "{REPO}/src/helpers/install_runner_mode.sh"\nir_is_runner_entrypoint "{REPO}" {CHAIN}'
    assert subprocess.run(["zsh", "-c", mode], env={"PATH": os.environ["PATH"], **WITH_SMOKE}, check=False).returncode == 0


@pytest.mark.parametrize("with_smoke", [False, True])
def test_the_same_type_lock_sees_the_smoke_module_only_with_ir_module_dirs(with_smoke):
    """The lock and the fan-out (install_runner_lock.sh, install_runner_fanout.sh) look modules up the same way."""
    installs = REPO / "src/install_runner/installs"
    body = (f'source "{REPO}/src/helpers/install_runner_mode.sh"\n'
            f'ir_entrypoint_install "{installs}" {CHAIN} && print -r -- "chain=$REPLY"\n'
            f'ir_entrypoint_install "{installs}" ./full_smoke_chain.sh --suffix && print -r -- "lease=$REPLY"\n'
            f'print -r -- "label=$(ir_module_value "{installs}" smoke INSTALL_LABEL)"\n'
            f'print -r -- "cpd=$(ir_module_value "{installs}" cpd INSTALL_ID)"\n')
    env = {"PATH": os.environ["PATH"], **(WITH_SMOKE if with_smoke else {})}
    result = subprocess.run(["zsh", "-c", body], env=env, capture_output=True, text=True, check=False)
    lines = result.stdout.splitlines()
    assert "cpd=cpd" in lines
    if with_smoke:
        assert {"chain=smoke", "lease=smoke", "label=Runner smoke test (test only, no product)"} <= set(lines), lines
    else:
        assert "label=" in lines and not any(line.startswith(("chain=", "lease=")) for line in lines), lines


def test_the_template_config_holds_no_credentials():
    text = (REPO / SMOKE / "smoke_config/smoke_vars.sh").read_text()
    assert "--token" not in text and "password" not in text.lower() and "techzone" not in text
    assert 'OCP_URL="${SMOKE_OCP_URL:-${OCP_URL:-' in text


# --- the sandbox ---------------------------------------------------------------------------------------------------
@pytest.fixture
def box():
    with make_sandbox(extra=SANDBOX_EXTRA + [SMOKE]) as sb:
        sb.fake = sb.root / "fake"
        sb.fake.mkdir()
        (sb.bin / "oc").write_text(FAKE_OC)
        config = sb.repo / "configs/smoke_config"
        config.mkdir(parents=True)
        shutil.copy(REPO / SMOKE / "smoke_config/smoke_vars.sh", config / "smoke_vars.sh")
        subprocess.run(["git", "init", "-q"], cwd=sb.repo, env=sb.env(), check=True, capture_output=True)
        yield sb


def launch_env(sb, extra=None):
    return {"FAKE_DIR": sb.fake, "SMOKE_OCP_URL": SANDBOX_URL, "SMOKE_OC_LOGIN": "true", **WITH_SMOKE, **(extra or {})}


def test_x_install_runner_finds_the_smoke_config_only_with_ir_module_dirs(box):
    tool = "scripts/install_runner/x_install_runner.sh"
    env = launch_env(box)
    hidden = box.run_script(tool, env={**env, "IR_MODULE_DIRS": None}, args=["status"])
    assert hidden.returncode == 2, hidden.stdout + hidden.stderr
    assert "Say which install" in hidden.stderr
    assert "smoke" not in hidden.stderr
    named = box.run_script(tool, env={**env, "IR_MODULE_DIRS": None}, args=["status", "--install", "smoke"])
    assert named.returncode == 2 and "No install module: smoke" in named.stderr, named.stderr
    found = box.run_script(tool, env=env, args=["status"])
    assert found.returncode == 0, found.stdout + found.stderr
    assert "CLUSTER" in found.stdout and "SLOT" in found.stdout


def test_a_local_run_of_the_smoke_chain_stops_before_its_first_step(box):
    result = box.run_script(CHAIN, env=launch_env(box, {"INSTALL_RUN_MODE": "local"}))
    assert result.returncode == 1
    assert "runs only in a runner pod" in result.stderr
    assert "cluster-admin:" not in result.stdout and "[long]" not in result.stdout
    assert box.calls("podman") == [] and box.calls("cpd-cli") == []


# --- end to end ----------------------------------------------------------------------------------------------------
# oc in the pod: answers the reads the chain makes and the supervisor's status publish. Every call is logged with
# the kubeconfig it used, so the chain's calls (on the chain's copy) can be told from the supervisor's.
POD_OC = r"""#!/bin/bash
printf '%s|%s\n' "${KUBECONFIG:-}" "$*" >> "$FAKE_DIR/pod_oc.log"
case "$1" in
  whoami) [ "${2:-}" = --show-server ] && echo "https://kubernetes.default.svc" || echo "system:serviceaccount:install-runner-smoke:install-runner" ;;
  auth) echo yes ;;
  get) [ "${2:-}" = namespaces ] && printf 'namespace/a\nnamespace/b\n' ;;
  version) echo "Client Version: 4.19.0" ;;
  create) echo "kind: ConfigMap" ;;
  label) cat ;;
  apply) cat > /dev/null ;;
esac
exit 0
"""
POD_HELM = '#!/bin/bash\necho "helm $*" >> "$FAKE_DIR/pod_tools.log"\n[ "$1" = version ] && echo v3.15.0\nexit 0\n'
POD_ANSIBLE = ('#!/bin/bash\necho "ansible $*" >> "$FAKE_DIR/pod_tools.log"\n'
               'echo \'localhost | SUCCESS => {"resources": [{"metadata": {"name": "x"}}]}\'\n')
FAKE_SETSID = f"#!{sys.executable}\nimport os, sys\nos.setsid()\nos.execvp(sys.argv[1], sys.argv[1:])\n"
# Reads only: oc whoami / get / auth can-i / version; helm version and list; ansible's k8s_info.
READ_ONLY_OC = ("whoami", "get", "auth", "version")


def run_like_the_pod(sb, tmp_path):
    """The staged run, as the pod gets it: snapshot, run.env and path_map on a /work volume. Then the real
    supervisor runs it to the end. Returns the run folder and the snapshot."""
    run_env = (sb.fake / "run.env").read_text()
    run_id = next(line.split("=", 1)[1].strip("'") for line in run_env.splitlines() if line.startswith("IR_RUN_ID="))
    work = tmp_path / "work"
    run, snapshot = work / "runs" / run_id, work / "snapshots" / run_id
    run.mkdir(parents=True)
    shutil.copytree(sb.fake / "pod", snapshot)
    (run / "run.env").write_text(run_env)
    (run / "path_map").write_text((sb.fake / "path_map").read_text())
    (run / "state").write_text("staged\n")
    os.symlink(run, work / "current")

    pod = tmp_path / "pod"
    irbin = pod / "irbin"
    shutil.copytree(IMAGE / "bin", irbin)
    shutil.copy(IMAGE / "shims/podman", irbin / "podman")
    # HOME is /opt/ansible in the image, with the cpd-cli shim in its cpd-cli folder.
    put(pod, "home/cpd-cli/cpd-cli", (IMAGE / "shims/cpd-cli").read_text(), mode=0o755)
    for name, text in (("oc", POD_OC), ("helm", POD_HELM), ("ansible", POD_ANSIBLE), ("script", FAKE_SCRIPT),
                       ("setsid", FAKE_SETSID)):
        put(pod, f"tools/{name}", text, mode=0o755)
    put(pod, "sa/token", "tok\n")
    put(pod, "sa/ca.crt", "ca\n")
    env = {"PATH": f"{pod}/tools:{irbin}:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(pod / "home"),
           "TMPDIR": str(sb.tmp), "FAKE_DIR": str(sb.fake), "IR_WORK": str(work), "IR_BIN": str(irbin),
           "IR_SA_DIR": str(pod / "sa"), "IR_POLL": "0.2", "IR_STOP_GRACE": "5", "IR_OCP_URL": "",
           "IR_NAMESPACE": "install-runner-smoke", "IR_SLOT": "smoke", "IR_ADMIN_BINDING": "install-runner-smoke-admin",
           "SMOKE_LONG_SECONDS": "1", "SMOKE_LONG_INTERVAL": "1", "SMOKE_PANEL_TICKS": "3",
           "SMOKE_PANEL_TICK_SECONDS": "0"}
    with open(tmp_path / "supervisor.log", "w") as log:
        proc = subprocess.Popen(["zsh", str(irbin / "supervisor.sh")], env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            wait_for(lambda: (run / "state").read_text().strip() not in ("staged", "running"), timeout=120)
        finally:
            proc.send_signal(signal.SIGTERM)
            proc.wait(timeout=60)
    return run, snapshot


def test_the_smoke_chain_end_to_end(box, tmp_path):
    (box.fake / "state").write_text("completed\n")
    result = box.run_script(CHAIN, env=launch_env(box), args=["--skip", "panel"], timeout=180)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "hello from the pod" in result.stdout, "the watch ran"
    assert "cluster-admin:" not in result.stdout, "no step ran on the workstation"
    assert box.calls("podman") == [] and box.calls("cpd-cli") == []
    staged = {str(p.relative_to(box.fake / "pod")) for p in (box.fake / "pod").rglob("*") if p.is_file()}
    assert {CHAIN, f"{SMOKE}/smoke.conf", "configs/smoke_config/smoke_vars.sh", "env_bootstrap.sh"} <= staged
    assert not any(p.startswith("configs/") and not p.startswith("configs/smoke_config/") for p in staged)
    run_env = (box.fake / "run.env").read_text()
    assert f"IR_CHAIN='{CHAIN}'" in run_env and "IR_INSTALL_ID='smoke'" in run_env
    assert "export ENV_TARGET='configs/smoke_config/smoke_vars.sh'" in run_env
    assert (box.fake / "path_map").read_text().splitlines() == [
        "configs/smoke_config=SMOKE_CONFIG_DIR:configs/smoke_config",
        "service_instances=SERVICE_INSTANCE_FILE_DIR:service_instances"]

    run, snapshot = run_like_the_pod(box, tmp_path)
    log = (run / "terminal.log").read_text()
    assert (run / "state").read_text().strip() == "completed-with-warnings", log
    assert (run / "attempts.log").read_text().splitlines()[-1].split("\t")[:3] == ["1", "completed-with-warnings", "0"]
    journal = [[f[1], f[2].rpartition("#")[2]] for f in (line.split("\t") for line in
                                                         (run / "journal.tsv").read_text().splitlines())]
    assert ["done", "write"] in journal and ["warned", "warn"] in journal and ["done", "identity"] in journal
    assert ["begin", "panel"] not in journal, "the chain's own arguments reached the pod"
    for text in ("cluster-admin: yes", "namespaces: 2", "Client Version: 4.19.0", "nothing to do in the in-cluster runner",
                 "[long] 1/1s (100%)", "this step warns on purpose"):
        assert text in log, text
    # Written only in its own snapshot, on the volume.
    assert (snapshot / "configs/smoke_config/result.txt").is_file()
    assert (snapshot / "service_instances/install_runner_smoke/result.json").read_text().strip() == '{"smoke": true}'
    assert not (box.repo / "configs/smoke_config/result.txt").exists()
    # Read the cluster only.
    chain_calls = [line.split("|", 1)[1] for line in (box.fake / "pod_oc.log").read_text().splitlines()
                   if line.split("|", 1)[0].endswith("chain.kubeconfig")]
    assert chain_calls and all(call.split()[0] in READ_ONLY_OC for call in chain_calls), chain_calls
    assert all(c.split()[1] in ("namespaces",) for c in chain_calls if c.startswith("get ")), chain_calls
    tools = (box.fake / "pod_tools.log").read_text().splitlines()
    assert tools == ["helm version --short", "helm list -A",
                     "ansible localhost -m kubernetes.core.k8s_info -a kind=Namespace name=install-runner-smoke"], tools
