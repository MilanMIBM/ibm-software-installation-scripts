"""In-cluster runner under multi-cluster management: the same-type lock, run mode per cluster, and the
questions before a multi-cluster install run.

Spec: .claude/plans/multi-cluster-management/in-cluster-install-addon/remaining-work.md, "User decisions,
2026-11-12": C10 (one install of each type per cluster, no user override), C11 (each cluster's own
INSTALL_RUN_MODE), C12 (the questions, answers Q-a1 to Q-a7).

Everything runs against fakes: the runner tests' fake oc (FAKE_OC, with a variant here that also writes a
timeline of what reached the "cluster" and what ran here), the tests/mcm_harness.py sandbox with its fake
podman and cpd-cli, a sandbox HOME for leases and launch records, and a pseudo-terminal for the questions.
Leases name a live PID that is this test process's own, never one read from the process table.
"""

import os
import pty
import re
import select
import subprocess
import time

import pytest
from test_install_runner import CPD_CHAIN, FAKE_OC, REPO, STAND_IN_CHAIN, fake, zsh  # noqa: F401
from test_install_runner_fanout import oc_variant, use_oc
from test_install_runner_workstation import SLOT, chain, clusters, oc_log, run, sb, url  # noqa: F401

WATCH = "scripts/install_runner/x_watch_install.sh"
PREFLIGHT_BASE = {"STG_CLASS_BLOCK": "blk", "STG_CLASS_FILE": "fil", "CONFIG_DIR": "/nonexistent"}
LABEL = "IBM Software Hub / Cloud Pak for Data (install cpd)"

# What reached the cluster, and what ran here, in order: a pod launch (its cluster from KUBECONFIG), a chain
# that ran on this machine, and the status table's reads (x_install_runner.sh status sets IR_STATUS_ROWS).
TRACE_OC = oc_variant(
    ('*"finalize-stage.sh"*) echo "$args" > "$d/finalized" ;;',
     '*"finalize-stage.sh"*) echo "$args" > "$d/finalized"; echo "pod ${KUBECONFIG}" >> "$d/timeline" ;;'),
    ('"get configmap -A"*) cat', '"get configmap -A"*) echo "configmap ${IR_STATUS_ROWS:+status}" >> "$d/timeline"; cat'),
)
TRACE_CHAIN = STAND_IN_CHAIN.replace(
    "print -r -- CHAIN-RAN-LOCALLY",
    'print -r -- "CHAIN-RAN-LOCALLY on=${MCM_CLUSTER:-flat} par=${IR_FANOUT_PARALLEL:-} '
    'override=${INSTALL_RUN_MODE_OVERRIDE:-} args=<${(j:,:)@}>"\n'
    'print -r -- "local ${MCM_CLUSTER:-flat}" >> "$FAKE_DIR/timeline"')
NO_TERMINAL = "There is no terminal to ask on, so nothing was run on any cluster."
FLAGS = ("--switch-to-cluster a,b", "--local-cluster NAME", "--yes")
Q1 = "Numbers or names (comma or space separated), none, or cancel: "
Q3 = "Number or name, or cancel: "
START = "Start? Type y to start (anything else cancels): "
CANCELLED = "Cancelled: nothing was run on any cluster."


def setup(box, modes, current="itz-a"):
    """Delineated clusters with the given INSTALL_RUN_MODE each, all of them targets, the tracing oc and chain."""
    names = tuple(modes)
    clusters(box, names=names, current=current, targets=" ".join(names))
    for name, mode in modes.items():
        path = box.repo / f"configs/clusters/{name}/cp4d_config/cpd_vars.sh"
        path.write_text(path.read_text().replace('INSTALL_RUN_MODE="cluster"', f'INSTALL_RUN_MODE="{mode}"'))
    use_oc(box.bin / "oc", TRACE_OC)
    return chain(box, body=TRACE_CHAIN)


def table_row(result, name):
    """The RESULT and DURATION of cluster name in the fan-out's result table (the first table printed)."""
    table = result.stdout.split("[MCM] Result per cluster:", 1)[1]
    return next((line.split(None, 2)[2] for line in table.splitlines()
                 if line.startswith("[MCM]   ") and line.split()[1:2] == [name]), None)


def timeline(box):
    """pod <cluster>, local <cluster> and status, in the order they happened (repeated status reads as one)."""
    path = box.fake / "timeline"
    events = []
    for line in (path.read_text().splitlines() if path.exists() else []):
        kind, _, rest = line.partition(" ")
        if kind == "pod":
            event = "pod " + re.search(r"clusters/([^/]+)/", rest).group(1)
        elif kind == "local":
            event = line
        elif kind == "configmap" and rest == "status":
            event = "status"
        else:
            continue
        if not (event == "status" and events[-1:] == ["status"]):
            events.append(event)
    return events


def nothing_started(box, result):
    assert oc_log(box) == "", "nothing may reach a cluster"
    assert timeline(box) == []
    assert "CHAIN-RAN-LOCALLY" not in result.stdout
    assert "[MCM] 1/" not in result.stdout, "no cluster may start"


class Result:
    def __init__(self, returncode, stdout, stderr):
        self.returncode, self.stdout, self.stderr = returncode, stdout, stderr


