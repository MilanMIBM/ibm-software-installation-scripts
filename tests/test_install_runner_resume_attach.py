"""In-cluster runner: the watch that follows `x_install_runner.sh resume` (live finding L-02).

On a live cluster the attach right after a resume printed one "Connection lost ... reconnecting" and then went
on with no duplicates. The cause: ir_resume only drops control.resume in the run folder and returns, and the
supervisor picks it up on its next poll. Until then the run's state is still the old failed or stopped, so
follow.sh, which ends once the run stops moving, ended at once; by the time the attach read the state, the
new attempt was running, which reads as a lost connection. ir_resume now waits for the hand-over.

The first test runs the real supervisor and the real follow.sh outside the image, with a bridge for oc that
runs each `oc exec` locally against the temp /work folder. The others use the runner tests' fake oc.
Nothing reaches a cluster, podman or cpd-cli.
"""

import os
import signal
import subprocess
import time

import pytest
from test_install_runner import FAKE_OC, HELPERS, REPO, fake, zsh  # noqa: F401
from test_install_runner_fanout import oc_variant, signalled, unit_env, use_oc
from test_install_runner_pod_internals import BIN, Supervisor, put, wait_for
from test_install_runner_workstation import clusters, oc_log, sb  # noqa: F401

RUNNER_TOOL = "scripts/install_runner/x_install_runner.sh"

LOST = "Connection lost"

# oc as the workstation calls it, with the pod being local folders: `oc exec ... -- <command>` runs the command
# here, with /work and the image's bin folder mapped to the test's copies.
BRIDGE_OC = r"""#!/bin/bash
echo "oc $*" >> "$WS_DIR/oc.log"
case "$1" in
  whoami) echo tester; exit 0 ;;
  get) [ "$2" = namespace ] && echo namespace/x; exit 0 ;;
  apply) cat > /dev/null; exit 0 ;;
  exec) ;;
  *) exit 0 ;;
esac
while [ "$1" != "--" ]; do shift; done
shift
args=()
for a in "$@"; do
  a="${a//\/opt\/install-runner\/bin/$POD_BIN}"
  args+=("${a//\/work\//$POD_WORK/}")
done
PATH="$POD_PATH" IR_WORK="$POD_WORK" exec "${args[@]}"
"""
# follow.sh sizes the log with GNU stat; macOS has BSD stat.
STAT_SHIM = '#!/bin/bash\nif [ "$1" = -c ]; then wc -c < "$3"; else exec /usr/bin/stat "$@"; fi\n'
# The resumed attempt: some output, a few seconds of work (longer than follow.sh's own 2 s wind-down), done.
SLOW_ATTEMPT = r"""#!/bin/bash
echo "attempt two output"
sleep 4
echo "attempt two done"
exit 0
"""


