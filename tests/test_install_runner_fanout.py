"""In-cluster runner, fan-out under multi-cluster management (phase I4).

Plan: .claude/plans/multi-cluster-management/in-cluster-install-addon/in-cluster-install-addon-plan.md, decision
D3 (15.1: the default fan-out stays sequential, --parallel launches only), gaps X9 (attach signals), X10 (one
run per cluster before G8), X11 (a bounded watch) and X13 (bad arguments).

Everything runs against fakes: the runner tests' fake oc (FAKE_OC, with variants made here), the
tests/mcm_harness.py sandbox with its fake podman and cpd-cli, and a supervisor run outside the image with
stand-ins for setsid and script. Nothing reaches a cluster or the podman VM.
"""

import os
import signal
import subprocess
import textwrap
import time

import pytest
from test_install_runner import CPD_CHAIN, FAKE_OC, HELPERS, REPO, STAND_IN_CHAIN, assert_clean_load, fake, zsh  # noqa: F401
from test_install_runner_workstation import SLOT, chain, clusters, oc_log, run, sb, starts, url  # noqa: F401

WATCH = "scripts/install_runner/x_watch_install.sh"
STREAM = '*"follow.sh"*) echo "hello from the pod" ;;'
RESOLVE = '*"follow.sh"*"resolve"*) echo 0 ;;'
WHOAMI = '"whoami"*) echo tester ;;'
EXEC_ANY = '"exec"*) ;;'
# The fake oc knows nothing of namespaces: an empty answer would read as "torn down".
NAMESPACE = '"get pvc"*) exit 1 ;;\n  "get namespace"*) [ -e "$d/ns_gone" ] || echo namespace/x ;;'


def oc_variant(*pairs):
    text = FAKE_OC.replace('"get pvc"*) exit 1 ;;', NAMESPACE)
    for old, new in pairs:
        assert old in text, old
        text = text.replace(old, new)
    return text


def use_oc(where, text):
    path = where / "bin" / "oc" if (where / "bin").is_dir() else where
    path.write_text(text)
    path.chmod(0o755)


def wait_for(path, timeout=30):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if path.exists():
            return True
        time.sleep(0.1)
    return False


def table_row(result, name):
    return next((line.split(None, 2)[2] for line in result.stdout.splitlines()
                 if line.startswith("[MCM]   ") and line.split()[1:2] == [name]), None)


# --- helpers that run with a signal on the way -----------------------------------------------------------------
def unit_env(fake_dir, env=None):
    run_env = {k: v for k, v in os.environ.items() if not k.startswith(("IR_", "INSTALL_RUN"))}
    # HOME too: launch records and the multi-cluster helpers read ~/cpd-cli, never the real one.
    run_env.update({"_CP4D_REPO_ROOT": str(REPO), "OC_LOGIN": "true", "_CP4D_PREP_DONE": "1",
                    "PATH": f"{fake_dir}/bin:{run_env['PATH']}", "FAKE_DIR": str(fake_dir),
                    "TMPDIR": str(fake_dir / "tmp"), "IR_ATTACH_RETRY_SECONDS": "0", "HOME": str(fake_dir / "home")})
    (fake_dir / "tmp").mkdir(exist_ok=True)
    (fake_dir / "home").mkdir(exist_ok=True)
    run_env.update(env or {})
    return run_env


def signalled(argv, env, cwd, marker, sig):
    """Starts argv in its own session, waits for the marker file, then signals the whole group (as a terminal's
    Ctrl-C or hang-up does) and returns (rc, stdout, stderr)."""
    proc = subprocess.Popen(argv, env=env, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                            start_new_session=True)
    try:
        assert wait_for(marker), "the watch never started"
        time.sleep(0.3)
        os.killpg(proc.pid, sig)
        out, err = proc.communicate(timeout=60)
    finally:
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.communicate()
    return proc.returncode, out, err


def attach_signalled(fake_dir, sig, env=None):
    script = f'set -euo pipefail\nsource "{HELPERS}"\nir_attach slot\n'
    return signalled(["zsh", "-c", script], unit_env(fake_dir, env), None, fake_dir / "streaming", sig)


