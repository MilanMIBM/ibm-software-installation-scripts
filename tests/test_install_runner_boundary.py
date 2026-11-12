"""In-cluster runner on multi-cluster management: the flat pod, mapped at stage and collect (phase I2).

Plan: .claude/plans/multi-cluster-management/in-cluster-install-addon/in-cluster-install-addon-plan.md §5
(gaps X1-X5). The pod always sees the flat layout: the workstation streams each root a module names
(RUNNER_STAGE_ROOTS) to its fixed snapshot path, wherever it lives locally, and collect maps it back
through the run's path record.

Everything runs in tests/mcm_harness.py sandboxes with the fake `oc` of tests/test_install_runner.py,
which unpacks each staging stream into <fake>/pod/ as the pod would. Nothing reaches a cluster, podman,
the real configs/ or ~/cpd-cli.
"""

import hashlib
import os
import re
import shutil
import stat
import subprocess
import tarfile
import textwrap
import unicodedata
from pathlib import Path

import pytest
import yaml
from mcm_harness import make_sandbox
from test_install_runner import (CPD_CHAIN, FAKE_OC, HANDOFF_CONFIG, SANDBOX_EXTRA, SANDBOX_URL, handoff,
                                 pod_files, sb)  # noqa: F401 (sb is a fixture)

REPO = Path(__file__).resolve().parents[1]
CLUSTER = "itz-a"
STALE_URL = "https://api.stale.example.com:6443"
COLLECT_TOOL = "scripts/install_runner/x_install_runner.sh"
# What the runner's podman shim answers (src/install_runner/image/shims/podman); anything else fails there.
SHIM_VERBS = {"exec", "inspect", "image", "pull", "create", "cp", "rm", "ps", "info", "version", "--version"}


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def read_env(path):
    """name -> value of the plain assignments in a run.env, the way zsh would read them."""
    script = f'source {path}\nfor n in ${{(k)parameters[(R)scalar*]}}; do [[ $n == (IR_*|ENV_TARGET|MCM_*) ]] && print -r -- "$n=${{(P)n}}"; done; true'
    # A clean env: only what the file sets counts, not what this process exports (the sandbox's MCM_STATE_FILE).
    out = subprocess.run(["zsh", "-f", "-c", script], capture_output=True, text=True, check=True,
                         env={"PATH": "/usr/bin:/bin"}).stdout
    return dict(line.split("=", 1) for line in out.splitlines())


def write_state(box, current=CLUSTER, url=SANDBOX_URL):
    box.write_cluster_marker(current, url)
    (box.repo / "configs/multi_cluster_management.sh").write_text(textwrap.dedent(f"""\
        export MULTI_CLUSTER_MANAGEMENT="true"
        export MCM_CLUSTERS="{current}"
        export MCM_CURRENT_CLUSTER="{current}"
        export APPLY_TO_ALL="false"
        export MCM_TARGET_CLUSTERS=""
        export MCM_CONTAINER_IDLE_TIMEOUT_MINUTES="0"
        """))


def put(root, rel, text, mode=None):
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    if mode is not None:
        path.chmod(mode)
    return path


def collect(box, install, *args, env=None):
    return box.run_script(COLLECT_TOOL, args=("collect", "--install", install, "--slot", "slot", *args),
                          env={"FAKE_DIR": box.fake, **(env or {})}, timeout=120)


def pod_changes(box, changes):
    """Edits the fake pod's snapshot the way a chain would, and fills the fake's collect answers from it:
    collect.tar (the changed files), collect_list (baseline and new hashes) and the pod's run record."""
    pod = box.fake / "pod"
    base = {}
    for rel in changes:
        target = pod / rel
        base[rel] = hashlib.sha256(target.read_bytes()).hexdigest() if target.exists() else "-"
    for rel, text in changes.items():
        put(pod, rel, text)
    with tarfile.open(box.fake / "collect.tar", "w") as tar:
        for rel in changes:
            tar.add(pod / rel, arcname=rel)
    (box.fake / "collect_list").write_text("".join(f"{base[rel]}\t{sha(text)}\t{rel}\n" for rel, text in changes.items()))
    shutil.copy(box.fake / "run.env", box.fake / "pod_run.env")
    shutil.copy(box.fake / "path_map", box.fake / "pod_path_map")
    (box.fake / "state").write_text("completed\n")


# --- stage: delineated and flat ---------------------------------------------------------------------------------
def test_delineated_round_trip(sb):
    """A pinned run stages its cluster's folders under the flat names, and nothing else of the cluster folder."""
    write_state(sb)
    cluster = sb.repo / "configs/clusters" / CLUSTER
    # A stale flat config of another cluster, side by side (gap X1 case 1): never staged.
    sb.write_config("cpd", ocp_url=STALE_URL, extra={"PROJECT_CPD_INST_OPERANDS": "stale"})
    put(sb.repo, "service_instances/flat_payload.json", "flat\n")
    put(cluster, "service_instances/wx.json", '{"a": 1}\n')
    put(cluster, "cp4d_config/managed-service-instances/wx/wx1-instance_details.sh", "export A=1\n")
    for rel in (".home/.kube/config", ".home/.cpd-cli/config", "cpd-cli-workspace/olm-utils-workspace/x",
                "datastax_mc_workspace/tools/helm", "concert_config/concert_vars.sh"):
        put(cluster, rel, "stays home\n")
    (sb.fake / "state").write_text("completed\n")

    result = handoff(sb, cluster=CLUSTER)
    assert result.returncode == 0, result.stdout + result.stderr
    names = pod_files(sb)
    assert (sb.fake / "pod/configs/cp4d_config/cpd_vars.sh").read_text() == (cluster / "cp4d_config/cpd_vars.sh").read_text()
    assert "configs/cp4d_config/managed-service-instances/wx/wx1-instance_details.sh" in names
    assert "service_instances/wx.json" in names
    assert "service_instances/flat_payload.json" not in names
    assert not any(re.search(r"(^|/)(\.home|\.kube|\.cpd-cli|[^/]*_workspace|clusters|\.cluster)(/|$)", n) for n in names), names
    assert "configs/multi_cluster_management.sh" not in names
    assert not any(n.startswith("configs/") and not n.startswith("configs/cp4d_config/") for n in names)
    assert (sb.fake / "streams").read_text().split() == [".", "configs/cp4d_config", "service_instances"]

    run_env = read_env(sb.fake / "run.env")
    assert run_env["IR_LAYOUT"] == "cluster"
    assert run_env["IR_SOURCE_CLUSTER"] == CLUSTER
    assert run_env["IR_CLUSTER_URL"] == SANDBOX_URL
    assert run_env["ENV_TARGET"] == "cpd", "an inferred target stays bare"
    assert run_env["IR_ENV_TARGET"] == "configs/cp4d_config/cpd_vars.sh"
    assert run_env["IR_PATH_MAP"].endswith("/path_map")
    assert not any(k.startswith("MCM_") for k in run_env), run_env
    assert (sb.fake / "path_map").read_text() == (
        f"configs/cp4d_config=CONFIG_DIR:configs/clusters/{CLUSTER}/cp4d_config\n"
        f"service_instances=SERVICE_INSTANCE_FILE_DIR:configs/clusters/{CLUSTER}/service_instances\n")
    docs = [d for d in yaml.safe_load_all((sb.fake / "applied.yaml").read_text()) if d]
    sts = next(d for d in docs if d["kind"] == "StatefulSet")
    env = {e["name"]: e.get("value") for e in sts["spec"]["template"]["spec"]["containers"][0]["env"]}
    assert env["IR_SOURCE_CLUSTER"] == CLUSTER
    assert "MCM_CLUSTER" not in env
    assert sts["metadata"]["namespace"] == "install-runner-cpd-cpd-op", "slot named from the pinned config"

    # Collect: the results land in the cluster folder, not in the stale flat one.
    pod_changes(sb, {"configs/cp4d_config/cpd_instance_details.sh": "export CPD_APIKEY=new\n",
                     "configs/cp4d_config/managed-service-instances/wx/wx2-instance_details.sh": "export B=2\n",
                     "service_instances/wx.json": '{"a": 2}\n'})
    result = collect(sb, "cpd")
    assert result.returncode == 0, result.stdout + result.stderr
    assert (cluster / "cp4d_config/cpd_instance_details.sh").read_text() == "export CPD_APIKEY=new\n"
    assert (cluster / "cp4d_config/managed-service-instances/wx/wx2-instance_details.sh").read_text() == "export B=2\n"
    assert (cluster / "service_instances/wx.json").read_text() == '{"a": 2}\n'
    assert not (sb.repo / "configs/cp4d_config/cpd_instance_details.sh").exists()
    assert (sb.repo / "service_instances/flat_payload.json").read_text() == "flat\n"
    assert sb.calls("cpd-cli") == [] or all(c[0] != "manage" for c in sb.calls("cpd-cli"))