def test_resume_then_attach_shows_no_reconnect(tmp_path):
    sup = Supervisor(tmp_path)
    put(sup.bin, "run-attempt.sh", SLOW_ATTEMPT, mode=0o755)
    # The run as a failed attempt leaves it.
    (sup.run / "state").write_text("failed\n")
    (sup.run / "attempts").write_text("1\n")
    (sup.run / "attempts.log").write_text("1\tfailed\t7\t2026-11-11T00:00:00Z\n")
    (sup.run / "terminal.log").write_text("old output\n[runner] Run r1: failed (exit 7)\n")
    (sup.run / "args-ok").touch()
    ws = tmp_path / "ws"
    put(ws, "bin/oc", BRIDGE_OC, mode=0o755)
    put(tmp_path, "podpath/stat", STAT_SHIM, mode=0o755)
    # A slow supervisor poll, so the old state is still there when the watch starts (as on a live cluster).
    env = sup.env({"IR_POLL": "1"})
    sup.log = open(tmp_path / "supervisor.log", "w")
    sup.proc = subprocess.Popen(["zsh", str(REPO / "src/install_runner/image/bin/supervisor.sh")], env=env,
                                stdout=sup.log, stderr=subprocess.STDOUT)
    try:
        wait_for(lambda: "ready" in (tmp_path / "supervisor.log").read_text())
        run_env = {k: v for k, v in os.environ.items() if not k.startswith(("IR_", "INSTALL_RUN"))}
        run_env.update({"_CP4D_REPO_ROOT": str(REPO), "OC_LOGIN": "true", "_CP4D_PREP_DONE": "1",
                        "PATH": f"{ws}/bin:{run_env['PATH']}", "WS_DIR": str(ws), "HOME": str(ws),
                        "POD_WORK": str(sup.work), "POD_BIN": str(BIN),
                        "POD_PATH": f"{tmp_path}/podpath:/usr/bin:/bin:/usr/sbin:/sbin",
                        "TMPDIR": str(tmp_path), "IR_ATTACH_RETRY_SECONDS": "0"})
        script = f'set -euo pipefail\nsource "{HELPERS}"\nir_resume slot\nir_attach slot\n'
        result = subprocess.run(["zsh", "-c", script], capture_output=True, text=True, env=run_env, timeout=120,
                                check=False)
    finally:
        sup.stop()
    assert result.returncode == 0, result.stdout + result.stderr
    assert LOST not in result.stderr, result.stderr
    assert "not reachable" not in result.stderr
    assert result.stdout.count("attempt two output") == 1, result.stdout
    assert result.stdout.count("attempt two done") == 1, result.stdout
    assert "Run finished: completed" in result.stdout
    assert (sup.run / "attempts.log").read_text().splitlines()[-1].split("\t")[:3] == ["1", "completed", "0"]


# --- the same with the fake oc -----------------------------------------------------------------------------------
# The resume hand-over as the fake pod answers ir_resume's check ("<pending|taken> <state> <lines in attempts.log>"):
# one check before the request is written, then control.resume is there until the supervisor's poll, after which
# the state reads running.
HANDOVER = (
    '*"control.resume"*) cat > "$d/resume" ;;',
    '*"ir-resume-check"*)\n'
    '      n=$(cat "$d/polls" 2>/dev/null || echo 0); echo $((n+1)) > "$d/polls"\n'
    '      if [ "$n" -lt 2 ]; then echo "pending failed 1"; else echo "taken running 1"; fi ;;\n'
    '  *"control.resume"*) cat > "$d/resume" ;;')
# A stream that drops once mid-run: part one, then (reconnected at its offset) part two and the end of the run.
DROPPING_STREAM = (
    '*"follow.sh"*) echo "hello from the pod" ;;',
    '*"follow.sh"*"offset:0"*) echo "part one"; echo running > "$d/state" ;;\n'
    '  *"follow.sh"*"offset:9"*) echo "part two"; echo completed > "$d/state" ;;\n'
    '  *"follow.sh"*) echo "follow.sh called at an unexpected offset: $args" ;;')


def test_resume_waits_for_the_supervisor_to_take_it(fake):
    use_oc(fake, oc_variant(HANDOVER))
    (fake / "state").write_text("failed\n")
    result = zsh("ir_resume slot", fake, unit_env(fake, {"IR_RESUME_POLL_SECONDS": "0"}))
    assert result.returncode == 0, result.stdout + result.stderr
    assert (fake / "polls").read_text().strip() == "3", "one check before the request, then polls until it is taken"
    assert "Resuming slot slot." in result.stdout
    assert "not picked up" not in result.stderr


def test_resume_that_is_not_taken_in_time_warns_and_watches_anyway(fake):
    use_oc(fake, oc_variant(HANDOVER))
    (fake / "polls").write_text("-1000\n")
    (fake / "state").write_text("failed\n")
    result = zsh("ir_resume slot", fake, unit_env(fake, {"IR_RESUME_POLL_SECONDS": "0", "IR_RESUME_WAIT_SECONDS": "0"}))
    assert result.returncode == 0, result.stdout + result.stderr
    assert "The runner has not picked up the resume yet" in result.stderr


