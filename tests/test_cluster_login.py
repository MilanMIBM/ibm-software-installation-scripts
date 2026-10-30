"""Cluster login guarantees for the shell scripts.

Every runnable script that talks to a cluster must log in first, so it works the
same run on its own, in a sub-chain or in a full chain:
  - cluster `cpd-cli manage` commands need eval "${CPDM_OC_LOGIN}"
  - local oc / kubectl / helm cluster calls need a local login (OC_LOGIN,
    CPDM_OC_LOGIN - which also logs the local oc in - or a login helper)
The wrapper tests run scripts/source_env_setup.sh against a throwaway config with
fake `oc` and `podman` on PATH, so nothing touches a real cluster or the
olm-utils container.
"""

import os
import re
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]

# cpd-cli manage commands that work without a cluster login.
OFFLINE_CPD_CLI = {
    "login-to-ocp", "restart-container", "clean-workspace", "case-download",
    "list-images", "mirror-images", "login-private-registry",
    "login-entitled-registry", "load-image", "save-image",
}
CPD_CLI_RE = re.compile(r"(?:^|[\s;(|&`$])cpd-cli\s+manage\s+([a-z][a-z0-9-]+)")
# Local client calls that need a session (whoami/config are used by the login checks themselves).
LOCAL_CLUSTER_RE = re.compile(
    r"(?:^|[\s;(|&`$\"])(?:oc|kubectl)\s+(?:get|apply|create|delete|patch|adm|wait|rollout|exec|logs|"
    r"debug|label|annotate|scale|project|new-project|set|describe|auth|extract|replace|edit|cp|"
    r"port-forward|policy|process|expose)\b"
    r"|(?:^|[\s;(|&`$\"])helm\s+(?:install|upgrade|uninstall|status|list|history|rollback)\b"
)
CPDM_LOGIN_RE = re.compile(r"eval\s+\"?\$\{CPDM_OC_LOGIN")
LOCAL_LOGIN_RE = re.compile(
    r"eval\s+\"?\$\{(?:CPDM_OC_LOGIN|OC_LOGIN|MIRROR_OC_LOGIN|CONCERT_REMOTE_HUB_OC_LOGIN)"
    r"|\bocu_login\b|\bpreg_cluster_login\b|(?:^|\s)oc\s+login\b"
)

# Runnable scripts that rely on a session someone else set up, and why.
ALLOWED_WITHOUT_LOGIN = {
    # IBM's vendored POSIX sh checker; 4.0_wxo_install_preverification.sh logs in, then runs it.
    "src/utilities/softwarehub_utils/wxo-prereq-check.sh",
    # Talks to Software Hub's API; oc is only an optional URL lookup, used when its session is on OCP_URL.
    "src/utilities/redhat_openshift_utils/generate_service_id_cpd_apikeys.sh",
}


def _runnable_scripts():
    out = subprocess.run(["git", "ls-files", "scripts/*.sh", "src/utilities/*.sh"],
                         cwd=REPO, capture_output=True, text=True, check=True).stdout.split()
    for rel in out:
        text = (REPO / rel).read_text(errors="ignore")
        head = text[:1500].lower()
        # Libraries: sourced by a script that already logged in.
        if "sourced, not executed" in head or "sourced, never executed" in head or "must be sourced" in head:
            continue
        # Private-registry hooks run as children of a step script that logged in.
        if rel.startswith("scripts/private_registry_mirroring/") and "/installs/" in rel:
            continue
        if rel in ("scripts/source_env_setup.sh", "scripts/operator_install_helpers.sh"):
            continue
        yield rel, text


def _code_lines(text):
    """Lines that are code, not comments, help text or echo'd hints."""
    in_heredoc = None
    for line in text.splitlines():
        s = line.strip()
        if in_heredoc:
            if s == in_heredoc:
                in_heredoc = None
            continue
        m = re.search(r"<<-?\s*['\"]?([A-Z_]+)['\"]?", line)
        if m:
            in_heredoc = m.group(1)
        if not s or s.startswith("#") or re.match(r"(echo|print|printf|preg_info|preg_warn|concert_info)\b", s):
            continue
        # Drop trailing comments and anything echo'd later in the line (hints like "(oc get storageclass)").
        yield re.sub(r"\b(echo|print|printf)\b.*|\s#\s.*", "", line)


class ScriptsLogInBeforeClusterCalls(unittest.TestCase):
    def test_cluster_cpd_cli_commands_follow_cpdm_login(self):
        missing = []
        for rel, text in _runnable_scripts():
            cmds = {m.group(1) for line in _code_lines(text) for m in CPD_CLI_RE.finditer(line)}
            if cmds - OFFLINE_CPD_CLI and not CPDM_LOGIN_RE.search(text) and rel not in ALLOWED_WITHOUT_LOGIN:
                missing.append(f"{rel}: {sorted(cmds - OFFLINE_CPD_CLI)}")
        self.assertEqual(missing, [], "cluster cpd-cli commands without eval \"${CPDM_OC_LOGIN}\"")

    def test_local_cluster_calls_follow_a_local_login(self):
        missing = []
        for rel, text in _runnable_scripts():
            uses = any(LOCAL_CLUSTER_RE.search(line) for line in _code_lines(text))
            if uses and not LOCAL_LOGIN_RE.search(text) and rel not in ALLOWED_WITHOUT_LOGIN:
                missing.append(rel)
        self.assertEqual(missing, [], "local oc/kubectl/helm cluster calls without a login")

    def test_cr_dashboard_never_logs_cpd_cli_in(self):
        # It runs next to install-components; a cpd-cli login may recreate the container and kill that job.
        text = (REPO / "scripts/install_cloud_pak_for_data/check_cr_status/x_cr_state_dashboard.sh").read_text()
        self.assertNotRegex(text, CPDM_LOGIN_RE)
        self.assertRegex(text, r"eval\s+\"\$\{OC_LOGIN\}\"")


