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


# -- cache plan C3: operator facts + embedded spec cached by image digest ---------------------------
class _Src:
    """A minimal SourceCache stand-in (get / put)."""

    def __init__(self):
        self.parts = {}

    def get(self, part):
        return self.parts.get(part)

    def put(self, part, obj, fp="", took=None):
        self.parts[part] = obj


def _pod(name, image, phase="Running"):
    return {"metadata": {"name": name}, "status": {"phase": phase, "containerStatuses": [
        {"image": "icr.io/op:1", "imageID": f"icr.io/op@sha256:{image}"}]}}


class FakeOpKube:
    WATCHES = "- kind: WxdEngine\n  group: watsonxdata.ibm.com\n"

    def __init__(self, pods, operator="op-b"):
        self.pods, self.operator = pods, operator
        self.execs = []

    def get(self, path, **kw):
        from tui.common.kube import KubeError
        if path.endswith("/pods"):
            return {"items": self.pods}
        name = path.rsplit("/", 1)[-1]
        hit = next((p for p in self.pods if p["metadata"]["name"] == name), None)
        if hit is None:
            raise KubeError(404, name)
        return hit

    def exec(self, ns, pod, cmd, timeout=15):
        self.execs.append((pod, cmd[-1]))
        if cmd[-1] == "/opt/ansible/watches.yaml":
            return self.WATCHES if pod == self.operator else "- kind: Other\n"
        if "scale" in cmd[-1]:
            return "#@@FILE /opt/ansible/config/scale/small.yaml\nscale:\n  presto_worker:\n    replicas: 10\n"
        return "# - presto_worker_replicas\n"


class FactsCache(unittest.TestCase):
    def _warm(self):
        src = _Src()
        kube = FakeOpKube([_pod(f"op-{c}", "aaa" if c == "b" else c * 3) for c in "abcdefghij"])
        f = OperatorFacts(kube, ["ops"], "WxdEngine", sources=src)
        self.assertEqual(f.pod(), ("ops", "op-b"))                        # found by the parallel scan
        self.assertEqual(list(f.presets()), ["small"])
        self.assertEqual(f.documented_fields("t.yaml"), {"presto_worker_replicas"})
        self.assertEqual(src.parts["subservices/wxd/facts"]["image"], "sha256:aaa")
        return src, kube

    def test_cached_pod_and_facts_need_no_exec(self):
        src, _ = self._warm()
        kube = FakeOpKube([_pod("op-a", "zzz"), _pod("op-b", "aaa")])
        f = OperatorFacts(kube, ["ops"], "WxdEngine", sources=src)
        self.assertEqual(f.pod(), ("ops", "op-b"))
        self.assertEqual(list(f.presets()), ["small"])
        self.assertEqual(f.documented_fields("t.yaml"), {"presto_worker_replicas"})
        self.assertEqual(kube.execs, [])                                   # all from the cache
        self.assertTrue(f.from_cache)

    def test_restarted_operator_is_found_by_its_image(self):              # V-C7
        src, _ = self._warm()
        kube = FakeOpKube([_pod("op-a", "zzz"), _pod("op-b-new", "aaa")], operator="op-b-new")
        f = OperatorFacts(kube, ["ops"], "WxdEngine", sources=src)
        self.assertEqual(f.pod(), ("ops", "op-b-new"))
        self.assertEqual(list(f.presets()), ["small"])
        self.assertEqual(kube.execs, [])

    def test_a_new_operator_image_rereads_the_facts(self):
        src, _ = self._warm()
        kube = FakeOpKube([_pod("op-a", "zzz"), _pod("op-b", "bbb")])
        f = OperatorFacts(kube, ["ops"], "WxdEngine", sources=src)
        self.assertEqual(f.pod(), ("ops", "op-b"))
        self.assertFalse(f.from_cache)
        f.presets()
        self.assertTrue(any("scale" in c for _, c in kube.execs))           # re-read from the new operator
        self.assertEqual(src.parts["subservices/wxd/facts"]["image"], "sha256:bbb")


class SpecCache(unittest.TestCase):
    def test_spec_is_reused_while_the_api_pod_runs_the_same_image(self):
        from tui.instance_manager.subservices import embedded_spec as es
        src = _Src()
        src.parts[es.SPEC_PART] = {"base": "/lakehouse/api/v3", "namespace": "ns", "service": "lh-api",
                                   "pod": "api-1", "image": "sha256:aaa", "spec": SPEC}
        with patch.object(es, "_service_pods", return_value=[_pod("api-2", "aaa")]), \
                patch.object(es, "_discover", side_effect=AssertionError("no discovery expected")):
            es._cache.clear()
            self.assertEqual(es.find_spec(None, "ns", "/lakehouse/api/v3", sources=src), SPEC)
        with patch.object(es, "_service_pods", return_value=[_pod("api-3", "bbb")]), \
                patch.object(es, "_discover", return_value=(SPEC, {"service": "lh-api", "pod": "api-3",
                                                                   "image": "sha256:bbb"})) as disc:
            es._cache.clear()
            es.find_spec(None, "ns", "/lakehouse/api/v3", sources=src)
            disc.assert_called_once()                                       # a new API image: discovered again
        self.assertEqual(src.parts[es.SPEC_PART]["image"], "sha256:bbb")
        es._cache.clear()

    def test_trim_keeps_collections_and_definitions(self):
        from tui.instance_manager.subservices.embedded_spec import trim_spec
        doc = {**SPEC, "paths": {**SPEC["paths"], "/catalogs": {"get": {}}}, "info": {"x": 1}}
        t = trim_spec(doc)
        self.assertNotIn("/catalogs", t["paths"])
        self.assertIn("/presto_engines/{engine_id}", t["paths"])
        self.assertNotIn("info", t)
        sp, _ = engines()
        sp.spec = t
        self.assertEqual(list(sp.collections()), ["milvus", "presto", "spark"])