def test_a_real_loss_after_resume_still_reports_and_reconnects_without_duplicates(fake):
    use_oc(fake, oc_variant(HANDOVER, DROPPING_STREAM))
    (fake / "state").write_text("failed\n")
    script = "ir_resume slot\nir_attach slot --from-start\n"
    result = zsh(script, fake, unit_env(fake, {"IR_RESUME_POLL_SECONDS": "0"}))
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stderr.count(f"[attach] {LOST} (run state: running); reconnecting...") == 1, result.stderr
    assert result.stdout.count("part one") == 1 and result.stdout.count("part two") == 1, result.stdout
    assert "unexpected offset" not in result.stdout
    assert "Run finished: completed" in result.stdout


# --- review follow-ups: a resume the runner is slow to take --------------------------------------------------------
def handover(pending, taken, on_take=""):
    """The fake pod's answer to ir_resume's check: "pending failed 1" for the first <pending> checks, then
    <taken> (after running <on_take>, e.g. the state the supervisor's new attempt writes)."""
    return ('*"control.resume"*) cat > "$d/resume" ;;',
            '*"ir-resume-check"*)\n'
            '      n=$(cat "$d/polls" 2>/dev/null || echo 0); echo $((n+1)) > "$d/polls"\n'
            f'      if [ "$n" -lt {pending} ]; then echo "pending failed 1"; else {on_take} echo "{taken}"; fi ;;\n'
            '  *"control.resume"*) cat > "$d/resume" ;;')


def test_a_slow_pick_up_says_it_is_waiting_once(fake):
    use_oc(fake, oc_variant(handover(6, "taken running 1")))
    (fake / "state").write_text("failed\n")
    result = zsh("ir_resume slot", fake, unit_env(fake, {"IR_RESUME_POLL_SECONDS": "0"}))
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout.count("Waiting for the runner to take the resume...") == 1, result.stdout


def test_a_resume_still_pending_after_the_wait_is_waited_for_not_reported(fake):
    """F1: the wait hands over to the watch after IR_RESUME_WAIT_SECONDS; the watch then reads the old failed
    state while control.resume is still there. With --resumed that is no failure: it waits for the take."""
    use_oc(fake, oc_variant(handover(4, "taken completed 2", 'echo completed > "$d/state";')))
    (fake / "state").write_text("failed\n")
    env = unit_env(fake, {"IR_RESUME_POLL_SECONDS": "0", "IR_RESUME_WAIT_SECONDS": "0"})
    result = zsh("ir_resume slot\nir_attach slot --resumed\n", fake, env)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "The runner has not picked up the resume yet" in result.stderr
    assert result.stderr.count("[attach] Waiting for the runner to take the resume (run state: failed)...") == 1, \
        result.stderr
    assert "Run failed" not in result.stderr and LOST not in result.stderr, result.stderr
    assert "Run finished: completed" in result.stdout


def test_without_resumed_the_watch_reports_the_state_it_reads(fake):
    use_oc(fake, oc_variant(handover(1000, "taken running 1")))
    (fake / "state").write_text("failed\n")
    result = zsh("ir_attach slot", fake, unit_env(fake))
    assert result.returncode == 1
    assert "Run failed in slot slot" in result.stderr
    assert not (fake / "polls").exists(), "a plain watch does not look for a pending resume"


@pytest.mark.parametrize("sig", [signal.SIGINT, signal.SIGHUP])
def test_ctrl_c_while_waiting_for_the_pick_up_detaches(sb, sig):  # noqa: F811
    """F2: the resume is already sent, so a Ctrl-C (or a closed terminal) in the wait detaches with 0."""
    clusters(sb)
    pending = ('*"control.resume"*) cat > "$d/resume" ;;',
               '*"ir-resume-check"*) touch "$d/streaming"; echo "pending failed 1" ;;\n'
               '  *"control.resume"*) cat > "$d/resume" ;;')
    use_oc(sb.bin / "oc", oc_variant(pending))
    (sb.fake / "state").write_text("failed\n")
    env = sb.env({"FAKE_DIR": sb.fake, "IR_RESUME_POLL_SECONDS": "1"})
    rc, out, err = signalled(["zsh", str(sb.repo / RUNNER_TOOL), "resume", "--install", "cpd"], env, sb.repo,
                             sb.fake / "streaming", sig)
    assert rc == 0, out + err
    assert "Resuming slot" in out
    assert "Detached. The resume is sent: the install goes on in slot" in out, out
    assert "follow.sh" not in oc_log(sb), "no watch after a detach"