# --- 1. the default stays sequential ------------------------------------------------------------------------------
def test_default_fanout_attaches_each_cluster_in_turn(sb):
    clusters(sb, names=("itz-a", "itz-b"), targets="itz-a itz-b")
    (sb.fake / "state").write_text("completed\n")
    result = run(sb, chain(sb))
    assert result.returncode == 0, result.stdout + result.stderr
    assert_clean_load(result)
    assert "[MCM] Running full_swhub_x_cpd_installprocess.sh on 2 clusters, one at a time: itz-a itz-b" in result.stdout
    assert table_row(result, "itz-a").startswith("ok ") and table_row(result, "itz-b").startswith("ok ")
    assert result.stdout.count("hello from the pod") == 2, "each child watches its run"
    assert "launched" not in result.stdout
    assert "Installs left running" not in result.stdout
    assert oc_log(sb).count("finalize-stage.sh") == 2


def test_default_fanout_shows_warnings(sb):
    clusters(sb, names=("itz-a", "itz-b"), targets="itz-a itz-b")
    (sb.fake / "state").write_text("completed-with-warnings\n")
    result = run(sb, chain(sb))
    assert result.returncode == 0, result.stdout + result.stderr
    assert table_row(result, "itz-a").startswith("ok (warnings)")
    assert table_row(result, "itz-b").startswith("ok (warnings)")


def test_single_target_handoff_exit_codes(sb):
    clusters(sb)
    (sb.fake / "state").write_text("completed-with-warnings\n")
    assert run(sb, chain(sb)).returncode == 77
    # The control tool keeps 0 for a run with warnings, as before.
    tool = run(sb, "scripts/install_runner/x_install_runner.sh", "attach", "--install", "cpd")
    assert tool.returncode == 0, tool.stdout + tool.stderr


# --- 2. --parallel: launch only ------------------------------------------------------------------------------------
def test_parallel_fanout_launches_without_watching(sb):
    clusters(sb, names=("itz-a", "itz-b"), targets="itz-a itz-b")
    result = run(sb, chain(sb), "--parallel", "--from", "x")
    assert result.returncode == 0, result.stdout + result.stderr
    assert_clean_load(result)
    assert "[MCM] Launching full_swhub_x_cpd_installprocess.sh on 2 clusters, one at a time; each install then runs on" in result.stdout
    for name in ("itz-a", "itz-b"):
        assert table_row(result, name).startswith(f"launched (slot {SLOT})"), result.stdout
        assert f"[MCM]   {name}: {WATCH} --install cpd --target-cluster {name}" in result.stdout
    assert "Installs left running in their clusters" in result.stdout
    log = oc_log(sb)
    assert log.count("finalize-stage.sh") == 2
    assert "follow.sh" not in log, "a --parallel child must not attach"
    assert "CHAIN-RAN-LOCALLY" not in result.stdout
    run_env = (sb.fake / "run.env").read_text()
    assert "--parallel" not in run_env, "the chain must never see --parallel"
    assert "--from" in run_env


def test_parallel_single_target_launches_and_returns(sb):
    clusters(sb)
    result = run(sb, chain(sb), "--parallel")
    assert result.returncode == 76, result.stdout + result.stderr
    assert f"Watch it with: {WATCH} --install cpd --target-cluster itz-a" in result.stdout
    assert "follow.sh" not in oc_log(sb)
    assert "[MCM] Launching" not in result.stdout


def test_parallel_from_the_environment(sb):
    clusters(sb)
    result = run(sb, chain(sb), env={"IR_FANOUT_PARALLEL": "1"})
    assert result.returncode == 76, result.stdout + result.stderr
    assert "follow.sh" not in oc_log(sb)


FANOUT_STUB = textwrap.dedent("""\
    #!/bin/zsh
    set -euo pipefail
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    _b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
    code="CODE_${MCM_CLUSTER//-/_}"
    if [[ -n "${NOTE:-}" && -n "${_MCM_FANOUT_NOTE:-}" ]]; then
        print -r -- "slot-${MCM_CLUSTER}"$'\\t'"watch ${MCM_CLUSTER}" > "${_MCM_FANOUT_NOTE}"
    fi
    exit "${(P)code:-0}"
    """)


