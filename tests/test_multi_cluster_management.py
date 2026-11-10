"""Multi-cluster management tests (plan: .claude/plans/multi-cluster-management/).

T1 pins what the env loaders export while multi-cluster mode is off. It copies the
loader scripts into a throwaway repo with fake configs, a temporary HOME and fake
`oc` / `podman` first on PATH, so nothing touches a real cluster, the podman VM or
the real ~/cpd-cli, ~/.kube and configs/.

T2 is a static guard: git grep fails the build on new repo-anchored configs/ paths,
hard-coded olm-utils-play-v4 or ${HOME}/cpd-cli/work.

The golden file records the behaviour from before the feature. Regenerate it only
for a deliberate change of mode-off behaviour:

    .venv/bin/python tests/test_multi_cluster_management.py --write-golden
"""

import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from dataclasses import dataclass, field
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
GOLDEN = Path(__file__).resolve().parent / "fixtures" / "multi_cluster_off_env_golden.txt"

# Names the feature may add to the mode-off environment. Later phases may extend
# this with MCM_ names only where the plan says so.
ALLOWED_NEW_NAMES = {"CPD_CLI_HOME", "CPD_CLI_BASE_WORK_PATH", "MULTI_CLUSTER_MANAGEMENT"}
# What a mode-off env load creates directly under HOME today.
EXPECTED_HOME_ENTRIES = {"cpd-cli"}

SCAFFOLD = ["env_bootstrap.sh", "s_env.sh", "scripts/source_env_setup.sh"]
# Sourced by the loaders once P2 lands; absent until then.
SCAFFOLD_OPTIONAL = ["src/helpers/multi_cluster_helpers.sh"]

FAKE_OC = """#!/bin/sh
# No session: whoami fails, so the login wrappers fall through to the echo commands in the fake configs.
case "$1" in
  whoami) exit 1 ;;
esac
exit 0
"""
FAKE_PODMAN = """#!/bin/sh
case "$1" in
  inspect|exec) exit 1 ;;
esac
exit 0
"""
FAKE_CPD_VARS = textwrap.dedent("""\
    export OCP_URL="https://api.golden-cpd.example.com:6443"
    export OC_LOGIN="echo FAKE-OC-LOGIN-CPD"
    export CPDM_OC_LOGIN="echo FAKE-CPDM-LOGIN-CPD"
    export OLM_UTILS_IMAGE="icr.io/cpopen/cpd/olm-utils-v4:5.4.0.8"
    export VERSION="5.4.0"
""")
# Same shape as the generated concert_vars.sh: no CPDM_OC_LOGIN or OLM_UTILS_IMAGE.
FAKE_CONCERT_VARS = textwrap.dedent("""\
    export OCP_URL="https://api.golden-concert.example.com:6443"
    export OC_LOGIN="echo FAKE-OC-LOGIN-CONCERT"
    export CONCERT_VERSION="2.2.0"
""")

DUMP_MARKER = "===MCM-ENV-DUMP==="
# Prints every exported name=value, one per line whatever the value holds.
DUMP_ZSH = textwrap.dedent(f"""\
    zmodload zsh/parameter
    print -r -- "{DUMP_MARKER}"
    for _dump_name in ${{(k)parameters}}; do
        if [[ "${{parameters[$_dump_name]}}" == *export* ]]; then
            _dump_value="${{(P)_dump_name}}"
            print -r -- "${{_dump_name}}=${{_dump_value//$'\\n'/\\\\n}}"
        fi
    done
""")
# Scripts run strict and load through env_bootstrap.sh; s_env.sh is sourced from an ordinary shell.
LOADERS = {
    "bootstrap": 'set -euo pipefail\nsource "${0:A:h}/env_bootstrap.sh"\n',
    "s_env": 'source "${0:A:h}/s_env.sh"\n',
}
# None leaves ENV_TARGET unset: the driver script sits outside every product folder, so all configs load.
TARGETS = {"cpd": "cpd", "concert": "concert", "all": None}


def _write_executable(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)
    path.chmod(0o755)


def _build_sandbox(root):
    repo, home, fake_bin = root / "repo", root / "home", root / "bin"
    home.mkdir()
    _write_executable(fake_bin / "oc", FAKE_OC)
    _write_executable(fake_bin / "podman", FAKE_PODMAN)
    for rel in SCAFFOLD + [r for r in SCAFFOLD_OPTIONAL if (REPO / r).exists()]:
        (repo / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPO / rel, repo / rel)
    for rel, body in (("cp4d_config/cpd_vars.sh", FAKE_CPD_VARS), ("concert_config/concert_vars.sh", FAKE_CONCERT_VARS)):
        (repo / "configs" / rel).parent.mkdir(parents=True, exist_ok=True)
        (repo / "configs" / rel).write_text(body)
    return repo, home, fake_bin


