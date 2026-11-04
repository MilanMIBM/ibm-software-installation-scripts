"""In-cluster install runner: workstation side, step journal and the mode switch.

Everything runs against a fake `oc`, so nothing touches a cluster, and under
`set -euo pipefail` because that is how the chains call these helpers. The pod side
is covered by tests/install_runner_container_test.sh, in the real image.
"""

import hashlib
import json
import os
import re
import stat
import subprocess
import tarfile
import textwrap
from pathlib import Path

import pytest
import yaml

REPO = Path(__file__).resolve().parents[1]
HELPERS = REPO / "src/helpers/install_runner_helpers.sh"
CPD_CHAIN = "scripts/install_cloud_pak_for_data/0_x_full_quick_install_script/full_swhub_x_cpd_installprocess.sh"

FAKE_OC = r"""#!/bin/bash
# Logs every call, keeps what `apply` receives, and answers from $FAKE_DIR.
d="${FAKE_DIR}"
echo "oc $*" >> "$d/oc.log"
args="$*"
case "$args" in
  "auth can-i"*) cat "$d/can_i" 2>/dev/null || echo yes ;;
  "whoami"*) echo tester ;;
  "get storageclass"*) [ -e "$d/no_storageclass" ] && exit 1; echo ok ;;
  "get configs.imageregistry"*) cat "$d/registry" 2>/dev/null || echo Managed ;;
  "get istag"*) [ -e "$d/image_missing" ] && exit 1; echo ok ;;
  "get pvc"*) exit 1 ;;
  "get configmap ir-status"*)
      key="$(sed -E 's/.*\.data\.([a-z]+).*/\1/' <<<"$args")"
      cat "$d/status.$key" 2>/dev/null ;;
  "get configmap -A"*) cat "$d/all_status.json" 2>/dev/null || echo '{"items":[]}' ;;
  "apply -f -"*) { cat; echo "---"; } >> "$d/applied.yaml" ;;
  "start-build"*) ;;
  "delete"*) ;;
  *"follow.sh"*"resolve"*) echo 0 ;;
  *"follow.sh"*) echo "hello from the pod" ;;
  *"collect-list.sh"*) cat "$d/collect_list" 2>/dev/null ;;
  *"tar -cf - -T -"*) cat >/dev/null; cat "$d/collect.tar" ;;
  *"tar -xf"*) cat > "$d/snapshot.tar" ;;
  *"cat > /work/runs"*) cat > "$d/run.env" ;;
  *"control.resume"*) cat > "$d/resume" ;;
  *"finalize-stage.sh"*) echo "$args" > "$d/finalized" ;;
  *"cat /work/current/state"*) cat "$d/state" 2>/dev/null ;;
  *"readlink -f /work/current"*) echo run1 ;;
  "exec"*) ;;
esac
exit 0
"""


