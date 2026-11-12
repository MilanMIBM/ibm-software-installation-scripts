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
import tempfile
import textwrap
from pathlib import Path

import pytest
import yaml
from mcm_harness import make_sandbox

REPO = Path(__file__).resolve().parents[1]
HELPERS = REPO / "src/helpers/install_runner_helpers.sh"
CPD_CHAIN = "scripts/install_cloud_pak_for_data/0_x_full_quick_install_script/full_swhub_x_cpd_installprocess.sh"

FAKE_OC = r"""#!/bin/bash
# Logs every call, keeps what `apply` receives, and answers from $FAKE_DIR.
# Each staging stream is unpacked into $FAKE_DIR/pod/<its snapshot folder>, as the pod would.
# With $FAKE_DIR/strict_ns, `apply` refuses an object whose namespace no applied Namespace made
# (or $FAKE_DIR/namespaces lists), as a real cluster does.
d="${FAKE_DIR}"
echo "oc $*" >> "$d/oc.log"
args="$*"
apply() {
  local doc; doc="$(cat)"
  if [ -e "$d/strict_ns" ]; then
    printf '%s\n' "$doc" | awk -v nsfile="$d/namespaces" '
      BEGIN { while ((getline l < nsfile) > 0) have[l] = 1 }
      function flush() {
        if (kind == "Namespace" && name != "") { have[name] = 1; print name >> nsfile }
        else if (ns != "" && !(ns in have) && missing == "") missing = ns
        kind = ""; name = ""; ns = ""; meta = 0
      }
      /^---/ { flush(); next }
      /^kind:/ { kind = $2 }
      /^metadata:/ { meta = 1; next }
      /^[^ #]/ { meta = 0 }
      meta && /^  name:/ { name = $2 }
      meta && /^  namespace:/ { ns = $2 }
      END { flush(); if (missing != "") { print "Error from server (NotFound): namespaces \"" missing "\" not found" > "/dev/stderr"; exit 1 } }
    ' || exit 1
  fi
  { printf '%s\n' "$doc"; echo "---"; } >> "$d/applied.yaml"
}
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
  "apply -f -"*) apply ;;
  "start-build"*) ;;
  "get builds"*) [ -e "$d/builds_fail" ] && exit 1; cat "$d/builds.json" 2>/dev/null || echo '{"items":[]}' ;;
  "get buildconfigs"*) [ -e "$d/bcs_fail" ] && exit 1; cat "$d/bcs.json" 2>/dev/null || echo '{"items":[]}' ;;
  "get clusterrolebinding"*) [ -e "$d/binding_there" ] && echo "clusterrolebinding.rbac.authorization.k8s.io/${3:-x}" ;;
  "get statefulsets -A"*) [ -e "$d/sets_fail" ] && exit 1; cat "$d/sets.json" 2>/dev/null || echo '{"items":[]}' ;;
  "patch configmap ir-status"*)
      [ -e "$d/patch_fail" ] && exit 1
      v="$(sed -nE 's/.*"collected":"([^"]*)".*/\1/p' <<<"$args")"
      [ -n "$v" ] && printf '%s' "$v" > "$d/status.collected" ;;
  "delete buildconfig"*) [ -e "$d/delete_bc_fail" ] && exit 1 ;;
  "delete build"*) [ -e "$d/delete_build_fail" ] && exit 1 ;;
  "delete"*) ;;
  *"follow.sh"*"resolve"*) echo 0 ;;
  *"follow.sh"*) echo "hello from the pod" ;;
  *"collect-list.sh"*) cat "$d/collect_list" 2>/dev/null ;;
  *"tar -cf - -T -"*) cat >/dev/null; cat "$d/collect.tar" ;;
  *"tar -xf"*)
      dest="$(sed -E 's#.* -C /work/snapshots/[^/ ]+/?([^ ]*)$#\1#' <<<"$args")"
      mkdir -p "$d/pod/$dest" && tar -xf - -C "$d/pod/$dest" && echo "${dest:-.}" >> "$d/streams" ;;
  *"cat > /work/runs/"*"/path_map"*) cat > "$d/path_map" ;;
  *"cat > /work/runs"*) cat > "$d/run.env" ;;
  *"cat /work/runs/"*"/run.env"*) cat "$d/pod_run.env" 2>/dev/null ;;
  *"cat /work/runs/"*"/path_map"*) cat "$d/pod_path_map" 2>/dev/null ;;
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
    with tempfile.TemporaryDirectory(prefix="ir-zsh-") as scratch:
        # Teardown and collect keep launch records under ~/cpd-cli: never the real one. With no fakes the
        # helpers get an empty HOME, and an oc, podman or cpd-cli that fails loudly instead of the real one.
        run_env["HOME"] = str(Path(scratch) / "home")
        if fake_dir:
            run_env["PATH"] = f"{fake_dir}/bin:{run_env['PATH']}"
            run_env["FAKE_DIR"] = str(fake_dir)
            run_env["HOME"] = str(Path(fake_dir) / "home")
        else:
            tripwires = Path(scratch) / "bin"
            tripwires.mkdir()
            for tool in ("oc", "kubectl", "podman", "cpd-cli"):
                (tripwires / tool).write_text(f'#!/bin/sh\necho "{tool} must not run in this test: $*" >&2\nexit 99\n')
                (tripwires / tool).chmod(0o755)
            run_env["PATH"] = f"{tripwires}:{run_env['PATH']}"
        run_env.update(env or {})
        script = f'set -euo pipefail\nsource "{HELPERS}"\n{textwrap.dedent(body)}'
        return subprocess.run(["zsh", "-c", script], capture_output=True, text=True, env=run_env, cwd=cwd, timeout=120,
                              check=False)


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


# --- sandboxed hand-off --------------------------------------------------------
# The hand-off, snapshot and collect tests run in a tests/mcm_harness.py sandbox: a
# throwaway repo with the real env_bootstrap.sh, source_env_setup.sh and helper copies,
# its own HOME and a fake config. So they go through the same env load as a real chain,
# and never read the developer's configs/ or the real checkout's files.
SANDBOX_EXTRA = [".gitignore", "pyproject.toml", "src/install_runner", "scripts/install_runner"]
# What a broken env load prints even when the line it was meant to stop at still runs.
LOAD_NOISE = ("command not found", "no such file", "no matches found")
SANDBOX_URL = "https://api.x:6443"
# The cpd config values the runner reads; the harness adds OCP_URL, the logins and OLM_UTILS_IMAGE.
HANDOFF_CONFIG = {"PROJECT_CPD_INST_OPERANDS": "cpd-op", "STG_CLASS_BLOCK": "blk", "STG_CLASS_FILE": "fil",
                  "VERSION": "5.4.0", "INSTALL_RUNNER_CPD_CLI_URL": "https://x/cli.tgz"}
# A chain entry point as the real ones start: env load, dispatch, then its own work.
STAND_IN_CHAIN = textwrap.dedent("""\
    #!/bin/zsh
    set -euo pipefail
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    _b="${SCRIPT_DIR}"; while [[ "${_b}" != "/" && ! -f "${_b}/env_bootstrap.sh" ]]; do _b="$(dirname "${_b}")"; done; source "${_b}/env_bootstrap.sh"; unset _b
    source "${_CP4D_REPO_ROOT}/src/helpers/common_helpers.sh"
    ir_dispatch "$@"
    print -r -- CHAIN-RAN-LOCALLY
    """)


def assert_clean_load(result):
    text = result.stderr.lower()
    for noise in LOAD_NOISE:
        assert noise not in text, result.stderr


@pytest.fixture
def sb():
    """A sandbox repo (a git checkout, so the snapshot can list it) with the runner's fake oc.

    sb.fake holds the fake oc's answers and logs, as the `fake` fixture does. The harness's own
    podman and cpd-cli fakes stay in place and log every call: none may happen on the workstation."""
    with make_sandbox(extra=SANDBOX_EXTRA) as box:
        box.fake = box.root / "fake"
        box.fake.mkdir()
        (box.bin / "oc").write_text(FAKE_OC)
        subprocess.run(["git", "init", "-q"], cwd=box.repo, env=box.env(), check=True, capture_output=True)
        yield box


def no_local_tools(box):
    """Neither cpd-cli nor podman ran on the workstation."""
    return box.calls("podman") == [] and box.calls("cpd-cli") == []


def handoff(box, *args, mode="cluster", env=None, chain=CPD_CHAIN, cluster=None):
    """Runs a stand-in for `chain` in the sandbox. mode=None leaves INSTALL_RUN_MODE out of the config.
    cluster writes the config into configs/clusters/<cluster>/ instead of the flat configs/."""
    config = dict(HANDOFF_CONFIG)
    if mode is not None:
        config["INSTALL_RUN_MODE"] = mode
    box.write_config("cpd", ocp_url=SANDBOX_URL, extra=config, cluster=cluster)
    script = box.repo / chain
    if not script.exists():
        script.parent.mkdir(parents=True, exist_ok=True)
        script.write_text(STAND_IN_CHAIN)
        script.chmod(0o755)
    return box.run_script(chain, env={"FAKE_DIR": box.fake, **(env or {})}, args=args, timeout=120)


def test_handoff_builds_everything_and_never_runs_locally(sb):
    (sb.fake / "state").write_text("completed\n")
    result = handoff(sb, "--from", "cpd", "--skip", "my step")
    assert result.returncode == 0, result.stdout + result.stderr
    assert_clean_load(result)
    assert "CHAIN-RAN-LOCALLY" not in result.stdout
    assert "hello from the pod" in result.stdout
    assert no_local_tools(sb), "cpd-cli or podman ran on the workstation"

    docs = [d for d in yaml.safe_load_all((sb.fake / "applied.yaml").read_text()) if d]
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


def test_run_env_keeps_arguments_exact(sb):
    (sb.fake / "state").write_text("completed\n")
    result = handoff(sb, "--skip", "two words", "--from", "it's", env={"DO_X": "false", "DO_API_TOKEN": "nope"})
    assert result.returncode == 0, result.stderr
    run_env = (sb.fake / "run.env").read_text()
    assert "export DO_X=" in run_env
    assert "nope" not in run_env
    read_back = subprocess.run(["zsh", "-c", f'source {sb.fake}/run.env; print -l -- "${{IR_ARGS[@]}}"; print -r -- "$IR_CHAIN"'],
                               capture_output=True, text=True, check=False)
    assert read_back.stdout.split("\n")[:5] == ["--skip", "two words", "--from", "it's", CPD_CHAIN]


def pod_files(box):
    """Every file the staging streams put in the fake pod's snapshot, snapshot-relative."""
    root = box.fake / "pod"
    return {str(p.relative_to(root)) for p in root.rglob("*") if p.is_file()} if root.exists() else set()


