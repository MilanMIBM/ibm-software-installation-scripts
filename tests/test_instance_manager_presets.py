"""Size presets like the web console: a t-shirt size, its sizes behind "advanced settings" (synthetic only)."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from tui.instance_manager.model import Role  # noqa: E402
from tui.instance_manager.subservices.wxd import provider as wp  # noqa: E402


def node(rep, cpu, mem):
    return {"replicas": rep, "resources": {"requests": {"cpu": cpu, "memory": mem},
                                           "limits": {"cpu": cpu * 2, "memory": mem}}}


PRESETS = {
    "starter": {"milvus_querynode": node(1, 0.5, "2G"), "milvus_datacoord": node(1, 0.5, "0.5G"),
                "etcd": node(3, 0.5, "1G")},
    "small": {"milvus_querynode": node(10, 2, "8G"), "milvus_datacoord": node(1, 0.5, "0.5G"),
              "etcd": node(3, 0.5, "1G")},
    "custom": {"milvus_querynode": node(9, 4, "16G"), "milvus_datacoord": node(1, 0.5, "0.5G"),
               "etcd": node(3, 1, "2G")},
}


def prop(t, desc, **kw):
    return {"type": t, "description": desc, **kw}


SCHEMA = {"type": "object", "required": ["origin"], "properties": {
    "origin": prop("string", "Origin of the milvus service", enum=["native"]),
    "tshirt_size": prop("string", "Predefined tshirt size for the milvus service",
                        enum=["starter", "small", "custom"]),
    "qw_cpu": prop("number", "query worker cpu", minimum=0.01),
    "qw_memory": prop("number", "query worker memory", minimum=0.01),
    "qw_replicas": prop("integer", "query worker replicas", minimum=1),
    "dc_memory": prop("number", "data coordinator memory, only configurable in cpd"),
    "etcd_cpu": prop("number", "etcd cpus, only configurable in cpd"),
    "vector_dimension": prop("integer", "vector dimension"),
}}
SPEC = {"paths": {"/milvus_services": {"get": {}, "post": {"parameters": [{"in": "body", "schema": SCHEMA}]}}},
        "definitions": {}}


class Facts:
    def presets(self):
        return PRESETS

    def documented_fields(self, task):
        return set()


def engines():
    e = wp.WxdEngines(cluster=type("C", (), {"find_crd": lambda s, k: None,
                                             "try_list": lambda s, p, **kw: []})())
    e.spec, e.facts = SPEC, Facts()
    e._rows = lambda kind, fresh=False: []
    return e


def milvus_model():
    e = engines()
    return e, e.form_model(e.itype("milvus"))


class Mapping(unittest.TestCase):
    def test_units_and_components(self):
        self.assertEqual((wp.gigabytes("8G"), wp.gigabytes("16Gi"), wp.gigabytes("512Mi"), wp.gigabytes("x")),
                         (8.0, 16.0, 0.5, None))
        self.assertEqual((wp.cores("500m"), wp.cores(2), wp.cores("")), (0.5, 2.0, None))
        keys = {"milvus_querynode", "milvus_datacoord", "milvus_rootcoord", "milvus_proxy", "etcd"}
        self.assertEqual(wp.api_component("qw_cpu", "query worker cpu", "milvus", keys), "milvus_querynode")
        self.assertEqual(wp.api_component("rc_memory", "root coodinator memory", "milvus", keys), "milvus_rootcoord")
        self.assertEqual(wp.api_component("proxy_cpu", "proxy cpus, only in cpd", "milvus", keys), "milvus_proxy")
        self.assertEqual(wp.api_component("etcd_cpu", "etcd cpus", "milvus", keys), "etcd")
        self.assertIsNone(wp.api_component("vector", "vector", "milvus", keys))

    def test_sizes_listed_only_in_a_description(self):
        text = ("CPD supported sizes are: custom, starter, small, medium, large, xlarge, and xxlarge. IBM cloud "
                "supported sizes are: custom, starter, small, medium, large, cache_optimized.")
        self.assertEqual(wp.sizes_in_text(text, {"starter", "small", "large", "custom", "cache_optimized"}),
                         ["custom", "starter", "small", "large"])          # the CPD list, known names only
        self.assertEqual(wp.sizes_in_text("pick small or large", {"small", "large"}), ["small", "large"])
        self.assertEqual(wp.sizes_in_text("", {"small"}), [])

    def test_each_size_fills_the_api_sizing_fields(self):
        _, fm = milvus_model()
        size = next(f for f in fm.fields.values() if f.role == Role.SIZE_PRESET)
        self.assertEqual(size.default, "small")                      # starts on a named size
        small = next(p for p in size.presets if p["value"] == "small")
        self.assertEqual(small["metadata"], {"qw_cpu": "2", "qw_memory": "8", "qw_replicas": "10",
                                             "dc_memory": "0.5", "etcd_cpu": "0.5"})
        self.assertEqual(small["cpu"], "22")                          # 10x2 + 1x0.5 + 3x0.5 requested
        self.assertIn("GB requested in total", small["memory"])
        self.assertEqual(fm.fields[("parameters", "qw_cpu")].default, "2")   # the starting size fills the form

    def test_a_named_size_sends_only_the_size_custom_sends_the_sizes(self):
        e, fm = milvus_model()
        vals = {p: f.default for p, f in fm.fields.items()}
        vals[("parameters", "origin")] = "native"
        body, _custom, chosen, _ = e.create_bodies(fm, vals, "mv1")
        self.assertEqual(chosen, "small")
        self.assertEqual(sorted(body), ["display_name", "origin", "tshirt_size"])
        vals[("parameters", "tshirt_size")] = "custom"
        vals[("parameters", "qw_replicas")] = "4"
        body, *_ = e.create_bodies(fm, vals, "mv1")
        self.assertEqual((body["tshirt_size"], body["qw_replicas"], body["qw_cpu"]), ("custom", 4, 2.0))


class AdvancedSettingsUI(unittest.IsolatedAsyncioTestCase):
    async def test_advanced_hidden_preset_fills_and_fine_tune_switches_to_custom(self):
        from textual.app import App
        from textual.widgets import Input, Select

        from tui.common.toggle import ToggleSetting
        from tui.instance_manager.ui.form_view import FormView, create_spec
        from tui.instance_manager.ui.forms import FieldRow

        e, fm = milvus_model()
        spec = create_spec(e.itype("milvus"), fm, {}, offers_vault=False)
        self.assertEqual(spec.size, ("parameters", "tshirt_size"))
        self.assertEqual({p[-1] for p in spec.advanced}, {"qw_cpu", "qw_memory", "qw_replicas", "dc_memory",
                                                         "etcd_cpu"})

        class T(App):
            def compose(self):
                yield FormView(spec, {}, id="form")

        app = T()
        async with app.run_test(size=(160, 60)) as pilot:
            form = app.query_one(FormView)

            def row(key):
                return next(r for r in form.query(FieldRow) if r.f.path[-1] == key)

            async def until(cond):
                for _ in range(200):
                    await pilot.pause(0.02)
                    if cond():
                        return True
                return False

            self.assertTrue(await until(lambda: form.query(FieldRow) and not row("qw_cpu").display))
            self.assertTrue(row("vector_dimension").display)          # not a sizing field: always shown
            self.assertTrue(row("tshirt_size").display)
            form.query_one("#advanced", ToggleSetting).toggle()
            self.assertTrue(await until(lambda: row("qw_cpu").display))
            self.assertEqual(row("qw_cpu").value, "2")
            # another size fills the advanced fields
            row("tshirt_size").query_one(Select).value = "starter"
            self.assertTrue(await until(lambda: row("qw_replicas").value == "1"))
            self.assertEqual(row("qw_memory").value, "2")
            # fine-tuning one: the size becomes custom and the typed values stay
            row("qw_replicas").query_one(Input).value = "3"
            self.assertTrue(await until(lambda: row("tshirt_size").value == "custom"))
            await pilot.pause(0.2)
            self.assertEqual((row("qw_replicas").value, row("qw_memory").value), ("3", "2"))
            # the advanced section closes; its values are still what gets sent (and checked)
            form.query_one("#advanced", ToggleSetting).toggle()
            self.assertTrue(await until(lambda: not row("qw_cpu").display))
            self.assertEqual(form.values()[("parameters", "qw_replicas")], "3")


if __name__ == "__main__":
    unittest.main()