@pytest.mark.parametrize("note", [True, False])
def test_fanout_maps_handoff_codes_only_with_a_note(sb, note):
    """76/77/78 from a hand-off (which leaves a note) get their own labels; from another script they are failures."""
    names = ("itz-a", "itz-b", "itz-c")
    clusters(sb, names=names, targets=" ".join(names))
    rel = chain(sb, rel="scripts/install_cloud_pak_for_data/x_stub.sh", body=FANOUT_STUB)
    env = {"CODE_itz_a": "76", "CODE_itz_b": "77", "CODE_itz_c": "78", **({"NOTE": "1"} if note else {})}
    result = run(sb, rel, env=env)
    assert result.returncode == (78 if note else 76), result.stdout + result.stderr
    if note:
        assert table_row(result, "itz-a").startswith("launched (slot slot-itz-a)")
        assert table_row(result, "itz-b").startswith("ok (warnings)")
        assert table_row(result, "itz-c").startswith("watch lost (still running?)")
        assert "[MCM]   itz-a: watch itz-a" in result.stdout and "[MCM]   itz-c: watch itz-c" in result.stdout
    else:
        assert [table_row(result, n).split(" (")[0] for n in names] == ["FAILED"] * 3
        assert "rc 76" in table_row(result, "itz-a") and "rc 77" in table_row(result, "itz-b")
        assert "Installs left running" not in result.stdout


# --- 3. --parallel where nothing runs in the cluster: refused before any work ---------------------------------------
def test_parallel_with_a_local_config_fails_before_any_work(sb):
    clusters(sb, mode="local")
    result = run(sb, chain(sb), "--parallel")
    assert result.returncode == 1, result.stdout + result.stderr
    assert "--parallel only applies to installs that run in the cluster (INSTALL_RUN_MODE=cluster)" in result.stderr
    assert "Cluster 'itz-a' runs full_swhub_x_cpd_installprocess.sh on this machine (INSTALL_RUN_MODE=local)" in result.stderr
    assert "CHAIN-RAN-LOCALLY" not in result.stdout
    assert starts(sb) == [], "no container may start for a refused run"
    assert oc_log(sb) == ""


def test_parallel_flat_local_config_names_the_url(sb):
    sb.write_config("cpd", ocp_url="https://api.x:6443", extra={"INSTALL_RUN_MODE": "local"})
    result = run(sb, chain(sb), "--parallel")
    assert result.returncode == 1
    assert "https://api.x:6443 runs full_swhub_x_cpd_installprocess.sh on this machine" in result.stderr
    assert "CHAIN-RAN-LOCALLY" not in result.stdout


def test_parallel_fanout_with_a_local_cluster_launches_nothing(sb):
    """C12: a local target of a --parallel fan-out is asked about before any launch. Without a terminal that
    refuses the run, with nothing launched; --switch-to-cluster answers it (tests/test_install_runner_fanout_confirm.py)."""
    clusters(sb, names=("itz-a", "itz-b"), targets="itz-a itz-b")
    local = sb.repo / "configs/clusters/itz-b/cp4d_config/cpd_vars.sh"
    local.write_text(local.read_text().replace('INSTALL_RUN_MODE="cluster"', 'INSTALL_RUN_MODE="local"'))
    result = run(sb, chain(sb), "--parallel")
    assert result.returncode == 1, result.stdout + result.stderr
    assert "--parallel runs nothing on this machine, but 1 target(s) would run full_swhub_x_cpd_installprocess.sh here (itz-b)." in result.stderr
    assert "--switch-to-cluster a,b" in result.stderr
    assert "CHAIN-RAN-LOCALLY" not in result.stdout
    assert "finalize-stage.sh" not in oc_log(sb)
    switched = run(sb, chain(sb), "--parallel", "--switch-to-cluster", "itz-b")
    assert switched.returncode == 0, switched.stdout + switched.stderr
    assert "Result per cluster" in switched.stdout
    assert oc_log(sb).count("finalize-stage.sh") == 2
    assert "CHAIN-RAN-LOCALLY" not in switched.stdout