def test_flat_round_trip(sb):
    put(sb.repo, "service_instances/payload.json", "old\n")
    (sb.fake / "state").write_text("completed\n")
    result = handoff(sb)
    assert result.returncode == 0, result.stdout + result.stderr
    run_env = read_env(sb.fake / "run.env")
    assert (run_env["IR_LAYOUT"], run_env["IR_SOURCE_CLUSTER"]) == ("flat", "")
    assert (sb.fake / "path_map").read_text() == ("configs/cp4d_config=CONFIG_DIR:configs/cp4d_config\n"
                                                  "service_instances=SERVICE_INSTANCE_FILE_DIR:service_instances\n")
    assert "service_instances/payload.json" in pod_files(sb)

    pod_changes(sb, {"configs/cp4d_config/cpd_instance_details.sh": "export CPD_APIKEY=new\n",
                     "service_instances/payload.json": "new\n"})
    result = collect(sb, "cpd")
    assert result.returncode == 0, result.stdout + result.stderr
    assert (sb.repo / "configs/cp4d_config/cpd_instance_details.sh").read_text() == "export CPD_APIKEY=new\n"
    assert (sb.repo / "service_instances/payload.json").read_text() == "new\n"


def test_code_files_never_hit_the_prune_list():
    """A code folder named like a pruned one (oadp, *_workspace, ...) would silently go missing in pods."""
    files = subprocess.check_output(["git", "ls-files", "-c", "-o", "--exclude-standard"], cwd=REPO, text=True).split("\n")
    script = textwrap.dedent("""\
        source src/helpers/install_runner_helpers.sh
        while IFS= read -r f; do [[ -n "$f" ]] && _ir_pruned "$f" && print -r -- "$f"; done
        true
        """)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("IR_", "INSTALL_RUN"))}
    result = subprocess.run(["zsh", "-c", script], input="\n".join(files), capture_output=True, text=True,
                            env={**env, "_CP4D_REPO_ROOT": str(REPO)}, cwd=REPO, check=False)
    assert result.returncode == 0, result.stderr
    assert result.stdout == "", result.stdout


# --- the pod stays flat -----------------------------------------------------------------------------------------
def test_pod_loads_flat_whatever_the_snapshot_and_env_say():
    """run-attempt.sh, on a snapshot that (wrongly) carries a .cluster marker and a mode-on state file, with
    MCM_CLUSTER in its env: the chain still loads flat, keeps the supervisor's kubeconfig and the work dir that
    the image links to the volume, and calls no podman verb the runner's shim lacks."""
    with make_sandbox() as box:
        box.write_config("cpd", ocp_url=SANDBOX_URL)
        put(box.repo, "configs/clusters/x/cp4d_config/cpd_vars.sh", 'export OCP_URL="https://api.x.example.com:6443"\n')
        box.write_cluster_marker("x", "https://api.x.example.com:6443")
        state_text = ('export MULTI_CLUSTER_MANAGEMENT="true"\nexport MCM_CLUSTERS="x"\n'
                      'export MCM_CURRENT_CLUSTER="x"\nexport MCM_CONTAINER_IDLE_TIMEOUT_MINUTES="0"\n')
        put(box.repo, "configs/multi_cluster_management.sh", state_text)
        put(box.repo, "chain.sh", textwrap.dedent("""\
            #!/bin/zsh
            set -euo pipefail
            source "${0:A:h}/env_bootstrap.sh"
            print -r -- "===DUMP==="
            print -r -- "CONFIGS_ROOT=${CONFIGS_ROOT}"
            print -r -- "CONFIG_DIR=${CONFIG_DIR}"
            print -r -- "KUBECONFIG=${KUBECONFIG:-}"
            print -r -- "CPD_CLI_WORK_PATH=${CPD_CLI_WORK_PATH}"
            print -r -- "MCM_CLUSTER=${MCM_CLUSTER:-}"
            print -r -- "MCM_STATE_FILE=${MCM_STATE_FILE:-}"
            print -r -- "OC_LOGIN=${OC_LOGIN}"
            """))
        work = box.root / "work"
        snap, run = work / "snapshots/r1", work / "runs/r1"
        shutil.copytree(box.repo, snap)
        run.mkdir(parents=True)
        (run / "run.env").write_text("IR_RUN_ID=r1\nIR_CHAIN=chain.sh\nIR_ARGS=()\nexport ENV_TARGET='cpd'\n")
        kubeconfig = box.home / ".kubeconfig"
        result = subprocess.run(
            ["zsh", str(REPO / "src/install_runner/image/bin/run-attempt.sh"), str(run)],
            env=box.env({"IR_WORK": work, "KUBECONFIG": kubeconfig, "MCM_CLUSTER": "x",
                         "MCM_CLUSTER_ROOT": snap / "configs/clusters/x", "CPDCONFIG": "/nope"}),
            capture_output=True, text=True, timeout=120, check=False)
        assert result.returncode == 0, result.stdout + result.stderr
        dump = dict(line.split("=", 1) for line in result.stdout.split("===DUMP===\n", 1)[1].splitlines())
        assert dump["CONFIGS_ROOT"] == f"{snap}/configs"
        assert dump["CONFIG_DIR"] == f"{snap}/configs/cp4d_config"
        assert dump["KUBECONFIG"] == str(kubeconfig)
        assert dump["CPD_CLI_WORK_PATH"] == f"{box.home}/cpd-cli/work"
        assert dump["MCM_CLUSTER"] == ""
        assert dump["MCM_STATE_FILE"] == f"{run}/mcm_off.sh"
        assert dump["OC_LOGIN"] == "oc whoami >/dev/null"
        verbs = {call[0] for call in box.calls("podman") if call}
        assert verbs <= SHIM_VERBS, verbs
        assert (snap / "configs/multi_cluster_management.sh").read_text() == state_text, "the staged state file is never used"
        off = (run / "mcm_off.sh").read_text()
        assert re.search(r'^export MULTI_CLUSTER_MANAGEMENT="false"', off, re.MULTILINE), off
        assert stat.S_IMODE((run / "mcm_off.sh").stat().st_mode) == 0o600
        # The repo's own reader takes it as mode off, without a complaint.
        check = box.run_zsh(f'source src/helpers/multi_cluster_helpers.sh\nif mcm_is_on; then print on; else print off; fi\n',
                            env={"MCM_STATE_FILE": run / "mcm_off.sh"})
        assert check.stdout.strip() == "off" and check.stderr == "", check.stdout + check.stderr


