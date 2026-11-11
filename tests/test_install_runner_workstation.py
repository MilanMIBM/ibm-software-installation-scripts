"""In-cluster runner, workstation flow under multi-cluster management (phase I3).

Plan: .claude/plans/multi-cluster-management/in-cluster-install-addon/in-cluster-install-addon-plan.md §6,
gaps X6, X7, X8, X8b, X8c, X12, X14, and X25 (a flat load of another product with no configs/cp4d_config).

Everything runs in tests/mcm_harness.py sandboxes: the real env_bootstrap.sh and source_env_setup.sh, the
harness's fake podman and cpd-cli, and the runner tests' fake oc (FAKE_OC), so nothing reaches a cluster,
the podman VM or the real configs/.
"""

import os
import platform
import subprocess
import textwrap

import pytest
from mcm_harness import make_sandbox
from test_install_runner import (CPD_CHAIN, FAKE_OC, HANDOFF_CONFIG, SANDBOX_EXTRA, STAND_IN_CHAIN,  # noqa: F401
                                 assert_clean_load, fake, zsh)

PLAY = "olm-utils-play-v4"
SLOT = "cpd-cpd-op"
RUNNER_TOOL = "scripts/install_runner/x_install_runner.sh"
WATCH_TOOL = "scripts/install_runner/x_watch_install.sh"
DARWIN = platform.system() == "Darwin"


@pytest.fixture
def sb():
    """As in test_install_runner.py, plus 0.0_make_executable.sh, which build-local-push runs to start the VM."""
    with make_sandbox(extra=[*SANDBOX_EXTRA, "scripts/0.0_make_executable.sh"]) as box:
        box.fake = box.root / "fake"
        box.fake.mkdir()
        (box.bin / "oc").write_text(FAKE_OC)
        subprocess.run(["git", "init", "-q"], cwd=box.repo, env=box.env(), check=True, capture_output=True)
        yield box


def url(name):
    return f"https://api.{name}.example.com:6443"


def clusters(box, names=("itz-a",), current="itz-a", targets="", mode="cluster", extra=None):
    """Delineated clusters with a cpd config each (the runner's values), mode on, idle watcher off."""
    for name in names:
        box.write_cluster_marker(name, url(name))
        config = dict(HANDOFF_CONFIG, **(extra or {}))
        if mode is not None:
            config["INSTALL_RUN_MODE"] = mode
        box.write_config("cpd", ocp_url=url(name), cluster=name, extra=config)
        box.add_container(f"{PLAY}-{name}", running=False)
    (box.repo / "configs/multi_cluster_management.sh").write_text(textwrap.dedent(f"""\
        export MULTI_CLUSTER_MANAGEMENT="true"
        export MCM_CLUSTERS="{' '.join(names)}"
        export MCM_CURRENT_CLUSTER="{current}"
        export APPLY_TO_ALL="false"
        export MCM_TARGET_CLUSTERS="{targets}"
        export MCM_CONTAINER_IDLE_TIMEOUT_MINUTES="0"
        """))


def chain(box, rel=CPD_CHAIN, body=STAND_IN_CHAIN):
    script = box.repo / rel
    script.parent.mkdir(parents=True, exist_ok=True)
    script.write_text(body)
    script.chmod(0o755)
    return rel


def run(box, rel, *args, env=None, timeout=120):
    return box.run_script(rel, env={"FAKE_DIR": box.fake, **(env or {})}, args=args, timeout=timeout)


def leases(box, name="itz-a"):
    folder = box.home / "cpd-cli/clusters" / name / ".leases"
    return sorted(p.name for p in folder.iterdir()) if folder.is_dir() else []


def starts(box):
    return [argv for argv in box.calls("podman") if argv[:1] == ["start"] or argv[:2] == ["machine", "start"]]


def oc_log(box):
    path = box.fake / "oc.log"
    return path.read_text() if path.exists() else ""


# --- X8: a remote run needs no local container and takes no lease ---------------------------------------------
def test_cluster_mode_chain_starts_no_container_and_takes_no_lease(sb):
    clusters(sb)
    (sb.fake / "state").write_text("completed\n")
    result = run(sb, chain(sb))
    assert result.returncode == 0, result.stdout + result.stderr
    assert_clean_load(result)
    assert "CHAIN-RAN-LOCALLY" not in result.stdout
    assert "hello from the pod" in result.stdout
    assert starts(sb) == [], sb.calls("podman")
    assert leases(sb) == []
    assert [c for c in sb.calls("cpd-cli")] == []