@pytest.mark.parametrize("args", [("--parallel", "--run-mode", "local"), ("--run-mode=local", "--parallel")])
def test_parallel_with_run_mode_local_stops_before_the_fanout(sb, args):
    clusters(sb, names=("itz-a", "itz-b"), targets="itz-a itz-b")
    result = run(sb, chain(sb), *args)
    assert result.returncode == 1
    assert result.stderr.count("not with --run-mode local") == 1
    assert "[MCM]" not in result.stdout and "CHAIN-RAN-LOCALLY" not in result.stdout


def test_parallel_on_a_script_that_never_runs_in_the_cluster(sb):
    clusters(sb, names=("itz-a", "itz-b"), targets="itz-a itz-b")
    rel = chain(sb, rel="scripts/install_cloud_pak_for_data/x_other.sh")
    result = run(sb, rel, "--parallel")
    assert result.returncode == 1
    assert result.stderr.count("x_other.sh is not one") == 1
    assert "[MCM]" not in result.stdout and "CHAIN-RAN-LOCALLY" not in result.stdout


def test_a_script_with_its_own_parallel_option_keeps_it(sb):
    """The scale-config table reads -j|--parallel N itself: env_bootstrap.sh must leave the flag alone."""
    body = STAND_IN_CHAIN.replace("ir_dispatch \"$@\"\n", "").replace(
        "print -r -- CHAIN-RAN-LOCALLY",
        'case "${1:-}" in -j|--parallel) print -r -- "OWN=$2" ;; esac\nprint -r -- "PAR=${IR_FANOUT_PARALLEL:-unset}"')
    sb.write_config("cpd", ocp_url="https://api.x:6443")
    rel = chain(sb, rel="src/utilities/cpd-cli_utils/x_table.sh", body=body)
    result = run(sb, rel, "--parallel", "4")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "OWN=4" in result.stdout and "PAR=unset" in result.stdout


# --- 4. one run per cluster before G8 (X10) ------------------------------------------------------------------------
def test_parallel_refuses_two_names_for_one_url(sb):
    clusters(sb, names=("itz-a", "itz-b"), targets="itz-a itz-b")
    sb.write_cluster_marker("itz-b", "https://API.itz-a.example.com:6443/")
    result = run(sb, chain(sb), "--parallel")
    assert result.returncode == 1, result.stdout + result.stderr
    assert "'itz-a' and 'itz-b' (api.itz-a.example.com:6443)" in result.stderr
    assert "Nothing was run" in result.stderr
    assert "[MCM] Launching" not in result.stdout
    assert oc_log(sb) == ""


def test_sequential_fanout_still_runs_two_names_for_one_url(sb):
    """Without --parallel the runs follow each other; the busy-slot and preflight checks guard the second."""
    clusters(sb, names=("itz-a", "itz-b"), targets="itz-a itz-b")
    sb.write_cluster_marker("itz-b", url("itz-a"))
    (sb.fake / "state").write_text("completed\n")
    result = run(sb, chain(sb))
    assert "these targets are one cluster" not in result.stderr
    assert "[MCM] Running" in result.stdout


def all_status(fake_dir, *slots, chain="-"):
    items = [{"metadata": {"name": "ir-status", "namespace": f"install-runner-{s}"},
              "data": {"slot": s, "state": "running", "chain": chain}} for s in slots]
    (fake_dir / "all_status.json").write_text(__import__("json").dumps({"items": items}))


PREFLIGHT_BASE = {"STG_CLASS_BLOCK": "blk", "STG_CLASS_FILE": "fil", "CONFIG_DIR": "/nonexistent"}


