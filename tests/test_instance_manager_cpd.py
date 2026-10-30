"""instance_manager L2 (cpd) layer: synthetic data only."""

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from tui.instance_manager.discovery.merge import merge  # noqa: E402
from tui.instance_manager.discovery.observed import observe  # noqa: E402
from tui.instance_manager.model import Role  # noqa: E402
from tui.instance_manager.providers.cpd import extensions, profile, registry  # noqa: E402
from tui.instance_manager.providers.cpd.cpdcli import CpdCli  # noqa: E402
from tui.instance_manager.providers.cpd.provider import zen_link  # noqa: E402
from tui.instance_manager.settings import Settings  # noqa: E402


def cm(name, addons=None, extensions_=None, raw=None):
    data = {}
    if addons is not None:
        data["add-ons.json"] = raw if raw is not None else json.dumps(addons)
    if extensions_ is not None:
        data["extensions"] = json.dumps(extensions_)
    return {"metadata": {"name": name}, "data": data}


EXT = {"extension_point_id": "service_provisioning", "extension_name": "db-schema", "details": {"provisioning": {
    "custom_steps": [{"step_key": "configure", "required": ["sc"],
                      "sections": {"s1": {"items": ["nodes", "flavour", "sc"]}},
                      "properties": {
                          "nodes": {"type": "range", "label": "Number of nodes", "min": 1, "max": 50, "default": 1},
                          "flavour": {"type": "radio", "label": "{{.global_flavour}}", "default": "A",
                                      "buttons": [{"value": "A", "label": "A"}, {"value": "B", "label": "B"}]},
                          "sc": {"type": "enum", "items": [{"id": "fs-file", "text": "fs-file"}]},
                          "unit": {"type": "enum", "default": "Gi", "items": [{"id": "optiongb", "text": "GB"}]},
                          "name": {"type": "string", "placeholder": "e.g. shared-thing", "validTextRegex": "[a-z]+"}},
                      "dependencies": {"flavour": {"oneOf": [{"properties": {
                          "flavour": {"enum": ["B"]}, "extra": {"type": "boolean", "default": True},
                          "title": {"type": "section_title"}}}]}}}],
    "hardware_configuration": {"scale_size": [
        {"value": "small", "label": "{{.x}}", "cpu_limit": "7", "memory_limit": "26Gi", "metadata": {"r": "2"}},
        {"value": "large", "label": "Large", "cpu_limit": "28", "memory_limit": "100Gi"}]}}}}


class Registry(unittest.TestCase):
    def test_lenient_and_capability(self):
        cms = [cm("a", {"db": {"max_instances": "1", "versions": {"5.4.0": {}},
                               "details": {"provisioning_type": "discovered-instance",
                                           "custom_resource_kind": "DbInstance",
                                           "custom_resource_status_field": "dbStatus",
                                           "provisionURL": "#/provisioning/db/5.4.0?extensionName=db-schema"}}}),
               cm("b", raw='{"broken": {"details": {"show_in_catalog": false,},},}', addons={}),
               cm("c", raw='{"bad": [}', addons={}),
               cm("d", {"ui": {"details": {"premium": False}}})]
        entries, notes = registry.parse_addon_cms(cms)
        db = entries["db"]
        self.assertTrue(db.instance_capable)
        self.assertEqual((db.cr_kind, db.status_field, db.max_instances, db.versions),
                         ("DbInstance", "dbStatus", 1, ["5.4.0"]))
        self.assertEqual(db.extension_name, "db-schema")
        self.assertIn("broken", entries)                 # trailing commas tolerated
        self.assertFalse(entries["ui"].instance_capable)
        self.assertEqual(len(notes), 1)                  # 'c' really is broken -> a notice, no crash

    def test_extensions(self):
        prov, details, _ = registry.parse_extensions([cm("e", extensions_=[EXT, {
            "extension_point_id": "service_instance_details", "match_instance_id": 17, "details": {}}])])
        self.assertIn("db-schema", prov)
        self.assertIn("17", details)