def _normalize(text, root):
    # Longest paths first, so <REPO>, <HOME> and <BIN> win over <TMP>.
    for path, placeholder in ((root / "repo", "<REPO>"), (root / "home", "<HOME>"), (root / "bin", "<BIN>"), (root, "<TMP>")):
        text = text.replace(str(path), placeholder)
    return text


def _capture_one(repo, home, fake_bin, root, loader, target):
    # s_env.sh is sourced from an interactive shell, where $ZSH_ARGZERO has no .sh suffix.
    driver = repo / ("capture_env.sh" if loader == "bootstrap" else "capture_env")
    source_line = LOADERS[loader]
    if loader == "s_env" and target:
        source_line = source_line.rstrip("\n") + f" {target}\n"
    _write_executable(driver, "#!/bin/zsh\n" + source_line + DUMP_ZSH)
    # LOGNAME is fixed because zsh otherwise fills it from the current login session.
    env = {"PATH": f"{fake_bin}:/usr/bin:/bin", "HOME": str(home), "LOGNAME": "golden-user", "_CP4D_PREP_DONE": "1"}
    if loader == "bootstrap" and target:
        env["ENV_TARGET"] = target
    result = subprocess.run(["zsh", str(driver)], cwd=repo, env=env, capture_output=True, text=True, timeout=60)
    if result.returncode != 0 or DUMP_MARKER not in result.stdout:
        raise AssertionError(f"{loader}:{target} failed (rc={result.returncode}):\n{result.stdout}\n{result.stderr}")
    lines = result.stdout.split(DUMP_MARKER + "\n", 1)[1].splitlines()
    kept = [line for line in lines if line.partition("=")[0] not in ALLOWED_NEW_NAMES]
    return [_normalize(line, root) for line in sorted(kept)]


def capture():
    """Golden text for every loader and target, and the top-level names left in the temporary HOME."""
    sections = []
    with tempfile.TemporaryDirectory() as tmp:
        # resolve(): macOS temp dirs sit behind a symlink, and `cd && pwd` in the scripts may report either form.
        root = Path(tmp).resolve()
        repo, home, fake_bin = _build_sandbox(root)
        for loader in LOADERS:
            for label, target in TARGETS.items():
                body = _capture_one(repo, home, fake_bin, root, loader, target)
                sections.append("\n".join([f"### {loader}:{label}", *body]))
        home_entries = {entry.name for entry in home.iterdir()}
    return "\n\n".join(sections) + "\n", home_entries


