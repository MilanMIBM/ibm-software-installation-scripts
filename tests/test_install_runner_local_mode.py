"""Local mode is byte-identical: the in-cluster runner changes nothing while INSTALL_RUN_MODE is unset.

Plan: .claude/plans/in-cluster-install-runner-plan.md G1, and
.claude/plans/multi-cluster-management/in-cluster-install-addon/in-cluster-install-addon-plan.md §12 (X21).

Every chain entry point that calls `ir_dispatch "$@"` (git grep in scripts/) runs in a throwaway copy of
the repo with INSTALL_RUN_MODE unset, a temporary HOME and fake tools first on PATH. Each fake logs its
call (argv, cwd, KUBECONFIG, OLM_UTILS_CONTAINER) and fails with rc 1, so nothing reaches a cluster,
podman or the network, and a chain stops at its first login or first cluster call. The one exception:
curl answers 401 for a registry's /v2/, so the mirror chains get past their reachability probe. The
mirror config's registry host ends in .internal, which the registry classifier reads without a DNS
lookup. Per chain:

  list-steps   <chain> --list-steps
  default      <chain> with no arguments, stopped early by the failing fakes

in two layouts:

  flat         configs/<product>/ with multi-cluster management off
  pinned       configs/clusters/itz-a/<product>/, mode on, itz-a current (idle watcher off)

The exit code, normalised stdout and stderr, and the call log are compared with
tests/golden/install_runner_local_mode.txt. stderr carries the [ENV] summary and every h_warn and h_error
line; zsh's own error lines carry script line numbers, which are normalised to <L>. The golden is
captured from commit c204519 (main before the runner was cherry-picked): --write-golden extracts
`git archive c204519` into a temporary folder and runs this same harness against it.

    .venv/bin/python tests/test_install_runner_local_mode.py --write-golden

So a green run means the runner cherry-pick changed no local behaviour of these chains. The template
holds tracked and new, not ignored, files, as the runner stages them, so an uncommitted phase is tested
as it stands.

What this does not cover (no fake can take a chain further without a cluster):
  - Every step after a chain's first `oc` call, login or network probe. With the fakes failing, the
    default runs stop there; what they do cover is the env load, ir_dispatch, step parsing and planning,
    and the steps that run before the first cluster call. Where each chain stops:
      CP4D full, 2.0, 4.0, Confluent: the first step's OC_LOGIN. 3.1: each step's login fails
      in turn, and the chain still ends rc 0 (as it did before the runner).
      Control Center, Flink: their 1.0 prep step stops on settings this minimal config lacks,
      before any cluster call.
      2.2: its own OC_LOGIN, before step parsing, so --list-steps stops there too.
      5.x StreamSets: rejects --list-steps ("unknown argument"); the default run stops at
      "CPD_URL is not set" (both checked through stderr), before any cluster call.
      DataStax MC: 0.1's `helm version`. Concert full: 0.1's installer download (curl).
      Concert 2.3: every provisioner skips (none selected) and it ends rc 0.
      Concert 3: 3.0's render, before any cluster call. Concert 5: Optimize not selected, rc 0.
      Mirror full: --list-steps plans every step; the default run stops in 0.1 detect (no push
      credentials). 4.x patch update: --list-steps plans; 4.0 plan stops (cpd not in MIRROR_INSTALLS).
  - INSTALL_RUN_MODE=cluster (tests/test_install_runner.py) and IR_IN_RUNNER=1 (T1 in
    tests/test_multi_cluster_management.py, and the runner env tests).
  - Fan-out runs (--all-clusters, --target-clusters): tests/test_mcm_fanout.py.
"""

import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
GOLDEN = Path(__file__).resolve().parent / "golden" / "install_runner_local_mode.txt"
SOURCE_COMMIT = "c204519"

CLUSTER = "itz-a"
URL = "https://api.itz-a.example.com:6443"
IMAGE = "icr.io/cpopen/cpd/olm-utils-v4:5.4.0.8"
MODES = {"list-steps": ("--list-steps",), "default": ()}
LAYOUTS = ("flat", "pinned")
# Anything that could reach a cluster, the podman VM, the network, the keychain or another program.
FAKE_TOOLS = ("oc", "podman", "cpd-cli", "kubectl", "helm", "curl", "wget", "skopeo", "oc-mirror", "docker",
              "ssh", "scp", "sudo", "open", "security", "osascript", "cloudctl", "ibmcloud", "confluent", "aws")