def test_snapshot_has_code_and_config_but_not_secrets_of_others(sb):
    (sb.fake / "state").write_text("completed\n")
    # Things a real checkout holds that must stay home: another product's config, a venv,
    # a mirror workspace, a cluster folder with its logins, and the multi-cluster state file.
    # service_instances/ is the cpd module's second root, so its payloads do go.
    sb.write_config("concert", ocp_url=SANDBOX_URL)
    for rel in (".venv/lib/site.py", "registry_mirror_workspace/inventory.tsv", "service_instances/payload.json",
                "configs/clusters/x/.home/.kube/config", "configs/multi_cluster_management.sh",
                "configs/cp4d_config/.home/.kube/config", "configs/cp4d_config/cpd_vars.sh.bak",
                "configs/cp4d_config/kubecost_workspace/big.bin", "configs/cp4d_config/old.sh.in-cluster-r1"):
        (sb.repo / rel).parent.mkdir(parents=True, exist_ok=True)
        (sb.repo / rel).write_text("stays home\n")
    assert handoff(sb).returncode == 0
    names = pod_files(sb)
    assert CPD_CHAIN in names
    assert "src/helpers/common_helpers.sh" in names
    assert "src/helpers/multi_cluster_helpers.sh" in names
    assert "pyproject.toml" in names, "1.1 and 3.3.1 walk up to it"
    assert "configs/cp4d_config/cpd_vars.sh" in names, "the module's own config is staged"
    assert "service_instances/payload.json" in names, "the module's second root is staged"
    assert not any(n.startswith((".venv/", "registry_mirror_workspace/", ".git/")) for n in names)
    assert not any(n.startswith("configs/") and not n.startswith("configs/cp4d_config/") for n in names)
    assert not any(re.search(r"(^|/)(\.home|\.kube|[^/]*_workspace)(/|$)|\.bak|\.in-cluster-", n) for n in names), names