def test_relative_env_target_becomes_absolute_in_the_pod(tmp_path):
    work = tmp_path / "work"
    snap, run = work / "snapshots/r1", work / "runs/r1"
    put(snap, "chain.sh", 'print -r -- "ENV_TARGET=$ENV_TARGET"\n')
    put(snap, "src/helpers/multi_cluster_helpers.sh", "")
    run.mkdir(parents=True)
    (run / "run.env").write_text("IR_RUN_ID=r1\nIR_CHAIN=chain.sh\nIR_ARGS=()\nexport ENV_TARGET='configs/cp4d_config/inst2/cpd_vars.sh'\n")
    result = subprocess.run(["zsh", str(REPO / "src/install_runner/image/bin/run-attempt.sh"), str(run)],
                            env={"PATH": "/usr/bin:/bin", "HOME": str(tmp_path), "IR_WORK": str(work)},
                            capture_output=True, text=True, timeout=60, check=False)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == f"ENV_TARGET={snap.resolve()}/configs/cp4d_config/inst2/cpd_vars.sh" \
        or result.stdout.strip() == f"ENV_TARGET={snap}/configs/cp4d_config/inst2/cpd_vars.sh"
    # The fallback state file still says mode off when the helpers can't render one.
    assert 'MULTI_CLUSTER_MANAGEMENT="false"' in (run / "mcm_off.sh").read_text()


def test_code_tar_skips_cluster_state_even_when_tracked(sb):
    """.gitignore hides configs/* in a normal checkout; the prune holds when someone force-added them."""
    (sb.fake / "state").write_text("completed\n")
    sb.write_cluster_marker("x", STALE_URL)
    put(sb.repo, "configs/clusters/x/cp4d_config/cpd_vars.sh", f'export OCP_URL="{STALE_URL}"\n')
    put(sb.repo, "configs/multi_cluster_management.sh", "# tracked by mistake\n")
    put(sb.repo, "src/notes/.cluster", "a marker in the code tree\n")
    tracked = ["configs/clusters/x/cp4d_config/cpd_vars.sh", "configs/clusters/x/.cluster",
               "configs/multi_cluster_management.sh", "src/notes/.cluster"]
    subprocess.run(["git", "add", "-f", *tracked], cwd=sb.repo, env=sb.env(), check=True, capture_output=True)
    result = handoff(sb)
    assert result.returncode == 0, result.stdout + result.stderr
    names = pod_files(sb)
    assert not set(tracked) & names, set(tracked) & names
    assert not any(n.startswith("configs/clusters") for n in names)


# --- refusals before anything changes on the cluster ------------------------------------------------------------
def test_same_cluster_guard_refuses_a_config_for_another_cluster(sb):
    """X1: the loaded session ends up on another URL than the config file's own literal OCP_URL."""
    put(sb.repo, "configs/cp4d_config/cpd_instance_details.sh", f'export OCP_URL="{STALE_URL}"\n')
    result = handoff(sb)
    assert result.returncode != 0
    assert "configs/cp4d_config/cpd_vars.sh" in result.stderr
    assert SANDBOX_URL in result.stderr and STALE_URL in result.stderr
    assert "Nothing was staged" in result.stderr
    assert not (sb.fake / "oc.log").exists(), "refused before any cluster call"


def test_same_cluster_guard_takes_one_cluster_written_two_ways(sb):
    """The guard compares clusters as MCM does: case and the default port do not make another cluster."""
    (sb.fake / "state").write_text("completed\n")
    put(sb.repo, "configs/cp4d_config/cpd_instance_details.sh", 'export OCP_URL="https://API.X:6443/"\n')
    result = handoff(sb)
    assert result.returncode == 0, result.stdout + result.stderr


def test_env_target_all_is_refused(sb):
    result = handoff(sb, "--env-target", "all")
    assert result.returncode != 0
    assert "ENV_TARGET=all loads every config" in result.stderr
    assert not (sb.fake / "oc.log").exists()


def test_env_target_file_run(sb):
    """X4: --env-target <file> stages that file and the pod loads it, under the slot named from it."""
    (sb.fake / "state").write_text("completed\n")
    sb.write_config("cpd", ocp_url=SANDBOX_URL, extra=HANDOFF_CONFIG)  # the default file, for the folder
    inst2 = {**HANDOFF_CONFIG, "PROJECT_CPD_INST_OPERANDS": "inst2", "INSTALL_RUN_MODE": "cluster"}
    put(sb.repo, "configs/cp4d_config/inst2/cpd_vars.sh",
        "".join(f'export {k}="{v}"\n' for k, v in {"OCP_URL": SANDBOX_URL, "OC_LOGIN": "true",
                                                   "OLM_UTILS_IMAGE": "icr.io/cpopen/cpd/olm-utils-v4:5.4.0.8", **inst2}.items()))
    result = handoff(sb, "--env-target", "configs/cp4d_config/inst2/cpd_vars.sh")
    assert result.returncode == 0, result.stdout + result.stderr
    run_env = read_env(sb.fake / "run.env")
    assert run_env["ENV_TARGET"] == "configs/cp4d_config/inst2/cpd_vars.sh"
    assert run_env["IR_ENV_TARGET"] == "configs/cp4d_config/inst2/cpd_vars.sh"
    assert "configs/cp4d_config/inst2/cpd_vars.sh" in pod_files(sb)
    assert "-n install-runner-cpd-inst2" in (sb.fake / "oc.log").read_text()