# --- C1: a Ctrl-C at any point of a resume is answered ------------------------------------------------------------
def resume_with_slow(sb, slow, binding_there=False):  # noqa: F811
    """`x_install_runner.sh resume` with one fake oc call that marks itself and takes 3 s: the first state read,
    the grant (apply), the check before the request (ir-resume-check), or the request itself (control.resume).
    SIGINT lands in it. <binding_there>: the slot's cluster-admin binding exists before the resume."""
    clusters(sb)
    if binding_there:
        (sb.fake / "binding_there").touch()
    pairs = {
        "state": [('*"cat /work/current/state"*) cat "$d/state" 2>/dev/null ;;',
                   '*"cat /work/current/state"*) touch "$d/streaming"; sleep 3; cat "$d/state" 2>/dev/null ;;')],
        "grant": [('"apply -f -"*) apply ;;', '"apply -f -"*) touch "$d/streaming"; sleep 3; apply ;;')],
        "check": [('*"control.resume"*) cat > "$d/resume" ;;',
                   ('*"ir-resume-check"*) touch "$d/streaming"; sleep 3; echo "pending failed 1" ;;\n'
                    '  *"control.resume"*) cat > "$d/resume" ;;'))],
        "write": [('*"control.resume"*) cat > "$d/resume" ;;',
                   ('*"ir-resume-check"*) [ -e "$d/sent" ] && echo "pending failed 1" || echo "taken failed 1" ;;\n'
                    '  *"control.resume"*) touch "$d/sent" "$d/streaming"; sleep 3; cat > "$d/resume" ;;'))],
        "write-lost": [('*"control.resume"*) cat > "$d/resume" ;;',
                        ('*"ir-resume-check"*) echo "taken failed 1" ;;\n'
                         '  *"control.resume"*) touch "$d/streaming"; sleep 3; cat > "$d/resume" ;;'))],
    }[slow]
    use_oc(sb.bin / "oc", oc_variant(*pairs))
    (sb.fake / "state").write_text("failed\n")
    env = sb.env({"FAKE_DIR": sb.fake, "IR_RESUME_POLL_SECONDS": "1"})
    return signalled(["zsh", str(sb.repo / RUNNER_TOOL), "resume", "--install", "cpd"], env, sb.repo,
                     sb.fake / "streaming", signal.SIGINT)


BINDING_DELETE = "oc delete clusterrolebinding install-runner-cpd-cpd-op-admin --ignore-not-found"


@pytest.mark.parametrize("slow", ["grant", "check"])
def test_ctrl_c_before_the_request_is_sent_says_so(sb, slow):  # noqa: F811
    """Nothing goes on, so no "Detached": 130 and a message. The cluster-admin binding the resume granted
    (or was granting) goes again, since no run will revoke it."""
    rc, out, err = resume_with_slow(sb, slow)
    assert rc == 130, out + err
    assert "Interrupted before the resume was sent: slot cpd-cpd-op still reads failed." in err, err
    assert "Detached" not in out and "Resuming slot" not in out
    log = oc_log(sb)
    assert "cat > /work/current/control.resume" not in log, "no request was sent"
    assert "follow.sh" not in log, "and no watch"
    assert BINDING_DELETE in log, log
    assert "Removed the cluster-admin binding install-runner-cpd-cpd-op-admin" in out


def test_ctrl_c_at_the_first_state_read_is_answered_too(sb):  # noqa: F811
    rc, out, err = resume_with_slow(sb, "state")
    assert rc == 130, out + err
    assert "Interrupted before the resume was sent: nothing changed in slot cpd-cpd-op." in err, err
    log = oc_log(sb)
    assert "apply -f -" not in log and "clusterrolebinding" not in log and "control.resume" not in log, log


