"""Check advisory sizing validation without writing to a cluster."""

import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "src/helpers"))
import cpd_shared_scale_check as checker

NAMESPACE = "demo-operands"
GROUP = "/apis/wkc.cpd.ibm.com"
API = GROUP + "/v1beta1"
BASE = API + "/namespaces/" + NAMESPACE
PARENT_API = "/apis/privacy.example.test/v2"
PARENT_BASE = PARENT_API + "/namespaces/" + NAMESPACE


def parent(kind, name, size):
    return {
        "apiVersion": "wkc.cpd.ibm.com/v1beta1" if kind == "WKC" else "privacy.example.test/v2",
        "kind": kind,
        "metadata": {"name": name, "uid": name + "-uid"},
        "spec": {"scaleConfig": size},
    }


def dependency(owners, size="small", kind="Metadataimports"):
    return {
        "kind": kind,
        "metadata": {
            "name": "custom-" + kind.lower(),
            "ownerReferences": [
                {"apiVersion": owner["apiVersion"], "kind": owner["kind"], **owner["metadata"]}
                for owner in owners
            ],
        },
        "spec": {"scaleConfig": size},
    }


def api_resource(name, kind):
    return {"name": name, "kind": kind, "namespaced": True}


def fixture(owners, children):
    responses = {
        GROUP: {"preferredVersion": {"groupVersion": "wkc.cpd.ibm.com/v1beta1"}},
        API: {"resources": [
            api_resource("metadataimports/status", "Metadataimports"),
            api_resource("metadataimports", "Metadataimports"),
            api_resource("enrichment", "Enrichment"),
            api_resource("wkc", "WKC"),
        ]},
        PARENT_API: {"resources": [api_resource("privacyservices", "PrivacyService")]},
        BASE + "/metadataimports": {"items": [x for x in children if x["kind"] == "Metadataimports"]},
        BASE + "/enrichment": {"items": [x for x in children if x["kind"] == "Enrichment"]},
    }
    for owner in owners:
        path = BASE + "/wkc/" if owner["kind"] == "WKC" else PARENT_BASE + "/privacyservices/"
        responses[path + owner["metadata"]["name"]] = owner
    return responses


class ScaleCheckTests(unittest.TestCase):
    def run_check(self, responses):
        calls = []

        def read(command, **kwargs):
            self.assertEqual(command[:3], ["oc", "get", "--raw"])
            path = command[3]
            calls.append(path)
            response = responses.get(path)
            if response is None:
                return SimpleNamespace(returncode=1, stdout="", stderr="Error from server (NotFound)")
            return SimpleNamespace(returncode=0, stdout=json.dumps(response), stderr="")

        output = io.StringIO()
        with patch.object(checker.subprocess, "run", side_effect=read), contextlib.redirect_stdout(output):
            checker.check(NAMESPACE, checker.ClusterReader())
        return output.getvalue(), calls

    def test_matching_sizes_accept_low_resource_and_other_profiles(self):
        for size in ("small_mincpureq", "small", "medium", "large", "custom-profile"):
            with self.subTest(size=size):
                owners = [parent("WKC", "catalog", size), parent("PrivacyService", "privacy", size)]
                children = [dependency(owners, size, kind) for kind in ("Metadataimports", "Enrichment")]
                output, calls = self.run_check(fixture(owners, children))
                self.assertNotIn("[WARN]", output)
                self.assertIn("2 dependencies with multiple explicitly sized owners, 0 conflicting", output)
                self.assertEqual(calls.count(BASE + "/wkc/catalog"), 1)
                self.assertEqual(calls.count(PARENT_API), 1)
                self.assertNotIn(BASE + "/metadataimports/status", calls)

    def test_conflict_reports_actual_custom_names_and_dependency(self):
        owners = [parent("WKC", "custom-catalog", "small"), parent("PrivacyService", "custom-privacy", "small_mincpureq")]
        output, _ = self.run_check(fixture(owners, [dependency(owners)]))
        self.assertIn("[WARN] Conflicting owner scaleConfig", output)
        self.assertIn("WKC/custom-catalog=small", output)
        self.assertIn("PrivacyService/custom-privacy=small_mincpureq", output)
        self.assertIn("Metadataimports/custom-metadataimports", output)
        self.assertIn("1 conflicting owner configurations", output)
        self.assertIn("no resources were changed", output)

    def test_unrelated_service_size_is_not_compared(self):
        owners = [parent("WKC", "catalog", "small"), parent("PrivacyService", "privacy", "small")]
        unrelated = parent("PrivacyService", "independent", "small_mincpureq")
        output, calls = self.run_check(fixture([*owners, unrelated], [dependency(owners)]))
        self.assertNotIn("[WARN]", output)
        self.assertNotIn(PARENT_BASE + "/privacyservices/independent", calls)

    def test_separate_single_owner_dependencies_can_have_different_sizes(self):
        owners = [parent("WKC", "catalog", "small"), parent("PrivacyService", "privacy", "small_mincpureq")]
        children = [dependency(owners[:1]), dependency(owners[1:], "small_mincpureq", "Enrichment")]
        output, _ = self.run_check(fixture(owners, children))
        self.assertNotIn("[WARN]", output)
        self.assertIn("0 dependencies with multiple", output)

    def test_child_lag_is_informational_when_owners_agree(self):
        owners = [parent("WKC", "catalog", "small"), parent("PrivacyService", "privacy", "small")]
        output, _ = self.run_check(fixture(owners, [dependency(owners, "small_mincpureq")]))
        self.assertNotIn("[WARN]", output)
        self.assertIn("Reconciliation may still be in progress", output)
        self.assertIn("1 dependencies awaiting alignment", output)

    def test_missing_stale_deleting_or_unsized_owners_are_not_assumed(self):
        for situation in ("missing", "stale", "deleting", "unsized"):
            with self.subTest(situation=situation):
                owners = [parent("WKC", "catalog", "small"), parent("PrivacyService", "privacy", "small_mincpureq")]
                child = dependency(owners)
                if situation == "stale":
                    child["metadata"]["ownerReferences"][1]["uid"] = "old-uid"
                elif situation == "deleting":
                    owners[1]["metadata"]["deletionTimestamp"] = "2026-10-28T10:00:00Z"
                elif situation == "unsized":
                    owners[1]["spec"] = {}
                responses = fixture(owners[:1] if situation == "missing" else owners, [child])
                output, _ = self.run_check(responses)
                self.assertNotIn("[WARN]", output)
                self.assertIn("0 dependencies with multiple", output)

    def test_duplicate_owner_reference_is_not_shared_ownership(self):
        owner = parent("WKC", "catalog", "small")
        output, _ = self.run_check(fixture([owner], [dependency([owner, owner], "small_mincpureq")]))
        self.assertIn("0 dependencies with multiple", output)
        self.assertNotIn("[WARN]", output)

    def test_absent_api_group_and_empty_installations_are_skipped(self):
        for responses in ({}, fixture([], [])):
            with self.subTest(responses=responses):
                output, _ = self.run_check(responses)
                self.assertNotIn("[WARN]", output)
                self.assertIn("0 dependencies with multiple", output)

    def test_unreadable_api_never_reports_a_successful_comparison(self):
        for result in (
            SimpleNamespace(returncode=1, stdout="", stderr="Error from server (Forbidden)"),
            SimpleNamespace(returncode=0, stdout="invalid JSON", stderr=""),
            SimpleNamespace(returncode=0, stdout="[]", stderr=""),
            FileNotFoundError("oc"),
            subprocess.TimeoutExpired("oc", 15),
        ):
            with self.subTest(result=result):
                output = io.StringIO()
                kwargs = {"side_effect": result} if isinstance(result, Exception) else {"return_value": result}
                with patch.object(checker.subprocess, "run", **kwargs), contextlib.redirect_stdout(output):
                    with patch.object(sys, "argv", ["check", "--namespace", NAMESPACE]):
                        self.assertEqual(checker.main(), 0)
                self.assertIn("comparison is incomplete", output.getvalue())
                self.assertNotIn("0 conflicting owner configurations", output.getvalue())