def converse(box, rel, answers, args=(), env=None, timeout=40):
    """Runs rel with a terminal on stdin. answers: [(prompt, typed)]; each is typed once its prompt shows on
    stdout. Returns the result and, per answer, what had reached the cluster or run here when its prompt
    showed (the fake oc's log plus the timeline), so a test can check that nothing started before it."""
    master, slave = pty.openpty()
    proc = subprocess.Popen(["zsh", str(box.repo / rel), *args], cwd=box.repo,
                            env=box.env({"FAKE_DIR": box.fake, **(env or {})}),
                            stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    os.close(slave)
    out, seen, pos = b"", [], 0
    try:
        for prompt, typed in answers:
            end = time.monotonic() + timeout
            while (found := out.find(prompt.encode(), pos)) < 0:
                left = end - time.monotonic()
                assert left > 0, f"no prompt {prompt!r} in:\n{out.decode()}"
                ready, _, _ = select.select([proc.stdout], [], [], left)
                if ready:
                    chunk = os.read(proc.stdout.fileno(), 65536)
                    if not chunk:
                        raise AssertionError(f"ended before {prompt!r}:\n{out.decode()}\n{proc.stderr.read().decode()}")
                    out += chunk
            pos = found + len(prompt)
            seen.append(oc_log(box) + "".join(timeline(box)))
            os.write(master, typed.encode() + b"\n")
        rest, err = proc.communicate(timeout=timeout)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.communicate()
        os.close(master)
    return Result(proc.returncode, (out + rest).decode(), err.decode()), seen


def assert_flags_named(result):
    assert NO_TERMINAL in result.stderr, result.stdout + result.stderr
    for flag in FLAGS:
        assert flag in result.stderr


THREE = {"itz-a": "local", "itz-b": "cluster", "itz-c": "local"}


# --- C11: each cluster's own mode ----------------------------------------------------------------------------------
def test_each_cluster_runs_in_its_own_mode(sb):
    """One local target: no question. Its pod targets launch first without watching, then it runs here in the
    foreground, then the status of every cluster (Q-a6)."""
    rel = setup(sb, {"itz-a": "local", "itz-b": "cluster"})
    result = run(sb, rel)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "[MCM]   itz-a                local    INSTALL_RUN_MODE in configs/clusters/itz-a/cp4d_config/cpd_vars.sh" in result.stdout
    assert "[MCM]   itz-b                cluster  INSTALL_RUN_MODE in configs/clusters/itz-b/cp4d_config/cpd_vars.sh" in result.stdout
    assert "Start?" not in result.stdout and NO_TERMINAL not in result.stderr
    assert timeline(sb) == ["pod itz-b", "local itz-a", "status"]
    assert table_row(result, "itz-b").startswith(f"launched (slot {SLOT})")
    assert table_row(result, "itz-a").startswith("ok")
    assert "CHAIN-RAN-LOCALLY on=itz-a par= override= args=<>" in result.stdout
    assert "follow.sh" not in oc_log(sb), "the pod target is launched, not watched"
    assert "[MCM] Where each install stands (scripts/install_runner/x_install_runner.sh status --all-clusters):" in result.stdout
    assert "[MCM] Running x_install_runner.sh on 2 clusters, one at a time: itz-a itz-b" in result.stdout


def test_a_shell_export_does_not_decide_a_clusters_mode(sb):
    """INSTALL_RUN_MODE exported in the shell is forgotten by the fan-out (C11): each child reads its own."""
    rel = setup(sb, {"itz-a": "local", "itz-b": "cluster"})
    result = run(sb, rel, env={"INSTALL_RUN_MODE": "local"})
    assert result.returncode == 0, result.stdout + result.stderr
    assert timeline(sb) == ["pod itz-b", "local itz-a", "status"]


def test_all_pod_fanouts_are_unchanged(sb):
    """No local target: no list, no question, the sequential watch as before."""
    rel = setup(sb, {"itz-a": "cluster", "itz-b": "cluster"})
    (sb.fake / "state").write_text("completed\n")
    result = run(sb, rel)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "Where each one's install runs" not in result.stdout
    assert "[MCM] Running full_swhub_x_cpd_installprocess.sh on 2 clusters, one at a time: itz-a itz-b" in result.stdout
    assert result.stdout.count("hello from the pod") == 2
    assert timeline(sb) == ["pod itz-a", "pod itz-b"], "no status table after a watched run"


def test_run_mode_cluster_makes_every_target_a_pod(sb):
    rel = setup(sb, THREE)
    (sb.fake / "state").write_text("completed\n")
    result = run(sb, rel, "--run-mode", "cluster")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "Where each one's install runs" not in result.stdout
    assert timeline(sb) == ["pod itz-a", "pod itz-b", "pod itz-c"]


PARALLEL_LEFT = "--parallel only launches installs in the cluster, and these targets would still run"


def test_parallel_with_local_targets_asks_before_any_launch(sb):
    """--parallel runs nothing here: even one local target needs question 1, and with no terminal that refuses
    the run, naming the flags, before any pod is launched."""
    rel = setup(sb, {"itz-a": "local", "itz-b": "cluster"})
    result = run(sb, rel, "--parallel")
    assert result.returncode == 1
    assert "--parallel runs nothing on this machine, but 1 target(s) would run full_swhub_x_cpd_installprocess.sh here (itz-a)." in result.stderr
    assert_flags_named(result)
    nothing_started(sb, result)


@pytest.mark.parametrize("args", [("--switch-to-cluster", "none"), ("--switch-to-cluster", "itz-c", "--yes")],
                         ids=["none", "one-of-two"])
def test_parallel_refuses_a_local_target_left_after_the_switch(sb, args):
    rel = setup(sb, THREE)
    result = run(sb, rel, "--parallel", *args)
    assert result.returncode == 1
    assert PARALLEL_LEFT in result.stderr
    assert "--switch-to-cluster itz-a" in result.stderr
    assert "This plan needs a last confirmation." not in result.stderr
    nothing_started(sb, result)


def test_parallel_refuses_local_cluster(sb):
    rel = setup(sb, THREE)
    result = run(sb, rel, "--parallel", "--switch-to-cluster", "itz-a", "--local-cluster", "itz-c", "--yes")
    assert result.returncode == 1
    assert "--local-cluster cannot be combined with --parallel" in result.stderr
    nothing_started(sb, result)


def test_parallel_launches_every_switched_target_without_watching(sb):
    rel = setup(sb, THREE)
    result = run(sb, rel, "--parallel", "--switch-to-cluster", "itz-a,itz-c", "--yes")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "launched one after the other and not watched (--parallel): itz-a, itz-b, itz-c (switched for this run: itz-a, itz-c)" in result.stdout
    assert timeline(sb) == ["pod itz-a", "pod itz-b", "pod itz-c"]
    for name in ("itz-a", "itz-b", "itz-c"):
        assert table_row(result, name).startswith("launched")
    assert "follow.sh" not in oc_log(sb) and "CHAIN-RAN-LOCALLY" not in result.stdout
    assert 'INSTALL_RUN_MODE="local"' in (sb.repo / "configs/clusters/itz-a/cp4d_config/cpd_vars.sh").read_text()


def test_parallel_at_a_terminal_asks_for_a_single_local_target(sb):
    rel = setup(sb, {"itz-a": "local", "itz-b": "cluster"})
    result, seen = converse(sb, rel, [(Q1, "1")], args=("--parallel",))
    assert result.returncode == 0, result.stdout + result.stderr
    assert seen == [""]
    assert "--parallel runs nothing on this machine, but 1 target(s) would run" in result.stdout
    assert START not in result.stdout, "one local target to begin with: no last confirmation"
    assert timeline(sb) == ["pod itz-a", "pod itz-b"]


def test_parallel_at_a_terminal_none_refuses(sb):
    rel = setup(sb, {"itz-a": "local", "itz-b": "cluster"})
    result, _ = converse(sb, rel, [(Q1, "none")], args=("--parallel",))
    assert result.returncode == 1
    assert PARALLEL_LEFT in result.stderr
    nothing_started(sb, result)


# --- C11: a mode the plan cannot read refuses the run ---------------------------------------------------------------
@pytest.mark.parametrize("value", ["${INSTALL_RUN_MODE:-cluster}", "Cluster", "$(echo cluster)"],
                         ids=["variable", "other-word", "command"])
def test_a_mode_that_is_not_plain_refuses_the_whole_run(sb, value):
    rel = setup(sb, {"itz-a": "local", "itz-b": value})
    result = run(sb, rel, "--yes")
    assert result.returncode == 1
    path = sb.repo / "configs/clusters/itz-b/cp4d_config/cpd_vars.sh"
    assert f'itz-b: INSTALL_RUN_MODE in {path} is not a plain "local" or "cluster" (line ' in result.stderr
    assert f'INSTALL_RUN_MODE="{value}"' in result.stderr, "the line is quoted"
    assert "--run-mode local|cluster" in result.stderr
    nothing_started(sb, result)


def test_run_mode_answers_a_mode_that_is_not_plain(sb):
    rel = setup(sb, {"itz-a": "local", "itz-b": "${INSTALL_RUN_MODE:-cluster}"})
    (sb.fake / "state").write_text("completed\n")
    result = run(sb, rel, "--run-mode", "cluster")
    assert result.returncode == 0, result.stdout + result.stderr
    assert timeline(sb) == ["pod itz-a", "pod itz-b"]


def test_an_empty_mode_is_local_as_the_child_reads_it(sb):
    rel = setup(sb, {"itz-a": "", "itz-b": "cluster"})
    result = run(sb, rel)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "INSTALL_RUN_MODE is empty: local" in result.stdout
    assert timeline(sb) == ["pod itz-b", "local itz-a", "status"]


# --- C12 with no terminal: the flags, or a refusal that names them (Q-a5) ------------------------------------------
def test_no_terminal_refuses_when_a_question_is_needed(sb):
    rel = setup(sb, THREE)
    result = run(sb, rel)
    assert result.returncode == 1
    assert "2 targets would run full_swhub_x_cpd_installprocess.sh on this machine (itz-a, itz-c)" in result.stderr
    assert_flags_named(result)
    nothing_started(sb, result)


def test_no_terminal_with_the_flags_keeps_the_main_target_local(sb):
    """--switch-to-cluster none answers the first question; the current cluster is the main target (Q-a3), so
    the other local target is skipped; --yes answers the last."""
    rel = setup(sb, THREE)
    result = run(sb, rel, "--switch-to-cluster", "none", "--yes", "--from", "x")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "Only the current cluster, itz-a (MCM_CURRENT_CLUSTER), runs here. Skipped in this run: itz-c." in result.stdout
    assert timeline(sb) == ["pod itz-b", "local itz-a", "status"]
    assert table_row(result, "itz-c") == "skipped (runs here, but only itz-a does in this run)  -"
    assert "CHAIN-RAN-LOCALLY on=itz-a par= override= args=<--from,x>" in result.stdout, "the flags never reach the chain"
    run_env = (sb.fake / "run.env").read_text()
    assert "--yes" not in run_env and "--switch-to-cluster" not in run_env


def test_switched_targets_run_in_the_cluster_for_this_run_only(sb):
    rel = setup(sb, THREE)
    result = run(sb, rel, "--switch-to-cluster=itz-c", "--yes")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "in the cluster, launched first and not watched: itz-b, itz-c (switched for this run: itz-c)" in result.stdout
    assert timeline(sb) == ["pod itz-b", "pod itz-c", "local itz-a", "status"]
    assert 'INSTALL_RUN_MODE="local"' in (sb.repo / "configs/clusters/itz-c/cp4d_config/cpd_vars.sh").read_text(), \
        "a switch never writes the config (Q-a2)"
    assert "skipped" not in result.stdout.split("Result per cluster:")[1]


def test_no_terminal_and_no_main_target_needs_the_local_cluster(sb):
    rel = setup(sb, THREE, current="itz-b")
    refused = run(sb, rel, "--switch-to-cluster", "none", "--yes")
    assert refused.returncode == 1
    assert "none of them is the current cluster (itz-b)" in refused.stderr
    assert_flags_named(refused)
    nothing_started(sb, refused)
    result = run(sb, rel, "--switch-to-cluster", "none", "--local-cluster", "itz-c", "--yes")
    assert result.returncode == 0, result.stdout + result.stderr
    assert timeline(sb) == ["pod itz-b", "local itz-c", "status"]
    assert table_row(result, "itz-a").startswith("skipped (runs here, but only itz-c does in this run)")


def test_local_cluster_takes_priority_over_the_main_target(sb):
    """Q-b2: --local-cluster names a local target that is not the current cluster: it runs here for this run.
    The current cluster goes to the normal list with the others: switched, or skipped (here: none, skipped)."""
    rel = setup(sb, THREE)
    result = run(sb, rel, "--switch-to-cluster", "none", "--local-cluster", "itz-c", "--yes")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "--local-cluster: itz-c runs here in this run. Skipped in this run: itz-a (the current cluster)." in result.stdout
    assert timeline(sb) == ["pod itz-b", "local itz-c", "status"]
    assert table_row(result, "itz-a").startswith("skipped (runs here, but only itz-c does in this run)")
    assert "CHAIN-RAN-LOCALLY on=itz-c" in result.stdout
    for name in ("itz-a", "itz-c"):
        assert 'INSTALL_RUN_MODE="local"' in (sb.repo / f"configs/clusters/{name}/cp4d_config/cpd_vars.sh").read_text(), \
            "nothing is saved to any config"


def test_local_cluster_lets_the_current_cluster_be_switched(sb):
    rel = setup(sb, THREE)
    result = run(sb, rel, "--switch-to-cluster", "itz-a", "--local-cluster", "itz-c", "--yes")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "in the cluster, launched first and not watched: itz-a, itz-b (switched for this run: itz-a)" in result.stdout
    assert timeline(sb) == ["pod itz-a", "pod itz-b", "local itz-c", "status"]
    assert "skipped" not in result.stdout.split("Result per cluster:")[1]


def test_local_cluster_asks_about_the_other_local_targets_only(sb):
    """At a terminal, question 1 lists the other local targets (the current cluster too), never the named one."""
    rel = setup(sb, {"itz-a": "local", "itz-b": "local", "itz-c": "local"})
    result, seen = converse(sb, rel, [(Q1, "1"), (START, "y")], args=("--local-cluster", "itz-c"))
    assert result.returncode == 0, result.stdout + result.stderr
    assert seen == ["", ""], "nothing starts before the last answer"
    question = result.stdout.split("Which of them should run in the cluster instead", 1)[1].split(Q1, 1)[0]
    assert "1) itz-a" in question and "2) itz-b" in question and "itz-c" not in question.split("To switch")[0]
    assert "itz-c runs full_swhub_x_cpd_installprocess.sh on this machine in this run (--local-cluster)" in result.stdout
    assert timeline(sb) == ["pod itz-a", "local itz-c", "status"]
    assert table_row(result, "itz-b").startswith("skipped (runs here, but only itz-c does in this run)")


def test_local_cluster_with_no_terminal_still_needs_the_switch_answer(sb):
    rel = setup(sb, THREE)
    result = run(sb, rel, "--local-cluster", "itz-c", "--yes")
    assert result.returncode == 1
    assert "itz-c runs full_swhub_x_cpd_installprocess.sh on this machine (--local-cluster), and 1 other target(s) would run it here too (itz-a)" in result.stderr
    assert_flags_named(result)
    nothing_started(sb, result)


def test_local_cluster_with_run_mode_local_skips_the_others(sb):
    """--run-mode local leaves nothing to switch (Q-a4): the named target runs here, every other is skipped."""
    rel = setup(sb, THREE)
    result = run(sb, rel, "--run-mode", "local", "--local-cluster", "itz-b", "--yes")
    assert result.returncode == 0, result.stdout + result.stderr
    assert Q1 not in result.stdout
    assert timeline(sb) == ["local itz-b"]
    for name in ("itz-a", "itz-c"):
        assert table_row(result, name).startswith("skipped (runs here, but only itz-b does in this run)")


def test_local_cluster_and_the_same_switch_contradict(sb):
    rel = setup(sb, THREE)
    result = run(sb, rel, "--switch-to-cluster", "itz-c", "--local-cluster", "itz-c", "--yes")
    assert result.returncode == 1
    assert "--local-cluster itz-c and --switch-to-cluster itz-c contradict each other" in result.stderr
    nothing_started(sb, result)


def test_local_cluster_may_name_the_main_target(sb):
    rel = setup(sb, THREE)
    result = run(sb, rel, "--switch-to-cluster", "none", "--local-cluster", "itz-a", "--yes")
    assert result.returncode == 0, result.stdout + result.stderr
    assert timeline(sb) == ["pod itz-b", "local itz-a", "status"]
    assert table_row(result, "itz-c").startswith("skipped")


def test_local_cluster_picks_among_the_rest_once_the_main_target_is_switched(sb):
    rel = setup(sb, {"itz-a": "local", "itz-b": "local", "itz-c": "local"})
    result = run(sb, rel, "--switch-to-cluster", "itz-a", "--local-cluster", "itz-c", "--yes")
    assert result.returncode == 0, result.stdout + result.stderr
    assert timeline(sb) == ["pod itz-a", "local itz-c", "status"]
    assert table_row(result, "itz-b").startswith("skipped (runs here, but only itz-c does in this run)")


def test_no_terminal_needs_yes_for_the_last_confirmation(sb):
    rel = setup(sb, THREE)
    result = run(sb, rel, "--switch-to-cluster", "none")
    assert result.returncode == 1
    assert "This plan needs a last confirmation." in result.stderr
    assert_flags_named(result)
    nothing_started(sb, result)


@pytest.mark.parametrize("args,text", [
    (("--switch-to-cluster", "itz-z", "--yes"), "--switch-to-cluster: 'itz-z' is not a target of this run"),
    (("--local-cluster", "itz-z", "--yes"), "--local-cluster: 'itz-z' is not a target of this run"),
    (("--switch-to-cluster", "none", "--local-cluster", "itz-b", "--yes"), "--local-cluster: itz-b does not run on this machine in this run (itz-a, itz-c)"),
    (("--switch-to-cluster", "itz-c", "--run-mode", "local", "--yes"), "--switch-to-cluster cannot be combined with --run-mode"),
    (("--switch-to-cluster",), "--switch-to-cluster needs cluster names (a,b) or none"),
    (("--local-cluster=",), "--local-cluster needs a cluster name"),
])
def test_bad_answers_in_the_command_stop_before_anything(sb, args, text):
    rel = setup(sb, THREE)
    result = run(sb, rel, *args)
    assert result.returncode == 1
    assert text in result.stderr, result.stderr
    nothing_started(sb, result)


def test_switching_every_local_target_watches_each_pod_as_before(sb):
    rel = setup(sb, THREE)
    (sb.fake / "state").write_text("completed\n")
    result = run(sb, rel, "--switch-to-cluster", "itz-a,itz-c", "--yes")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "in the cluster, one after the other, each watched to its end: itz-a, itz-b, itz-c" in result.stdout
    assert timeline(sb) == ["pod itz-a", "pod itz-b", "pod itz-c"]
    assert result.stdout.count("hello from the pod") == 3


def test_targets_that_share_a_url_are_refused_when_they_overlap(sb):
    rel = setup(sb, {"itz-a": "local", "itz-b": "cluster", "itz-c": "cluster"})
    sb.write_cluster_marker("itz-c", url("itz-b"))
    result = run(sb, rel)
    assert result.returncode == 1
    assert "These targets run at the same time: these targets are one cluster under two names: 'itz-b' and 'itz-c'" in result.stderr
    nothing_started(sb, result)


def test_the_same_url_is_refused_before_the_last_confirmation(sb):
    """itz-c is switched next to itz-b, which has its URL: refused before the plan is confirmed."""
    rel = setup(sb, THREE)
    sb.write_cluster_marker("itz-c", url("itz-b"))
    refused = run(sb, rel, "--switch-to-cluster", "itz-c")
    assert refused.returncode == 1
    assert "These targets run at the same time: these targets are one cluster under two names: 'itz-b' and 'itz-c'" in refused.stderr
    assert "This plan needs a last confirmation." not in refused.stderr
    nothing_started(sb, refused)
    result, _ = converse(sb, rel, [(Q1, "itz-c")])
    assert result.returncode == 1
    assert START not in result.stdout and "[MCM] The plan:" not in result.stdout
    nothing_started(sb, result)


def test_parallel_same_url_is_refused_before_the_last_confirmation(sb):
    rel = setup(sb, THREE)
    sb.write_cluster_marker("itz-c", url("itz-b"))
    result = run(sb, rel, "--parallel", "--switch-to-cluster", "itz-a,itz-c")
    assert result.returncode == 1
    assert "--parallel: these targets are one cluster under two names: 'itz-b' and 'itz-c'" in result.stderr
    assert "This plan needs a last confirmation." not in result.stderr
    nothing_started(sb, result)


def test_the_status_follows_even_when_every_pod_launch_failed(sb):
    """Q-a6: once answered, pods, then the local run, then the status, whatever each launch returned."""
    rel = setup(sb, {"itz-a": "local", "itz-b": "cluster"})
    (sb.fake / "no_storageclass").write_text("")
    result = run(sb, rel)
    assert result.returncode == 1, result.stdout + result.stderr
    assert table_row(result, "itz-b").startswith("FAILED")
    assert table_row(result, "itz-a").startswith("ok")
    assert timeline(sb) == ["local itz-a", "status"]


# --- C12 at a terminal: each question, cancel at each one, nothing before the last answer --------------------------
def test_terminal_switch_one_then_start(sb):
    rel = setup(sb, THREE)
    result, seen = converse(sb, rel, [(Q1, "2"), (START, "y")])
    assert result.returncode == 0, result.stdout + result.stderr
    assert seen == ["", ""], "nothing may start before the last answer"
    out = result.stdout
    assert "Which of them should run in the cluster instead, for this run only?" in out
    assert "[MCM]   1) itz-a" in out and "[MCM]   2) itz-c" in out
    # Q-a2: the permanent switch and where, per cluster.
    assert 'To switch a cluster for good, set INSTALL_RUN_MODE="cluster" in its cpd_vars.sh:' in out
    for name in ("itz-a", "itz-c"):
        assert f"[MCM]   {name}: {sb.repo}/configs/clusters/{name}/cp4d_config/cpd_vars.sh" in out
    assert Q3 not in out, "one local target left: no second question"
    assert out.index(START) < out.index("[MCM] 1/")
    assert timeline(sb) == ["pod itz-b", "pod itz-c", "local itz-a", "status"]


def test_terminal_pick_the_local_target_when_no_main_one(sb):
    rel = setup(sb, THREE, current="itz-b")
    result, seen = converse(sb, rel, [(Q1, "none"), (Q3, "itz-c"), (START, "yes")])
    assert result.returncode == 0, result.stdout + result.stderr
    assert seen == ["", "", ""]
    assert "Only one runs on this machine; the others are skipped in this run. Which one?" in result.stdout
    assert timeline(sb) == ["pod itz-b", "local itz-c", "status"]
    assert table_row(result, "itz-a").startswith("skipped (runs here, but only itz-c does in this run)")


def test_terminal_main_target_asks_no_second_question(sb):
    rel = setup(sb, THREE)
    result, _ = converse(sb, rel, [(Q1, ""), (Q1, "none"), (START, "y")])
    assert result.returncode == 0, result.stdout + result.stderr
    assert "No answer: type numbers or names, none, or cancel." in result.stderr
    assert Q3 not in result.stdout
    assert timeline(sb) == ["pod itz-b", "local itz-a", "status"]


@pytest.mark.parametrize("answers,current", [
    ([(Q1, "cancel")], "itz-a"),
    ([(Q1, "itz-z"), (Q1, "c")], "itz-a"),
    ([(Q1, "none"), (Q3, "cancel")], "itz-b"),
    ([(Q1, "none"), (Q3, "1"), (START, "n")], "itz-b"),
    ([(Q1, "itz-c"), (START, "")], "itz-a"),
], ids=["first", "first-after-a-typo", "second", "last", "last-empty"])
def test_terminal_cancel_at_each_question_runs_nothing(sb, answers, current):
    rel = setup(sb, THREE, current=current)
    result, seen = converse(sb, rel, answers)
    assert result.returncode == 1, result.stdout + result.stderr
    assert CANCELLED in result.stderr
    assert set(seen) == {""}
    nothing_started(sb, result)


def test_terminal_three_bad_answers_cancel(sb):
    rel = setup(sb, THREE)
    result, _ = converse(sb, rel, [(Q1, "9"), (Q1, "x"), (Q1, "itz-b")])
    assert result.returncode == 1
    assert "'9' is not one of: itz-a, itz-c (or 1-2)." in result.stderr
    assert CANCELLED in result.stderr
    nothing_started(sb, result)


def test_terminal_flags_skip_their_questions(sb):
    rel = setup(sb, THREE, current="itz-b")
    result, seen = converse(sb, rel, [(START, "y")], args=("--switch-to-cluster", "none", "--local-cluster", "itz-a"))
    assert result.returncode == 0, result.stdout + result.stderr
    assert seen == [""]
    assert Q1 not in result.stdout and Q3 not in result.stdout
    assert timeline(sb) == ["pod itz-b", "local itz-a", "status"]


def test_terminal_yes_skips_the_last_question(sb):
    rel = setup(sb, THREE)
    result, _ = converse(sb, rel, [(Q1, "none")], args=("--yes",))
    assert result.returncode == 0, result.stdout + result.stderr
    assert START not in result.stdout
    assert timeline(sb) == ["pod itz-b", "local itz-a", "status"]


def test_terminal_run_mode_skips_the_switch_question(sb):
    """--run-mode local sets every target's mode (Q-a4): nothing to switch, the one-local rule still applies."""
    rel = setup(sb, THREE)
    result, _ = converse(sb, rel, [(START, "y")], args=("--run-mode", "local"))
    assert result.returncode == 0, result.stdout + result.stderr
    assert Q1 not in result.stdout
    assert timeline(sb) == ["local itz-a"], "no pod, so no status table"
    for name in ("itz-b", "itz-c"):
        assert table_row(result, name).startswith("skipped")


# --- Q-a7: one cluster asks nothing new ----------------------------------------------------------------------------
def test_a_single_cluster_run_ignores_the_answers(sb):
    rel = setup(sb, THREE)
    result = run(sb, rel, "--target-cluster", "itz-c", "--local-cluster", "itz-a", "--yes")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "only answer the questions of a run on several clusters: ignored" in result.stderr
    assert "CHAIN-RAN-LOCALLY on=itz-c par= override= args=<>" in result.stdout
    assert "Where each one's install runs" not in result.stdout


def test_other_scripts_keep_their_own_yes(sb):
    clusters(sb)
    body = STAND_IN_CHAIN.replace('ir_dispatch "$@"\n', "").replace(
        "print -r -- CHAIN-RAN-LOCALLY", 'print -r -- "ARGS=<${(j:,:)@}>"')
    rel = chain(sb, rel="scripts/install_cloud_pak_for_data/x_other.sh", body=body)
    result = run(sb, rel, "--yes", "--local-cluster", "x")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "ARGS=<--yes,--local-cluster,x>" in result.stdout


PREREQ_CHAIN = ("scripts/install_cloud_pak_for_data/2_prepare_cluster/2.2_install_prerequisite_operators/"
                "2.2_install_prerequisite_operators.sh")


@pytest.mark.parametrize("mode", ["cluster", "local"])
def test_the_prerequisite_operators_chain_has_a_help(sb, mode):
    """2.2 has no step options, so no h_steps_plan: its own --help names the cluster and mode flags (Q-a7)."""
    clusters(sb, mode=mode)
    rel = chain(sb, rel=PREREQ_CHAIN, body=(REPO / PREREQ_CHAIN).read_text())
    result = run(sb, rel, "--help")
    assert result.returncode == 0, result.stdout + result.stderr
    for flag in ("--target-cluster NAME", "--run-mode local|cluster", "--switch-to-cluster a,b|none"):
        assert flag in result.stdout
    assert "[gpu]" not in result.stdout and "2.2.1_install" not in result.stdout, "no lane may run"
    assert oc_log(sb) == ""


def test_chain_help_names_the_cluster_and_mode_flags():
    text = (REPO / "src/helpers/common_helpers.sh").read_text()
    for flag in ("--target-cluster NAME", "--run-mode local|cluster", "--switch-to-cluster a,b|none", "--local-cluster NAME"):
        assert flag in text
    tool = subprocess.run(["zsh", str(REPO / "scripts/install_runner/x_install_runner.sh"), "--help"],
                          capture_output=True, text=True, timeout=30, check=False)
    assert tool.returncode == 0
    assert "--target-cluster NAME" in tool.stdout


# --- C10: the same-type lock, launch side (preflight) --------------------------------------------------------------
def modules_with_confluent(tmp_path):
    """A second install type next to the real modules -> the env that adds it (the test-only IR_MODULE_DIRS)."""
    extra = tmp_path / "more_installs"
    extra.mkdir()
    (extra / "confluent.conf").write_text(
        'INSTALL_ID="confluent"\nINSTALL_LABEL="Confluent Platform"\nINSTALL_ENV_TARGET="confluent"\n'
        'RUNNER_ENTRYPOINTS="scripts/install_confluent_platform/x_full.sh"\n')
    return {**PREFLIGHT_BASE, "IR_MODULE_DIRS": str(extra)}


def status_items(fake_dir, *items):
    rows = [{"metadata": {"name": "ir-status", "namespace": f"install-runner-{slot}"},
             "data": {"slot": slot, "state": state, "chain": chain_, "cluster": "-"}} for slot, state, chain_ in items]
    (fake_dir / "all_status.json").write_text(__import__("json").dumps({"items": rows}))


def test_another_install_type_on_the_cluster_is_allowed(fake, tmp_path):
    """The chain decides the type before the slot name does: cpd-x runs the Confluent chain."""
    env = modules_with_confluent(tmp_path)
    status_items(fake, ("confluent-cp", "running", "-"), ("cpd-x", "staged", "scripts/install_confluent_platform/x_full.sh"))
    result = zsh("ir_preflight cpd", fake, env)
    assert result.returncode == 0, result.stderr
    assert "Also running on this cluster, other install types (allowed): confluent-cp (confluent), cpd-x (confluent)." in result.stdout
    assert "already runs" not in result.stderr


def test_the_same_type_is_refused_by_its_chain_too(fake, tmp_path):
    env = modules_with_confluent(tmp_path)
    status_items(fake, ("odd-name", "interrupted", CPD_CHAIN), ("confluent-cp", "running", "-"))
    result = zsh("ir_preflight cpd", fake, env)
    assert result.returncode != 0
    assert f"{LABEL} already runs on this cluster." in result.stderr
    assert "in the cluster: slot odd-name (interrupted)." in result.stderr
    assert f"Watch it with: {WATCH} --install cpd --slot odd-name" in result.stderr
    assert "confluent-cp (confluent)" in result.stdout


def test_the_debug_bypass_lets_the_same_type_through(fake):
    status_items(fake, ("cpd-other", "running", "-"))
    result = zsh("ir_preflight cpd", fake, {**PREFLIGHT_BASE, "_IR_DEBUG_ALLOW_SAME_TYPE": "true"})
    assert result.returncode == 0, result.stderr
    assert "_IR_DEBUG_ALLOW_SAME_TYPE=true: launching cpd although another cpd install runs on this cluster." in result.stderr


def test_the_bypass_is_mentioned_only_in_code():
    """Q-a1: no user override; the hidden one is named nowhere a user reads, and the old switch is gone."""
    for rel in ("README.md", "src/helpers/config_file_jinja2_templates/cpd_variable_template.sh.j2"):
        assert "_IR_DEBUG_ALLOW_SAME_TYPE" not in (REPO / rel).read_text()
    for path in [REPO / "README.md", *(REPO / "src").rglob("*"), *(REPO / "scripts").rglob("*")]:
        if path.is_file() and path.suffix in ("", ".sh", ".j2", ".py", ".ipynb", ".conf", ".md"):
            assert "INSTALL_RUNNER_ALLOW_PARALLEL" not in path.read_text(errors="ignore"), path


def lease(box, cluster, script, pid=None):
    """A lease of a live run (this test process, unless pid is given) on cluster, started by script."""
    folder = box.home / "cpd-cli/clusters" / cluster / ".leases"
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / str(pid or os.getpid())
    path.write_text(f"{script}\n")
    return path


def test_a_local_run_of_the_same_type_on_the_same_url_refuses_a_launch(sb):
    """Another cluster name for the same URL is the same cluster; a lease is how a local run shows."""
    clusters(sb, names=("itz-a", "itz-b"))
    sb.write_cluster_marker("itz-b", url("itz-a"))
    chain(sb)
    path = lease(sb, "itz-b", f"/elsewhere/checkout/{CPD_CHAIN}")
    result = run(sb, CPD_CHAIN, "--target-cluster", "itz-a")
    assert result.returncode == 1, result.stdout + result.stderr
    assert f"{LABEL} already runs on this cluster." in result.stderr
    assert f"on this machine: full_swhub_x_cpd_installprocess.sh (PID {os.getpid()}, cluster itz-b)." in result.stderr
    assert f"its lease is stale: delete {path}" in result.stderr
    assert "finalize-stage.sh" not in oc_log(sb)


# 4194305 is above Linux's PID_MAX_LIMIT (2**22) and macOS's 99998: never a live process, on any host.
DEAD_PID = 4194305


@pytest.mark.parametrize("script,pid", [("scripts/install_confluent_platform/x_full.sh", None), (CPD_CHAIN, DEAD_PID)],
                         ids=["other-type", "dead-pid"])
def test_a_lease_of_another_type_or_a_dead_run_does_not_block(sb, script, pid):
    clusters(sb)
    chain(sb)
    (sb.fake / "state").write_text("completed\n")
    lease(sb, "itz-a", script, pid)
    result = run(sb, CPD_CHAIN, "--target-cluster", "itz-a")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "already runs" not in result.stderr


@pytest.mark.parametrize("script", ["./full_swhub_x_cpd_installprocess.sh", "full_swhub_x_cpd_installprocess.sh",
                                    "0_x_full_quick_install_script/full_swhub_x_cpd_installprocess.sh"])
def test_a_lease_written_before_absolute_paths_still_counts(sb, script):
    """Leases taken before this change hold the path as typed, relative to where the run started."""
    clusters(sb)
    chain(sb)
    lease(sb, "itz-a", script)
    result = run(sb, CPD_CHAIN, "--target-cluster", "itz-a")
    assert result.returncode == 1, result.stdout + result.stderr
    assert f"on this machine: full_swhub_x_cpd_installprocess.sh (PID {os.getpid()}, cluster itz-a)." in result.stderr


def test_a_relative_lease_of_an_unknown_script_does_not_block(sb):
    clusters(sb)
    chain(sb)
    (sb.fake / "state").write_text("completed\n")
    lease(sb, "itz-a", "./x_some_utility.sh")
    result = run(sb, CPD_CHAIN, "--target-cluster", "itz-a")
    assert result.returncode == 0, result.stdout + result.stderr


# --- C10: a launch on its way (its launch mark) ---------------------------------------------------------------------
def launch_mark(box, cluster="itz-a", slot="cpd-other", install="cpd", pid=None, mark_url=None):
    """A launch of this machine on its way (ir_lock_launch_mark), by a live PID (this test's) unless pid is given."""
    folder = box.home / "cpd-cli/.runner_launching"
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / str(pid or os.getpid())
    path.write_text(f"install={install}\nslot={slot}\ncluster={cluster}\nurl={mark_url or url(cluster)}\n")
    return path


def test_a_launch_on_its_way_refuses_a_second_launch(sb):
    """The first launch builds its image or starts its pod: no ir-status says staged yet, only its mark."""
    clusters(sb, names=("itz-a", "itz-b"))
    sb.write_cluster_marker("itz-b", url("itz-a"))
    chain(sb)
    launch_mark(sb, cluster="itz-b", mark_url=url("itz-a"))
    result = run(sb, CPD_CHAIN, "--target-cluster", "itz-a")
    assert result.returncode == 1, result.stdout + result.stderr
    assert f"{LABEL} already runs on this cluster." in result.stderr
    assert f"being launched from this machine: slot cpd-other (PID {os.getpid()}" in result.stderr
    assert f"Once it is staged, watch it with: {WATCH} --install cpd --slot cpd-other --target-cluster itz-b" in result.stderr
    assert "finalize-stage.sh" not in oc_log(sb)


@pytest.mark.parametrize("kwargs", [{"pid": DEAD_PID}, {"install": "confluent"},
                                    {"cluster": "itz-b", "mark_url": "https://api.elsewhere.example.com:6443"}],
                         ids=["dead-pid", "other-type", "other-cluster"])
def test_marks_that_do_not_block_a_launch(sb, kwargs):
    clusters(sb, names=("itz-a", "itz-b"))
    chain(sb)
    (sb.fake / "state").write_text("completed\n")
    launch_mark(sb, **kwargs)
    result = run(sb, CPD_CHAIN, "--target-cluster", "itz-a")
    assert result.returncode == 0, result.stdout + result.stderr


def test_a_launch_marks_itself_until_it_is_staged(sb):
    clusters(sb)
    chain(sb)
    folder = sb.home / "cpd-cli/.runner_launching"
    use_oc(sb.bin / "oc", oc_variant(
        ('*"finalize-stage.sh"*) echo "$args" > "$d/finalized" ;;',
         f'*"finalize-stage.sh"*) echo "$args" > "$d/finalized"; cat "{folder}"/* > "$d/marks" ;;')))
    result = run(sb, CPD_CHAIN, "--parallel")
    assert result.returncode == 76, result.stdout + result.stderr
    assert (sb.fake / "marks").read_text() == f"install=cpd\nslot={SLOT}\ncluster=itz-a\nurl={url('itz-a')}\n"
    assert list(folder.iterdir()) == [], "the mark goes once the run is staged"


def test_a_launch_on_its_way_refuses_a_local_run(sb):
    clusters(sb, mode="local")
    chain(sb)
    launch_mark(sb)
    result = run(sb, CPD_CHAIN)
    assert result.returncode == 1
    assert "being launched from this machine: slot cpd-other" in result.stderr
    assert "CHAIN-RAN-LOCALLY" not in result.stdout


# --- C10: the same-type lock, local side (ir_dispatch) -------------------------------------------------------------
def record(box, cluster, slot=SLOT, install="cpd", state="launched", record_url=None):
    folder = (box.home / "cpd-cli/clusters" / cluster / ".runner_slots") if cluster else (box.home / "cpd-cli/.runner_slots")
    folder.mkdir(parents=True, exist_ok=True)
    (folder / slot).write_text(f"url={record_url or url(cluster or 'itz-a')}\nrun=r1\ninstall={install}\n"
                               f"launched=2026-11-12T00:00:00Z\nstate={state}\n")


@pytest.mark.parametrize("state", ["staged", "running", "interrupted"])
def test_a_local_run_is_refused_while_a_launch_of_the_same_type_still_runs(sb, state):
    clusters(sb, mode="local")
    chain(sb)
    record(sb, "itz-a")
    (sb.fake / "status.state").write_text(state)
    result = run(sb, CPD_CHAIN)
    assert result.returncode == 1, result.stdout + result.stderr
    assert "CHAIN-RAN-LOCALLY" not in result.stdout
    assert f"{LABEL} already runs on this cluster ({url('itz-a')}). One install of each type per cluster: nothing was run." in result.stderr
    assert f"in the cluster: slot {SLOT} ({state}, launched from this machine)." in result.stderr
    assert f"Watch it with: {WATCH} --install cpd --slot {SLOT} --target-cluster itz-a" in result.stderr
    assert f"get configmap ir-status -n install-runner-{SLOT}" in oc_log(sb)


@pytest.mark.parametrize("state", ["completed", "failed", "idle", ""], ids=["completed", "failed", "idle", "no-status"])
@pytest.mark.parametrize("record_state", ["launched", "starting"])
def test_a_launch_that_has_ended_only_gets_a_note(sb, state, record_state):
    """Collect is manual: a record not collected yet must not block once its slot stopped running."""
    clusters(sb, mode="local")
    chain(sb)
    record(sb, "itz-a", state=record_state)
    if state:
        (sb.fake / "status.state").write_text(state)
    result = run(sb, CPD_CHAIN)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "CHAIN-RAN-LOCALLY" in result.stdout
    assert f"[INFO] Slot {SLOT} (install cpd), launched from this machine, is not running" in result.stdout
    assert f"x_install_runner.sh collect --install cpd --slot {SLOT} --target-cluster itz-a" in result.stdout
    assert "already runs" not in result.stderr


UNREACHABLE = ('"get configmap ir-status"*)',
               '"get configmap ir-status"*) echo "error: Unable to connect to the server" >&2; exit 1 ;;\n  "never"*)')
GONE = ('"get configmap ir-status"*)',
        '"get configmap ir-status"*) echo \'Error from server (NotFound): configmaps "ir-status" not found\' >&2; exit 1 ;;\n  "never"*)')


def test_a_slot_whose_state_cannot_be_read_refuses_and_says_how_to_clear_it(sb):
    clusters(sb, mode="local")
    chain(sb)
    record(sb, "itz-a")
    use_oc(sb.bin / "oc", oc_variant(UNREACHABLE))
    result = run(sb, CPD_CHAIN)
    assert result.returncode == 1
    assert "may still run on this cluster" in result.stderr and "already runs" not in result.stderr
    assert "Its state could not be read (error: Unable to connect to the server)." in result.stderr
    assert f"collect --install cpd --slot {SLOT} --target-cluster itz-a" in result.stderr
    assert f"teardown --install cpd --slot {SLOT} --target-cluster itz-a --discard, or --forget" in result.stderr
    assert oc_log(sb).count("get configmap ir-status") == 2, "one more try after a login"
    assert "CHAIN-RAN-LOCALLY" not in result.stdout


def test_a_slot_the_cluster_no_longer_has_does_not_block(sb):
    clusters(sb, mode="local")
    chain(sb)
    record(sb, "itz-a")
    use_oc(sb.bin / "oc", oc_variant(GONE))
    result = run(sb, CPD_CHAIN)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "no status: the slot is gone, or its pod never started" in result.stdout


@pytest.mark.parametrize("kwargs", [{"state": "collected"}, {"install": "confluent"},
                                    {"record_url": "https://api.elsewhere.example.com:6443"}],
                         ids=["collected", "other-type", "other-cluster"])
def test_records_that_do_not_block_a_local_run(sb, kwargs):
    clusters(sb, names=("itz-a", "itz-b"), mode="local")
    chain(sb)
    record(sb, "itz-b" if "record_url" in kwargs else "itz-a", **kwargs)
    result = run(sb, CPD_CHAIN, "--target-cluster", "itz-a")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "CHAIN-RAN-LOCALLY" in result.stdout


def test_a_local_run_is_refused_while_another_local_run_of_the_same_type_holds_a_lease(sb):
    clusters(sb, mode="local")
    chain(sb)
    lease(sb, "itz-a", str(sb.repo / CPD_CHAIN))
    result = run(sb, CPD_CHAIN)
    assert result.returncode == 1
    assert f"on this machine: full_swhub_x_cpd_installprocess.sh (PID {os.getpid()}, cluster itz-a)." in result.stderr
    assert "CHAIN-RAN-LOCALLY" not in result.stdout


def test_flat_records_block_a_flat_local_run(sb):
    sb.write_config("cpd", ocp_url="https://api.x:6443", extra={"INSTALL_RUN_MODE": "local"})
    chain(sb)
    record(sb, None, record_url="https://API.x:6443/")
    (sb.fake / "status.state").write_text("running")
    result = run(sb, CPD_CHAIN)
    assert result.returncode == 1
    assert f"in the cluster: slot {SLOT} (running, launched from this machine)." in result.stderr
    assert f"Watch it with: {WATCH} --install cpd --slot {SLOT}\n" in result.stderr + "\n"


@pytest.mark.parametrize("env,args", [({"_IR_DEBUG_ALLOW_SAME_TYPE": "true"}, ()), ({"_IR_LOCK_CHECKED": "itz-a:cpd"}, ()),
                                      ({}, ("--list-steps",))], ids=["bypass", "nested", "list-steps"])
def test_when_the_local_lock_stands_aside(sb, env, args):
    clusters(sb, mode="local")
    chain(sb, body=TRACE_CHAIN)
    record(sb, "itz-a")
    (sb.fake / "status.state").write_text("running")
    result = run(sb, CPD_CHAIN, *args, env=env)
    assert "already runs on this cluster" not in result.stderr
    if not args:
        assert result.returncode == 0, result.stdout + result.stderr
        assert "CHAIN-RAN-LOCALLY" in result.stdout


def test_a_local_run_marks_its_check_and_leaves_an_absolute_lease(sb):
    clusters(sb, mode="local")
    body = TRACE_CHAIN.replace('print -r -- "local', 'print -r -- "MARK=${_IR_LOCK_CHECKED:-}"\nprint -r -- "local')
    chain(sb, body=body)
    result = run(sb, CPD_CHAIN, env=None)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "MARK=itz-a:cpd" in result.stdout
    leases_dir = sb.home / "cpd-cli/clusters/itz-a/.leases"
    contents = [p.read_text().strip() for p in leases_dir.iterdir()]
    assert str((sb.repo / CPD_CHAIN).resolve()) in contents