def test_image_is_reused_when_unchanged(sb):
    (sb.fake / "state").write_text("completed\n")
    assert handoff(sb).returncode == 0
    assert "start-build" not in (sb.fake / "oc.log").read_text()


def test_image_is_built_when_missing(sb):
    (sb.fake / "state").write_text("completed\n")
    (sb.fake / "image_missing").touch()
    assert handoff(sb).returncode == 0
    assert "start-build" in (sb.fake / "oc.log").read_text()
    docs = [d for d in yaml.safe_load_all((sb.fake / "applied.yaml").read_text()) if d]
    build = next(d for d in docs if d["kind"] == "BuildConfig")
    args = {a["name"]: a["value"] for a in build["spec"]["strategy"]["dockerStrategy"]["buildArgs"]}
    assert args == {"BASE_IMAGE": "icr.io/cpopen/cpd/olm-utils-v4:5.4.0.8", "CPD_CLI_URL": "https://x/cli.tgz"}


def builds_json(*builds):
    """Builds of one BuildConfig as `oc get builds -o json` lists them: (name, number, phase)."""
    return json.dumps({"items": [{
        "metadata": {"name": n, "creationTimestamp": f"2026-11-11T10:00:{i:02d}Z",
                     "annotations": {"openshift.io/build.number": str(num), "openshift.io/build.pod-name": f"{n}-build"}},
        "status": {"phase": phase}} for i, (n, num, phase) in enumerate(builds)]})