# Not copied into the throwaway repo: tests, and anything a checkout keeps that is not code.
SKIP_TOP = ("tests", ".claude", ".venv", "configs", "service_instances", ".git")
RUN_TIMEOUT = 90

# One config per product: path -> (drives olm-utils, values its chains check before they start).
# Products that drive olm-utils get its image and a cpd-cli login too.
CONFIGS = {
    "cp4d_config/cpd_vars.sh": (True, {
        "PROJECT_CPD_INST_OPERANDS": "cpd-operands", "PROJECT_CPD_INST_OPERATORS": "cpd-operators",
        "CPD_COMPONENTS": "cpfs,cpd_platform", "IMAGE_PULL_PREFIX": "cp.icr.io", "IMAGE_PULL_SECRET": "ibm-entitlement-key",
        "STG_CLASS_BLOCK": "blk", "STG_CLASS_FILE": "fil"}),
    "cp4d_config/swhub_control_center/swhub_control_center_vars.sh": (True, {}),
    "concert_config/concert_vars.sh": (False, {
        "CONCERT_VERSION": "2.2.0", "CONCERT_RELEASE_TAG": "v2.2.0", "CONCERT_ARCHIVE": "concert.tgz",
        "PROJECT_CONCERT_INSTALLER": "concert-installer", "PROJECT_CONCERT_DATASTORES": "concert-datastores",
        "CONCERT_IMAGE_SOURCE": "entitled"}),
    "confluent_platform_config/confluent_vars.sh": (False, {
        "PROJECT_CONFLUENT_SERVER": "confluent", "PROJECT_CONFLUENT_FLINK": "flink"}),
    "datastax_mc_config/datastax_mc_vars.sh": (False, {
        "MC_VERSION": "1.0.0", "MC_RELEASE_NAME": "mission-control", "MC_NAMESPACE": "mission-control",
        "MC_PLANE": "control", "MC_SCC_MODE": "restricted-v2"}),
    "registry_mirror_config/registry_mirror_vars.sh": (False, {
        "MIRROR_CONFIG_VERSION": "1", "MIRROR_REGISTRY_ROOT": "registry.mirror.internal:5000", "MIRROR_IMAGE_SOURCE": "private"}),
}

FAKE = textwrap.dedent("""\
    #!/bin/zsh -f
    # Fake for the local-mode harness: log the call, then fail like a tool with no cluster.
    print -r -- "${0:t}${@:+ ${(j: :)${(q-)@}}} | cwd=${PWD} | KUBECONFIG=${KUBECONFIG-} | OLM_UTILS_CONTAINER=${OLM_UTILS_CONTAINER-}" >> "@@LOG@@"
    # A registry's /v2/ answers 401 (there, needs a login), so the mirror chains' reachability probe
    # (private_registry_helpers.sh) passes and they reach step planning. Every other call fails.
    if [[ "${0:t}" == curl && "${@[-1]-}" == */v2/ ]]; then print -rn -- 401; exit 0; fi
    exit 1
    """)


def chains(root=REPO):
    """Every chain entry point with an ir_dispatch call, from the current tree."""
    # --untracked: phases are built and reviewed uncommitted, and a new chain must be in the golden too.
    out = subprocess.run(["git", "grep", "--untracked", "-l", 'ir_dispatch "$@"', "--", "scripts"], cwd=root,
                         capture_output=True, text=True, check=True)
    return sorted(out.stdout.split())


def code_files(tree):
    """Repo-relative code files of a tree: tracked and new, not ignored, files of a git checkout (as the
    runner stages them), else every file (git archive). Deleted tracked files drop out at is_file()."""
    if (tree / ".git").exists():
        out = subprocess.run(["git", "ls-files", "-z", "-c", "-o", "--exclude-standard"], cwd=tree,
                             capture_output=True, check=True).stdout
        names = [n.decode() for n in out.split(b"\0") if n]
    else:
        names = [str(p.relative_to(tree)) for p in tree.rglob("*") if p.is_file() or p.is_symlink()]
    return sorted(n for n in names if Path(n).parts[0] not in SKIP_TOP and (tree / n).is_file())


def make_template(tree, dest):
    """A copy of the tree's code at dest, run through once per chain run."""
    for rel in code_files(tree):
        target = dest / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(tree / rel, target)


