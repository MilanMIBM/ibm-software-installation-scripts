"""A chain no install module lists, in a run set to run in the cluster: it asks to run here instead.

ir_local_fallback (src/helpers/install_runner_mode.sh) asks, for this run only, and nothing is written to a
config; --local-install-fallback (IR_LOCAL_INSTALL_FALLBACK=1) answers yes, and with no terminal and no flag
the run stops naming the flag. A multi-cluster run asks once, in the parent, for every target set to run in
the cluster (ir_fanout_local_fallback); those then run here one at a time, and --parallel is dropped. A config
without INSTALL_RUN_MODE is local: a value left in the shell never reaches the run (source_env_setup.sh).
"""
import pytest
from test_install_runner import CPD_CHAIN, SANDBOX_URL, STAND_IN_CHAIN, handoff  # noqa: F401
from test_install_runner_fanout_confirm import TRACE_CHAIN, converse, timeline
from test_install_runner_workstation import chain, clusters, oc_log, run, sb  # noqa: F401

# Under scripts/install_cloud_pak_for_data/, so it loads cpd_vars.sh and its INSTALL_RUN_MODE, but no module
# lists it (like 5.x StreamSets).
NO_MODULE = "scripts/install_cloud_pak_for_data/5_component_specific_scripts/x_no_module_chain.sh"
CONFLUENT = "scripts/install_confluent_platform/x_no_module_chain.sh"
QUESTION = "Run it on this machine instead, for this run only? The config stays as it is. [y/N] "
FANOUT_QUESTION = "Run them on this machine instead, one cluster at a time, for this run only? The configs stay as they are. [y/N] "
OVERRIDE_CHAIN = STAND_IN_CHAIN.replace(
    "print -r -- CHAIN-RAN-LOCALLY",
    'print -r -- "CHAIN-RAN-LOCALLY override=${INSTALL_RUN_MODE_OVERRIDE:-} fallback=${IR_LOCAL_INSTALL_FALLBACK:-} '
    'args=<${(j:,:)@}>"')


def cpd_vars(box, cluster=None):
    base = box.repo / "configs" / (f"clusters/{cluster}" if cluster else "")
    return (base / "cp4d_config/cpd_vars.sh").read_text()


# --- one cluster --------------------------------------------------------------------------------------------------
def test_no_terminal_and_no_flag_stops_and_names_the_flag(sb):
    result = handoff(sb, chain=NO_MODULE)
    assert result.returncode != 0
    assert "CHAIN-RAN-LOCALLY" not in result.stdout
    assert "no install module" in result.stderr
    assert "--local-install-fallback" in result.stderr
    assert "INSTALL_RUN_MODE=cluster in configs/cp4d_config/cpd_vars.sh" in result.stderr
    assert not (sb.fake / "oc.log").exists(), "nothing may reach the cluster"


@pytest.mark.parametrize("how", ["flag", "env"])
def test_the_flag_runs_it_here_without_asking_and_keeps_the_config(sb, how):
    args, env = (("--local-install-fallback", "--x"), None) if how == "flag" else (("--x",), {"IR_LOCAL_INSTALL_FALLBACK": "1"})
    chain(sb, NO_MODULE, OVERRIDE_CHAIN)
    result = handoff(sb, *args, chain=NO_MODULE, env=env)
    assert result.returncode == 0, result.stdout + result.stderr
    # The flag never reaches the chain; nested steps get the override and ask nothing.
    assert "CHAIN-RAN-LOCALLY override=local fallback=1 args=<--x>" in result.stdout
    assert "running it on this machine for this run (--local-install-fallback)" in result.stdout
    assert QUESTION not in result.stdout
    assert 'INSTALL_RUN_MODE="cluster"' in cpd_vars(sb)
    assert "hello from the pod" not in result.stdout


@pytest.mark.parametrize(("typed", "ran"), [("y", True), ("yes", True), ("n", False), ("", False)])
def test_at_a_terminal_it_asks(sb, typed, ran):
    handoff(sb, "--list-steps", chain=NO_MODULE)  # writes the config and the chain; a question about it asks nothing
    result, _ = converse(sb, NO_MODULE, [(QUESTION, typed)])
    assert ("CHAIN-RAN-LOCALLY" in result.stdout) is ran, result.stdout + result.stderr
    assert (result.returncode == 0) is ran
    if not ran:
        assert "Nothing was run." in result.stderr
    assert 'INSTALL_RUN_MODE="cluster"' in cpd_vars(sb)


def test_a_question_about_the_chain_asks_nothing(sb):
    result = handoff(sb, "--help", chain=NO_MODULE)
    assert "CHAIN-RAN-LOCALLY" in result.stdout
    assert QUESTION not in result.stdout