def test_build_prunes_older_builds_and_keeps_the_newest(fake):
    """L-05: a build leaves older finished Builds (and their pods) of its BuildConfig behind; only
    the newest stays, and one still going is never touched."""
    (fake / "builds.json").write_text(builds_json(("bc-1", 1, "Complete"), ("bc-10", 10, "Complete"),
                                                  ("bc-2", 2, "Failed"), ("bc-3", 3, "Running")))
    result = zsh("_ir_prune_builds bc", fake)
    assert result.returncode == 0, result.stderr
    log = (fake / "oc.log").read_text().splitlines()
    assert "oc get builds -n install-runner-system -l openshift.io/build-config.name=bc -o json" in log
    deleted = [c for c in log if c.startswith("oc delete")]
    assert deleted == ["oc delete build bc-1 -n install-runner-system --ignore-not-found",
                       "oc delete pod bc-1-build -n install-runner-system --ignore-not-found",
                       "oc delete build bc-2 -n install-runner-system --ignore-not-found",
                       "oc delete pod bc-2-build -n install-runner-system --ignore-not-found"], "numbers sort as numbers: bc-10 is newest"
    assert "Removed 2 older build(s) of bc." in result.stderr + result.stdout


def test_build_runs_the_prune_and_a_failed_prune_only_warns(sb):
    (sb.fake / "state").write_text("completed\n")
    (sb.fake / "image_missing").touch()
    (sb.fake / "builds_fail").touch()
    result = handoff(sb)
    assert result.returncode == 0, result.stdout + result.stderr
    log = (sb.fake / "oc.log").read_text()
    assert log.index("start-build") < log.index("get builds"), "pruned after the build"
    assert "Could not list the builds of install-runner-" in result.stderr
    assert "hello from the pod" in result.stdout, "the launch went on"


def test_a_failed_build_delete_only_warns(fake):
    (fake / "builds.json").write_text(builds_json(("bc-1", 1, "Complete"), ("bc-2", 2, "Complete")))
    (fake / "delete_build_fail").touch()
    result = zsh("_ir_prune_builds bc", fake)
    assert result.returncode == 0, result.stderr
    assert "Could not delete the old build bc-1" in result.stderr
    assert "delete pod" not in (fake / "oc.log").read_text()


def test_nothing_to_prune(fake):
    (fake / "builds.json").write_text(builds_json(("bc-1", 1, "Complete")))
    result = zsh("_ir_prune_builds bc", fake)
    assert result.returncode == 0, result.stderr
    assert "oc delete" not in (fake / "oc.log").read_text()
    assert "Removed" not in result.stderr + result.stdout


# --- C3: BuildConfigs of older image tags ---------------------------------------------------------------------
def bcs_json(*bcs):
    """BuildConfigs as `oc get buildconfigs -o json` lists them: (name, tag, created second)."""
    return json.dumps({"items": [{
        "metadata": {"name": n, "creationTimestamp": f"2026-11-11T10:00:{t:02d}Z"},
        "spec": {"output": {"to": {"kind": "ImageStreamTag", "name": f"install-runner:{tag}"}}}} for n, tag, t in bcs]})


def all_builds_json(*builds):
    """Builds of several BuildConfigs: (name, build config, created second, phase)."""
    return json.dumps({"items": [{
        "metadata": {"name": n, "creationTimestamp": f"2026-11-11T10:00:{t:02d}Z",
                     "labels": {"openshift.io/build-config.name": bc},
                     "annotations": {"openshift.io/build.pod-name": f"{n}-build"}},
        "status": {"phase": phase}} for n, bc, t, phase in builds]})