def test_a_binding_that_was_there_before_the_resume_stays(sb):  # noqa: F811
    """A run launched with INSTALL_RUNNER_KEEP_ADMIN=true keeps its binding: not the resume's to remove."""
    rc, out, err = resume_with_slow(sb, "check", binding_there=True)
    assert rc == 130, out + err
    assert "oc get clusterrolebinding install-runner-cpd-cpd-op-admin --ignore-not-found -o name" in oc_log(sb)
    assert "delete clusterrolebinding" not in oc_log(sb)


def test_ctrl_c_while_the_request_is_written_detaches_like_the_wait(sb):  # noqa: F811
    """The pod side opens control.resume as the call starts: a request cut off on the way can still be there,
    so the runner looks, and finds it pending here."""
    rc, out, err = resume_with_slow(sb, "write")
    assert rc == 0, out + err
    assert "Detached. The resume is sent: the install goes on in slot cpd-cpd-op once the runner takes it." in out
    assert "follow.sh" not in oc_log(sb), "no watch after a detach"
    assert "delete clusterrolebinding" not in oc_log(sb), "the resumed run needs its binding"


def test_ctrl_c_while_the_request_is_written_and_it_is_not_there_says_to_check(sb):  # noqa: F811
    rc, out, err = resume_with_slow(sb, "write-lost")
    assert rc == 0, out + err
    assert "Detached while sending the resume: it may not have reached slot cpd-cpd-op." in err, err
    assert "x_install_runner.sh status --target-cluster itz-a" in err
    # No request, the same state and no new attempt: nothing reached the pod, so the binding goes again.
    assert BINDING_DELETE in oc_log(sb)


def test_a_failed_request_that_reached_nothing_removes_the_binding(fake):
    failing = ('*"control.resume"*) cat > "$d/resume" ;;',
               '*"ir-resume-check"*) echo "taken failed 1" ;;\n'
               '  *"control.resume"*) cat > /dev/null; exit 1 ;;')
    use_oc(fake, oc_variant(failing))
    (fake / "state").write_text("failed\n")
    result = zsh("ir_resume slot", fake, unit_env(fake))
    assert result.returncode != 0
    assert "Could not send the resume to slot slot (oc exec exited 1)" in result.stderr
    assert "oc delete clusterrolebinding install-runner-slot-admin --ignore-not-found" in (fake / "oc.log").read_text()


def test_a_failed_request_that_may_be_there_keeps_the_binding(fake):
    failing = ('*"control.resume"*) cat > "$d/resume" ;;',
               '*"ir-resume-check"*) [ -e "$d/resume" ] && echo "pending failed 1" || echo "taken failed 1" ;;\n'
               '  *"control.resume"*) cat > "$d/resume"; exit 1 ;;')
    use_oc(fake, oc_variant(failing))
    (fake / "state").write_text("failed\n")
    result = zsh("ir_resume slot", fake, unit_env(fake))
    assert result.returncode != 0
    assert "delete clusterrolebinding" not in (fake / "oc.log").read_text()


# --- C1: no gap between the request and the new attempt (image side) ---------------------------------------------
# mv as state_set calls it (`mv -f state.new state`): notes what the new state is and whether control.resume is
# still there at that moment, then moves.
NOTING_MV = r"""#!/bin/bash
for last; do :; done
if [ "${last##*/}" = state ] && [ -f "${last}.new" ]; then
  if [ -e "${last%/state}/control.resume" ]; then r=yes; else r=no; fi
  echo "$(cat "${last}.new") $r" >> "$FAKE_DIR/states.log"
fi
exec /bin/mv "$@"
"""


def test_the_supervisor_sets_running_before_it_takes_the_request(tmp_path):
    sup = Supervisor(tmp_path)
    put(tmp_path / "bin", "mv", NOTING_MV, mode=0o755)
    (sup.run / "state").write_text("failed\n")
    (sup.run / "attempts").write_text("1\n")
    (sup.run / "args-ok").touch()
    (sup.run / "control.resume").write_text("")
    try:
        sup.start("ok")
        wait_for(lambda: sup.state() == "completed")
    finally:
        sup.stop()
    states = (tmp_path / "states.log").read_text().splitlines()
    assert states[0] == "running yes", "the new state is set while the request is still there"
    assert not (sup.run / "control.resume").exists(), "then the request is taken"
    assert states[-1] == "completed no"