def test_preflight_refuses_another_live_run_of_the_same_install(fake):
    """C10: a second cpd on one cluster is refused, whatever its instance; the message names the slot, its
    install and how to watch it. There is no user override (Q-a1): the old switch no longer does anything."""
    all_status(fake, "cpd-other")
    refused = zsh("ir_preflight cpd", fake, {**PREFLIGHT_BASE, "MCM_CLUSTER": "itz-a",
                                             "INSTALL_RUNNER_ALLOW_PARALLEL": "true"})
    assert refused.returncode != 0
    assert "IBM Software Hub / Cloud Pak for Data (install cpd) already runs on this cluster." in refused.stderr
    assert "in the cluster: slot cpd-other (running)." in refused.stderr
    assert f"Watch it with: {WATCH} --install cpd --slot cpd-other --target-cluster itz-a" in refused.stderr
    assert "Preflight failed: nothing was changed." in refused.stderr
    assert "ALLOW_PARALLEL" not in refused.stderr + refused.stdout


def test_preflight_ignores_its_own_slot(fake):
    all_status(fake, "cpd-op1")
    base = {"STG_CLASS_BLOCK": "blk", "STG_CLASS_FILE": "fil", "CONFIG_DIR": "/nonexistent",
            "PROJECT_CPD_INST_OPERANDS": "op1"}
    result = zsh("ir_preflight cpd", fake, base)
    assert result.returncode == 0, result.stderr
    assert "Also running" not in result.stderr


# --- 5. attach signals (X9) ----------------------------------------------------------------------------------------
BLOCKING_STREAM = (STREAM, '*"follow.sh"*) echo "hello from the pod"; touch "$d/streaming"; sleep 30 ;;')


@pytest.mark.parametrize("sig", [signal.SIGINT, signal.SIGHUP])
def test_attach_detaches_on_ctrl_c_and_hang_up(fake, sig):
    use_oc(fake, oc_variant(BLOCKING_STREAM))
    rc, out, err = attach_signalled(fake, sig)
    assert rc == 76, out + err
    assert "Detached. The install keeps running in slot slot." in out
    assert "no run to watch" not in err
    assert list((fake / "tmp").iterdir()) == [], "the offset file was left behind"


def test_ctrl_c_during_the_resolve_is_a_detach(fake):
    use_oc(fake, oc_variant((RESOLVE, '*"follow.sh"*"resolve"*) touch "$d/streaming"; sleep 30; echo 0 ;;')))
    rc, out, err = attach_signalled(fake, signal.SIGINT)
    assert rc == 76, out + err
    assert "no run to watch" not in err
    assert list((fake / "tmp").iterdir()) == []


@pytest.mark.parametrize("sig", [signal.SIGINT, signal.SIGHUP])
def test_detach_in_a_sequential_fanout_stops_the_rest(sb, sig):
    clusters(sb, names=("itz-a", "itz-b"), targets="itz-a itz-b")
    use_oc(sb.bin / "oc", oc_variant(BLOCKING_STREAM))
    rel = chain(sb)
    env = sb.env({"FAKE_DIR": sb.fake})
    rc, out, err = signalled(["zsh", str(sb.repo / rel)], env, sb.repo, sb.fake / "streaming", sig)

    class Result:
        stdout = out
    assert rc == 130, out + err
    assert table_row(Result, "itz-a").startswith("detached (still running)"), out
    assert table_row(Result, "itz-b").startswith("not run"), out
    assert "Ctrl-C detached from a running install; the clusters after it were not launched (not run)." in out
    assert f"[MCM]   itz-a: {WATCH} --install cpd --target-cluster itz-a" in out
    assert oc_log(sb).count("finalize-stage.sh") == 1, "itz-b must not be launched"


# --- 6. a bounded watch (X11) --------------------------------------------------------------------------------------
UNREACHABLE = [(RESOLVE, '*"follow.sh"*"resolve"*) exit 1 ;;'), (EXEC_ANY, '"exec"*) exit 1 ;;')]


def test_watch_ends_lost_after_the_limit(fake):
    use_oc(fake, oc_variant(*UNREACHABLE))
    result = zsh("ir_attach slot", fake, unit_env(fake, {"INSTALL_RUNNER_ATTACH_LOST_MAX": "0", "MCM_CLUSTER": "itz-b"}))
    assert result.returncode == 78, result.stdout + result.stderr
    assert "No word from slot slot" in result.stderr
    assert f"{WATCH} --slot slot --target-cluster itz-b" in result.stderr