def test_env_target_file_outside_the_roots_is_staged_at_its_flat_place(sb):
    (sb.fake / "state").write_text("completed\n")
    sb.write_config("cpd", ocp_url=SANDBOX_URL, extra=HANDOFF_CONFIG)
    alt = {**HANDOFF_CONFIG, "INSTALL_RUN_MODE": "cluster", "OCP_URL": SANDBOX_URL, "OC_LOGIN": "true",
           "OLM_UTILS_IMAGE": "icr.io/cpopen/cpd/olm-utils-v4:5.4.0.8"}
    put(sb.repo, "configs/alt_config/cpd_alt_vars.sh", "".join(f'export {k}="{v}"\n' for k, v in alt.items()))
    result = handoff(sb, "--env-target", "configs/alt_config/cpd_alt_vars.sh")
    assert result.returncode == 0, result.stdout + result.stderr
    assert read_env(sb.fake / "run.env")["ENV_TARGET"] == "configs/alt_config/cpd_alt_vars.sh"
    assert "configs/alt_config/cpd_alt_vars.sh" in pod_files(sb)
    assert not any(n.startswith("configs/alt_config/") and n != "configs/alt_config/cpd_alt_vars.sh" for n in pod_files(sb))


def test_env_target_file_outside_the_repo_is_refused(sb, tmp_path):
    sb.write_config("cpd", ocp_url=SANDBOX_URL, extra=HANDOFF_CONFIG)
    outside = put(tmp_path, "elsewhere/cpd_vars.sh",
                  f'export OCP_URL="{SANDBOX_URL}"\nexport OC_LOGIN="true"\nexport INSTALL_RUN_MODE="cluster"\n'
                  'export PROJECT_CPD_INST_OPERANDS="x"\n')
    result = handoff(sb, "--env-target", str(outside))
    assert result.returncode != 0
    assert "outside this checkout" in result.stderr
    assert not (sb.fake / "oc.log").exists()


def module(box, conf, hook=None):
    (box.repo / "src/install_runner/installs/demo.conf").write_text(conf)
    if hook is not None:
        (box.repo / "src/install_runner/installs/demo.sh").write_text(hook)


def plan(box, env, body="_ir_stage_plan demo chain.sh"):
    script = f'source src/helpers/install_runner_helpers.sh\n{body}\n'
    return box.run_zsh(script, env={"_CP4D_REPO_ROOT": box.repo, "FAKE_DIR": box.fake, **env})


@pytest.mark.parametrize("folder,why", [
    ("configs/clusters/x", "whole configs folder"),
    ("configs", "whole configs folder"),
    ("configs/clusters/x/.home/demo_config", "holds logins"),
    ("configs/notes", "only *_config folders"),
])
def test_roots_outside_the_allowlist_are_refused(sb, folder, why):
    module(sb, 'INSTALL_ID="demo"\nRUNNER_STAGE_ROOTS="DEMO_DIR:configs/demo_config"\n')
    (sb.repo / folder).mkdir(parents=True, exist_ok=True)
    result = plan(sb, {"DEMO_DIR": sb.repo / folder, "ENV_TARGET": "demo"})
    assert result.returncode != 0
    assert why in result.stderr, result.stderr


def test_stage_hook_adds_files_and_folders(sb):
    (sb.fake / "state").write_text("completed\n")
    put(sb.repo, "extra/rendered/a.yaml", "a\n")
    put(sb.repo, "extra/rendered/kubecost_workspace/big", "no\n")
    put(sb.repo, "extra/archive.tgz", "tgz\n")
    hook = textwrap.dedent("""\
        #!/bin/zsh
        case "${1:-}" in
            stage) print -r -- $'extra/rendered\\tconfigs/demo_config/rendered'
                   print -r -- "${_CP4D_REPO_ROOT}/extra/archive.tgz"$'\\tdemo_workspace_in_pod/installer.tgz' ;;
        esac
        """)
    sb.write_config("cpd", ocp_url=SANDBOX_URL, extra=HANDOFF_CONFIG)
    (sb.repo / "src/install_runner/installs/cpd.sh").write_text(hook)
    result = handoff(sb)
    assert result.returncode == 0, result.stdout + result.stderr
    names = pod_files(sb)
    assert "configs/demo_config/rendered/a.yaml" in names
    assert "configs/demo_config/rendered/kubecost_workspace/big" not in names
    assert (sb.fake / "pod/demo_workspace_in_pod/installer.tgz").read_text() == "tgz\n"


def test_cpd_preflight_checks_the_staged_folder(sb):
    """4.1 reads INSTALL_OPTIONS_FILE from the staged configs/cp4d_config: under a pin that is the cluster's
    folder, so an options file only in the flat folder is refused before anything is staged."""
    write_state(sb)
    cluster = sb.repo / "configs/clusters" / CLUSTER
    put(sb.repo, "configs/cp4d_config/install-options.yml", "flat: true\n")
    (sb.fake / "state").write_text("completed\n")
    env = {"INSTALL_OPTIONS_FILE": "install-options.yml"}
    result = handoff(sb, cluster=CLUSTER, env=env)
    assert result.returncode != 0
    assert f"is not in {cluster.resolve()}/cp4d_config" in result.stdout + result.stderr, result.stdout + result.stderr
    assert not (sb.fake / "streams").exists(), "refused before staging"

    put(cluster, "cp4d_config/install-options.yml", "cluster: true\n")
    result = handoff(sb, cluster=CLUSTER, env=env)
    assert result.returncode == 0, result.stdout + result.stderr
    assert (sb.fake / "pod/configs/cp4d_config/install-options.yml").read_text() == "cluster: true\n"


def test_stage_hook_cannot_name_a_login_folder(sb):
    sb.write_config("cpd", ocp_url=SANDBOX_URL, extra=HANDOFF_CONFIG)
    put(sb.home, ".kube/config", "token\n")
    (sb.repo / "src/install_runner/installs/cpd.sh").write_text(
        f'case "${{1:-}}" in stage) print -r -- "{sb.home}/.kube/config"$\'\\t\'"configs/cp4d_config/kc" ;; esac\n')
    result = handoff(sb)
    assert result.returncode != 0
    assert "holds logins" in result.stderr
    assert not (sb.fake / "oc.log").exists()


@pytest.mark.parametrize("named", [f"configs/clusters/{CLUSTER}", f"configs/clusters/{CLUSTER}/.cluster",
                                   "configs/multi_cluster_management.sh", "configs"])
def test_stage_hook_refuses_cluster_state(sb, named):
    """Hook pairs skip the prune list, so cluster markers, the state file and whole cluster folders are refused."""
    sb.write_cluster_marker(CLUSTER, STALE_URL)
    put(sb.repo, "configs/multi_cluster_management.sh", "# not read: the sandbox's state file is elsewhere\n")
    sb.write_config("cpd", ocp_url=SANDBOX_URL, extra=HANDOFF_CONFIG)
    (sb.repo / "src/install_runner/installs/cpd.sh").write_text(
        f'case "${{1:-}}" in stage) print -r -- "{named}"$\'\\t\'"configs/cp4d_config/x" ;; esac\n')
    result = handoff(sb)
    assert result.returncode != 0
    assert "never go to a pod" in result.stderr, result.stderr
    assert not (sb.fake / "oc.log").exists()


