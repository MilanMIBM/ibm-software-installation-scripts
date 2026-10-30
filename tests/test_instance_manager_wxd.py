"""watsonx.data engines sub-provider: spec-driven (synthetic spec, presets, API; nothing runs)."""

import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from tui.common.state import State  # noqa: E402
from tui.instance_manager.discovery.openapi import inline, prototype_fields  # noqa: E402
from tui.instance_manager.model import Instance, Role  # noqa: E402
from tui.instance_manager.ops.subcli import start_values  # noqa: E402
from tui.instance_manager.subservices.wxd import provider as wp  # noqa: E402
from tui.instance_manager.subservices.wxd.operator import OperatorFacts  # noqa: E402


def scale(workers, cpu, mem):
    res = {"requests": {"cpu": cpu, "memory": mem}, "limits": {"cpu": cpu, "memory": mem}}
    return {"presto_coordinator": {"replicas": 1, "resources": res},
            "presto_worker": {"replicas": workers, "resources": res}}


PRESETS = {"small": scale(10, "5818m", "46.55G"), "starter": scale(1, "2", "8G"), "lightweight": scale(0, "1", "4G")}
NODE = {"type": "object", "required": ["node_type", "quantity"], "properties": {
    "node_type": {"type": "string", "example": "starter"}, "quantity": {"type": "integer", "minimum": 1}}}
SPEC = {"basePath": "/lakehouse/api/v3", "paths": {
    "/presto_engines": {"get": {}, "post": {"parameters": [{"in": "body", "schema": {"$ref": "#/definitions/prestoP"}}]}},
    "/presto_engines/{engine_id}": {"delete": {}},
    "/spark_engines": {"get": {}},                                        # list only: no POST
    "/milvus_services": {"get": {}, "post": {"parameters": [{"in": "body", "schema": {"$ref": "#/definitions/milvusP"}}]}},
    "/presto_engines/{engine_id}/catalogs": {"get": {}}},
    "definitions": {
        "prestoP": {"type": "object", "required": ["display_name", "configuration", "origin"], "properties": {
            "display_name": {"type": "string"}, "id": {"type": "string"},
            "origin": {"type": "string", "enum": ["native"], "example": "native"},
            "configuration": {"type": "object", "required": ["size_config", "coordinator", "worker"], "properties": {
                "size_config": {"type": "string", "enum": ["starter", "small", "custom"], "example": "starter"},
                "coordinator": {"$ref": "#/definitions/node"}, "worker": {"$ref": "#/definitions/node"}}}}},
        "node": NODE,
        "milvusP": {"type": "object", "required": ["display_name", "tshirt_size"], "properties": {
            "display_name": {"type": "string"}, "qw_replicas": {"type": "integer"}, "qw_cpu": {"type": "number"},
            "tshirt_size": {"type": "string", "enum": ["small", "medium"]}}}}}


class FakeFacts:
    error = None

    def presets(self):
        return PRESETS

    def documented_fields(self, f):
        return {f"presto_{c}_{x}" for c in ("coordinator", "worker")
                for x in ("replicas", "resources_requests_cpu", "resources_limits_cpu",
                          "resources_requests_memory", "resources_limits_memory")}


class FakeAPI:
    def __init__(self):
        self.calls = []

    def request(self, method, path, body=None):
        self.calls.append((method, path, body))
        if method == "GET":
            return {path.strip("/"): [{"id": "presto9", "display_name": "p-old", "status": "running",
                                       "configuration": {"worker": {"node_type": "bx2.4x16", "quantity": 10},
                                                         "coordinator": {"node_type": "bx2.4x16", "quantity": 1},
                                                         "size_config": "small"}}]
                    if path == "/presto_engines" else []}
        return {"id": "presto123"}


def engines():
    sp = wp.WxdEngines(cluster=type("C", (), {"find_crd": lambda s, k: None, "try_list": lambda s, p, **kw: []})())
    sp.facts, sp.spec = FakeFacts(), SPEC
    sp.parent = Instance("cpd:watsonx-data", "lakehouse", "ns", "u", {"spec": {"zenServiceInstanceId": "1"}},
                         State.HEALTHY, "")
    sp.namespace = "ns"
    api = FakeAPI()
    sp.api = lambda: api
    return sp, api


