"""Scripts-mode byte identity: CONFLUENT_DEPLOY_MODE=scripts must behave exactly like the baseline.

Runs tests/confluent_scripts_mode_identity.sh, which snapshots a git worktree of the baseline commit
(IDENTITY_BASELINE_REF, default 0efad5f) and this checkout, runs the same side-effect-free probes in
sandboxes of both (fake oc/helm/kubectl/confluent, own HOME and configs/) and diffs the normalised
outputs. Nothing touches a cluster or the real configs/.

Skipped when the baseline cannot be had: no git, not a git checkout, the commit missing (shallow
clone) or `git worktree add` failing (harness exit 3).

Environment passed through to the harness: IDENTITY_BASELINE_REF, IDENTITY_BASELINE_WT,
IDENTITY_JOBS, IDENTITY_PROBE_TIMEOUT. IDENTITY_ONLY=a,b runs just those probes.
"""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
HARNESS = REPO / "tests" / "confluent_scripts_mode_identity.sh"
BASELINE_REF = os.environ.get("IDENTITY_BASELINE_REF", "0efad5f")
EXIT_NO_WORKTREE = 3


def _git(*args):
    return subprocess.run(["git", "-C", str(REPO), *args], capture_output=True, text=True, check=False)


def _skip_reason():
    for tool in ("git", "zsh", "perl"):
        if shutil.which(tool) is None:
            return f"{tool} is not installed"
    if _git("rev-parse", "--show-toplevel").returncode != 0:
        return "not a git checkout: the baseline worktree cannot be created"
    if _git("cat-file", "-e", f"{BASELINE_REF}^{{commit}}").returncode != 0:
        return f"baseline commit {BASELINE_REF} is not in this clone (shallow?): no worktree possible"
    return None


def test_confluent_scripts_mode_is_byte_identical_to_baseline():
    reason = _skip_reason()
    if reason:
        pytest.skip(reason)
    cmd = [str(HARNESS), "--baseline-ref", BASELINE_REF]
    if os.environ.get("IDENTITY_ONLY"):
        cmd += ["--only", os.environ["IDENTITY_ONLY"]]
    proc = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True, timeout=900, check=False)
    output = proc.stdout + proc.stderr
    if proc.returncode == EXIT_NO_WORKTREE:
        pytest.skip("git worktree creation is not possible here:\n" + output[-2000:])
    assert proc.returncode == 0, (
        "scripts mode is not byte-identical to the baseline "
        f"(harness exit {proc.returncode}); harness output:\n{output[-20000:]}"
    )


# ---------------------------------------------------------------------------------------------
# The probe table and the allow-list (no worktree, no probes run)
# ---------------------------------------------------------------------------------------------
SNIPPET = (
    "# ---- Deploy mode ---------------------------------------------------------------\n"
    "# scripts  = the repo renders and applies raw manifests (StatefulSet broker, Deployments, ...).\n"
    "# operator = Confluent for Kubernetes (CFK) and cp-fko, installed through OLM, run the platform.\n"
    "# Unset or any other value means operator; a scripts-mode install in the namespace then stops every script.\n"
    'export CONFLUENT_DEPLOY_MODE="scripts"\n'
)
ANCHOR = "# Topology from https://github.com/confluentinc/cp-all-in-one (KRaft variant).\n"
INFO = '[INFO] CONFLUENT_DEPLOY_MODE="scripts" written to confluent_vars.sh.\n'
VARS = "--- new repo/configs/confluent_platform_config/confluent_vars.sh\n"


def _heredoc(name):
    """The body of the helper the harness writes with cat > "${HELPERS}/<name>" <<'TAG'."""
    text = HARNESS.read_text()
    start = text.index(f'cat > "${{HELPERS}}/{name}" <<\'')
    tag = text[start:].split("<<'", 1)[1].split("'", 1)[0]
    body_start = text.index("\n", start) + 1
    return text[body_start:text.index(f"\n{tag}\n", body_start) + 1]


def _report(stdout="", files=""):
    return ("### probe: p\n### command: c\n### exit: 0\n### stdout\n" + stdout + "### stderr\n"
            "### fake cluster CLI calls\n(none)\n"
            "### files written or removed (configs/: with content; elsewhere: names only)\n" + files)


