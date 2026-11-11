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