def sets_json(*sets):
    """Slot StatefulSets: (namespace, image tag of the runner container)."""
    reg = "image-registry.openshift-image-registry.svc:5000/install-runner-system/install-runner"
    return json.dumps({"items": [{
        "metadata": {"name": "install-runner", "namespace": ns},
        "spec": {"template": {"spec": {"containers": [{"name": "runner", "image": f"{reg}:{tag}"},
                                                      {"name": "swhcc", "image": "cp.icr.io/cp/cpd/olm-utils-premium-v4@sha256:x"}]}}}}
        for ns, tag in sets]})


def prune_scene(fake):
    # e was made first but built last, so it is the newest by use; d is the current one.
    (fake / "bcs.json").write_text(bcs_json(("bc-a", "a", 1), ("bc-b", "b", 2), ("bc-c", "c", 3), ("bc-d", "d", 4),
                                            ("bc-e", "e", 0)))
    (fake / "builds.json").write_text(all_builds_json(("bc-a-1", "bc-a", 1, "Complete"), ("bc-b-1", "bc-b", 2, "Running"),
                                                      ("bc-c-1", "bc-c", 3, "Complete"), ("bc-c-2", "bc-c", 3, "Failed"),
                                                      ("bc-e-1", "bc-e", 5, "Complete")))
    # A slot runs tag a; a StatefulSet outside install-runner-* namespaces protects nothing.
    (fake / "sets.json").write_text(sets_json(("install-runner-cpd-x", "a"), ("openshift-other", "c")))


def deletes(fake):
    return [c for c in (fake / "oc.log").read_text().splitlines() if c.startswith("oc delete")]


def test_older_build_configs_are_pruned_but_never_a_live_or_used_one(fake):
    prune_scene(fake)
    result = zsh("_ir_prune_build_configs bc-d", fake)
    assert result.returncode == 0, result.stderr
    log = (fake / "oc.log").read_text().splitlines()
    assert "oc get buildconfigs -n install-runner-system -l app.kubernetes.io/managed-by=install-runner -o json" in log
    assert "oc get statefulsets -A -l app.kubernetes.io/managed-by=install-runner -o json" in log
    assert deletes(fake) == ["oc delete build bc-c-1 -n install-runner-system --ignore-not-found",
                             "oc delete pod bc-c-1-build -n install-runner-system --ignore-not-found",
                             "oc delete build bc-c-2 -n install-runner-system --ignore-not-found",
                             "oc delete pod bc-c-2-build -n install-runner-system --ignore-not-found",
                             "oc delete buildconfig bc-c -n install-runner-system --ignore-not-found"], \
        "e and d are the newest two, b has a build running, a slot runs a"
    assert not any("istag" in c or "imagestream" in c for c in log), "image tags stay"
    assert "Removed 1 older runner BuildConfig(s)" in result.stdout


def test_the_current_build_config_is_kept_even_when_it_is_old(fake):
    prune_scene(fake)
    result = zsh("IR_KEEP_IMAGE_TAGS=1 _ir_prune_build_configs bc-c", fake)
    assert result.returncode == 0, result.stderr
    assert [c.split()[3] for c in deletes(fake) if c.startswith("oc delete buildconfig")] == ["bc-d"]


@pytest.mark.parametrize("broken", ["bcs_fail", "builds_fail", "sets_fail"])
def test_a_list_that_cannot_be_read_prunes_nothing(fake, broken):
    prune_scene(fake)
    (fake / broken).touch()
    result = zsh("_ir_prune_build_configs bc-d", fake)
    assert result.returncode == 0, result.stderr
    assert "Could not list the runner's older BuildConfigs" in result.stderr
    assert deletes(fake) == []


def test_a_failed_build_config_delete_only_warns(fake):
    prune_scene(fake)
    (fake / "delete_bc_fail").touch()
    result = zsh("_ir_prune_build_configs bc-d", fake)
    assert result.returncode == 0, result.stderr
    assert "Could not delete the old BuildConfig bc-c" in result.stderr
    assert "Removed" not in result.stdout


def test_a_failed_build_delete_keeps_its_build_config(fake):
    """A BuildConfig whose Builds could not all go stays, so none is left without its config."""
    prune_scene(fake)
    (fake / "delete_build_fail").touch()
    result = zsh("_ir_prune_build_configs bc-d", fake)
    assert result.returncode == 0, result.stderr
    assert "Could not delete the old BuildConfig bc-c (or one of its builds)" in result.stderr
    assert not any(c.startswith("oc delete buildconfig") for c in deletes(fake)), deletes(fake)
    assert "Removed" not in result.stdout