def _allow(tmp_path, allowances, report):
    if shutil.which("perl") is None:
        pytest.skip("perl is not installed")
    (tmp_path / "allow.pl").write_text(_heredoc("allow.pl"))
    (tmp_path / "snippet").write_text(SNIPPET)
    (tmp_path / "report").write_text(report)
    proc = subprocess.run(["perl", str(tmp_path / "allow.pl"), str(tmp_path / "snippet"), allowances,
                           str(tmp_path / "report")], capture_output=True, text=True, check=True)
    return proc.stdout


def test_probe_table_and_allow_list_are_valid():
    proc = subprocess.run([str(HARNESS), "--list"], cwd=REPO, capture_output=True, text=True, timeout=60, check=False)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    rows = {line.split()[0]: line for line in proc.stdout.splitlines()}
    for name in ("gen-confluent-rewrite-unquoted", "chain-platform-list-steps-unquoted", "j2-template-render",
                 "mirror-prefill", "mirror-map-images"):
        assert name in rows
    assert "${=IDENTITY_GEN_ARGS}" in rows["gen-confluent-write-empty"]
    assert "${=IDENTITY_NB_ARGS}" in rows["j2-notebook-default"]
    assert "full-unquoted" in rows["gen-confluent-rewrite-unquoted"]
    assert "--deploy-mode scripts" not in proc.stdout       # only through the side variable


def test_allow_list_removes_only_the_fixed_texts_once_in_their_place(tmp_path):
    body = "export A=1\n"
    # j2-snippet: after the anchor only, once
    base = _report(stdout=ANCHOR + body)
    assert _allow(tmp_path, "j2-snippet", _report(stdout=ANCHOR + SNIPPET + body)) == base
    moved = _report(stdout=ANCHOR + body + SNIPPET)
    assert _allow(tmp_path, "j2-snippet", moved) == moved
    twice = _report(stdout=ANCHOR + SNIPPET + SNIPPET + body)
    assert _allow(tmp_path, "j2-snippet", twice) == _report(stdout=ANCHOR + SNIPPET + body)
    # info-line: one line, stdout only; an operator value is never allowed
    assert _allow(tmp_path, "info-line", _report(stdout=INFO + INFO)) == _report(stdout=INFO)
    op = _report(stdout=INFO.replace('"scripts"', '"operator"'))
    assert _allow(tmp_path, "info-line", op) == op
    # file-snippet: blank line + snippet inside confluent_vars.sh's content only
    files = VARS + body + "\n" + SNIPPET
    assert _allow(tmp_path, "file-snippet", _report(files=files)) == _report(files=VARS + body)
    other = "--- new repo/configs/other.sh\n" + body + "\n" + SNIPPET
    assert _allow(tmp_path, "file-snippet", _report(files=other)) == _report(files=other)
    # an allowance a probe does not list removes nothing
    assert _allow(tmp_path, "info-line", _report(files=files)) == _report(files=files)


HELP_ANCHOR = "  -h, --help                this message\n\n"
FLINK_HELP = (
    "Flink operator mode:\n"
    "  --operator-source SRC     helm | olm | existing (FLINK_OPERATOR_SOURCE). Without\n"
    "                            it the Flink scripts follow the platform mode: olm when\n"
    "                            CONFLUENT_DEPLOY_MODE is operator (or missing), else helm.\n"
    "  --cmf-resource-mode MODE  cli | cfk (FLINK_CMF_RESOURCE_MODE). Without it: cfk\n"
    "                            when the operator source is not helm, else cli.\n"
    "\n"
)


def test_help_allowance_removes_only_the_new_flag_lines_after_the_help_line(tmp_path):
    tail = "Namespace note: unchanged\n"
    base = _report(stdout=HELP_ANCHOR + tail)
    assert _allow(tmp_path, "help-flink", _report(stdout=HELP_ANCHOR + FLINK_HELP + tail)) == base
    # anywhere else, changed by one character, or under the other generator's allowance: kept
    moved = _report(stdout=HELP_ANCHOR + tail + FLINK_HELP)
    assert _allow(tmp_path, "help-flink", moved) == moved
    edited = _report(stdout=HELP_ANCHOR + FLINK_HELP.replace("cli | cfk", "cli | cfk ") + tail)
    assert _allow(tmp_path, "help-flink", edited) == edited
    other = _report(stdout=HELP_ANCHOR + FLINK_HELP + tail)
    assert _allow(tmp_path, "help-confluent", other) == other
    # the real generators' --help text carries exactly the allowed block
    gen = REPO / "scripts/install_confluent_platform/install_confluent_platform_flink_addon/0_flink_prepare_template_config.sh"
    assert HELP_ANCHOR + FLINK_HELP in gen.read_text()