@pytest.fixture
def fake(tmp_path):
    """A PATH with a fake oc, and tripwires for the commands that must never run."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    (bin_dir / "oc").write_text(FAKE_OC)
    for tool in ("cpd-cli", "podman"):
        (bin_dir / tool).write_text(f'#!/bin/bash\necho "{tool} $*" >> "$FAKE_DIR/tripwire"\nexit 0\n')
    for tool in bin_dir.iterdir():
        tool.chmod(tool.stat().st_mode | stat.S_IEXEC)
    return tmp_path


def zsh(body, fake_dir=None, env=None, cwd=None):
    run_env = {k: v for k, v in os.environ.items() if not k.startswith(("IR_", "INSTALL_RUN"))}
    run_env.update({"_CP4D_REPO_ROOT": str(REPO), "OC_LOGIN": "true", "_CP4D_PREP_DONE": "1"})
    if fake_dir:
        run_env["PATH"] = f"{fake_dir}/bin:{run_env['PATH']}"
        run_env["FAKE_DIR"] = str(fake_dir)
    run_env.update(env or {})
    script = f'set -euo pipefail\nsource "{HELPERS}"\n{textwrap.dedent(body)}'
    return subprocess.run(["zsh", "-c", script], capture_output=True, text=True, env=run_env, cwd=cwd, timeout=120, check=False)


def out(result):
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout.strip()


# --- modules and names ---------------------------------------------------------
def test_template_is_not_an_install():
    assert "_template" not in out(zsh("ir_install_ids")).split()


def test_chain_maps_to_its_install():
    assert out(zsh(f'ir_install_for_chain {CPD_CHAIN}; print -r -- "$REPLY"')) == "cpd"
    assert zsh("ir_install_for_chain scripts/nope.sh").returncode != 0


def test_entrypoints_exist_and_dispatch_before_parsing():
    for conf in (REPO / "src/install_runner/installs").glob("*.conf"):
        text = conf.read_text()
        entries = re.search(r'^RUNNER_ENTRYPOINTS="(.*)"$', text, re.MULTILINE).group(1).split()
        for chain in entries:
            body = (REPO / chain).read_text()
            assert 'ir_dispatch "$@"' in body, chain


def test_every_chain_dispatches_right_after_env_load():
    chains = subprocess.check_output(["git", "ls-files", "scripts/*.sh"], cwd=REPO, text=True).split()
    chains = [c for c in chains if re.search(r"full_|_full_", c)]
    assert len(chains) >= 13
    for chain in chains:
        text = (REPO / chain).read_text()
        assert text.count('ir_dispatch "$@"') == 1, chain
        assert text.index("env_bootstrap.sh") < text.index('ir_dispatch "$@"'), chain
        parse = re.search(r"^h_steps_parse", text, re.MULTILINE)
        if parse:
            assert text.index('ir_dispatch "$@"') < parse.start(), chain


@pytest.mark.parametrize("instance,expected", [
    ("cpd-operands", "cpd-cpd-operands"),
    ("My_Instance", "cpd-my-instance"),
])
def test_slot_names(instance, expected):
    assert out(zsh('ir_slot cpd; print -r -- "$REPLY"', env={"PROJECT_CPD_INST_OPERANDS": instance})) == expected


def test_long_slot_names_stay_valid_and_distinct():
    a = out(zsh('ir_slot cpd; print -r -- "$REPLY"', env={"PROJECT_CPD_INST_OPERANDS": "x" * 80 + "a"}))
    b = out(zsh('ir_slot cpd; print -r -- "$REPLY"', env={"PROJECT_CPD_INST_OPERANDS": "x" * 80 + "b"}))
    assert a != b
    assert len(f"install-runner-{a}") <= 63
    assert re.fullmatch(r"[a-z0-9]([a-z0-9-]*[a-z0-9])?", a)


# --- manifests -----------------------------------------------------------------
def test_unfilled_placeholder_is_refused():
    result = zsh("ir_render system.yaml.tmpl")
    assert result.returncode != 0
    assert "Unfilled placeholder" in result.stderr + result.stdout


def handoff(fake, *args, env=None):
    base = {"OCP_URL": "https://api.x:6443", "OLM_UTILS_IMAGE": "icr.io/cpopen/cpd/olm-utils-v4:5.4.0.8",
            "PROJECT_CPD_INST_OPERANDS": "cpd-op", "STG_CLASS_BLOCK": "blk", "STG_CLASS_FILE": "fil",
            "VERSION": "5.4.0", "INSTALL_RUNNER_CPD_CLI_URL": "https://x/cli.tgz", "INSTALL_RUN_MODE": "cluster"}
    base.update(env or {})
    chain = fake / "chain.sh"
    chain.write_text(textwrap.dedent(f"""\
        #!/bin/zsh
        set -euo pipefail
        ZSH_ARGZERO="{REPO}/{CPD_CHAIN}"
        source "{REPO}/src/helpers/common_helpers.sh"
        ir_dispatch "$@"
        print -r -- CHAIN-RAN-LOCALLY
        """))
    run_env = {k: v for k, v in os.environ.items() if not k.startswith(("IR_", "INSTALL_RUN"))}
    run_env.update({"_CP4D_REPO_ROOT": str(REPO), "OC_LOGIN": "true", "PATH": f"{fake}/bin:{run_env['PATH']}",
                    "FAKE_DIR": str(fake), **base})
    return subprocess.run(["zsh", str(chain), *args], capture_output=True, text=True, env=run_env, timeout=120, check=False)


def test_handoff_builds_everything_and_never_runs_locally(fake):
    (fake / "state").write_text("completed\n")
    result = handoff(fake, "--from", "cpd", "--skip", "my step")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "CHAIN-RAN-LOCALLY" not in result.stdout
    assert "hello from the pod" in result.stdout
    assert not (fake / "tripwire").exists(), "cpd-cli or podman ran on the workstation"

    docs = [d for d in yaml.safe_load_all((fake / "applied.yaml").read_text()) if d]
    kinds = {d["kind"] for d in docs}
    assert {"Namespace", "ServiceAccount", "StatefulSet", "PersistentVolumeClaim", "ClusterRoleBinding"} <= kinds

    sts = next(d for d in docs if d["kind"] == "StatefulSet")
    assert sts["metadata"]["namespace"] == "install-runner-cpd-cpd-op"
    assert sts["spec"]["replicas"] == 1
    pod = sts["spec"]["template"]
    assert pod["metadata"]["annotations"]["openshift.io/required-scc"] == "restricted-v2"
    container = pod["spec"]["containers"][0]
    assert "livenessProbe" not in container
    assert container["securityContext"]["allowPrivilegeEscalation"] is False
    assert not re.search(r"(?i)password|token|apikey", json.dumps(container["env"]))

    pvc = next(d for d in docs if d["kind"] == "PersistentVolumeClaim")
    assert pvc["spec"]["storageClassName"] == "blk"
    binding = next(d for d in docs if d["kind"] == "ClusterRoleBinding")
    assert binding["subjects"][0]["namespace"] == "install-runner-cpd-cpd-op"
    assert not any(d["kind"] == "PodDisruptionBudget" for d in docs)


def test_run_env_keeps_arguments_exact(fake):
    (fake / "state").write_text("completed\n")
    result = handoff(fake, "--skip", "two words", "--from", "it's", env={"DO_X": "false", "DO_API_TOKEN": "nope"})
    assert result.returncode == 0, result.stderr
    run_env = (fake / "run.env").read_text()
    assert "export DO_X=" in run_env
    assert "nope" not in run_env
    read_back = subprocess.run(["zsh", "-c", f'source {fake}/run.env; print -l -- "${{IR_ARGS[@]}}"; print -r -- "$IR_CHAIN"'],
                               capture_output=True, text=True, check=False)
    assert read_back.stdout.split("\n")[:5] == ["--skip", "two words", "--from", "it's", CPD_CHAIN]


def test_snapshot_has_code_and_config_but_not_secrets_of_others(fake):
    (fake / "state").write_text("completed\n")
    assert handoff(fake).returncode == 0
    with tarfile.open(fake / "snapshot.tar") as tar:
        names = set(tar.getnames())
    assert CPD_CHAIN in names
    assert "src/helpers/common_helpers.sh" in names
    assert "pyproject.toml" in names, "1.1 and 3.3.1 walk up to it"
    assert not any(n.startswith((".venv/", "registry_mirror_workspace/")) for n in names)
    assert not any(n.startswith("configs/") and not n.startswith("configs/cp4d_config/") for n in names)


def test_image_is_reused_when_unchanged(fake):
    (fake / "state").write_text("completed\n")
    assert handoff(fake).returncode == 0
    assert "start-build" not in (fake / "oc.log").read_text()


def test_image_is_built_when_missing(fake):
    (fake / "state").write_text("completed\n")
    (fake / "image_missing").touch()
    assert handoff(fake).returncode == 0
    assert "start-build" in (fake / "oc.log").read_text()
    docs = [d for d in yaml.safe_load_all((fake / "applied.yaml").read_text()) if d]
    build = next(d for d in docs if d["kind"] == "BuildConfig")
    args = {a["name"]: a["value"] for a in build["spec"]["strategy"]["dockerStrategy"]["buildArgs"]}
    assert args == {"BASE_IMAGE": "icr.io/cpopen/cpd/olm-utils-v4:5.4.0.8", "CPD_CLI_URL": "https://x/cli.tgz"}


def test_failed_run_returns_failure(fake):
    (fake / "state").write_text("failed\n")
    result = handoff(fake)
    assert result.returncode != 0
    assert "resume" in result.stderr


# --- mode switch ---------------------------------------------------------------
@pytest.mark.parametrize("env", [{}, {"INSTALL_RUN_MODE": "local"}, {"INSTALL_RUN_MODE": "cluster", "IR_IN_RUNNER": "1"}])
def test_dispatch_leaves_the_chain_alone(fake, env):
    full = {"INSTALL_RUN_MODE": "", **env}
    result = handoff(fake, env=full) if env else handoff(fake, env={"INSTALL_RUN_MODE": "local"})
    assert "CHAIN-RAN-LOCALLY" in result.stdout, result.stderr
    assert not (fake / "oc.log").exists()


def test_bad_mode_is_refused(fake):
    result = handoff(fake, env={"INSTALL_RUN_MODE": "pod"})
    assert result.returncode != 0
    assert "INSTALL_RUN_MODE" in result.stderr


@pytest.mark.parametrize("flag", ["--list-steps", "--help", "-h"])
def test_questions_about_a_chain_stay_local(fake, flag):
    assert "CHAIN-RAN-LOCALLY" in handoff(fake, flag).stdout
    assert not (fake / "oc.log").exists()


def test_chain_without_a_module_is_refused_not_run_locally(fake):
    chain = fake / "other.sh"
    chain.write_text(f'#!/bin/zsh\nset -euo pipefail\nZSH_ARGZERO="{REPO}/scripts/other.sh"\n'
                     f'source "{REPO}/src/helpers/common_helpers.sh"\nir_dispatch "$@"\nprint LOCAL\n')
    env = {**os.environ, "_CP4D_REPO_ROOT": str(REPO), "OC_LOGIN": "true", "INSTALL_RUN_MODE": "cluster",
           "PATH": f"{fake}/bin:{os.environ['PATH']}", "FAKE_DIR": str(fake)}
    result = subprocess.run(["zsh", str(chain)], capture_output=True, text=True, env=env, check=False)
    assert result.returncode != 0
    assert "LOCAL" not in result.stdout
    assert "no install module" in result.stderr


# --- preflight -----------------------------------------------------------------
def preflight(fake, env=None):
    base = {"STG_CLASS_BLOCK": "blk", "STG_CLASS_FILE": "fil", "CONFIG_DIR": "/nonexistent"}
    return zsh("ir_preflight cpd", fake, {**base, **(env or {})})


def test_preflight_passes(fake):
    out(preflight(fake))


def test_preflight_reports_all_problems_at_once(fake):
    (fake / "can_i").write_text("no\n")
    (fake / "registry").write_text("Removed\n")
    (fake / "no_storageclass").touch()
    result = preflight(fake)
    assert result.returncode != 0
    for text in ("not cluster-admin", "does not exist", "Removed"):
        assert text in result.stderr


def test_preflight_changes_nothing(fake):
    preflight(fake)
    assert not re.search(r"^oc (apply|create|delete|patch)", (fake / "oc.log").read_text(), re.MULTILINE)


def test_private_registry_refused_until_supported(fake):
    result = preflight(fake, {"CPD_IMAGE_SOURCE": "private"})
    assert result.returncode != 0
    assert "entitled only" in result.stderr


def test_workstation_registry_refused(fake):
    result = preflight(fake, {"LOCAL_REGISTRY_HOST": "laptop.local"})
    assert result.returncode != 0
    assert "outlive this machine" in result.stderr


# --- busy slots ----------------------------------------------------------------
@pytest.mark.parametrize("state,collected,allowed", [
    ("", "", True), ("idle", "", True),
    ("running", "", False), ("staged", "", False), ("interrupted", "", False),
    ("failed", "", False), ("stopped", "", False),
    ("completed", "no", False), ("completed", "yes", True),
])
def test_busy_slot(fake, state, collected, allowed):
    (fake / "status.state").write_text(state)
    (fake / "status.collected").write_text(collected)
    assert (zsh("ir_refuse_busy_slot ns slot", fake).returncode == 0) is allowed


def test_new_run_flag_never_overrides_a_live_run(fake):
    (fake / "status.state").write_text("running")
    assert zsh("ir_refuse_busy_slot ns slot", fake, {"INSTALL_RUNNER_NEW_RUN": "true"}).returncode != 0


# --- collect -------------------------------------------------------------------
def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


@pytest.fixture
def collect_repo(fake, tmp_path):
    """A stand-in repo root with one module, so collect writes nowhere real."""
    root = tmp_path / "root"
    (root / "src/install_runner/installs").mkdir(parents=True)
    (root / "src/helpers").mkdir()
    for name in ("common_helpers.sh", "install_runner_helpers.sh"):
        (root / "src/helpers" / name).write_text((REPO / "src/helpers" / name).read_text())
    (root / "src/install_runner/installs/demo.conf").write_text('INSTALL_ID="demo"\nRUNNER_COLLECT_PATHS="configs"\n')
    (root / "configs").mkdir()
    (root / "configs/unchanged_here.sh").write_text("old\n")
    (root / "configs/edited_here.sh").write_text("my edit\n")
    pod = tmp_path / "pod"
    (pod / "configs").mkdir(parents=True)
    for name in ("unchanged_here.sh", "edited_here.sh", "new.sh"):
        (pod / "configs" / name).write_text("from pod\n")
    with tarfile.open(fake / "collect.tar", "w") as tar:
        tar.add(pod / "configs", arcname="configs")
    (fake / "collect_list").write_text("".join([
        f"{sha('old' + chr(10))}\t{sha('from pod' + chr(10))}\tconfigs/unchanged_here.sh\n",
        f"{sha('old' + chr(10))}\t{sha('from pod' + chr(10))}\tconfigs/edited_here.sh\n",
        f"-\t{sha('from pod' + chr(10))}\tconfigs/new.sh\n"]))
    (fake / "state").write_text("completed\n")
    return root


def collect(fake, root, args=""):
    return zsh(f"ir_collect demo slot {args}", fake, {"_CP4D_REPO_ROOT": str(root), "TMPDIR": str(fake)})


def test_collect_takes_changes_and_never_overwrites_local_edits(fake, collect_repo):
    result = collect(fake, collect_repo)
    assert result.returncode == 0, result.stdout + result.stderr
    assert (collect_repo / "configs/unchanged_here.sh").read_text() == "from pod\n"
    assert (collect_repo / "configs/new.sh").read_text() == "from pod\n"
    assert (collect_repo / "configs/edited_here.sh").read_text() == "my edit\n"
    assert (collect_repo / "configs/edited_here.sh.in-cluster-run1").read_text() == "from pod\n"
    assert "Kept your local" in result.stderr
    assert "touch /work/current/collected" in (fake / "oc.log").read_text()


def test_collect_waits_for_the_run(fake, collect_repo):
    (fake / "state").write_text("running\n")
    assert collect(fake, collect_repo).returncode != 0
    assert (collect_repo / "configs/unchanged_here.sh").read_text() == "old\n"
    assert collect(fake, collect_repo, "--force").returncode == 0


# --- teardown ------------------------------------------------------------------
def test_teardown_needs_a_collected_run(fake):
    (fake / "status.state").write_text("completed")
    (fake / "status.collected").write_text("no")
    assert zsh("ir_teardown slot", fake).returncode != 0
    assert "delete namespace" not in (fake / "oc.log").read_text()
    out(zsh("ir_teardown slot --discard", fake))
    log = (fake / "oc.log").read_text()
    assert "delete namespace install-runner-slot" in log
    assert "delete clusterrolebinding install-runner-slot-admin" in log


def test_teardown_refuses_a_live_run(fake):
    (fake / "status.state").write_text("running")
    assert zsh("ir_teardown slot --discard", fake).returncode != 0


# --- status --------------------------------------------------------------------
def test_status_flags_a_silent_run(fake):
    (fake / "all_status.json").write_text(json.dumps({"items": [{
        "metadata": {"name": "ir-status", "namespace": "install-runner-a"},
        "data": {"slot": "a", "state": "running", "step": "scripts/x.sh#cpd", "attempts": "1",
                 "collected": "no", "heartbeat": "1000", "warned": "-"}}]}))
    result = zsh("ir_status", fake)
    assert result.returncode == 0, result.stderr
    assert "x.sh#cpd" in result.stdout
    assert "no report" in result.stderr


def test_login_never_goes_through_cpd_cli():
    for script in (HELPERS, REPO / "scripts/install_runner/x_install_runner.sh"):
        code = "\n".join(l for l in script.read_text().splitlines() if not l.lstrip().startswith("#"))
        assert "CPDM_OC_LOGIN" not in code
        assert "cpd-cli manage" not in code


# --- step journal --------------------------------------------------------------
def chain_run(tmp_path, journal, steps):
    (tmp_path / "chain.zsh").write_text(textwrap.dedent(f"""\
        set -euo pipefail
        export _CP4D_REPO_ROOT="{tmp_path}"
        source "{REPO}/src/helpers/common_helpers.sh"
        h_steps_parse --strict
        {steps}
        h_steps_plan
        h_steps_run
        """))
    env = {k: v for k, v in os.environ.items() if not k.startswith("IR_")}
    if journal:
        env["IR_JOURNAL_FILE"] = str(journal)
    return subprocess.run(["zsh", str(tmp_path / "chain.zsh")], capture_output=True, text=True, env=env, cwd=tmp_path, check=False)


def events(journal):
    return [line.split("\t")[1:3] for line in journal.read_text().splitlines()]


def test_no_journal_without_the_runner(tmp_path):
    result = chain_run(tmp_path, None, 'h_step a true "a" /usr/bin/true')
    assert result.returncode == 0, result.stderr
    assert "ir_step" not in result.stderr


def test_journal_records_and_skips_finished_steps(tmp_path):
    journal = tmp_path / "j.tsv"
    count = tmp_path / "count"
    steps = f'h_step a true "a" /bin/sh -c "echo x >> {count}"'
    assert chain_run(tmp_path, journal, steps).returncode == 0
    second = chain_run(tmp_path, journal, steps)
    assert second.returncode == 0
    assert "Already finished" in second.stdout
    assert count.read_text() == "x\n"
    assert [e[0] for e in events(journal)] == ["begin", "done"]


def test_journal_reruns_an_interrupted_step(tmp_path):
    journal = tmp_path / "j.tsv"
    journal.write_text("t\tbegin\tchain.zsh#a\t\n")
    result = chain_run(tmp_path, journal, 'h_step a true "a" /usr/bin/true')
    assert result.returncode == 0, result.stderr
    assert [e[0] for e in events(journal)] == ["begin", "begin", "done"]


def test_journal_gives_up_on_a_step_that_keeps_dying(tmp_path):
    journal = tmp_path / "j.tsv"
    journal.write_text("t\tbegin\tchain.zsh#a\t\n" * 4)
    result = chain_run(tmp_path, journal, 'h_step a true "a" /usr/bin/true')
    assert result.returncode != 0
    assert "without finishing" in result.stderr


def test_journal_real_failures_do_not_count_as_interruptions(tmp_path):
    journal = tmp_path / "j.tsv"
    journal.write_text("t\tbegin\tchain.zsh#a\t\nt\tfailed\tchain.zsh#a\t1\n" * 6)
    assert chain_run(tmp_path, journal, 'h_step a true "a" /usr/bin/true').returncode == 0


def test_journal_records_failure_and_warning(tmp_path):
    journal = tmp_path / "j.tsv"
    result = chain_run(tmp_path, journal, 'h_step --warn w true "w" /usr/bin/false\nh_step f true "f" /usr/bin/false')
    assert result.returncode != 0
    assert [e[0] for e in events(journal)] == ["begin", "warned", "begin", "failed"]


def test_journal_ignores_steps_that_are_off(tmp_path):
    journal = tmp_path / "j.tsv"
    assert chain_run(tmp_path, journal, 'h_step a false "a" /usr/bin/false').returncode == 0
    assert not journal.exists() or journal.read_text() == ""


# --- runner environment --------------------------------------------------------
def test_runner_login_is_a_session_check(tmp_path):
    (tmp_path / "scripts").mkdir()
    for name in ("source_env_setup.sh",):
        (tmp_path / "scripts" / name).write_text((REPO / "scripts" / name).read_text())
    cfg = tmp_path / "configs/cp4d_config"
    cfg.mkdir(parents=True)
    (cfg / "cpd_vars.sh").write_text('export OCP_URL=https://api.x:6443\nexport OC_LOGIN="oc login"\n'
                                     'export CPDM_OC_LOGIN="cpd-cli manage login-to-ocp"\n')
    env = {**os.environ, "HOME": str(tmp_path), "ENV_TARGET": "cpd", "ENV_SETUP_QUIET": "1", "IR_IN_RUNNER": "1"}
    probe = f'source {tmp_path}/scripts/source_env_setup.sh; print -r -- "$OC_LOGIN|$CPDM_OC_LOGIN"'
    result = subprocess.run(["zsh", "-c", probe], capture_output=True, text=True, env=env, check=False)
    assert result.stdout.strip().split("\n")[-1] == "oc whoami >/dev/null|oc whoami >/dev/null", result.stderr


def test_env_loads_without_a_cp4d_config(tmp_path):
    """A non-CP4D slot's snapshot holds only its own config."""
    (tmp_path / "scripts").mkdir()
    (tmp_path / "scripts/source_env_setup.sh").write_text((REPO / "scripts/source_env_setup.sh").read_text())
    cfg = tmp_path / "configs/other_config"
    cfg.mkdir(parents=True)
    (cfg / "other_vars.sh").write_text("export OTHER_LOADED=yes\n")
    env = {**os.environ, "HOME": str(tmp_path), "ENV_TARGET": "other", "ENV_SETUP_QUIET": "1"}
    probe = f'source {tmp_path}/scripts/source_env_setup.sh; print -r -- "loaded=$OTHER_LOADED"'
    result = subprocess.run(["zsh", "-c", probe], capture_output=True, text=True, env=env, check=False)
    assert "loaded=yes" in result.stdout, result.stderr


def test_handoff_works_through_a_symlinked_repo_path(fake, tmp_path):
    """macOS /var is a symlink to /private/var; a repo can sit behind one anywhere."""
    (fake / "state").write_text("completed\n")
    link = tmp_path / "linked"
    link.symlink_to(REPO)
    result = zsh(f"""
        ZSH_ARGZERO="{REPO}/{CPD_CHAIN}"
        ir_install_for_chain "${{${{ZSH_ARGZERO:A}}#${{_CP4D_REPO_ROOT:A}}/}}"
        print -r -- "$REPLY"
        """, env={"_CP4D_REPO_ROOT": str(link)})
    assert out(result) == "cpd"


def test_attach_to_an_empty_slot_says_so_and_ends(fake):
    (fake / "bin/oc").write_text(FAKE_OC.replace('*"follow.sh"*"resolve"*) echo 0 ;;', '*"follow.sh"*"resolve"*) exit 10 ;;'))
    result = zsh("ir_attach slot", fake)
    assert result.returncode != 0
    assert "no run to watch" in result.stderr