FOLLOW = REPO / "src/install_runner/image/bin/follow.sh"


def follow_run(tmp_path, state, extra=None, files=()):
    work = tmp_path / "work"
    run = work / "runs/r1"
    run.mkdir(parents=True)
    (run / "state").write_text(state + "\n")
    for name, text in files:
        (run / name).write_text(text)
    (run / "terminal.log").write_text("old output\n")
    os.symlink(run, work / "current")
    env = {"PATH": "/usr/bin:/bin", "IR_WORK": str(work), **(extra or {})}
    proc = subprocess.Popen(["bash", str(FOLLOW), "terminal", "start"], env=env, stdout=subprocess.PIPE, text=True)
    return run, proc


def ended_within(proc, seconds):
    try:
        proc.wait(timeout=seconds)
        return True
    except subprocess.TimeoutExpired:
        return False
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()


def test_follow_keeps_a_finished_run_open_while_a_resume_is_pending(tmp_path):
    run, proc = follow_run(tmp_path, "failed", files=[("control.resume", "")])
    try:
        time.sleep(3)
        assert proc.poll() is None, "a pending resume is still a live run"
        # The supervisor takes it: running first, then the file goes; the run then ends.
        (run / "state").write_text("running\n")
        (run / "control.resume").unlink()
        time.sleep(3)
        assert proc.poll() is None
        (run / "state").write_text("completed\n")
        assert ended_within(proc, 15), "a finished run with no request ends the stream"
    finally:
        if proc.poll() is None:
            proc.kill()


def test_follow_without_a_request_ends_on_a_finished_run(tmp_path):
    _, proc = follow_run(tmp_path, "failed")
    assert ended_within(proc, 10)


# --- C2: a stuck supervisor does not hold the watch for ever -----------------------------------------------------
def test_follow_ends_once_the_supervisor_is_silent_and_the_log_still(tmp_path):
    _, proc = follow_run(tmp_path, "running", {"IR_HEARTBEAT": "1"},
                         files=[("../.heartbeat", f"{int(time.time()) - 1000}\n")])
    assert ended_within(proc, 20), "three missed reports and a still log end the stream"


def test_follow_waits_on_a_supervisor_that_reports(tmp_path):
    _, proc = follow_run(tmp_path, "running", {"IR_HEARTBEAT": "1"},
                         files=[("../.heartbeat", f"{int(time.time()) + 100000}\n")])
    assert not ended_within(proc, 7)


def stuck_env(fake, beat_age, lost_max="0.02", stale="0"):  # noqa: F811
    """A heartbeat read back from ir-status (<beat_age> s behind this machine's clock) and a watch that calls a
    report stale after <stale> s of this watch with no change (IR_ATTACH_STALE_SECONDS, default 180)."""
    (fake / "status.heartbeat").write_text(str(int(time.time()) - beat_age))
    return unit_env(fake, {"INSTALL_RUNNER_ATTACH_LOST_MAX": lost_max, "IR_ATTACH_STALE_SECONDS": stale})


# The stream ends at once on a running run (as follow.sh does for a silent supervisor), each round a little later.
QUIET_STREAM = ('*"follow.sh"*) echo "hello from the pod" ;;', '*"follow.sh"*) sleep 0.3 ;;')
# The same, with new bytes each round, then the run ends after 30 rounds (about 9 s, well past a 6 s cap).
BUSY_STREAM = ('*"follow.sh"*) echo "hello from the pod" ;;',
               ('*"follow.sh"*) n=$(cat "$d/rounds" 2>/dev/null || echo 0); echo $((n+1)) > "$d/rounds"\n'
                '      sleep 0.3; echo "line $n"; [ "$n" -ge 30 ] && echo completed > "$d/state" ;;'))