class Discovery(unittest.TestCase):
    def test_types_come_from_the_spec(self):
        sp, _ = engines()
        self.assertEqual(list(sp.collections()), ["milvus", "presto", "spark"])
        self.assertTrue(sp.itype("presto").creatable)
        self.assertTrue(sp.itype("milvus").creatable)                  # not just presto
        self.assertFalse(sp.itype("spark").creatable)                  # no POST in the spec
        self.assertTrue(sp.collections()["presto"]["delete"] is not None)

    def test_request_schema_to_fields(self):
        f = prototype_fields(inline(SPEC["definitions"]["prestoP"], SPEC["definitions"]), SPEC["definitions"])
        self.assertNotIn(("parameters", "id"), f)                      # server-assigned
        q = f[("parameters", "configuration", "worker", "quantity")]
        self.assertTrue(q.required)
        self.assertEqual((q.minimum, q.default), (1, 1))
        self.assertEqual(f[("parameters", "origin")].default, "native")  # required + example in enum

    def test_presto_form_starter_template_and_observed_values(self):
        sp, _ = engines()
        fm = sp.form_model(sp.itype("presto"))
        size = fm.fields[("parameters", "configuration", "size_config")]
        self.assertEqual(size.role, Role.SIZE_PRESET)
        small = next(p for p in size.presets if p["value"] == "small")["metadata"]
        self.assertEqual(small["presto_worker_replicas"], "10")
        self.assertEqual(small["configuration.worker.quantity"], "10")  # API quantities follow the template
        self.assertEqual(fm.fields[("parameters", "configuration", "worker", "node_type")].default, "bx2.4x16")
        self.assertIn(("parameters", "presto_worker_cpu"), fm.fields)   # operator resize fields

    def test_types_with_their_own_sizes_get_no_operator_resize(self):
        sp, _ = engines()
        fm = sp.form_model(sp.itype("milvus"))
        self.assertFalse(any(f.step == wp.RESIZE_STEP for f in fm.fields.values()))


class CreatePlan(unittest.TestCase):
    def _plan(self, sets, name="p1"):
        sp, api = engines()
        it = sp.itype("presto")
        fm = sp.form_model(it)
        size = ("parameters", "configuration", "size_config")
        sets = {size: "small", **sets}
        return sp.plan_create(it, fm, start_values(fm, sets), name), api

    def test_small_then_three_workers_patches_only_the_difference(self):
        plan, _ = self._plan({("parameters", "presto_worker_replicas"): "3"})
        self.assertTrue(plan.runnable, plan.errors)
        self.assertEqual([s.title.split(" ")[0] for s in plan.steps], ["POST", "resize", "watch"])
        self.assertIn('"presto_worker_replicas": "3"', plan.steps[1].preview)
        self.assertNotIn("cpu", plan.steps[1].preview)
        self.assertIn('"size_config": "small"', plan.steps[0].preview)
        self.assertIn('"display_name": "p1"', plan.steps[0].preview)
        self.assertNotIn("presto_worker", plan.steps[0].preview)       # resize values never go to the API

    def test_template_unchanged_registers_only_and_validation(self):
        plan, _ = self._plan({})
        self.assertEqual(len(plan.steps), 2)
        plan, _ = self._plan({("parameters", "presto_worker_replicas"): "0"}, name="")
        self.assertTrue(any("name is required" in e for e in plan.errors))
        self.assertTrue(any("at least 1" in e for e in plan.errors))
        plan, _ = self._plan({}, name="p-old")
        self.assertTrue(any("already exists" in e for e in plan.errors))


class Facts(unittest.TestCase):
    def test_one_exec_for_all_presets_and_documented_fields(self):
        out = ("#@@FILE /opt/ansible/config/scale/small.yaml\nscale:\n  presto_worker:\n    replicas: 10\n"
               "#@@FILE /opt/ansible/config/scale/bad.yaml\n: [\n")
        f = OperatorFacts(kube=None, operator_ns=["ops"], kind="WxdEngine")
        with patch.object(f, "pod", return_value=("ops", "p")), \
                patch.object(f, "_run", side_effect=[out, "# - presto_worker_replicas\n# - presto_x_y\nnot: a field"]):
            self.assertEqual(list(f.presets()), ["small"])
            self.assertEqual(f.documented_fields("t.yaml"), {"presto_worker_replicas", "presto_x_y"})

    def test_state_mapping(self):
        self.assertEqual(wp.api_state("RUNNING"), State.HEALTHY)
        self.assertEqual(wp.api_state("failed"), State.FAILING)
        self.assertEqual(wp.api_state("stopped"), State.INACTIVE)


if __name__ == "__main__":
    unittest.main()