def test_a_root_that_is_a_file_is_refused(sb):
    module(sb, 'INSTALL_ID="demo"\nRUNNER_STAGE_ROOTS="DEMO_DIR:configs/demo_config"\n')
    put(sb.repo, "configs/demo_config", "a file\n")
    result = plan(sb, {"DEMO_DIR": sb.repo / "configs/demo_config", "ENV_TARGET": "demo"})
    assert result.returncode != 0
    assert "which is not a folder" in result.stderr, result.stderr


def test_chain_env_target_still_runs_the_same_cluster_guard(sb):
    """X1 holds for a chain with its own target (I6's RUNNER_CHAIN_ENV_TARGETS): the file this session loaded
    still names its cluster, and a stale one is refused before any cluster call."""
    module(sb, 'INSTALL_ID="demo"\nRUNNER_CHAIN_ENV_TARGETS="chain.sh=demo_chain"\n')
    loaded = put(sb.repo, "configs/demo_config/demo_vars.sh", f'export OCP_URL="{STALE_URL}"\n')
    env = {"ENV_TARGET": "demo", "ENV_TARGET_FILE": loaded, "OCP_URL": SANDBOX_URL}
    result = plan(sb, env)
    assert result.returncode != 0
    assert SANDBOX_URL in result.stderr and STALE_URL in result.stderr, result.stderr
    assert not (sb.fake / "oc.log").exists()

    loaded.write_text(f'export OCP_URL="{SANDBOX_URL}"\n')
    result = plan(sb, env, body='_ir_stage_plan demo chain.sh\nprint -r -- "TARGET=$_IR_ENV_TARGET"')
    assert result.returncode == 0, result.stderr
    assert "TARGET=demo_chain" in result.stdout
    assert plan(sb, {**env, "ENV_TARGET": "all"}).returncode != 0, "ENV_TARGET=all is refused for it too"


def preflight(box, install):
    return box.run_script(COLLECT_TOOL, args=("preflight", "--install", install),
                          env={"FAKE_DIR": box.fake, "INSTALL_RUNNER_STORAGE_CLASS": "blk"}, timeout=120)


def test_preflight_verb_runs_the_hand_off_refusals(sb):
    """`x_install_runner.sh preflight` refuses what a hand-off would, e.g. a config for another cluster."""
    sb.write_config("cpd", ocp_url=SANDBOX_URL, extra=HANDOFF_CONFIG)
    put(sb.repo, "configs/cp4d_config/cpd_instance_details.sh", f'export OCP_URL="{STALE_URL}"\n')
    result = preflight(sb, "cpd")
    assert result.returncode != 0
    assert SANDBOX_URL in result.stderr and STALE_URL in result.stderr, result.stderr
    assert "Preflight passed" not in result.stdout


def test_preflight_hook_sees_the_staged_folders(sb):
    """IR_STAGED_<VAR> is each root resolved as it is staged (here without the `..` the config wrote)."""
    module(sb, 'INSTALL_ID="demo"\nINSTALL_ENV_TARGET="demo"\nRUNNER_STAGE_ROOTS="DEMO_DIR:configs/demo_config"\n',
           hook='case "${1:-}" in preflight) print -r -- "STAGED=${IR_STAGED_DEMO_DIR:-unset}" ;; esac\n')
    put(sb.repo, "configs/demo_config/demo_vars.sh",
        f'export OCP_URL="{SANDBOX_URL}"\nexport OC_LOGIN="true"\nexport DEMO_DIR="${{CONFIGS_ROOT}}/../configs/demo_config"\n')
    sb.write_config("cpd", ocp_url=SANDBOX_URL)
    result = preflight(sb, "demo")
    assert result.returncode == 0, result.stdout + result.stderr
    assert f"STAGED={(sb.repo / 'configs/demo_config').resolve()}\n" in result.stdout, result.stdout


# --- collect ----------------------------------------------------------------------------------------------------
DEMO_VARS = f'export OCP_URL="{SANDBOX_URL}"\nexport OC_LOGIN="true"\nexport DEMO_CONFIG_DIR="${{CONFIGS_ROOT}}/demo_config"\n'
# A post-collect hook that leaves a mark, to see whether collect ran it.
MARKING_HOOK = 'case "${1:-}" in post-collect) print -r -- "$DEMO_CONFIG_DIR" > "$FAKE_DIR/post_collect" ;; esac\n'


@pytest.fixture
def demo(sb):
    """A demo module staged from the flat layout, with its collect answers to be filled per test."""
    module(sb, 'INSTALL_ID="demo"\nINSTALL_ENV_TARGET="demo"\nRUNNER_COLLECT_ROOTS="DEMO_CONFIG_DIR:configs/demo_config"\n')
    put(sb.repo, "configs/demo_config/demo_vars.sh", DEMO_VARS)
    sb.write_config("cpd", ocp_url=SANDBOX_URL)
    (sb.fake / "run.env").write_text(f"IR_RUN_ID=run1\nIR_CLUSTER_URL='{SANDBOX_URL}'\nIR_SOURCE_CLUSTER=''\nIR_LAYOUT='flat'\n")
    (sb.fake / "path_map").write_text("configs/demo_config=DEMO_CONFIG_DIR:configs/demo_config\n")
    return sb


def stage_pod(box, files):
    for rel, text in files.items():
        put(box.fake / "pod", rel, text)


def test_collect_takes_a_missing_file_and_keeps_an_edited_one(demo):
    local = demo.repo / "configs/demo_config"
    put(local, "edited.sh", "my edit\n")
    stage_pod(demo, {"configs/demo_config/edited.sh": "seed\n", "configs/demo_config/gone_here.sh": "seed\n"})
    pod_changes(demo, {"configs/demo_config/edited.sh": "from pod\n", "configs/demo_config/gone_here.sh": "from pod\n",
                       "configs/demo_config/managed-service-instances/wx/wx1-instance_details.sh": "export X=1\n"})
    result = collect(demo, "demo")
    assert result.returncode == 0, result.stdout + result.stderr
    assert (local / "gone_here.sh").read_text() == "from pod\n", "nothing local to protect: taken"
    assert not (local / "gone_here.sh.in-cluster-run1").exists()
    assert (local / "edited.sh").read_text() == "my edit\n"
    assert (local / "edited.sh.in-cluster-run1").read_text() == "from pod\n"
    for folder in (local / "managed-service-instances", local / "managed-service-instances/wx"):
        assert stat.S_IMODE(folder.stat().st_mode) == 0o700, folder
    assert "Collected 2 file(s); 1 kept back" in result.stdout


def test_collect_into_a_missing_folder_makes_it_owner_only(demo):
    """Another machine, or a folder removed since launch: the folder is made, 0700."""
    shutil.rmtree(demo.repo / "configs/demo_config")
    put(demo.repo, "configs/other_config/demo_vars.sh", f'export OCP_URL="{SANDBOX_URL}"\nexport OC_LOGIN="true"\n')
    pod_changes(demo, {"configs/demo_config/new.sh": "from pod\n"})
    result = collect(demo, "demo")
    assert result.returncode == 0, result.stdout + result.stderr
    assert (demo.repo / "configs/demo_config/new.sh").read_text() == "from pod\n"
    assert stat.S_IMODE((demo.repo / "configs/demo_config").stat().st_mode) == 0o700