def test_local_mode_chain_still_starts_its_container(sb):
    """The control for the test above: the same pinned load in local mode does start the container."""
    clusters(sb, mode="local")
    result = run(sb, chain(sb))
    assert result.returncode == 0, result.stdout + result.stderr
    assert "CHAIN-RAN-LOCALLY" in result.stdout
    assert ["start", f"{PLAY}-itz-a"] in sb.calls("podman")
    assert leases(sb) != []


def test_mcm_sync_mode_stop_only_is_honoured(sb):
    clusters(sb, mode="local")
    result = sb.run_zsh('source "${0:A:h}/env_bootstrap.sh"\nprint -r -- LOADED\n',
                        env={"ENV_TARGET": "cpd", "MCM_SYNC_MODE": "stop-only"})
    assert result.returncode == 0, result.stderr
    assert "LOADED" in result.stdout
    assert starts(sb) == []
    assert leases(sb) == []


def test_an_unknown_mcm_sync_mode_warns_and_syncs_as_usual(sb):
    clusters(sb, mode="local")
    result = sb.run_zsh('source "${0:A:h}/env_bootstrap.sh"\n', env={"ENV_TARGET": "cpd", "MCM_SYNC_MODE": "nope"})
    assert result.returncode == 0, result.stderr
    assert "MCM_SYNC_MODE='nope'" in result.stderr
    assert ["start", f"{PLAY}-itz-a"] in sb.calls("podman")


@pytest.mark.parametrize("tool,args", [(RUNNER_TOOL, ("attach", "--install", "cpd")), (WATCH_TOOL, ("--install", "cpd")),
                                       (RUNNER_TOOL, ("status",))])
def test_runner_tool_starts_nothing_and_boots_no_vm(sb, tool, args):
    """Attach and status need only oc: no container start, no lease, and the stopped VM stays down (X8c)."""
    clusters(sb)
    sb.set_machine("stopped")
    (sb.fake / "state").write_text("completed\n")
    # No _CP4D_PREP_DONE: as from a terminal, where env_bootstrap.sh's auto-prep would start the VM.
    result = run(sb, tool, *args, env={"_CP4D_PREP_DONE": None})
    assert result.returncode == 0, result.stdout + result.stderr
    assert starts(sb) == [], sb.calls("podman")
    assert sb.fake_state()["machine"] == "stopped"
    assert leases(sb) == []
    assert "0.0_make_executable" not in result.stdout + result.stderr


def test_status_in_local_mode_starts_nothing(sb):
    """A local-mode config gives no stop-only of its own (that is a cluster-mode chain's): the runner's
    MCM_SYNC_MODE export is what keeps the container down here."""
    clusters(sb, mode="local")
    result = run(sb, RUNNER_TOOL, "status", "--install", "cpd")
    assert result.returncode == 0, result.stdout + result.stderr
    assert starts(sb) == [], sb.calls("podman")
    assert leases(sb) == []


def test_the_long_lived_load_alone_takes_no_lease(sb):
    """Without the MCM_SYNC_MODE export, the long-lived-load entry still keeps the runner off the lease.
    (The container starts then: only the export stops that, as the test above shows.)"""
    clusters(sb, mode="local")
    tool = sb.repo / RUNNER_TOOL
    text = tool.read_text()
    assert "export MCM_SYNC_MODE=stop-only\n" in text
    tool.write_text(text.replace("export MCM_SYNC_MODE=stop-only\n", "unset MCM_SYNC_MODE\n", 1))
    result = run(sb, RUNNER_TOOL, "status", "--install", "cpd")
    assert result.returncode == 0, result.stdout + result.stderr
    assert leases(sb) == []


# --- X8b: build-local-push holds a lease for the build and push ------------------------------------------------
BUILD = textwrap.dedent("""\
    source "${0:A:h}/env_bootstrap.sh"
    source "${_CP4D_REPO_ROOT}/src/helpers/install_runner_helpers.sh"
    ir_image_ensure cpd
    print -r -- "IMAGE=${REPLY}"
    print -r -- "HELD=${_MCM_LEASE_HELD:-}"
    print -r -- "WORKSPACE=${MCM_CPD_CLI_WORKSPACE}"
    """)