def test_watch_keeps_retrying_within_the_limit(fake):
    """Pod unreachable for a while, then back: the watch carries on to the end of the run."""
    use_oc(fake, oc_variant((RESOLVE, '*"follow.sh"*"resolve"*) n=$(cat "$d/n" 2>/dev/null || echo 0); echo $((n+1)) > "$d/n"; [ "$n" -ge 2 ] || exit 1; echo 0 ;;'),
                            (EXEC_ANY, '"exec"*) exit 1 ;;')))
    (fake / "state").write_text("completed\n")
    result = zsh("ir_attach slot", fake, unit_env(fake))
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stderr.count("Runner pod not reachable; retrying...") == 1
    assert "Run finished: completed" in result.stdout


LOGGED_OUT = 'echo "error: You must be logged in to the server (Unauthorized)" >&2; exit 1;'
NO_API = 'echo "Unable to connect to the server: dial tcp 10.0.0.1:6443: connect: connection refused" >&2; exit 1;'


def test_expired_login_is_tried_once_then_ends_the_watch(fake):
    use_oc(fake, oc_variant(*UNREACHABLE, (WHOAMI, f'"whoami"*) {LOGGED_OUT} ;;')))
    env = unit_env(fake, {"OC_LOGIN_FORCE": 'echo relogin >> "$FAKE_DIR/relogins"', "OCP_URL": "https://api.b:6443",
                          "MCM_CLUSTER": "itz-b"})
    result = zsh("ir_attach slot", fake, env)
    assert result.returncode == 78, result.stdout + result.stderr
    assert (fake / "relogins").read_text().count("relogin") == 1
    assert "The login to https://api.b:6443 (cluster itz-b) has expired" in result.stderr
    assert f"{WATCH} --slot slot --target-cluster itz-b" in result.stderr


def test_a_fresh_login_lets_the_watch_go_on(fake):
    gate = '[ -e "$d/logged_out" ] && exit 1;'
    use_oc(fake, oc_variant((RESOLVE, f'*"follow.sh"*"resolve"*) {gate} echo 0 ;;'),
                            (EXEC_ANY, f'"exec"*) {gate} ;;'),
                            (WHOAMI, f'"whoami"*) [ -e "$d/logged_out" ] && {{ {LOGGED_OUT} }}; echo tester ;;')))
    (fake / "logged_out").touch()
    (fake / "state").write_text("completed\n")
    result = zsh("ir_attach slot", fake, unit_env(fake, {"OC_LOGIN_FORCE": 'rm -f "$FAKE_DIR/logged_out"'}))
    assert result.returncode == 0, result.stdout + result.stderr
    assert "Logged in again." in result.stdout
    assert "Run finished: completed" in result.stdout


def test_an_unreachable_api_is_no_expired_login(fake):
    """A network drop fails whoami too, but not with an auth error: no relogin, no 78, the watch waits it out."""
    gate = 'n=$(cat "$d/n" 2>/dev/null || echo 0);'
    use_oc(fake, oc_variant(
        (RESOLVE, f'*"follow.sh"*"resolve"*) {gate} echo $((n+1)) > "$d/n"; [ "$n" -ge 3 ] || {{ {NO_API} }}; echo 0 ;;'),
        (EXEC_ANY, f'"exec"*) {NO_API} ;;'),
        (WHOAMI, f'"whoami"*) {gate} [ "$n" -ge 3 ] || {{ {NO_API} }}; echo tester ;;')))
    (fake / "state").write_text("completed\n")
    env = unit_env(fake, {"OC_LOGIN_FORCE": 'echo relogin >> "$FAKE_DIR/relogins"'})
    result = zsh("ir_attach slot", fake, env)
    assert result.returncode == 0, result.stdout + result.stderr
    assert not (fake / "relogins").exists()
    assert result.stderr.count("API not reachable; retrying...") == 1
    assert "has expired" not in result.stderr and "no longer works" not in result.stderr
    assert "Run finished: completed" in result.stdout