def test_a_chain_with_a_module_still_goes_to_the_pod(sb):
    (sb.fake / "state").write_text("completed\n")
    result = handoff(sb, "--local-install-fallback")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "hello from the pod" in result.stdout
    assert "CHAIN-RAN-LOCALLY" not in result.stdout


def test_a_config_without_the_mode_is_local_whatever_the_shell_says(sb):
    """confluent_vars.sh has no INSTALL_RUN_MODE: local, even with cluster exported in the shell."""
    sb.write_config("confluent", ocp_url=SANDBOX_URL)
    result = handoff(sb, chain=CONFLUENT, env={"INSTALL_RUN_MODE": "cluster"})
    assert result.returncode == 0, result.stdout + result.stderr
    assert "CHAIN-RAN-LOCALLY" in result.stdout
    assert "no install module" not in result.stdout + result.stderr


def test_run_mode_cluster_on_such_a_chain_asks_too(sb):
    sb.write_config("confluent", ocp_url=SANDBOX_URL)
    result = handoff(sb, "--run-mode", "cluster", chain=CONFLUENT)
    assert result.returncode != 0
    assert "--run-mode cluster, but scripts/install_confluent_platform/x_no_module_chain.sh has no install module" in result.stderr
    result = handoff(sb, "--run-mode", "cluster", "--local-install-fallback", chain=CONFLUENT)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "CHAIN-RAN-LOCALLY" in result.stdout


# --- several clusters -----------------------------------------------------------------------------------------------
def fanout(box, names=("itz-a", "itz-b"), mode="cluster"):
    clusters(box, names=names, targets=" ".join(names), mode=mode)
    return chain(box, NO_MODULE, TRACE_CHAIN)


def test_fanout_with_no_terminal_and_no_flag_runs_nothing(sb):
    rel = fanout(sb)
    result = run(sb, rel)
    assert result.returncode != 0
    assert "2 target(s) are set to run it there: itz-a, itz-b." in result.stderr
    assert "--local-install-fallback" in result.stderr
    assert timeline(sb) == [] and oc_log(sb) == ""
    assert "[MCM] 1/" not in result.stdout


def test_fanout_flag_runs_every_target_here_one_at_a_time(sb):
    rel = fanout(sb)
    result = run(sb, rel, "--local-install-fallback")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "itz-a, itz-b run it on this machine instead, one cluster at a time (--local-install-fallback)" in result.stdout
    assert "[MCM] Running x_no_module_chain.sh on 2 clusters, one at a time: itz-a itz-b" in result.stdout
    assert timeline(sb) == ["local itz-a", "local itz-b"]
    assert "CHAIN-RAN-LOCALLY on=itz-a par= override=local args=<>" in result.stdout
    assert FANOUT_QUESTION not in result.stdout and "[y/N]" not in result.stdout, "no child asks again"
    assert 'INSTALL_RUN_MODE="cluster"' in cpd_vars(sb, "itz-a")


@pytest.mark.parametrize(("typed", "ran"), [("y", True), ("n", False)])
def test_fanout_asks_once_for_every_target(sb, typed, ran):
    rel = fanout(sb)
    result, seen = converse(sb, rel, [(FANOUT_QUESTION, typed)])
    assert seen == [""], "nothing starts before the answer"
    assert result.stdout.count("[y/N]") == 1, result.stdout
    if ran:
        assert result.returncode == 0, result.stdout + result.stderr
        assert timeline(sb) == ["local itz-a", "local itz-b"]
    else:
        assert result.returncode != 0
        assert "Cancelled: nothing was run on any cluster." in result.stderr
        assert timeline(sb) == []


def test_fanout_of_local_targets_asks_nothing(sb):
    rel = fanout(sb, mode="local")
    result = run(sb, rel)
    assert result.returncode == 0, result.stdout + result.stderr
    assert timeline(sb) == ["local itz-a", "local itz-b"]
    assert "no install module" not in result.stdout + result.stderr


def test_parallel_with_the_flag_runs_one_cluster_at_a_time(sb):
    rel = fanout(sb)
    result = run(sb, rel, "--parallel", "--local-install-fallback")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "--parallel ignored: x_no_module_chain.sh has no install module" in result.stderr
    assert timeline(sb) == ["local itz-a", "local itz-b"]
    assert "par= " in result.stdout


def test_parallel_without_the_flag_is_refused_naming_it(sb):
    rel = fanout(sb)
    result = run(sb, rel, "--parallel")
    assert result.returncode != 0
    assert "add --local-install-fallback" in result.stderr
    assert timeline(sb) == []