class InstallerIntegrationTests(unittest.TestCase):
    def test_advisory_failure_preserves_install_success_and_install_failure_still_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / "scripts/install_cloud_pak_for_data/4_install_components/4.1_install_components.sh"
            script.parent.mkdir(parents=True)
            shutil.copy(REPO / script.relative_to(root), script)
            script.chmod(0o755)
            (root / "env_bootstrap.sh").write_text(
                'export _CP4D_REPO_ROOT="' + str(root) + '"\n'
                'for var in CPD_COMPONENTS VERSION PROJECT_CPD_INST_OPERATORS PROJECT_CPD_INST_OPERANDS '
                'STG_CLASS_BLOCK STG_CLASS_FILE IMAGE_PULL_PREFIX IMAGE_PULL_SECRET; do export "$var=demo"; done\n'
                'export COMPLETE_COMPONENT_LIST=analyticsengine UPDATE=false CPDM_OC_LOGIN=":"\n'
                'function cpd-cli() { print install >> "$TRACE"; return "$INSTALL_RESULT"; }\n'
            )
            helper = root / "src/helpers/cpd_shared_scale_check.py"
            helper.parent.mkdir(parents=True)
            helper.write_text(
                'import os\nfrom pathlib import Path\n'
                'with Path(os.environ["TRACE"]).open("a") as log: log.write("check\\n")\n'
                'raise SystemExit(int(os.environ["CHECK_RESULT"]))\n'
            )
            trace = root / "trace"
            for install_result, check_result in ((0, 0), (0, 1), (7, 0)):
                with self.subTest(install_result=install_result, check_result=check_result):
                    trace.write_text("")
                    env = {
                        **os.environ, "TRACE": str(trace), "INSTALL_RESULT": str(install_result),
                        "CHECK_RESULT": str(check_result), "COMPONENTS_TO_SKIP": "", "PATCH_ID": "",
                        "INSTALL_OPTIONS": "",
                    }
                    result = subprocess.run(["zsh", str(script)], env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, install_result, result.stderr)
                    expected = ["install", "check"] if install_result == 0 else ["install"]
                    self.assertEqual(trace.read_text().splitlines(), expected)
                    if check_result:
                        self.assertIn("installation result is unchanged", result.stdout)


if __name__ == "__main__":
    unittest.main()
