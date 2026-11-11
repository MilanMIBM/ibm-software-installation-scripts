"""Multi-cluster management tests (plan: .claude/plans/multi-cluster-management/).

T1 pins what the env loaders export while multi-cluster mode is off. It copies the
loader scripts into a throwaway repo with fake configs, a temporary HOME and fake
`oc` / `podman` first on PATH, so nothing touches a real cluster, the podman VM or
the real ~/cpd-cli, ~/.kube and configs/.

T2 is a static guard: git grep fails the build on new repo-anchored configs/ or
service_instances/ paths, hard-coded olm-utils-play-v4 or ${HOME}/cpd-cli/work.

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
    export INSTALL_RUN_MODE="local"
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
# bootstrap_in_runner is a chain inside an in-cluster runner pod: the same strict load of a flat
# snapshot, with IR_IN_RUNNER=1 as run-attempt.sh sets it (pod-side login, no CP4D config needed).
LOADERS = {
    "bootstrap": 'set -euo pipefail\nsource "${0:A:h}/env_bootstrap.sh"\n',
    "s_env": 'source "${0:A:h}/s_env.sh"\n',
    "bootstrap_in_runner": 'set -euo pipefail\nsource "${0:A:h}/env_bootstrap.sh"\n',
}
LOADER_ENV = {"bootstrap_in_runner": {"IR_IN_RUNNER": "1"}}
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
    driver = repo / ("capture_env" if loader == "s_env" else "capture_env.sh")
    source_line = LOADERS[loader]
    if loader == "s_env" and target:
        source_line = source_line.rstrip("\n") + f" {target}\n"
    _write_executable(driver, "#!/bin/zsh\n" + source_line + DUMP_ZSH)
    # LOGNAME is fixed because zsh otherwise fills it from the current login session.
    env = {"PATH": f"{fake_bin}:/usr/bin:/bin", "HOME": str(home), "LOGNAME": "golden-user", "_CP4D_PREP_DONE": "1"}
    env.update(LOADER_ENV.get(loader, {}))
    if loader != "s_env" and target:
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
    allow: dict = field(default_factory=dict)  # repo path -> why the whole file may keep the literal
    # repo path -> (regex of the one known line, why). Narrower than allow: a new line in the same file
    # is still caught. Every entry must still match (T2 fails on a stale one, so the fix removes it).
    allow_lines: dict = field(default_factory=dict)


GUARD_RULES = {
    "a_shell_configs": GuardRule(
        # Any root variable with REPO in its name (REPO_ROOT, _CP4D_REPO_ROOT, REPO_DIR, ...), quoted or
        # not. Digits too: _CP4D_ has one.
        pattern=r'(\$\{?[A-Z0-9_]*REPO[A-Z0-9_]*\}?|\$\{SCRIPT_DIR[^"]*|_cfg=.*SCRIPT_DIR.*)"?/configs\b',
        globs=SHELL_GLOBS,
        fallback_vars=("CONFIGS_ROOT",),
        allow_lines={
            "src/utilities/multi_cluster_management_utils/migrate_to_multi_cluster.sh": (
                r'^MCM_MIG_CONFIGS="\$\{MCM_MIG_REPO\}/configs"$',
                "the migration reads the flat configs/ itself: it is the source it moves into configs/clusters/"),
        },
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
    "e_service_instances": GuardRule(
        # Under a repo root or a script dir, or bare and repo-relative. Per cluster it is
        # <cluster>/service_instances, which only SERVICE_INSTANCE_FILE_DIR knows.
        pattern=r'''(\$\{?[A-Z0-9_]*REPO[A-Z0-9_]*\}?|\$\{SCRIPT_DIR[^"]*|\$\{?_ENV_SETUP_DIR\}?|\.\.)"?/service_instances\b|(?<![\w./#$-])service_instances/''',
        globs=SHELL_GLOBS,
        fallback_vars=("SERVICE_INSTANCE_FILE_DIR",),
        # Tests of a user's value against the repo-relative form (4.5_provision_cognos.sh maps that
        # form onto SERVICE_INSTANCE_FILE_DIR).
        skip=r'==\s*"?service_instances/',
        allow_lines={
            "scripts/source_env_setup.sh": (
                r'^export SERVICE_INSTANCE_FILE_DIR=.*MCM_CLUSTER_ROOT',
                "the one definition: per cluster under MCM_CLUSTER_ROOT, else the flat folder"),
        },
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


def _guard_hits(rule, root=REPO, no_index=False):
    """(path, code line, path:line:text) for each code line under root that breaks the rule, allowlists
    not applied."""
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
        if rule.skip and re.search(rule.skip, code):
            continue
        if re.search(rule.pattern, code):
            found.append((path, text, line))
    return found


def _allowed(rule, path, text):
    if path in rule.allow:
        return True
    known = rule.allow_lines.get(path)
    return bool(known) and re.search(known[0], text.strip()) is not None


def guard_violations(rule, root=REPO, no_index=False):
    """path:line:text for each code line under root that breaks the rule."""
    return [line for path, text, line in _guard_hits(rule, root, no_index) if not _allowed(rule, path, text)]


# rule -> (file name, line or lines that must be flagged, lines that must pass)
GUARD_SEEDS = {
    "a_shell_configs": ("a.sh", [
        'X="${REPO_ROOT}/configs/cp4d_config/cpd_vars.sh"',
        'found=("${REPO_DIR}"/configs/*/${target}_vars.sh(N))',
        'X="${_CP4D_REPO_ROOT}/configs/x"',
        'for f in "${_CP4D_REPO_ROOT}"/configs/*; do',
        'X=$REPO_DIR/configs',
    ], [
        'X="${CONFIGS_ROOT:-${REPO_ROOT}/configs}/cp4d_config/cpd_vars.sh"',
        'X="${CONFIGS_ROOT:-${REPO_DIR}/configs}/cp4d_config/cpd_vars.sh"',
        'X="${REPO_DIR}/configs_backup"',
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
    "e_service_instances": ("e.sh", [
        'OUT="${REPO_ROOT}/service_instances/payload.json"',
        'cp x "${REPO_DIR}"/service_instances/',
        'P="service_instances/db2.json"',
        'D="${SCRIPT_DIR}/../../service_instances"',
        # A script re-pinning the flat folder: only the MCM-aware one in source_env_setup.sh may define it.
        'export SERVICE_INSTANCE_FILE_DIR="${REPO_ROOT}/service_instances"',
        'SERVICE_INSTANCE_FILE_DIR="${SCRIPT_DIR}/../../service_instances"',
        'export SERVICE_INSTANCE_FILE_DIR="${_ENV_SETUP_DIR}/../service_instances"',
    ], [
        'OUT="${SERVICE_INSTANCE_FILE_DIR:-${REPO_ROOT}/service_instances}/payload.json"',
        'elif [[ "${value}" == service_instances/?* ]]; then',
        'print -r -- "${SERVICE_INSTANCE_FILE_DIR}/${value#service_instances/}"',
        'rows="$(curl "${url}/zen-data/v3/service_instances?limit=1")"',
        '# under ${REPO_ROOT}/service_instances',
        'echo "See service_instances/ for the payloads"',
    ]),
    "d_work_path": ("d.sh", 'WORK="${HOME}/cpd-cli/work"', [
        'WORK="${CPD_CLI_WORK_PATH:-${HOME}/cpd-cli/work}"',
        'SRC="${CPD_CLI_BASE_WORK_PATH:-${HOME}/cpd-cli/work}/offline"',
        'export CPD_CLI_BASE_WORK_PATH="${HOME}/cpd-cli/work"',
        '# never ${HOME}/cpd-cli/work directly',
    ]),
}


def _as_list(lines):
    return [lines] if isinstance(lines, str) else list(lines)


class T2StaticPathGuard(unittest.TestCase):
    def test_repo_has_no_hard_coded_paths(self):
        for name, rule in GUARD_RULES.items():
            with self.subTest(rule=name):
                self.assertEqual(guard_violations(rule), [])

    def test_allowlisted_files_still_exist(self):
        for name, rule in GUARD_RULES.items():
            for path in [*rule.allow, *rule.allow_lines]:
                with self.subTest(rule=name, path=path):
                    self.assertTrue((REPO / path).is_file())

    def test_allowlist_entries_still_match(self):
        """A stale entry fails here, so the phase that fixes the line also removes its entry."""
        for name, rule in GUARD_RULES.items():
            hits = _guard_hits(rule)
            for path in rule.allow:
                with self.subTest(rule=name, path=path):
                    self.assertTrue(any(p == path for p, _, _ in hits),
                                    f"{path} no longer breaks {name}: remove it from allow")
            for path, (known, _) in rule.allow_lines.items():
                with self.subTest(rule=name, path=path):
                    self.assertTrue(any(p == path and re.search(known, t.strip()) for p, t, _ in hits),
                                    f"{path} no longer has the allowlisted line: remove it from allow_lines")

    def test_allow_lines_exempt_only_the_known_line(self):
        """A new hard-coded line in an allowlisted file is still caught."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            for name, rule in GUARD_RULES.items():
                for path in rule.allow_lines:
                    known = next(t for p, t, _ in _guard_hits(rule) if p == path and _allowed(rule, p, t))
                    target = root / path
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_text(known + "\n" + _as_list(GUARD_SEEDS[name][1])[0] + "\n")
            for name, rule in GUARD_RULES.items():
                expected = sorted(f"{path}:2:{_as_list(GUARD_SEEDS[name][1])[0]}" for path in rule.allow_lines)
                with self.subTest(rule=name):
                    found = [v for v in guard_violations(rule, root, no_index=True) if v.split(":", 1)[0] in rule.allow_lines]
                    self.assertEqual(sorted(found), expected)

    def test_guard_flags_seeded_violations_only(self):
        self.assertEqual(set(GUARD_SEEDS), set(GUARD_RULES))
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            for name, (filename, bad, good) in GUARD_SEEDS.items():
                (root / filename).write_text("\n".join([*_as_list(bad), *good]) + "\n")
            for name, (filename, bad, _) in GUARD_SEEDS.items():
                expected = [f"{filename}:{n}:{line}" for n, line in enumerate(_as_list(bad), 1)]
                with self.subTest(rule=name):
                    self.assertEqual(guard_violations(GUARD_RULES[name], root, no_index=True), expected)


if __name__ == "__main__":
    if "--write-golden" in sys.argv:
        GOLDEN.parent.mkdir(parents=True, exist_ok=True)
        GOLDEN.write_text(capture()[0])
        print(f"wrote {GOLDEN}")
    else:
        unittest.main()