def test_a_build_prunes_older_build_configs_after_its_own_builds(sb):
    (sb.fake / "state").write_text("completed\n")
    (sb.fake / "image_missing").touch()
    result = handoff(sb)
    assert result.returncode == 0, result.stdout + result.stderr
    log = (sb.fake / "oc.log").read_text()
    assert log.index("start-build") < log.index("get builds -n install-runner-system -l") < log.index("get buildconfigs")
    assert "Could not" not in result.stderr


def test_failed_run_returns_failure(sb):
    (sb.fake / "state").write_text("failed\n")
    result = handoff(sb)
    assert result.returncode != 0
    assert "resume" in result.stderr


# --- mode switch ---------------------------------------------------------------
@pytest.mark.parametrize("mode,env", [(None, {}), ("local", {}), ("cluster", {"IR_IN_RUNNER": "1"})])
def test_dispatch_leaves_the_chain_alone(sb, mode, env):
    result = handoff(sb, mode=mode, env=env)
    assert result.returncode == 0, result.stderr
    assert_clean_load(result)
    assert "CHAIN-RAN-LOCALLY" in result.stdout, result.stderr
    assert not (sb.fake / "oc.log").exists()
    assert no_local_tools(sb)


def test_bad_mode_is_refused(sb):
    result = handoff(sb, mode="pod")
    assert result.returncode != 0
    assert "INSTALL_RUN_MODE" in result.stderr


@pytest.mark.parametrize("flag", ["--list-steps", "--help", "-h"])
def test_questions_about_a_chain_stay_local(sb, flag):
    assert "CHAIN-RAN-LOCALLY" in handoff(sb, flag).stdout
    assert not (sb.fake / "oc.log").exists()


def test_chain_without_a_module_is_refused_not_run_locally(sb):
    # Under scripts/install_cloud_pak_for_data/, so it loads the cpd config like a real CP4D script.
    result = handoff(sb, chain="scripts/install_cloud_pak_for_data/other.sh")
    assert result.returncode != 0
    assert "CHAIN-RAN-LOCALLY" not in result.stdout
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


def runner_knobs_in_template():
    """(name, default) pairs of the INSTALL_RUNNER_* knob list in the cpd_vars.sh template."""
    text = (REPO / "src/helpers/config_file_jinja2_templates/cpd_variable_template.sh.j2").read_text()
    return dict(re.findall(r'\("(INSTALL_RUNNER_[A-Z_]+)", "([^"]*)"\)', text))


def fanout_kept_runner_names():
    """The INSTALL_RUNNER_* names the multi-cluster fan-out passes to every cluster (one-run switches)."""
    text = (REPO / "src/helpers/multi_cluster_helpers.sh").read_text()
    return set(re.search(r"_mcm_ir_names:#\(([^)]*)\)", text).group(1).split("|"))