def write_configs(repo, layout):
    base = repo / "configs" / ("clusters/" + CLUSTER if layout == "pinned" else "")
    for rel, (olm, values) in CONFIGS.items():
        lines = [f'export OCP_URL="{URL}"', f'export OC_LOGIN="oc login {URL} --token=fake-token"',
                 'export VERSION="5.4.0"', 'export PATCH_ID="8"']
        if olm:
            lines += [f'export OLM_UTILS_IMAGE="{IMAGE}"',
                      f'export CPDM_OC_LOGIN="cpd-cli manage login-to-ocp --server={URL} --token=fake-token"']
        lines += [f'export {key}="{value}"' for key, value in values.items()]
        (base / rel).parent.mkdir(parents=True, exist_ok=True)
        (base / rel).write_text("\n".join(lines) + "\n")
    if layout == "pinned":
        (base / ".cluster").write_text(f'NAME="{CLUSTER}"\nOCP_URL="{URL}"\nCREATED="2026-11-09T00:00:00Z"\n')
        (repo / "configs/multi_cluster_management.sh").write_text(textwrap.dedent(f"""\
            export MULTI_CLUSTER_MANAGEMENT="true"
            export MCM_CLUSTERS="{CLUSTER}"
            export MCM_CURRENT_CLUSTER="{CLUSTER}"
            export APPLY_TO_ALL="false"
            export MCM_TARGET_CLUSTERS=""
            export MCM_CONTAINER_IDLE_TIMEOUT_MINUTES="0"
            """))


def normalize(text, root):
    text = text.replace(str(root), "<ROOT>")
    text = re.sub(r"\d{4}-\d\d-\d\d[T ]\d\d:\d\d:\d\d(\.\d+)?Z?", "<TIME>", text)
    text = re.sub(r"\d{8}T\d{6}Z?", "<TIME>", text)
    text = re.sub(r"\b\d\d:\d\d:\d\d\b", "<TIME>", text)
    # One rule for "3s", "1.5s" and "1m 3s": a run over a minute must not read as a change.
    text = re.sub(r"\b(\d+m ?)?\d+(\.\d+)?s\b", "<N>s", text)
    return text


def normalize_stderr(text, root):
    """normalize(), plus zsh's script line numbers (<script>:<line>: ...), which move with any edit."""
    return re.sub(r":\d+:", ":<L>:", normalize(text, root))


def run_one(template, chain, mode, layout):
    """rc, normalised stdout, call log and stderr for one chain run in a fresh copy of template."""
    with tempfile.TemporaryDirectory(prefix="ir-local-") as tmp:
        root = Path(tmp).resolve()
        repo, home, bin_dir, tmpdir = root / "repo", root / "home", root / "bin", root / "tmp"
        shutil.copytree(template, repo, symlinks=True)
        for folder in (home / "cpd-cli", bin_dir, tmpdir):
            folder.mkdir(parents=True)
        log = root / "calls.log"
        log.touch()
        body = FAKE.replace("@@LOG@@", str(log))
        for path in [bin_dir / t for t in FAKE_TOOLS] + [home / "cpd-cli/cpd-cli"]:
            path.write_text(body)
            path.chmod(0o755)
        write_configs(repo, layout)
        env = {"PATH": f"{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home), "TMPDIR": str(tmpdir),
               "LOGNAME": "ir-tester", "USER": "ir-tester", "LANG": "en_US.UTF-8", "TERM": "dumb",
               "_CP4D_PREP_DONE": "1"}
        try:
            result = subprocess.run(["zsh", str(repo / chain), *MODES[mode]], cwd=repo, env=env,
                                    stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=RUN_TIMEOUT, check=False)
            rc, stdout, stderr = str(result.returncode), result.stdout, result.stderr
        except subprocess.TimeoutExpired as exc:
            # A hang is a result too; the partial output comes back as bytes even with text=True.
            def text(partial):
                return partial.decode(errors="replace") if isinstance(partial, bytes) else (partial or "")
            rc, stdout, stderr = "timeout", text(exc.stdout), text(exc.stderr)
        calls = log.read_text()
        return rc, normalize(stdout, root), normalize(calls, root), normalize_stderr(stderr, root)


def section(chain, mode, layout, rc, stdout, calls, stderr):
    return "\n".join([f"### {chain} :: {mode} :: {layout}", f"rc={rc}", "--- stdout", stdout.rstrip("\n"),
                      "--- stderr", stderr.rstrip("\n"), "--- calls", calls.rstrip("\n"), ""])


def golden_header(label):
    return f"# Local-mode chain runs (tests/test_install_runner_local_mode.py). Captured from {label}."