@pytest.mark.parametrize("where", ["resolve", "stream"])
def test_a_torn_down_slot_ends_the_watch(fake, where):
    """The namespace is gone (teardown from another terminal): exit 1, not an endless reconnect."""
    pairs = UNREACHABLE if where == "resolve" else [(STREAM, '*"follow.sh"*) ;;')]
    use_oc(fake, oc_variant(*pairs))
    (fake / "ns_gone").touch()
    result = zsh("ir_attach slot", fake, unit_env(fake))
    assert result.returncode == 1, result.stdout + result.stderr
    assert "Slot slot was torn down: its namespace install-runner-slot is gone." in result.stderr


def test_a_bad_lost_limit_warns_and_uses_the_default(fake):
    (fake / "state").write_text("completed\n")
    result = zsh("ir_attach slot", fake, unit_env(fake, {"INSTALL_RUNNER_ATTACH_LOST_MAX": "soon"}))
    assert result.returncode == 0
    assert "INSTALL_RUNNER_ATTACH_LOST_MAX must be a number of minutes (got 'soon'); using 30." in result.stderr


# --- 7. bad arguments (X13) ----------------------------------------------------------------------------------------
STRICT_CHAIN = STAND_IN_CHAIN.replace('ir_dispatch "$@"\n', 'ir_dispatch "$@"\nh_steps_parse --strict "$@"\n')


@pytest.mark.parametrize("args,text", [(("--form", "cpd"), "Unknown option: cpd"), (("--from",), "needs a step name")])
def test_bad_options_stop_before_anything_is_launched(sb, args, text):
    clusters(sb)
    result = run(sb, chain(sb, body=STRICT_CHAIN), *args)
    assert result.returncode == 2, result.stdout + result.stderr
    assert text in result.stderr
    assert "Nothing was launched: fix the arguments of full_swhub_x_cpd_installprocess.sh" in result.stderr
    assert oc_log(sb) == ""


def test_good_options_and_step_picks_pass_the_precheck(sb):
    clusters(sb)
    (sb.fake / "state").write_text("completed\n")
    result = run(sb, chain(sb, body=STRICT_CHAIN), "--from", "x", "--some-step")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "finalize-stage.sh" in oc_log(sb)


def test_rejected_frees_the_slot(fake):
    (fake / "status.state").write_text("rejected")
    (fake / "status.collected").write_text("no")
    assert zsh("ir_refuse_busy_slot ns slot", fake).returncode == 0


def test_attach_to_a_rejected_run_ends_with_its_reason(fake):
    (fake / "state").write_text("rejected\n")
    result = zsh("ir_attach slot", fake, unit_env(fake))
    assert result.returncode == 1
    assert "Run rejected in slot slot: the chain stopped before its first step" in result.stderr


def test_a_rejected_run_is_not_resumed(fake):
    (fake / "state").write_text("rejected\n")
    result = zsh("ir_resume slot", fake)
    assert result.returncode != 0
    assert "was rejected before its first step: nothing to resume" in result.stderr
    assert "control.resume" not in (fake / "oc.log").read_text()


def test_status_explains_a_rejected_run(fake):
    (fake / "all_status.json").write_text(
        '{"items":[{"metadata":{"name":"ir-status","namespace":"install-runner-s"},'
        '"data":{"slot":"s","state":"rejected","heartbeat":"1","attempts":"1","collected":"no"}}]}')
    result = zsh("ir_status", fake)
    assert result.returncode == 0, result.stderr
    assert "rejected" in result.stdout
    assert "s: the last run stopped before its first step" in result.stderr


# --- the supervisor records "rejected" ---------------------------------------------------------------------------
SETSID = "#!/bin/sh\nexec \"$@\"\n"
SCRIPT = textwrap.dedent("""\
    #!/bin/bash
    # Stand-in for util-linux script(1): -q -f -e --append --log-out FILE -c CMD
    log="" cmd=""
    while [ $# -gt 0 ]; do case "$1" in --log-out) log="$2"; shift 2 ;; -c) cmd="$2"; shift 2 ;; *) shift ;; esac; done
    sh -c "$cmd" >> "$log" 2>&1
    """)