def test_every_runner_knob_is_in_cpd_vars_or_a_one_run_switch():
    """A knob the runner reads is either a per-cluster setting, commented at its default in cpd_vars.sh
    (and forgotten by the fan-out, so each cluster reads its own), or a one-run switch the fan-out
    keeps. Never both, never neither, and the fan-out keeps no name nothing reads."""
    read, defaults = set(), []
    for path in [*(REPO / "src").rglob("*"), *(REPO / "scripts").rglob("*")]:
        if path.is_file() and path.suffix in ("", ".sh", ".tmpl", ".conf"):
            text = path.read_text(errors="ignore")
            read |= set(re.findall(r"\$\{(INSTALL_RUNNER_[A-Z_]*[A-Z])", text))
            defaults += re.findall(r"\$\{(INSTALL_RUNNER_[A-Z_]+):-([^}$]*)\}", text)
    knobs, kept = runner_knobs_in_template(), fanout_kept_runner_names()
    assert not knobs.keys() & kept
    assert read - knobs.keys() - kept == set(), "a knob missing from cpd_vars.sh and the fan-out list"
    assert kept <= read, "the fan-out keeps a name nothing reads"
    for name in ("INSTALL_RUNNER_ROLLOUT_TIMEOUT", "INSTALL_RUNNER_SWHCC_PULL_SECRET", "INSTALL_RUNNER_SWHCC_MEMORY_LIMIT"):
        assert name in knobs
    # Where the code has a literal default, the template shows the same one.
    checked = {name for name, default in defaults if default and name in knobs}
    assert {"INSTALL_RUNNER_ROLLOUT_TIMEOUT", "INSTALL_RUNNER_SWHCC_MEMORY_LIMIT", "INSTALL_RUNNER_TTY_SIZE"} <= checked
    for name, default in defaults:
        if default and name in knobs:
            assert knobs[name] == default, name


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
def collect_repo(sb):
    """A demo module with its own config in the sandbox, collected through x_install_runner.sh."""
    (sb.repo / "src/install_runner/installs/demo.conf").write_text(
        'INSTALL_ID="demo"\nINSTALL_ENV_TARGET="demo"\nRUNNER_COLLECT_ROOTS="DEMO_CONFIG_DIR:configs/demo_config"\n')
    local = sb.repo / "configs/demo_config"
    local.mkdir(parents=True)
    (local / "demo_vars.sh").write_text(f'export OCP_URL="{SANDBOX_URL}"\nexport OC_LOGIN="oc login {SANDBOX_URL} --token=fake"\n')
    (local / "unchanged_here.sh").write_text("old\n")
    (local / "edited_here.sh").write_text("my edit\n")
    # No configs/cp4d_config: a flat load of another product needs none (gap X25).
    pod = sb.root / "pod"
    (pod / "configs/demo_config").mkdir(parents=True)
    for name in ("unchanged_here.sh", "edited_here.sh", "new.sh"):
        (pod / "configs/demo_config" / name).write_text("from pod\n")
    with tarfile.open(sb.fake / "collect.tar", "w") as tar:
        tar.add(pod / "configs", arcname="configs")
    (sb.fake / "collect_list").write_text("".join([
        f"{sha('old' + chr(10))}\t{sha('from pod' + chr(10))}\tconfigs/demo_config/unchanged_here.sh\n",
        f"{sha('old' + chr(10))}\t{sha('from pod' + chr(10))}\tconfigs/demo_config/edited_here.sh\n",
        f"-\t{sha('from pod' + chr(10))}\tconfigs/demo_config/new.sh\n"]))
    (sb.fake / "state").write_text("completed\n")
    # The run record the pod keeps: staged from the flat layout.
    (sb.fake / "pod_run.env").write_text(f"IR_RUN_ID=run1\nIR_CLUSTER_URL='{SANDBOX_URL}'\nIR_SOURCE_CLUSTER=''\nIR_LAYOUT=flat\n")
    (sb.fake / "pod_path_map").write_text("configs/demo_config=DEMO_CONFIG_DIR:configs/demo_config\n")
    return local


def collect(box, *args):
    return box.run_script("scripts/install_runner/x_install_runner.sh",
                          args=("collect", "--install", "demo", "--slot", "slot", *args),
                          env={"FAKE_DIR": box.fake}, timeout=120)


def test_collect_takes_changes_and_never_overwrites_local_edits(sb, collect_repo):
    result = collect(sb)
    assert result.returncode == 0, result.stdout + result.stderr
    assert_clean_load(result)
    assert (collect_repo / "unchanged_here.sh").read_text() == "from pod\n"
    assert (collect_repo / "new.sh").read_text() == "from pod\n"
    assert (collect_repo / "edited_here.sh").read_text() == "my edit\n"
    assert (collect_repo / "edited_here.sh.in-cluster-run1").read_text() == "from pod\n"
    assert "Kept your local" in result.stderr
    assert "touch /work/current/collected" in (sb.fake / "oc.log").read_text()
    assert no_local_tools(sb)


def test_collect_waits_for_the_run(sb, collect_repo):
    (sb.fake / "state").write_text("running\n")
    assert collect(sb).returncode != 0
    assert (collect_repo / "unchanged_here.sh").read_text() == "old\n"
    assert collect(sb, "--force").returncode == 0


def test_teardown_right_after_collect_needs_no_supervisor_report(sb, collect_repo):
    """L-04: collect marks ir-status itself, so a teardown at once is not refused while the
    supervisor's next report (up to a heartbeat later) is still to come."""
    (sb.fake / "status.state").write_text("completed")
    (sb.fake / "status.collected").write_text("no")
    result = collect(sb)
    assert result.returncode == 0, result.stdout + result.stderr
    calls = (sb.fake / "oc.log").read_text().splitlines()
    touch = next(i for i, c in enumerate(calls) if "touch /work/current/collected" in c)
    patch = next(i for i, c in enumerate(calls) if c.startswith("oc patch configmap ir-status"))
    assert touch < patch, "the marker the supervisor reads comes first, so its next report says yes too"
    assert calls[patch] == """oc patch configmap ir-status -n install-runner-slot --type merge -p {"data":{"collected":"yes"}}"""
    assert (sb.fake / "status.collected").read_text() == "yes", "the supervisor's format: yes"
    teardown = sb.run_script("scripts/install_runner/x_install_runner.sh",
                             args=("teardown", "--install", "demo", "--slot", "slot"), env={"FAKE_DIR": sb.fake}, timeout=120)
    assert teardown.returncode == 0, teardown.stdout + teardown.stderr
    assert "isn't collected" not in teardown.stderr
    assert "delete namespace install-runner-slot" in (sb.fake / "oc.log").read_text()