def test_collect_refuses_a_changed_layout_and_takes_to(demo, tmp_path):
    """Staged from cluster folder 'old' (renamed since, or another machine): the URL has no cluster folder here."""
    (demo.fake / "run.env").write_text(f"IR_CLUSTER_URL='{SANDBOX_URL}'\nIR_SOURCE_CLUSTER='old'\nIR_LAYOUT='cluster'\n")
    (demo.fake / "path_map").write_text("configs/demo_config=DEMO_CONFIG_DIR:configs/clusters/old/demo_config\n")
    (demo.repo / "src/install_runner/installs/demo.sh").write_text(MARKING_HOOK)
    pod_changes(demo, {"configs/demo_config/new.sh": "from pod\n"})
    result = collect(demo, "demo")
    assert result.returncode != 0
    assert "configs/clusters/old" in result.stderr and "--to" in result.stderr
    assert "collect --to-loaded (into configs/demo_config)" in result.stderr, result.stderr
    assert not (demo.repo / "configs/clusters").exists()
    assert "touch /work/current/collected" not in (demo.fake / "oc.log").read_text()

    target = tmp_path / "picked"
    result = collect(demo, "demo", "--to", target)
    assert result.returncode == 0, result.stdout + result.stderr
    assert (target / "demo_config/new.sh").read_text() == "from pod\n"
    assert stat.S_IMODE(target.stat().st_mode) == 0o700
    assert "touch /work/current/collected" in (demo.fake / "oc.log").read_text()
    # The follow-up reads the loaded config, which --to did not fill: it is skipped, and says so.
    assert not (demo.fake / "post_collect").exists()
    assert "Skipped the demo follow-up" in result.stdout

    result = collect(demo, "demo", "--to-loaded")
    assert result.returncode == 0, result.stdout + result.stderr
    assert (demo.repo / "configs/demo_config/new.sh").read_text() == "from pod\n"
    assert (demo.fake / "post_collect").read_text().strip() == str(demo.repo / "configs/demo_config")
    assert collect(demo, "demo", "--to", target, "--to-loaded").returncode != 0


@pytest.mark.parametrize("record", ["cluster folder renamed", "no path record"])
def test_flat_recovery_puts_each_root_where_the_flat_load_reads_it(sb, record):
    """The flat layout has the cpd roots in different parents (configs/cp4d_config, service_instances): following
    the refusal's hint lands each where the flat load reads it, never in configs/service_instances."""
    (sb.fake / "state").write_text("completed\n")
    assert handoff(sb).returncode == 0
    pod_changes(sb, {"configs/cp4d_config/cpd_instance_details.sh": "export CPD_APIKEY=new\n",
                     "service_instances/p.json": "{}\n"})
    if record == "no path record":
        (sb.fake / "pod_path_map").unlink()
        (sb.fake / "pod_run.env").unlink()
    else:
        (sb.fake / "pod_run.env").write_text(f"IR_CLUSTER_URL='{SANDBOX_URL}'\nIR_SOURCE_CLUSTER='old'\nIR_LAYOUT='cluster'\n")
        (sb.fake / "pod_path_map").write_text("configs/cp4d_config=CONFIG_DIR:configs/clusters/old/cp4d_config\n"
                                              "service_instances=SERVICE_INSTANCE_FILE_DIR:configs/clusters/old/service_instances\n")
    result = collect(sb, "cpd")
    assert result.returncode != 0
    hint = re.search(r"collect (--to-loaded) \(into ([^)]*)\)", result.stderr)
    assert hint and hint.group(2) == "configs/cp4d_config, service_instances", result.stderr

    result = collect(sb, "cpd", hint.group(1))
    assert result.returncode == 0, result.stdout + result.stderr
    assert (sb.repo / "service_instances/p.json").read_text() == "{}\n"
    assert (sb.repo / "configs/cp4d_config/cpd_instance_details.sh").read_text() == "export CPD_APIKEY=new\n"
    assert not (sb.repo / "configs/service_instances").exists()


def test_to_loaded_refuses_folders_outside_the_runs_cluster(demo):
    """--to-loaded from a session pinned to cluster itz-b, for a run whose URL cluster itz-a owns: refused."""
    write_state(demo, current="itz-b", url=STALE_URL)
    demo.write_cluster_marker(CLUSTER, SANDBOX_URL)
    state = demo.repo / "configs/multi_cluster_management.sh"
    state.write_text(state.read_text().replace('MCM_CLUSTERS="itz-b"', f'MCM_CLUSTERS="{CLUSTER} itz-b"'))
    shutil.rmtree(demo.repo / "configs/demo_config")
    put(demo.repo, "configs/clusters/itz-b/demo_config/demo_vars.sh", DEMO_VARS.replace(SANDBOX_URL, STALE_URL))
    (demo.fake / "run.env").write_text(f"IR_CLUSTER_URL='{SANDBOX_URL}'\nIR_SOURCE_CLUSTER='old'\nIR_LAYOUT='cluster'\n")
    pod_changes(demo, {"configs/demo_config/new.sh": "from pod\n"})
    result = collect(demo, "demo", "--to-loaded")
    assert result.returncode != 0
    assert (f"loaded configs/clusters/itz-b/demo_config for configs/demo_config" in result.stderr
            and f"configs/clusters/{CLUSTER}" in result.stderr), result.stderr
    assert not (demo.repo / "configs/clusters/itz-b/demo_config/new.sh").exists()
    assert "touch /work/current/collected" not in (demo.fake / "oc.log").read_text()


def test_collect_follows_the_url_to_a_cluster_folder(demo):
    """Staged pinned to 'itz-a': the URL's marker still says itz-a, so collect goes there with no --to."""
    write_state(demo)
    cluster = demo.repo / "configs/clusters" / CLUSTER
    put(cluster, "demo_config/demo_vars.sh", f'export OCP_URL="{SANDBOX_URL}"\nexport OC_LOGIN="true"\n')
    (demo.fake / "run.env").write_text(f"IR_CLUSTER_URL='{SANDBOX_URL}'\nIR_SOURCE_CLUSTER='{CLUSTER}'\nIR_LAYOUT='cluster'\n")
    (demo.fake / "path_map").write_text(f"configs/demo_config=DEMO_CONFIG_DIR:configs/clusters/{CLUSTER}/demo_config\n")
    pod_changes(demo, {"configs/demo_config/new.sh": "from pod\n"})
    result = collect(demo, "demo")
    assert result.returncode == 0, result.stdout + result.stderr
    assert (cluster / "demo_config/new.sh").read_text() == "from pod\n"
    assert not (demo.repo / "configs/demo_config/new.sh").exists()