FAKE_OC = """#!/bin/sh
# whoami succeeds only with a session; --show-server prints the session's API server.
[ -n "${FAKE_OC_SERVER:-}" ] || exit 1
case "$*" in
  "whoami --show-server") echo "${FAKE_OC_SERVER}" ;;
  whoami) echo kube:admin ;;
esac
"""
FAKE_PODMAN = """#!/bin/sh
case "$1" in
  inspect) [ -n "${FAKE_CTR_IMAGE:-}" ] || exit 125; echo "${FAKE_CTR_IMAGE}" ;;
  exec) [ -n "${FAKE_CTR_SERVER:-}" ] || exit 1
        case "$*" in *--show-server*) echo "${FAKE_CTR_SERVER}" ;; *) echo kube:admin ;; esac ;;
  *) exit 0 ;;
esac
"""
URL = "https://api.test.example:6443"
IMAGE = "icr.io/cpopen/cpd/olm-utils-v4:5.4.0.8"


class CpdmLoginWrapper(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        root = Path(cls.tmp.name)
        (root / "bin").mkdir()
        for name, body in (("oc", FAKE_OC), ("podman", FAKE_PODMAN)):
            p = root / "bin" / name
            p.write_text(body)
            p.chmod(p.stat().st_mode | stat.S_IXUSR)
        (root / "t_vars.sh").write_text(textwrap.dedent(f"""\
            export OCP_URL="{URL}"
            export OLM_UTILS_IMAGE="{IMAGE}"
            export OC_LOGIN="${{FAKE_OC_FORCE:-echo OC-FORCE}}"
            export CPDM_OC_LOGIN="${{FAKE_CPDM_FORCE:-echo CPDM-FORCE}}"
        """))
        cls.root = root

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_login(self, **env):
        script = (f'set -euo pipefail; ENV_TARGET="{self.root}/t_vars.sh" ENV_SETUP_QUIET=1 '
                  f'source "{REPO}/scripts/source_env_setup.sh"; eval "${{CPDM_OC_LOGIN}}"; echo REACHED')
        full_env = {
            "PATH": f"{self.root}/bin:/usr/bin:/bin", "HOME": str(self.root),
            "FAKE_OC_SERVER": URL, "FAKE_CTR_SERVER": URL, "FAKE_CTR_IMAGE": IMAGE,
            **env,
        }
        r = subprocess.run(["zsh", "-c", script], env=full_env, capture_output=True, text=True)
        return r.returncode, r.stdout

    def test_skips_both_logins_when_sessions_are_valid(self):
        rc, out = self.run_login()
        self.assertEqual(rc, 0, out)
        self.assertNotIn("FORCE", out)
        self.assertIn("REACHED", out)

    def test_container_on_another_image_logs_in_again(self):
        # cpd-cli recreates a container whose image name differs, so its login would be lost.
        rc, out = self.run_login(FAKE_CTR_IMAGE="icr.io/cpopen/cpd/olm-utils-v4:5.4.0")
        self.assertIn("CPDM-FORCE", out)
        self.assertNotIn("OC-FORCE", out)

    def test_container_without_session_logs_in(self):
        rc, out = self.run_login(FAKE_CTR_SERVER="")
        self.assertIn("CPDM-FORCE", out)

    def test_container_on_another_cluster_logs_in(self):
        rc, out = self.run_login(FAKE_CTR_SERVER="https://api.other:6443")
        self.assertIn("CPDM-FORCE", out)

    def test_local_oc_without_session_or_on_another_cluster_logs_in(self):
        for server in ("", "https://api.other:6443"):
            with self.subTest(server=server):
                rc, out = self.run_login(FAKE_OC_SERVER=server)
                self.assertIn("OC-FORCE", out)
                self.assertNotIn("CPDM-FORCE", out)

    def test_failed_container_login_stops_a_set_e_script(self):
        rc, out = self.run_login(FAKE_CTR_SERVER="", FAKE_CPDM_FORCE="false")
        self.assertNotEqual(rc, 0)
        self.assertNotIn("REACHED", out)

    def test_failed_local_login_stops_a_set_e_script(self):
        rc, out = self.run_login(FAKE_OC_SERVER="", FAKE_OC_FORCE="false")
        self.assertNotEqual(rc, 0)
        self.assertNotIn("REACHED", out)


if __name__ == "__main__":
    unittest.main()