def capture(tree, label, chain_list=None):
    """The whole golden text for a tree; label names the tree in the header."""
    chain_list = chain_list or chains()
    parts = [golden_header(label), ""]
    with tempfile.TemporaryDirectory(prefix="ir-local-template-") as tmp:
        template = Path(tmp) / "repo"
        make_template(tree, template)
        total = len(chain_list) * len(MODES) * len(LAYOUTS)
        done = 0
        for chain in chain_list:
            for mode in MODES:
                for layout in LAYOUTS:
                    done += 1
                    print(f"[{done}/{total} {done * 100 // total}%] {chain} {mode} {layout}", file=sys.stderr)
                    parts.append(section(chain, mode, layout, *run_one(template, chain, mode, layout)))
    return "\n".join(parts)


def golden_sections():
    text = GOLDEN.read_text()
    found = {}
    for block in re.split(r"(?m)^(?=### )", text):
        if block.startswith("### "):
            key = tuple(block.splitlines()[0][4:].split(" :: "))
            found[key] = block
    return found


@pytest.fixture(scope="module")
def template():
    with tempfile.TemporaryDirectory(prefix="ir-local-template-") as tmp:
        dest = Path(tmp) / "repo"
        make_template(REPO, dest)
        yield dest


def test_golden_covers_every_dispatching_chain():
    keys = golden_sections()
    expected = {(c, m, l) for c in chains() for m in MODES for l in LAYOUTS}
    assert set(keys) == expected


def test_golden_was_captured_from_the_pre_runner_commit():
    """A golden captured from any other tree would only compare the tree with itself."""
    assert GOLDEN.read_text().splitlines()[0] == golden_header(f"git archive {SOURCE_COMMIT}")


def test_normalize_hides_durations_of_any_length():
    assert normalize("done in 3s, 1.5s, 1m 3s and 12m4s", Path("/x")) == "done in <N>s, <N>s, <N>s and <N>s"


def test_template_takes_new_untracked_files(tmp_path):
    """Phases are reviewed uncommitted: a new helper must be in the template, or the runs test a mixed tree."""
    clone = tmp_path / "clone"
    subprocess.run(["git", "init", "-q", str(clone)], check=True)
    (clone / "src/helpers").mkdir(parents=True)
    (clone / "src/helpers/tracked.sh").write_text("x\n")
    (clone / ".gitignore").write_text("ignored.sh\n")
    subprocess.run(["git", "add", "src/helpers/tracked.sh", ".gitignore"], cwd=clone, check=True)
    (clone / "src/helpers/zz_new_helper.sh").write_text("y\n")
    (clone / "src/helpers/ignored.sh").write_text("z\n")
    names = code_files(clone)
    assert "src/helpers/tracked.sh" in names and "src/helpers/zz_new_helper.sh" in names
    assert "src/helpers/ignored.sh" not in names


@pytest.mark.parametrize("layout", LAYOUTS)
@pytest.mark.parametrize("mode", list(MODES))
@pytest.mark.parametrize("chain", chains())
def test_local_mode_matches_the_pre_runner_tree(template, chain, mode, layout):
    expected = golden_sections()[(chain, mode, layout)]
    actual = section(chain, mode, layout, *run_one(template, chain, mode, layout))
    assert actual.rstrip("\n") == expected.rstrip("\n")


if __name__ == "__main__":
    # The golden always comes from the pre-runner commit, extracted here with git archive (read-only
    # for the checkout). --from-tree <dir> captures another tree, under its own label, for a probe:
    # test_golden_was_captured_from_the_pre_runner_commit then fails, so it cannot be committed by mistake.
    if "--write-golden" not in sys.argv:
        sys.exit("usage: test_install_runner_local_mode.py --write-golden [--from-tree <dir>]")
    GOLDEN.parent.mkdir(parents=True, exist_ok=True)
    if "--from-tree" in sys.argv:
        tree = Path(sys.argv[sys.argv.index("--from-tree") + 1]).resolve()
        GOLDEN.write_text(capture(tree, f"tree {tree}"))
    else:
        with tempfile.TemporaryDirectory(prefix=f"ir-local-{SOURCE_COMMIT}-") as tmp:
            tree = Path(tmp).resolve()
            archive = subprocess.run(["git", "archive", SOURCE_COMMIT], cwd=REPO, capture_output=True, check=True).stdout
            subprocess.run(["tar", "-x", "-C", str(tree)], input=archive, check=True)
            GOLDEN.write_text(capture(tree, f"git archive {SOURCE_COMMIT}"))
    print(f"wrote {GOLDEN} from {tree}")