@pytest.mark.parametrize("recorded", [
    "src/helpers",                                   # code, not a config folder
    "configs/clusters/other/demo_config",            # another cluster's folder, in a flat run
    "configs/demo_config/.home/demo_config",         # inside a login folder
])
def test_collect_refuses_a_path_record_it_would_never_write_to(demo, recorded):
    """The path record comes back from the pod: a folder collect would never write to is refused, not used."""
    (demo.fake / "path_map").write_text(f"configs/demo_config=DEMO_CONFIG_DIR:{recorded}\n")
    pod_changes(demo, {"configs/demo_config/new.sh": "from pod\n"})
    result = collect(demo, "demo")
    assert result.returncode != 0
    assert recorded in result.stderr and "--to" in result.stderr, result.stderr
    assert not (demo.repo / recorded / "new.sh").exists()
    assert "touch /work/current/collected" not in (demo.fake / "oc.log").read_text()


SI_MODULE = ('INSTALL_ID="demo"\nINSTALL_ENV_TARGET="demo"\n'
             'RUNNER_COLLECT_ROOTS="DEMO_CONFIG_DIR:configs/demo_config SERVICE_INSTANCE_FILE_DIR:service_instances"\n')


@pytest.mark.parametrize("recorded", ["src/service_instances", "configs/service_instances"])
def test_collect_puts_the_service_instance_root_only_at_its_own_place(demo, recorded):
    """A root that is not a *_config folder is taken from the record only at its layout's place: flat, the
    snapshot path itself. Anything else named like it (in the code tree, say) is refused."""
    module(demo, SI_MODULE)
    (demo.fake / "path_map").write_text("configs/demo_config=DEMO_CONFIG_DIR:configs/demo_config\n"
                                        f"service_instances=SERVICE_INSTANCE_FILE_DIR:{recorded}\n")
    pod_changes(demo, {"service_instances/new.json": "{}\n"})
    result = collect(demo, "demo")
    assert result.returncode != 0
    assert f"records {recorded} for service_instances" in result.stderr, result.stderr
    assert not (demo.repo / recorded / "new.json").exists()


def test_collect_takes_the_cluster_service_instance_folder_from_the_record(demo):
    """Pinned run, collected from a session that loads flat: the record's configs/clusters/<c>/service_instances
    is not this session's SERVICE_INSTANCE_FILE_DIR, but it is that root's place in the cluster folder."""
    module(demo, SI_MODULE)
    demo.write_cluster_marker(CLUSTER, SANDBOX_URL)
    shutil.rmtree(demo.repo / "configs/demo_config")
    put(demo.repo, "configs/other_config/demo_vars.sh", f'export OCP_URL="{STALE_URL}"\nexport OC_LOGIN="true"\n')
    (demo.fake / "run.env").write_text(f"IR_CLUSTER_URL='{SANDBOX_URL}'\nIR_SOURCE_CLUSTER='{CLUSTER}'\nIR_LAYOUT='cluster'\n")
    (demo.fake / "path_map").write_text(f"configs/demo_config=DEMO_CONFIG_DIR:configs/clusters/{CLUSTER}/demo_config\n"
                                        f"service_instances=SERVICE_INSTANCE_FILE_DIR:configs/clusters/{CLUSTER}/service_instances\n")
    pod_changes(demo, {"service_instances/new.json": "{}\n"})
    result = collect(demo, "demo")
    assert result.returncode == 0, result.stdout + result.stderr
    assert (demo.repo / f"configs/clusters/{CLUSTER}/service_instances/new.json").read_text() == "{}\n"
    assert not (demo.repo / "service_instances/new.json").exists()


def test_collect_rewrites_pod_paths_in_text_files(demo):
    root = "/work/snapshots/run1"
    text = (f"values={root}/configs/demo_config/helm/values.yaml\n"
            f"chart={root}/charts/x.tgz\n"
            f"cwd {root}\n"
            f"not={root}/configs/demo_config2/y\n")
    binary = b"\x00\x01" + f"{root}/configs/demo_config/x".encode() + b"\x00"
    # Text from 1 MB up is left as it is, pod paths and all.
    big = f"{root}/configs/demo_config/x\n"
    big += "a" * (1048576 - len(big)) + "\n"
    pod_changes(demo, {"configs/demo_config/helm-values-files.txt": text, "configs/demo_config/big.txt": big})
    with tarfile.open(demo.fake / "collect.tar", "a") as tar:
        put(demo.fake / "pod", "configs/demo_config/blob.bin", "")
        (demo.fake / "pod/configs/demo_config/blob.bin").write_bytes(binary)
        tar.add(demo.fake / "pod/configs/demo_config/blob.bin", arcname="configs/demo_config/blob.bin")
    with (demo.fake / "collect_list").open("a") as listing:
        listing.write(f"-\t{hashlib.sha256(binary).hexdigest()}\tconfigs/demo_config/blob.bin\n")
    (demo.fake / "pod/configs/demo_config/helm-values-files.txt").chmod(0o600)
    result = collect(demo, "demo")
    assert result.returncode == 0, result.stdout + result.stderr
    local = demo.repo / "configs/demo_config"
    got = (local / "helm-values-files.txt").read_text()
    assert got == (f"values={local}/helm/values.yaml\n"
                   f"chart={demo.repo}/charts/x.tgz\n"
                   f"cwd {demo.repo}\n"
                   f"not={demo.repo}/configs/demo_config2/y\n"), got
    assert (local / "blob.bin").read_bytes() == binary, "binary files are left alone"
    assert (local / "big.txt").read_text() == big, "text from 1 MB up is left alone"
    # Collecting the same run again finds nothing new to take and makes no conflict copy.
    again = collect(demo, "demo")
    assert again.returncode == 0, again.stdout + again.stderr
    assert not (local / "helm-values-files.txt.in-cluster-run1").exists()
    assert "Collected 0 file(s); 0 kept back" in again.stdout


# --- tar portability --------------------------------------------------------------------------------------------
POD_SIDE_OC = r"""#!/bin/bash
# Plays the pod for _ir_stream_to_pod: runs its shell command with /work moved to $W, keeping the stream.
while [ "$1" != "--" ]; do shift; done; shift
[ "$1" = sh ] && [ "$2" = -c ] || exit 9
cmd="${3//\/work\//$W/}"
# GNU tar in the pod. Here: gtar when this machine has it, else this tar without the GNU-only flag.
if command -v gtar >/dev/null 2>&1; then mkdir -p "$W/gnu"; ln -sf "$(command -v gtar)" "$W/gnu/tar"; export PATH="$W/gnu:$PATH"
elif ! tar --version 2>/dev/null | grep -q GNU; then cmd="${cmd// --warning=no-unknown-keyword/}"; fi
tee "$W/stream.tar" | sh -c "$cmd"
"""