PUSH_ENV = {"ENV_TARGET": "cpd", "INSTALL_RUNNER_IMAGE_SOURCE": "build-local-push",
            "PRIVATE_REGISTRY_LOCATION": "reg.example.com:5000/x", "PRIVATE_REGISTRY_PUSH_USER": "u",
            "PRIVATE_REGISTRY_PUSH_PASSWORD": "p"}


def watch_builds(box):
    """Records the cluster's leases at the moment podman build runs."""
    real = box.bin / "real" / "podman"
    real.parent.mkdir()
    (box.bin / "podman").rename(real)
    seen = box.root / "leases_during_build"
    folder = box.home / "cpd-cli/clusters/itz-a/.leases"
    (box.bin / "podman").write_text(
        f'#!/bin/sh\nif [ "$1" = build ]; then ls "{folder}" > "{seen}" 2>/dev/null; fi\nexec "{real}" "$@"\n')
    (box.bin / "podman").chmod(0o755)
    return seen


def lines(result):
    return dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line and line[:1].isupper())


def test_build_local_push_takes_and_releases_the_lease(sb):
    clusters(sb)
    seen = watch_builds(sb)
    # The cluster-mode chain's load is stop-only: no lease of its own before the build.
    result = sb.run_zsh(BUILD, env={**PUSH_ENV, "MCM_SYNC_MODE": "stop-only"}, timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
    verbs = [argv[0] for argv in sb.calls("podman") if argv[0] in ("build", "login", "push")]
    assert verbs == ["build", "login", "push"]
    assert seen.read_text().split(), "no lease while podman build ran"
    assert leases(sb) == [], "the lease outlived the push"
    out = lines(result)
    assert "itz-a" not in out["HELD"].split()
    assert out["IMAGE"].startswith("reg.example.com:5000/x/install-runner/install-runner:")
    assert out["WORKSPACE"] and os.path.isfile(os.path.join(out["WORKSPACE"], ".last_activity"))


def test_build_local_push_keeps_a_lease_it_did_not_take(sb):
    clusters(sb, mode="local")
    result = sb.run_zsh(BUILD, env=PUSH_ENV, timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "itz-a" in lines(result)["HELD"].split()
    assert leases(sb) != []


@pytest.mark.skipif(not DARWIN, reason="the podman VM exists on macOS only (mcm_podman_machine_needs_prep)")
def test_build_local_push_starts_a_stopped_vm_first(sb):
    clusters(sb)
    sb.set_machine("stopped")
    result = sb.run_zsh(BUILD, env={**PUSH_ENV, "MCM_SYNC_MODE": "stop-only"}, timeout=120)
    assert result.returncode == 0, result.stdout + result.stderr
    calls = sb.calls("podman")
    assert ["machine", "start"] in calls
    assert calls.index(["machine", "start"]) < next(i for i, argv in enumerate(calls) if argv[:1] == ["build"])
    assert "Starting the podman VM for the image build" in result.stdout
    assert "Podman VM is up" in result.stdout


def test_prebuilt_and_build_in_cluster_take_no_lease(sb):
    clusters(sb)
    for extra in ({"INSTALL_RUNNER_IMAGE_SOURCE": "prebuilt", "INSTALL_RUNNER_IMAGE": "reg/x:1"},
                  {"INSTALL_RUNNER_IMAGE_SOURCE": "build-in-cluster"}):
        result = sb.run_zsh(BUILD, env={"ENV_TARGET": "cpd", "MCM_SYNC_MODE": "stop-only", "FAKE_DIR": sb.fake, **extra},
                            timeout=120)
        assert result.returncode == 0, result.stdout + result.stderr
        assert leases(sb) == []
    assert not [argv for argv in sb.calls("podman") if argv[:1] in (["build"], ["push"], ["machine"])]


def test_release_lease_drops_only_that_cluster(sb):
    result = sb.run_zsh(textwrap.dedent("""\
        source src/helpers/multi_cluster_helpers.sh
        mcm_take_lease itz-a
        mcm_take_lease itz-b
        mcm_release_lease itz-a
        print -r -- "HELD=${${_MCM_LEASE_HELD}// /}"
        ls ~/cpd-cli/clusters/itz-a/.leases | wc -l | tr -d ' '
        ls ~/cpd-cli/clusters/itz-b/.leases | wc -l | tr -d ' '
        mcm_release_lease itz-b
        print -r -- "LEFT=${_MCM_LEASE_HELD-unset}"
        """))
    assert result.returncode == 0, result.stderr
    assert result.stdout.split() == ["HELD=itz-b", "0", "1", "LEFT=unset"]


# --- X12: --run-mode overrides the config for one run ------------------------------------------------------------
ARGS_CHAIN = STAND_IN_CHAIN.replace("print -r -- CHAIN-RAN-LOCALLY", 'print -r -- "CHAIN-RAN-LOCALLY args=<${(j:,:)@}>"')


def flat(box, mode):
    box.write_config("cpd", ocp_url="https://api.x:6443", extra={**HANDOFF_CONFIG, "INSTALL_RUN_MODE": mode})
    return chain(box, body=ARGS_CHAIN)


@pytest.mark.parametrize("how", [("--run-mode", "local"), ("--run-mode=local",), "env"])
def test_run_mode_local_beats_a_config_set_to_cluster(sb, how):
    rel = flat(sb, "cluster")
    args = () if how == "env" else (*how, "--from", "x")
    env = {"INSTALL_RUN_MODE_OVERRIDE": "local"} if how == "env" else None
    result = run(sb, rel, *args, env=env)
    assert result.returncode == 0, result.stdout + result.stderr
    assert_clean_load(result)
    expected = "<>" if how == "env" else "<--from,x>"
    assert f"CHAIN-RAN-LOCALLY args={expected}" in result.stdout, "the flag must not reach the chain"
    assert oc_log(sb) == ""


def test_run_mode_cluster_beats_a_config_set_to_local(sb):
    rel = flat(sb, "local")
    (sb.fake / "state").write_text("completed\n")
    result = run(sb, rel, "--run-mode", "cluster")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "CHAIN-RAN-LOCALLY" not in result.stdout
    assert "hello from the pod" in result.stdout
    run_env = (sb.fake / "run.env").read_text()
    assert "--run-mode" not in run_env


@pytest.mark.parametrize("args,env,text", [
    (("--run-mode", "pod"), None, "--run-mode needs local or cluster"),
    (("--run-mode",), None, "--run-mode needs local or cluster"),
    ((), {"INSTALL_RUN_MODE_OVERRIDE": "pod"}, "must be local or cluster"),
    (("--run-mode=pod",), None, "must be local or cluster"),
])
def test_a_bad_run_mode_is_refused(sb, args, env, text):
    rel = flat(sb, "local")
    result = run(sb, rel, *args, env=env)
    assert result.returncode != 0
    assert "CHAIN-RAN-LOCALLY" not in result.stdout
    assert text in result.stderr


def test_a_bad_run_mode_stops_before_the_fanout(sb):
    clusters(sb, names=("itz-a", "itz-b"), targets="itz-a itz-b")
    result = run(sb, chain(sb), env={"INSTALL_RUN_MODE_OVERRIDE": "pod"})
    assert result.returncode != 0
    assert result.stderr.count("must be local or cluster") == 1
    assert "[MCM] Running" not in result.stdout
    assert "CHAIN-RAN-LOCALLY" not in result.stdout


def test_run_mode_override_reaches_every_cluster_of_a_fanout(sb):
    clusters(sb, names=("itz-a", "itz-b"), targets="itz-a itz-b")
    result = run(sb, chain(sb, body=ARGS_CHAIN), "--run-mode", "local")
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout.count("CHAIN-RAN-LOCALLY args=<>") == 2
    assert oc_log(sb) == ""


def test_cluster_mode_by_flag_also_skips_the_container(sb):
    clusters(sb, mode="local")
    (sb.fake / "state").write_text("completed\n")
    result = run(sb, chain(sb), "--run-mode", "cluster")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "hello from the pod" in result.stdout
    assert starts(sb) == []
    assert leases(sb) == []


# --- X6: a fan-out of the control script keeps its verb ----------------------------------------------------------
def path_records(box, names):
    """The run record and path record each cluster's pod keeps (collect refuses a run without them).

    One fake oc serves every cluster, so a wrapper hands it the record of the cluster in
    MCM_CLUSTER (each fan-out child exports its own)."""
    for name in names:
        folder = box.fake / "records" / name
        folder.mkdir(parents=True)
        (folder / "pod_run.env").write_text(
            f"IR_RUN_ID=run1\nIR_CLUSTER_URL='{url(name)}'\nIR_SOURCE_CLUSTER='{name}'\nIR_LAYOUT=cluster\n")
        (folder / "pod_path_map").write_text(
            f"configs/cp4d_config=CONFIG_DIR:configs/clusters/{name}/cp4d_config\n"
            f"service_instances=SERVICE_INSTANCE_FILE_DIR:configs/clusters/{name}/service_instances\n")
    real = box.bin / "oc.fake"
    (box.bin / "oc").rename(real)
    (box.bin / "oc").write_text(textwrap.dedent(f"""\
        #!/bin/bash
        r="${{FAKE_DIR}}/records/${{MCM_CLUSTER:-}}"
        if [ -n "${{MCM_CLUSTER:-}}" ] && [ -d "$r" ]; then cp "$r/pod_run.env" "$r/pod_path_map" "${{FAKE_DIR}}/"; fi
        exec "{real}" "$@"
        """))
    (box.bin / "oc").chmod(0o755)


def test_fanout_of_collect_keeps_its_verb(sb):
    clusters(sb, names=("itz-a", "itz-b"), targets="itz-a itz-b")
    path_records(sb, ("itz-a", "itz-b"))
    (sb.fake / "state").write_text("completed\n")
    result = run(sb, RUNNER_TOOL, "collect", "--install", "cpd")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "watch and control installs" not in result.stdout, "a child printed the help"
    assert oc_log(sb).count("touch /work/current/collected") == 2
    for name in ("itz-a", "itz-b"):
        assert f"[MCM] {'1' if name == 'itz-a' else '2'}/2 {name}: ok" in result.stdout
        assert f"Slot {SLOT} on cluster {name}, {url(name)}" in result.stdout


def test_target_cluster_flag_is_taken_before_the_verb_options(sb):
    clusters(sb, names=("itz-a", "itz-b"), current="itz-a")
    path_records(sb, ("itz-a", "itz-b"))
    (sb.fake / "state").write_text("completed\n")
    result = run(sb, RUNNER_TOOL, "collect", "--target-cluster", "itz-b", "--install", "cpd")
    assert result.returncode == 0, result.stdout + result.stderr
    assert f"Slot {SLOT} on cluster itz-b, {url('itz-b')}" in result.stdout
    assert "Unknown" not in result.stderr


# --- collect --to over several clusters (merge of the pod and workstation tracks) ---------------------------------
@pytest.mark.parametrize("form", ["split", "joined"])
def test_collect_to_a_folder_takes_one_cluster(sb, form):
    """--to <dir> has no cluster in its path: a fan-out would put every cluster's results in the same folders."""
    clusters(sb, names=("itz-a", "itz-b"), targets="itz-a itz-b")
    path_records(sb, ("itz-a", "itz-b"))
    (sb.fake / "state").write_text("completed\n")
    dest = sb.root / "results"
    to = ["--to", str(dest)] if form == "split" else [f"--to={dest}"]
    result = run(sb, RUNNER_TOOL, "collect", "--install", "cpd", *to)
    assert result.returncode == 1, result.stdout + result.stderr
    assert "one cluster at a time, but the targets are: itz-a itz-b" in result.stderr
    assert "collect --to <dir> puts every cluster's results in the same folders" in result.stderr
    assert "[MCM] Running" not in result.stdout
    assert oc_log(sb) == ""
    assert not dest.exists()


def test_collect_to_a_folder_on_one_target_still_goes(sb):
    clusters(sb, names=("itz-a", "itz-b"), targets="itz-a itz-b")
    path_records(sb, ("itz-a", "itz-b"))
    (sb.fake / "state").write_text("completed\n")
    dest = sb.root / "results"
    result = run(sb, RUNNER_TOOL, "collect", "--target-cluster", "itz-b", "--install", "cpd", "--to", str(dest))
    assert result.returncode == 0, result.stdout + result.stderr
    assert f"Collecting into {dest.resolve()} (--to)." in result.stdout
    assert "collect --target-cluster itz-b --to-loaded would put them there" in result.stdout


def test_collect_to_loaded_still_runs_on_every_target(sb):
    clusters(sb, names=("itz-a", "itz-b"), targets="itz-a itz-b")
    path_records(sb, ("itz-a", "itz-b"))
    (sb.fake / "state").write_text("completed\n")
    result = run(sb, RUNNER_TOOL, "collect", "--install", "cpd", "--to-loaded")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "[MCM] 1/2 itz-a: ok" in result.stdout and "[MCM] 2/2 itz-b: ok" in result.stdout


def test_a_collect_refusal_hint_carries_the_cluster(sb):
    """The way out of a layout refusal acts on the cluster that refused, not the current one."""
    clusters(sb, names=("itz-a", "itz-b"), current="itz-a")
    path_records(sb, ("itz-b",))
    record = sb.fake / "records/itz-b/pod_run.env"
    record.write_text(record.read_text().replace("IR_SOURCE_CLUSTER='itz-b'", "IR_SOURCE_CLUSTER='old-name'"))
    (sb.fake / "state").write_text("completed\n")
    result = run(sb, RUNNER_TOOL, "collect", "--target-cluster", "itz-b", "--install", "cpd")
    assert result.returncode == 1, result.stdout + result.stderr
    assert "Nothing was collected" in result.stderr
    assert "collect --target-cluster itz-b --to-loaded (into configs/clusters/itz-b/cp4d_config" in result.stderr
    assert "or collect --target-cluster itz-b --to <folder>" in result.stderr


def test_install_is_discovered_in_the_cluster_folder(sb):
    """No --install, two modules: the one with a config in the pinned cluster's folder (not the flat configs/)."""
    sb.write_cluster_marker("itz-a", url("itz-a"))
    (sb.repo / "src/install_runner/installs/demo.conf").write_text(
        'INSTALL_ID="demo"\nINSTALL_ENV_TARGET="demo"\nRUNNER_COLLECT_PATHS="configs/demo_config"\n')
    demo = sb.repo / "configs/clusters/itz-a/demo_config/demo_vars.sh"
    demo.parent.mkdir(parents=True)
    demo.write_text(f'export OCP_URL="{url("itz-a")}"\nexport OC_LOGIN="oc login {url("itz-a")} --token=t"\n')
    (sb.repo / "configs/multi_cluster_management.sh").write_text(
        'export MULTI_CLUSTER_MANAGEMENT="true"\nexport MCM_CLUSTERS="itz-a"\nexport MCM_CURRENT_CLUSTER="itz-a"\n'
        'export APPLY_TO_ALL="false"\nexport MCM_TARGET_CLUSTERS=""\nexport MCM_CONTAINER_IDLE_TIMEOUT_MINUTES="0"\n')
    # Another product's config in the same folder: only the install's own config may load (no "all" load).
    sb.write_config("concert", ocp_url="https://api.concert.example.com:6443", cluster="itz-a")
    result = run(sb, RUNNER_TOOL, "status")
    assert result.returncode == 0, result.stdout + result.stderr
    assert_clean_load(result)
    assert "configs/clusters/itz-a/demo_config/demo_vars.sh" in result.stderr
    assert "concert_vars.sh" not in result.stderr
    assert "install demo, the one with a config here" in result.stderr
    assert "Say which install" not in result.stderr


def test_a_target_left_in_the_shell_does_not_pick_the_config(sb):
    """ENV_TARGET=concert in the shell, no --install: the cpd install is found, so its config loads."""
    clusters(sb)
    sb.write_config("concert", ocp_url="https://api.concert.example.com:6443", cluster="itz-a")
    result = run(sb, RUNNER_TOOL, "status", env={"ENV_TARGET": "concert"})
    assert result.returncode == 0, result.stdout + result.stderr
    assert "configs/clusters/itz-a/cp4d_config/cpd_vars.sh" in result.stderr
    assert "concert_vars.sh" not in result.stderr


def test_a_fanout_skips_a_cluster_with_no_install_config(sb):
    """No --install over two targets: a cluster with no cp4d_config is skipped, not failed (as with --install)."""
    clusters(sb, names=("itz-a", "itz-b"), targets="itz-a itz-b")
    (sb.repo / "configs/clusters/itz-b/cp4d_config/cpd_vars.sh").unlink()
    sb.write_config("concert", ocp_url=url("itz-b"), cluster="itz-b")
    result = run(sb, RUNNER_TOOL, "status")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "[MCM] 1/2 itz-a: ok" in result.stdout
    assert "[MCM] 2/2 itz-b: skipped" in result.stdout
    assert "Cluster 'itz-b' has no install config" in result.stderr
    assert "Say which install" not in result.stderr


def test_the_policy_does_not_reach_the_install_module(sb):
    """MCM_SCRIPT_POLICY is the control script's own, for its verb: a module hook run from it has none."""
    clusters(sb)
    hook = sb.repo / "src/install_runner/installs/cpd.sh"
    # Only on preflight: preflight plans the staging first, and the stage verb's output is parsed.
    hook.write_text('#!/bin/zsh\n[[ "$1" == preflight ]] && print -r -- "POLICY=${MCM_SCRIPT_POLICY-unset}"\nexit 0\n')
    result = run(sb, RUNNER_TOOL, "preflight", "--install", "cpd")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "POLICY=unset" in result.stdout


def test_help_and_unknown_verbs_stop_before_the_env_load(sb):
    clusters(sb, names=("itz-a", "itz-b"), targets="itz-a itz-b")
    shown = run(sb, RUNNER_TOOL)
    assert shown.returncode == 0 and "watch and control installs" in shown.stdout
    assert "[MCM]" not in shown.stdout
    bad = run(sb, RUNNER_TOOL, "bogus")
    assert bad.returncode == 2 and "Unknown command: bogus" in bad.stderr
    assert "[MCM]" not in bad.stdout


# --- X7: the policy goes by verb -----------------------------------------------------------------------------------
@pytest.mark.parametrize("verb", ["attach", "shell", "resume"])
def test_terminal_and_resume_verbs_take_one_cluster(sb, verb):
    clusters(sb, names=("itz-a", "itz-b"), targets="itz-a itz-b")
    result = run(sb, RUNNER_TOOL, verb, "--install", "cpd")
    assert result.returncode == 1, result.stdout + result.stderr
    assert "one cluster at a time" in result.stderr
    assert oc_log(sb) == ""


@pytest.mark.parametrize("verb", ["stop", "teardown"])
def test_stop_and_teardown_ask_before_a_fanout(sb, verb):
    clusters(sb, names=("itz-a", "itz-b"), targets="itz-a itz-b")
    result = run(sb, RUNNER_TOOL, verb, "--install", "cpd")
    assert result.returncode == 1, result.stdout + result.stderr
    assert "--yes-all-clusters" in result.stderr
    assert oc_log(sb) == ""


def test_teardown_fanout_runs_once_confirmed(sb):
    clusters(sb, names=("itz-a", "itz-b"), targets="itz-a itz-b")
    result = run(sb, RUNNER_TOOL, "teardown", "--install", "cpd", "--discard", "--yes-all-clusters")
    assert result.returncode == 0, result.stdout + result.stderr
    assert oc_log(sb).count(f"delete namespace install-runner-{SLOT}") == 2


@pytest.mark.parametrize("verb", ["status", "preflight"])
def test_read_only_verbs_run_on_every_target(sb, verb):
    clusters(sb, names=("itz-a", "itz-b"), targets="itz-a itz-b")
    result = run(sb, RUNNER_TOOL, verb, "--install", "cpd")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "[MCM] 1/2 itz-a: ok" in result.stdout and "[MCM] 2/2 itz-b: ok" in result.stdout


def test_attach_on_one_cluster_still_works(sb):
    clusters(sb, names=("itz-a", "itz-b"), targets="itz-a itz-b")
    (sb.fake / "state").write_text("completed\n")
    result = run(sb, RUNNER_TOOL, "attach", "--install", "cpd", "--target-cluster", "itz-b")
    assert result.returncode == 0, result.stdout + result.stderr
    assert f"collect --slot {SLOT} --target-cluster itz-b" in result.stdout


@pytest.mark.parametrize("value,expected", [("allow", "allow"), ("single-only", "single-only"), ("confirm", "confirm")])
def test_exported_policy_wins_over_the_file_name(sb, value, expected):
    result = sb.run_zsh('source src/helpers/multi_cluster_helpers.sh\nmcm_script_policy "$PWD/x_uninstall_all.sh"\n',
                        env={"MCM_SCRIPT_POLICY": value})
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == expected


def test_a_bad_exported_policy_is_an_error(sb):
    result = sb.run_zsh('source src/helpers/multi_cluster_helpers.sh\nmcm_script_policy "$PWD/x.sh"\n',
                        env={"MCM_SCRIPT_POLICY": "sometimes"})
    assert result.returncode != 0
    assert "MCM_SCRIPT_POLICY must be allow, single-only or confirm" in result.stderr


# --- X14: printed next steps name the cluster ----------------------------------------------------------------------
@pytest.mark.parametrize("state,collected,hint", [
    ("running", "", "attach --slot slot"),
    ("failed", "", "resume --slot slot"),
    ("completed", "no", "collect --slot slot"),
])
def test_busy_slot_hints_carry_the_cluster(fake, state, collected, hint):
    (fake / "status.state").write_text(state)
    (fake / "status.collected").write_text(collected)
    pinned = zsh("ir_refuse_busy_slot ns slot", fake, {"MCM_CLUSTER": "itz-b"})
    assert f"{hint} --target-cluster itz-b" in pinned.stderr
    flat_run = zsh("ir_refuse_busy_slot ns slot", fake, {"MCM_CLUSTER": ""})
    assert f"{hint}" in flat_run.stderr and "--target-cluster" not in flat_run.stderr


def test_attach_and_error_hints_carry_the_cluster(fake):
    (fake / "state").write_text("completed\n")
    assert "collect --slot slot --target-cluster itz-b" in zsh("ir_attach slot", fake, {"MCM_CLUSTER": "itz-b"}).stdout
    (fake / "state").write_text("completed-with-warnings\n")
    warned = zsh("ir_attach slot", fake, {"MCM_CLUSTER": "itz-b"}).stderr
    assert "status --target-cluster itz-b, then collect --slot slot --target-cluster itz-b." in warned
    assert "See x_install_runner.sh status, then collect." in zsh("ir_attach slot", fake, {"MCM_CLUSTER": ""}).stderr
    failed = zsh("ir_error_state slot failed", fake, {"MCM_CLUSTER": "itz-b"})
    assert "resume --slot slot --target-cluster itz-b" in failed.stderr


def test_handoff_watch_hint_carries_the_cluster(sb):
    clusters(sb)
    (sb.fake / "state").write_text("completed\n")
    result = run(sb, chain(sb))
    assert result.returncode == 0, result.stdout + result.stderr
    assert "x_watch_install.sh --install cpd --target-cluster itz-a" in result.stdout
    assert f"collect --slot {SLOT} --target-cluster itz-a" in result.stdout


# --- X25: a flat load of another product needs no configs/cp4d_config ---------------------------------------------
LOAD = 'source "${0:A:h}/env_bootstrap.sh"\nprint -r -- "URL=${OCP_URL:-}"\n'


def test_flat_concert_load_without_a_cp4d_config(sb):
    sb.write_config("concert", ocp_url="https://api.c:6443")
    result = sb.run_zsh(LOAD, env={"ENV_TARGET": "concert"})
    assert result.returncode == 0, result.stderr
    assert_clean_load(result)
    assert "URL=https://api.c:6443" in result.stdout


def test_a_cp4d_target_with_no_cp4d_config_folder_keeps_the_error(sb):
    """cpd_vars.sh found in another folder: the CP4D work-dir copy still has nothing to copy, as before."""
    legacy = sb.repo / "configs/legacy/cpd_vars.sh"
    legacy.parent.mkdir(parents=True)
    legacy.write_text('export OCP_URL="https://api.c:6443"\n')
    result = sb.run_zsh(LOAD, env={"ENV_TARGET": "cpd"})
    assert result.returncode != 0
    assert "no matches found" in result.stderr


def test_an_empty_cp4d_config_folder_keeps_the_error(sb):
    sb.write_config("concert", ocp_url="https://api.c:6443")
    (sb.repo / "configs/cp4d_config").mkdir()
    result = sb.run_zsh(LOAD, env={"ENV_TARGET": "concert"})
    assert result.returncode != 0
    assert "no matches found" in result.stderr