class T1ModeOffEnvironment(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text, cls.home_entries = capture()

    def test_exported_env_matches_golden(self):
        self.maxDiff = None
        self.assertEqual(self.text, GOLDEN.read_text())

    def test_home_has_no_new_top_level_entries(self):
        self.assertEqual(self.home_entries - EXPECTED_HOME_ENTRIES, set())


SHELL_GLOBS = ("*.sh", "*.zsh", "*.sh.j2")
# Keeps the guard out of user data even where .gitignore would not.
GUARD_EXCLUDES = (":!tests", ":!configs", ":!service_instances", ":!*_workspace/*", ":!cpd-cli-workspace")


@dataclass(frozen=True)
class GuardRule:
    pattern: str
    globs: tuple
    fallback_vars: tuple = ()  # the ${VAR:-...} halves are removed before matching
    skip: str = ""  # code lines matching this are fine
    allow: dict = field(default_factory=dict)  # repo path -> why it may keep the literal


GUARD_RULES = {
    "a_shell_configs": GuardRule(
        pattern=r'(\$\{?(_CP4D_)?REPO_ROOT\}?|\$\{SCRIPT_DIR[^"]*|_cfg=.*SCRIPT_DIR.*)/configs\b|"\$\{_CP4D_REPO_ROOT\}"/configs',
        globs=SHELL_GLOBS,
        fallback_vars=("CONFIGS_ROOT",),
    ),
    "b_python_configs": GuardRule(
        # The lookarounds leave dict keys alone: .get("configs"), x["configs"], "configs": ...
        pattern=r"""(?<!\.get\()(?<![\w\]]\[)["']configs(/[^"']*)?["'](?!\s*:)""",
        globs=("*.py",),
        allow={"src/helpers/multi_cluster_state.py": "configs_root() holds the one fallback every caller routes through"},
    ),
    "c_container_shell": GuardRule(
        pattern=r"olm-utils-play-v4",
        globs=SHELL_GLOBS,
        fallback_vars=("OLM_UTILS_CONTAINER",),
    ),
    "c_container_python": GuardRule(
        # Quoted only: docstrings name the container in plain prose.
        pattern=r"""["']olm-utils-play-v4["']""",
        globs=("*.py",),
        skip=r"\bOLM_UTILS_CONTAINER\b",
    ),
    "d_work_path": GuardRule(
        pattern=r"\$\{?HOME\}?/cpd-cli/work\b",
        globs=(*SHELL_GLOBS, "*.py"),
        fallback_vars=("CPD_CLI_WORK_PATH", "CPD_CLI_BASE_WORK_PATH"),
        skip=r"^\s*(export\s+)?CPD_CLI_BASE_WORK_PATH=",
    ),
}


def _code_part(text):
    """The line without its comment; empty for a comment or a user-facing message."""
    if re.match(r"\s*(echo|printf)\b", text):
        return ""
    return re.sub(r"(^|\s)#.*", "", text)


def _without_fallbacks(text, names):
    for name in names:
        text = re.sub(r"\$\{" + name + r":-(?:[^{}]|\$\{[^{}]*\})*\}", "", text)
    return text


def guard_violations(rule, root=REPO, no_index=False):
    """path:line:text for each code line under root that breaks the rule."""
    scope = "--no-index" if no_index else "--untracked"
    cmd = ["git", "grep", scope, "-InP", rule.pattern, "--", *rule.globs, *GUARD_EXCLUDES]
    result = subprocess.run(cmd, cwd=root, capture_output=True, text=True, timeout=60)
    # 1 means no match; anything else (such as a git built without PCRE) must not read as a clean tree.
    if result.returncode not in (0, 1):
        raise AssertionError(f"git grep failed (rc={result.returncode}): {result.stderr}")
    found = []
    for line in result.stdout.splitlines():
        path, _, text = line.split(":", 2)
        code = _without_fallbacks(_code_part(text), rule.fallback_vars)
        if path in rule.allow or (rule.skip and re.search(rule.skip, code)):
            continue
        if re.search(rule.pattern, code):
            found.append(line)
    return found


# rule -> (file name, line that must be flagged, lines that must pass)
GUARD_SEEDS = {
    "a_shell_configs": ("a.sh", 'X="${REPO_ROOT}/configs/cp4d_config/cpd_vars.sh"', [
        'X="${CONFIGS_ROOT:-${REPO_ROOT}/configs}/cp4d_config/cpd_vars.sh"',
        '_cfg="${CONFIGS_ROOT:-${SCRIPT_DIR:h:h:h}/configs}/x/y.sh"',
        '# see ${REPO_ROOT}/configs/cp4d_config',
        'echo "Edit ${REPO_ROOT}/configs/cp4d_config/cpd_vars.sh"',
    ]),
    "b_python_configs": ("b.py", 'p = os.path.join(root, "configs", "cp4d_config")', [
        'names = result.get("configs", [])',
        'block = {"configs": configs}',
        'text = pl["configs"]',
        'label = "Save directly to ./configs/cp4d_config/"',
        '# os.path.join(root, "configs")',
    ]),
    "c_container_shell": ("c.sh", 'CONTAINER_NAME="olm-utils-play-v4"', [
        'CONTAINER_NAME="${OLM_UTILS_CONTAINER:-olm-utils-play-v4}"',
        '# the shared olm-utils-play-v4 is never touched',
    ]),
    "c_container_python": ("c.py", 'container = "olm-utils-play-v4"', [
        'container = os.environ.get("OLM_UTILS_CONTAINER") or "olm-utils-play-v4"',
        'OLM_UTILS_CONTAINER (olm-utils-play-v4), IMAGE_ARCH (amd64).',
    ]),
    "d_work_path": ("d.sh", 'WORK="${HOME}/cpd-cli/work"', [
        'WORK="${CPD_CLI_WORK_PATH:-${HOME}/cpd-cli/work}"',
        'SRC="${CPD_CLI_BASE_WORK_PATH:-${HOME}/cpd-cli/work}/offline"',
        'export CPD_CLI_BASE_WORK_PATH="${HOME}/cpd-cli/work"',
        '# never ${HOME}/cpd-cli/work directly',
    ]),
}


class T2StaticPathGuard(unittest.TestCase):
    def test_repo_has_no_hard_coded_paths(self):
        for name, rule in GUARD_RULES.items():
            with self.subTest(rule=name):
                self.assertEqual(guard_violations(rule), [])

    def test_allowlisted_files_still_exist(self):
        for name, rule in GUARD_RULES.items():
            for path in rule.allow:
                with self.subTest(rule=name, path=path):
                    self.assertTrue((REPO / path).is_file())

    def test_guard_flags_seeded_violations_only(self):
        self.assertEqual(set(GUARD_SEEDS), set(GUARD_RULES))
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            for name, (filename, bad, good) in GUARD_SEEDS.items():
                (root / filename).write_text("\n".join([bad, *good]) + "\n")
            for name, (filename, bad, _) in GUARD_SEEDS.items():
                with self.subTest(rule=name):
                    self.assertEqual(guard_violations(GUARD_RULES[name], root, no_index=True), [f"{filename}:1:{bad}"])


if __name__ == "__main__":
    if "--write-golden" in sys.argv:
        GOLDEN.parent.mkdir(parents=True, exist_ok=True)
        GOLDEN.write_text(capture()[0])
        print(f"wrote {GOLDEN}")
    else:
        unittest.main()