def test_root_stream_is_portable_with_the_system_tar(tmp_path):
    """The per-root stream: made with this machine's tar from `cd <root>` and a NUL list, unpacked by the pod's
    command at <snapshot>/<snapshot path>. Plain relative names: no -s/--transform, no AppleDouble files."""
    local = tmp_path / "configs/clusters/itz-a/cp4d_config"
    files = {"cpd_vars.sh": "export A=1\n", "with space/inner file.sh": "x\n", "managed-service-instances/wx/a.sh": "y\n",
             "ünïcode.txt": "z\n", "-dash.sh": "d\n"}
    for rel, text in files.items():
        put(local, rel, text)
    (local / "cpd_vars.sh").chmod(0o600)
    put(local, ".home/.kube/config", "token\n")
    bin_dir, work = tmp_path / "bin", tmp_path / "w"
    put(bin_dir, "oc", POD_SIDE_OC, mode=0o755)
    work.mkdir()
    script = textwrap.dedent(f"""\
        source "{REPO}/src/helpers/install_runner_helpers.sh"
        _ir_find_files "{local}" | _ir_stream_to_pod ns r1 configs/cp4d_config "{local}"
        """)
    env = {k: v for k, v in os.environ.items() if not k.startswith(("IR_", "INSTALL_RUN"))}
    env.update({"_CP4D_REPO_ROOT": str(REPO), "PATH": f"{bin_dir}:{env['PATH']}", "W": str(work)})
    result = subprocess.run(["zsh", "-c", "set -euo pipefail\n" + script], env=env, capture_output=True, text=True,
                            timeout=60, check=False)
    assert result.returncode == 0, result.stderr
    landed = work / "snapshots/r1/configs/cp4d_config"
    # NFC: macOS may hand names back decomposed.
    got = {unicodedata.normalize("NFC", str(p.relative_to(landed))) for p in landed.rglob("*") if p.is_file()}
    assert got == set(files), got
    for rel, text in files.items():
        assert (landed / rel).read_text() == text
    assert stat.S_IMODE((landed / "cpd_vars.sh").stat().st_mode) == 0o600
    with tarfile.open(work / "stream.tar") as tar:
        names = tar.getnames()
    assert all(not n.startswith(("/", "..")) and "configs/clusters" not in n for n in names), names
    assert not any(Path(n).name.startswith("._") for n in names), names


# --- L-01: the first launch on a cluster ------------------------------------------------------------------------
def test_first_build_creates_the_system_namespace_first(sb):
    """Live finding L-01: the build went into install-runner-system before anything had created it."""
    (sb.fake / "state").write_text("completed\n")
    (sb.fake / "image_missing").touch()
    (sb.fake / "strict_ns").touch()
    result = handoff(sb)
    assert result.returncode == 0, result.stdout + result.stderr
    docs = [d for d in yaml.safe_load_all((sb.fake / "applied.yaml").read_text()) if d]
    kinds = [(d["kind"], d["metadata"]["name"]) for d in docs]
    assert kinds.index(("Namespace", "install-runner-system")) < kinds.index(("ImageStream", "install-runner"))
    assert "start-build" in (sb.fake / "oc.log").read_text()


def test_strict_fake_refuses_a_namespace_that_does_not_exist(sb):
    """The fake behind the L-01 test really refuses: the old order fails with the live error."""
    (sb.fake / "strict_ns").touch()
    result = sb.run_zsh('source src/helpers/install_runner_helpers.sh\n'
                        'ir_apply build.yaml.tmpl SYSTEM_NAMESPACE=install-runner-system BUILD_NAME=b BASE_IMAGE=i '
                        'CPD_CLI_URL=u IMAGE_TAG=t\n', env={"_CP4D_REPO_ROOT": sb.repo, "FAKE_DIR": sb.fake})
    assert result.returncode != 0
    assert 'namespaces "install-runner-system" not found' in result.stderr


POD_FLAT_UNSETS = ("MCM_CLUSTER", "MCM_CLUSTER_ROOT", "MCM_CPD_CLI_WORKSPACE", "MCM_CONTAINER_SUFFIX",
                   "MCM_KUBECONFIG_OVERRIDE", "MCM_TARGET_CLUSTERS", "MCM_RUN_TARGETS", "CPDCONFIG", "CPD_CLI_WORKSPACE")


def test_supervisor_drops_the_multi_cluster_env():
    """The supervisor's own env is flat too (plan §5.5): its prologue unsets every pinning variable."""
    supervisor = (REPO / "src/install_runner/image/bin/supervisor.sh").read_text()
    prologue = re.search(r"^unset MCM_CLUSTER .*?[^\\]\n", supervisor, re.S | re.M).group(0)
    script = prologue + "for n in " + " ".join(POD_FLAT_UNSETS) + '; do (( ${+parameters[$n]} )) && print -r -- "$n"; done; true\n'
    env = {"PATH": "/usr/bin:/bin", **{n: "set" for n in POD_FLAT_UNSETS}}
    result = subprocess.run(["zsh", "-f", "-c", script], env=env, capture_output=True, text=True, timeout=60, check=False)
    assert result.returncode == 0, result.stderr
    assert result.stdout == "", f"still set: {result.stdout}"


# --- the supervisor's status record -----------------------------------------------------------------------------
def test_status_carries_the_run_record(tmp_path):
    """publish_status sends cluster and ocp_url from the slot env, and the run's layout, target and path map."""
    supervisor = (REPO / "src/install_runner/image/bin/supervisor.sh").read_text()
    functions = re.search(r"^current_run\(\).*?(?=^# --- one attempt)", supervisor, re.S | re.M).group(0)
    run = tmp_path / "runs/r1"
    put(run, "run.env", "IR_CHAIN='x.sh'\nIR_LAYOUT='cluster'\nIR_ENV_TARGET='configs/cp4d_config/cpd_vars.sh'\n")
    put(run, "state", "running\n")
    put(run, "path_map", "configs/cp4d_config=CONFIG_DIR:configs/clusters/itz-a/cp4d_config\n")
    put(tmp_path, "bin/oc", '#!/bin/bash\necho "$*" >> "$LOG"\n[ "$1" = create ] && echo "yaml"\nexit 0\n', mode=0o755)
    script = f"typeset -g SIG_TERM='' LAST_STATUS='' LAST_PUBLISH=0\nIR_HEARTBEAT=60\nsay() {{ :; }}\n{functions}\npublish_status {run}\n"
    env = {"PATH": f"{tmp_path}/bin:/usr/bin:/bin", "LOG": str(tmp_path / "oc.log"), "IR_NAMESPACE": "ns", "IR_WORK": str(tmp_path),
           "IR_SOURCE_CLUSTER": "itz-a", "IR_OCP_URL": SANDBOX_URL, "HOME": str(tmp_path)}
    result = subprocess.run(["zsh", "-c", script], env=env, capture_output=True, text=True, timeout=60, check=False)
    assert result.returncode == 0, result.stderr
    create = next(line for line in (tmp_path / "oc.log").read_text().splitlines() if line.startswith("create configmap"))
    for part in ("--from-literal=cluster=itz-a", f"--from-literal=ocp_url={SANDBOX_URL}", "--from-literal=layout=cluster",
                 "--from-literal=env_target=configs/cp4d_config/cpd_vars.sh",
                 "--from-literal=path_map=configs/cp4d_config=CONFIG_DIR:configs/clusters/itz-a/cp4d_config"):
        assert part in create, create
    beat = (tmp_path / "runs/.heartbeat").read_text().strip()
    assert f"--from-literal=heartbeat={beat}" in create, "follow.sh's heartbeat file carries the reported time"