def test_collect_goes_on_when_the_status_mark_fails(sb, collect_repo):
    (sb.fake / "patch_fail").touch()
    result = collect(sb)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "Could not mark slot slot collected" in result.stderr
    assert "touch /work/current/collected" in (sb.fake / "oc.log").read_text()


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
# Strict, as run-attempt.sh runs a chain, and through the real env_bootstrap.sh, so a load
# that breaks half way (a missing helper, an empty glob) fails here instead of passing.
def test_runner_login_is_a_session_check():
    with make_sandbox() as box:
        box.write_config("cpd", ocp_url=SANDBOX_URL)
        result = box.run_zsh('source "${0:A:h}/env_bootstrap.sh"\nprint -r -- "$OC_LOGIN|$CPDM_OC_LOGIN"\n',
                             env={"ENV_TARGET": "cpd", "ENV_SETUP_QUIET": "1", "IR_IN_RUNNER": "1"})
    assert result.returncode == 0, result.stdout + result.stderr
    assert_clean_load(result)
    assert result.stdout.strip().split("\n")[-1] == "oc whoami >/dev/null|oc whoami >/dev/null", result.stderr


def test_env_loads_without_a_cp4d_config():
    """A non-CP4D slot's snapshot holds only its own config."""
    with make_sandbox() as box:
        other = box.repo / "configs/other_config/other_vars.sh"
        other.parent.mkdir(parents=True)
        other.write_text("export OTHER_LOADED=yes\n")
        result = box.run_zsh('source "${0:A:h}/env_bootstrap.sh"\nprint -r -- "loaded=$OTHER_LOADED"\n',
                             env={"ENV_TARGET": "other", "ENV_SETUP_QUIET": "1", "IR_IN_RUNNER": "1"})
    assert result.returncode == 0, result.stdout + result.stderr
    assert_clean_load(result)
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


# --- end-to-end harness --------------------------------------------------------
E2E = REPO / "tests/install_runner_e2e.sh"


def test_e2e_script_parses():
    result = subprocess.run(["zsh", "-n", str(E2E)], capture_output=True, text=True, check=False)
    assert result.returncode == 0, result.stderr


def test_e2e_repo_copy_loads_its_env(tmp_path):
    """The full e2e needs a built image (IR_TEST_IMAGE). Its throwaway repo is checked here: the
    demo chain must get through the real env load and dispatch, which a fixed copy list once broke
    (rc 127 on a helper the load sources)."""
    prep, home, bin_dir = tmp_path / "e2e", tmp_path / "home", tmp_path / "bin"
    for folder in (prep, home, bin_dir):
        folder.mkdir()
    for tool in ("oc", "podman", "cpd-cli"):
        (bin_dir / tool).write_text(f'#!/bin/sh\necho "{tool} $*" >> "{tmp_path}/tripwire"\nexit 0\n')
        (bin_dir / tool).chmod(0o755)
    env = {"PATH": f"{bin_dir}:/usr/bin:/bin", "HOME": str(home), "TMPDIR": str(tmp_path), "_CP4D_PREP_DONE": "1",
           "LOGNAME": "e2e-tester", "USER": "e2e-tester"}
    made = subprocess.run(["zsh", str(E2E), "--prepare-only", str(prep)], capture_output=True, text=True, env=env,
                          timeout=120, check=False)
    assert made.returncode == 0, made.stdout + made.stderr
    root = prep / "repo"
    for rel in ("env_bootstrap.sh", "src/helpers/multi_cluster_helpers.sh", "src/install_runner/installs/e2e.conf",
                "scripts/install_runner/x_install_runner.sh", "scripts/e2e/chain.sh"):
        assert (root / rel).is_file(), rel
    result = subprocess.run(["zsh", "scripts/e2e/chain.sh", "--list-steps"], cwd=root, capture_output=True,
                            text=True, env=env, timeout=120, check=False)
    assert result.returncode == 0, result.stdout + result.stderr
    assert_clean_load(result)
    assert "step one" in result.stdout + result.stderr
    assert not (tmp_path / "tripwire").exists()
