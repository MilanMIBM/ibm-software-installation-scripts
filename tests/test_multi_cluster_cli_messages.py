"""Regression: multi_cluster.sh messages must not read as cluster cpd-cli commands.

tests/test_cluster_login.py scans code lines for `cpd-cli manage <verb>` and
requires a CPDM_OC_LOGIN. multi_cluster.sh only manages local per-cluster state
and never runs a cluster cpd-cli command, so an info message such as
"the next cpd-cli manage creates it" was misread as `cpd-cli manage creates`.
"""
import unittest
from pathlib import Path

from tests.test_cluster_login import CPD_CLI_RE, OFFLINE_CPD_CLI, _code_lines

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "src/utilities/multi_cluster_management_utils/multi_cluster.sh"


class MultiClusterCliMessages(unittest.TestCase):
    def test_no_cluster_cpd_cli_commands_detected(self):
        text = SCRIPT.read_text()
        cmds = {m.group(1) for line in _code_lines(text) for m in CPD_CLI_RE.finditer(line)}
        self.assertEqual(sorted(cmds - OFFLINE_CPD_CLI), [])

    def test_no_container_message_still_mentions_cpd_cli_manage(self):
        self.assertIn("the next 'cpd-cli manage' command creates it.", SCRIPT.read_text())


if __name__ == "__main__":
    unittest.main()