SUP_OC = textwrap.dedent("""\
    #!/bin/bash
    echo "oc $*" >> "$FAKE_DIR/oc.log"
    case "$*" in create\\ configmap*) printf 'kind: ConfigMap\\n# %s\\n' "$*" ;; label*) cat ;; apply*) cat >/dev/null ;; esac
    exit 0
    """)


# The pod's view of the helpers: run-attempt.sh sets IR_IN_RUNNER, so ir_dispatch only marks and returns.
POD_CHAIN = f'source "{REPO}/src/helpers/common_helpers.sh"\nir_dispatch "$@"\n'
STEPS = 'h_step a true "a" true\nh_steps_plan\n'


@pytest.mark.parametrize("chain_body,expected,rc", [
    ("echo bad option; exit 3", "rejected", 3),
    ('printf "t\\tbegin\\tchain.sh#a\\t\\n" >> "$IR_JOURNAL_FILE"; exit 3', "failed", 3),
    # Arguments passed, then a failure before any journal entry: real work may have happened.
    (': > "$IR_RUN_DIR/args-ok"; exit 3', "failed", 3),
    # A 2.2-style chain (no h_steps_plan, lanes run directly): ir_dispatch marks it.
    (POD_CHAIN + "exit 3", "failed", 3),
    # A step chain with a bad option dies in h_steps_parse, before h_steps_plan marks it.
    (POD_CHAIN + 'h_steps_parse --strict "$@"\n' + STEPS + "exit 3", "rejected", 1),
    # The same chain with good options (h_steps_plan passed) failing before its first step.
    (POD_CHAIN + "h_steps_parse --strict\n" + STEPS + "exit 3", "failed", 3),
])
def test_supervisor_marks_a_run_that_never_reached_a_step_rejected(tmp_path, chain_body, expected, rc):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name, text in (("setsid", SETSID), ("script", SCRIPT), ("oc", SUP_OC)):
        (bin_dir / name).write_text(text)
        (bin_dir / name).chmod(0o755)
    work = tmp_path / "work"
    run_dir = work / "runs/r1"
    (work / "snapshots/r1").mkdir(parents=True)
    run_dir.mkdir(parents=True)
    (run_dir / "run.env").write_text("IR_RUN_ID=r1\nIR_CHAIN=chain.sh\nIR_ARGS=(--form cpd)\n")
    (work / "snapshots/r1/chain.sh").write_text(f"#!/bin/zsh\n{chain_body}\n")
    (work / "current").symlink_to(run_dir)
    (run_dir / "state").write_text("staged\n")
    env = {**{k: v for k, v in os.environ.items() if not k.startswith("IR_")},
           "PATH": f"{bin_dir}:{os.environ['PATH']}", "FAKE_DIR": str(tmp_path), "IR_WORK": str(work),
           "HOME": str(tmp_path / "home"),
           "IR_BIN": str(REPO / "src/install_runner/image/bin"), "IR_POLL": "0.2", "IR_HEARTBEAT": "1",
           "IR_SLOT": "t", "IR_NAMESPACE": "ns", "IR_ADMIN_BINDING": "b"}
    sup = subprocess.Popen(["zsh", str(REPO / "src/install_runner/image/bin/supervisor.sh")], env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        end = time.monotonic() + 30
        while time.monotonic() < end and (run_dir / "state").read_text().strip() in ("staged", "running"):
            time.sleep(0.2)
    finally:
        sup.terminate()
        log, _ = sup.communicate(timeout=30)
    assert (run_dir / "state").read_text().strip() == expected, log
    assert f"Run r1: {expected} (exit {rc})" in log
    assert f"from-literal=state={expected}" in (tmp_path / "oc.log").read_text()
    assert "delete clusterrolebinding b" in (tmp_path / "oc.log").read_text()