# A supervisor that reports: each read of ir-status gets a newer heartbeat (still on the pod's clock), and the
# run ends after 12 reads.
REPORTING = ('"get configmap ir-status"*)',
             ('"get configmap ir-status"*)\n'
              '      n=$(cat "$d/rounds" 2>/dev/null || echo 0); echo $((n+1)) > "$d/rounds"\n'
              '      b=$(cat "$d/status.heartbeat"); echo $((b+1)) > "$d/status.heartbeat"\n'
              '      [ "$n" -ge 12 ] && echo completed > "$d/state"'))


def test_a_watch_on_a_stuck_supervisor_stops_with_78(fake):  # noqa: F811
    use_oc(fake, oc_variant(QUIET_STREAM))
    (fake / "state").write_text("running\n")
    # A cap (3 s) longer than the staleness (0 s here), so the notice comes before the stop.
    result = zsh("ir_attach slot", fake, stuck_env(fake, 1000, lost_max="0.05"))
    assert result.returncode == 78, result.stdout + result.stderr
    assert "The runner in slot slot has not reported for " in result.stderr
    assert "second(s) of this watch, and its log has not moved for" in result.stderr
    assert "The install may still be running." in result.stderr
    assert "x_install_runner.sh status" in result.stderr and "oc logs install-runner-0 -n install-runner-slot" in result.stderr
    assert result.stderr.count("[attach] The runner has not reported for") == 1, result.stderr
    # Stream ends before the report could be judged stale read as dropped connections; none after the notice.
    assert result.stderr.rfind("Connection lost") < result.stderr.index("[attach] The runner has not reported for")


def test_a_stuck_supervisor_with_a_moving_log_is_still_watched(fake):  # noqa: F811
    use_oc(fake, oc_variant(BUSY_STREAM))
    (fake / "state").write_text("running\n")
    # A cap of a few seconds: SECONDS counts whole seconds, so a 1 s cap could pass between a byte and the check.
    # The stream outlasts it by half again, so only the log's bytes keep the watch going.
    result = zsh("ir_attach slot", fake, stuck_env(fake, 1000, lost_max="0.1"))
    assert result.returncode == 0, result.stdout + result.stderr
    assert "Run finished: completed" in result.stdout
    assert result.stdout.count("line ") >= 30
    assert "[attach] The runner has not reported for" in result.stderr, "the runner is stuck, the log is not"
    assert "stopped watching" not in result.stderr


def test_a_reporting_supervisor_is_never_cut_off(fake):  # noqa: F811
    use_oc(fake, oc_variant(QUIET_STREAM, REPORTING))
    (fake / "state").write_text("running\n")
    result = zsh("ir_attach slot", fake, stuck_env(fake, 5))
    assert result.returncode == 0, result.stdout + result.stderr
    assert "has not reported" not in result.stderr


def test_a_cluster_clock_far_behind_this_machine_is_no_stuck_runner(fake):  # noqa: F811
    """B-R2: the heartbeat is the pod's clock. Read against this machine's, a cluster 1000 s behind looked
    stuck at once; a heartbeat that keeps changing is a runner that reports, whatever its value."""
    use_oc(fake, oc_variant(QUIET_STREAM, REPORTING))
    (fake / "state").write_text("running\n")
    result = zsh("ir_attach slot", fake, stuck_env(fake, 1000, stale="1"))
    assert result.returncode == 0, result.stdout + result.stderr
    assert "has not reported" not in result.stderr and "stopped watching" not in result.stderr


def test_a_resume_the_stuck_runner_never_takes_stops_the_watch(fake):  # noqa: F811
    use_oc(fake, oc_variant(handover(10 ** 6, "taken running 1"), QUIET_STREAM))
    (fake / "state").write_text("failed\n")
    result = zsh("ir_attach slot --resumed", fake, stuck_env(fake, 1000))
    assert result.returncode == 78, result.stdout + result.stderr
    assert "has not reported for " in result.stderr and "of this watch" in result.stderr