class S1Fields(unittest.TestCase):
    def setUp(self):
        self.fields, _ = extensions.provisioning_fields(EXT, sc_names={"fs-file", "rbd-block"})

    def test_types_labels_order(self):
        f = self.fields
        nodes = f[("parameters", "nodes")]
        self.assertEqual((nodes.type, nodes.minimum, nodes.maximum, nodes.default), ("integer", 1, 50, 1))
        self.assertTrue(nodes.payload)
        self.assertEqual(f[("parameters", "flavour")].enum, ["A", "B"])
        self.assertEqual(f[("parameters", "flavour")].label, "Flavour")          # i18n token -> humanised key
        self.assertLess(nodes.order, f[("parameters", "sc")].order)
        self.assertTrue(f[("parameters", "sc")].required)
        self.assertEqual(f[("parameters", "name")].pattern, "[a-z]+")
        self.assertEqual(f[("parameters", "name")].placeholder, "e.g. shared-thing")
        self.assertNotIn("shared", f[("parameters", "name")].description)    # placeholder is never evidence

    def test_storage_enum_is_soft_and_dependencies(self):
        sc = self.fields[("parameters", "sc")]
        self.assertTrue(sc.enum_soft)
        self.assertEqual(sc.role, Role.STORAGE_CLASS)
        extra = self.fields[("parameters", "extra")]
        self.assertEqual(extra.show_if, {("parameters", "flavour"): ["B"]})
        self.assertNotIn(("parameters", "title"), self.fields)

    def test_presets_attach_to_the_observed_carrier(self):
        obs, _ = observe([{"parameters": {"size": "small"}}])
        merged = merge([self.fields, obs])
        notes = []
        extensions.attach_presets(merged, notes)
        size = merged[("parameters", "size")]
        self.assertEqual(size.role, Role.SIZE_PRESET)
        self.assertEqual([p["value"] for p in size.presets], ["small", "large"])
        self.assertEqual(size.enum_labels["small"], "Small")      # i18n token -> humanised value
        self.assertEqual(notes, [])
        lone = dict(self.fields)
        extensions.attach_presets(lone, notes)
        self.assertIn(("parameters", "scaleConfig"), lone)
        self.assertTrue(notes)

    def test_ui_option_ids_give_way_to_live_values(self):
        obs, _ = observe([{"parameters": {"unit": "Gi", "flavour": "A"}}])
        merged = merge([self.fields, obs])
        extensions.reconcile_vocabulary(merged)
        self.assertEqual(merged[("parameters", "unit")].enum, ["Gi"])
        self.assertTrue(merged[("parameters", "unit")].enum_soft)
        self.assertEqual(merged[("parameters", "flavour")].enum, ["A", "B"])   # live value is in the enum


class ZenLink(unittest.TestCase):
    def test_value_anywhere(self):
        ids = {"1793299674066027", "42"}
        self.assertEqual(zen_link({"status": {"instance_id": 1793299674066027}}, ids), "1793299674066027")
        self.assertEqual(zen_link({"spec": {"zenServiceInstanceId": "42"}}, ids), "42")
        self.assertIsNone(zen_link({"spec": {"a": "42", "b": 1793299674066027}}, ids))     # ambiguous
        self.assertEqual(zen_link({"metadata": {"labels": {"icpdsupport/serviceInstanceId": "7"}}}), "7")


class Profile(unittest.TestCase):
    def test_auto_repair_precedence_and_persistence(self):
        with tempfile.TemporaryDirectory() as d:
            st = Settings(Path(d) / "managed-service-instances" / "settings.json")
            url = "https://api.c1:6443"
            with patch.dict("os.environ", {}, clear=False) as env:
                env.pop(profile.ENV_AUTO, None)
                self.assertEqual(profile.auto_repair_setting(url, None, st), (False, "default"))
                profile.save_auto_repair(url, True, st)
                self.assertEqual(profile.auto_repair_setting(url, None, st), (True, "saved"))
                self.assertEqual(profile.auto_repair_setting("https://api.other:6443", None, st),
                                 (False, "default"))            # per cluster
                self.assertEqual(profile.auto_repair_setting(url, False, st), (False, "flag"))
                env[profile.ENV_AUTO] = "off"
                self.assertEqual(profile.auto_repair_setting(url, None, st), (False, "env"))
                self.assertTrue(st.cluster(url)["auto_repair_profile"])   # run-only overrides don't rewrite
            self.assertEqual(oct(st.path.stat().st_mode & 0o777), "0o600")
            self.assertEqual(oct(st.path.parent.stat().st_mode & 0o777), "0o700")

    def test_preflight_is_a_no_op_when_healthy(self):
        ok = profile.ProfileStatus(state="ok", profile="p")
        with patch.object(profile, "check", return_value=ok), patch.object(profile, "repair") as rep:
            self.assertTrue(profile.preflight(None, "ns", CpdCli("p", binary="/bin/true"), auto=True).ok)
            rep.assert_not_called()
        stale = profile.ProfileStatus(state="stale", profile="p")
        with patch.object(profile, "check", side_effect=[stale, ok]), \
                patch.object(profile, "repair", return_value=(True, [])) as rep:
            st = profile.preflight(None, "ns", CpdCli("p", binary="/bin/true"), auto=True, log=lambda m: None)
            rep.assert_called_once()
            self.assertEqual(st.tag, "profile repaired")
        with patch.object(profile, "check", return_value=stale), patch.object(profile, "repair") as rep:
            profile.preflight(None, "ns", CpdCli("p", binary="/bin/true"), auto=False)
            rep.assert_not_called()


class CpdCliGuard(unittest.TestCase):
    def test_manage_is_refused(self):
        cli = CpdCli("p", binary="/bin/echo")
        for bad in (("manage", "login-to-ocp"), ("manage-k8s",), ()):
            with self.assertRaises(ValueError):
                cli.run(*bad)


if __name__ == "__main__":
    unittest.main()
