"""instance_manager L1 core: synthetic data only (no captured cluster objects)."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from tui.instance_manager.discovery import aliases, roles  # noqa: E402
from tui.instance_manager.discovery.merge import merge  # noqa: E402
from tui.instance_manager.discovery.observed import flatten, infer_type, observe  # noqa: E402
from tui.instance_manager.discovery.schema_walk import walk_crd  # noqa: E402
from tui.instance_manager.model import Field, Kind, Mutability, Need, Role  # noqa: E402
from tui.instance_manager.providers.k8s_crd.cluster import OwnerGraph  # noqa: E402
from tui.instance_manager.storage import field_need, sc_classifier  # noqa: E402

FILE, BLOCK = "fs-file", "rbd-block"


def edb_like(name="db1", nodes="2", cores="2", mem="4", sc=FILE, size="50"):
    """Shape of a schema-less wrapper CR that copies its payload to top-level aliases."""
    return {
        "blockStorageClass": sc, "sstorageclass": sc, "members": nodes, "numberofnodes": nodes,
        "corespernode": cores, "memorypernode": mem, "ssize": size, "sunit": "Gi", "storageSize": f"{size}Gi",
        "resources": {"limits": {"cpu": int(cores), "memory": f"{mem}Gi"},
                      "requests": {"cpu": int(cores), "memory": f"{mem}Gi"}},
        "parameters": {"numberofnodes": nodes, "corespernode": cores, "memorypernode": mem, "ssize": size,
                       "sunit": "Gi", "sstorageclass": sc, "version": "18.3"},
        "version": "18.3", "superuserSecret": "<no value>", "shutdown": False, "enableMultiReplicas": False,
        "serviceInstanceName": name,
    }


def model(specs, scs=(FILE, BLOCK), schema=None):
    fields_obs, flats = observe(specs)
    fields = merge([fields_obs, schema or {}])
    roles.infer_all(fields, roles.RoleContext(storage_classes=set(scs)))
    aliases.detect(fields, flats)
    return fields, flats


def pvc(name, sc, modes, uid, ns="ns", owner=None, mode="Filesystem", sink=None):
    meta = {"name": name, "namespace": ns, "uid": uid}
    if owner:
        meta["ownerReferences"] = [{"apiVersion": owner[0], "kind": owner[1], "uid": owner[2], "controller": True}]
    p = {"metadata": meta, "spec": {"storageClassName": sc, "accessModes": modes, "volumeMode": mode},
         "status": {"phase": "Bound"}}
    if sink:
        p["_sink"] = sink
    return p


def sc(name, provisioner, **params):
    return {"metadata": {"name": name}, "provisioner": provisioner, "parameters": params,
            "allowVolumeExpansion": True}


class SchemaWalk(unittest.TestCase):
    CRD = {"spec": {"group": "g.io", "names": {"kind": "Db", "plural": "dbs"}, "scope": "Namespaced",
                    "versions": [{"name": "v1", "served": True, "storage": True,
                                  "subresources": {"scale": {"specReplicasPath": ".spec.instances"}},
                                  "schema": {"openAPIV3Schema": {"properties": {"spec": {
                                      "type": "object", "required": ["instances"],
                                      "properties": {
                                          "instances": {"type": "integer", "minimum": 1, "maximum": 10},
                                          "resources": {"type": "object", "properties": {
                                              "limits": {"type": "object", "additionalProperties": {
                                                  "x-kubernetes-int-or-string": True}},
                                              "requests": {"type": "object", "additionalProperties": {
                                                  "x-kubernetes-int-or-string": True}}}},
                                          "storage": {"type": "object", "properties": {
                                              "size": {"x-kubernetes-int-or-string": True},
                                              "storageClass": {"type": "string",
                                                               "x-kubernetes-validations": [
                                                                   {"rule": "self == oldSelf"}]}}},
                                          "volumes": {"type": "array", "items": {"type": "object", "properties": {
                                              "name": {"type": "string"}, "size": {"type": "string"}}}},
                                      }}}}}}]}}

    def test_shapes(self):
        f = walk_crd(self.CRD)
        self.assertEqual(f[("instances",)].role, Role.REPLICAS)
        self.assertTrue(f[("instances",)].required)
        self.assertEqual((f[("instances",)].minimum, f[("instances",)].maximum), (1, 10))
        self.assertEqual(f[("resources",)].type, "resources")
        self.assertEqual(f[("storage", "size")].type, "quantity")
        self.assertEqual(f[("storage", "storageClass")].mutability, Mutability.IMMUTABLE)
        self.assertIn(("volumes", "[]", "size"), f)

    def test_schema_list_paths_map_onto_observed_names(self):
        obs, _ = observe([{"volumes": [{"name": "data", "size": "1Gi"}, {"name": "logs", "size": "2Gi"}]}])
        fields = merge([obs, walk_crd(self.CRD)])
        self.assertIn(("volumes", "[name=data]", "size"), fields)
        self.assertNotIn(("volumes", "[]", "size"), fields)


class Observed(unittest.TestCase):
    def test_flatten(self):
        flat = flatten({"a": {"b": 1}, "s": [{"name": "x", "v": 1}], "l": [1, 2], "u": "<no value>"})
        self.assertEqual(flat[("a", "b")], 1)
        self.assertEqual(flat[("s", "[name=x]", "v")], 1)
        self.assertEqual(flat[("l",)], [1, 2])
        self.assertIsNone(flat[("u",)])

    def test_infer_type(self):
        self.assertEqual(infer_type(["4Gi"]), "quantity")
        self.assertEqual(infer_type(["2"]), "string")
        self.assertEqual(infer_type([True]), "boolean")
        self.assertEqual(infer_type([1, 2.5]), "number")


class Roles(unittest.TestCase):
    def test_edb_like(self):
        f, _ = model([edb_like()])
        r = {k: v.role for k, v in f.items()}
        self.assertEqual(r[("members",)], Role.REPLICAS)          # not "mem" -> memory
        self.assertEqual(r[("numberofnodes",)], Role.REPLICAS)
        self.assertEqual(r[("memorypernode",)], Role.MEMORY)
        self.assertEqual(r[("corespernode",)], Role.CPU)
        self.assertEqual(r[("resources", "limits", "memory")], Role.MEMORY)
        self.assertEqual(r[("blockStorageClass",)], Role.STORAGE_CLASS)
        self.assertEqual(f[("blockStorageClass",)].role_evidence.source, "live")
        self.assertEqual(r[("ssize",)], Role.STORAGE_SIZE)
        self.assertEqual(r[("sunit",)], Role.UNIT)
        self.assertEqual(r[("superuserSecret",)], Role.SECRET_REF)
        self.assertEqual(r[("shutdown",)], Role.LIFECYCLE)
        self.assertEqual(r[("enableMultiReplicas",)], Role.OTHER)   # boolean never gets a capacity role


class Aliases(unittest.TestCase):
    def test_single_instance_candidates(self):
        f, _ = model([edb_like()])
        self.assertEqual(set(f[("members",)].aliases), {("numberofnodes",), ("parameters", "numberofnodes")})
        self.assertIn(("resources", "limits", "memory"), f[("memorypernode",)].aliases)   # "4" ~ "4Gi"
        self.assertIn(("storageSize",), f[("ssize",)].aliases)
        self.assertNotIn(("corespernode",), f[("members",)].aliases)   # equal "2" but different role
        self.assertFalse(f[("members",)].alias_confirmed)

    def test_confirmed_and_broken(self):
        f, _ = model([edb_like("a", nodes="2", cores="2"), edb_like("b", nodes="3", cores="3")])
        self.assertTrue(f[("members",)].alias_confirmed)
        f, _ = model([edb_like("a"), {**edb_like("b"), "members": "5"}])
        self.assertNotIn(("members",), f[("numberofnodes",)].aliases)


class Merge(unittest.TestCase):
    def test_tighten_and_conflict(self):
        a = {("x",): Field(path=("x",), type="integer", minimum=1, maximum=50, enum=None, sources={"S1"})}
        b = {("x",): Field(path=("x",), type="integer", minimum=4, maximum=100, sources={"S5"})}
        m = merge([a, b])[("x",)]
        self.assertEqual((m.minimum, m.maximum), (4, 50))
        self.assertEqual(m.sources, {"S1", "S5"})
        c = {("e",): Field(path=("e",), enum=["a"])}
        d = {("e",): Field(path=("e",), enum=["b"])}
        self.assertTrue(merge([c, d])[("e",)].notices)


class StorageClasses(unittest.TestCase):
    def test_kinds(self):
        scs = [sc("decl", "x.example"), sc("cfs", "openshift-storage.cephfs.csi.ceph.com"),
               sc("census-file", "unknown.example"), sc("census-block", "unknown.example"),
               sc("vm", "openshift-storage.rbd.csi.ceph.com"), sc("obc", "openshift-storage.noobaa.io/obc"),
               sc("px", "pxd.portworx.com", sharedv4="true"), sc("mystery", "unknown.example"),
               sc("forced", "openshift-storage.cephfs.csi.ceph.com")]
        pvcs = [pvc("a", "census-file", ["ReadWriteMany"], "1"),
                *[pvc(f"b{i}", "census-block", ["ReadWriteOnce"], f"b{i}") for i in range(3)],
                pvc("vmdisk", "vm", ["ReadWriteMany"], "v", mode="Block")]
        info = sc_classifier.classify(scs, pvcs, declared={"decl": Kind.BLOCK},
                                      overrides={"forced": Kind.BLOCK})
        self.assertEqual(info["decl"].kind, Kind.BLOCK)
        self.assertEqual(info["cfs"].kind, Kind.FILE)
        self.assertEqual(info["census-file"].kind, Kind.FILE)
        self.assertEqual(info["census-block"].kind, Kind.BLOCK)
        self.assertEqual(info["vm"].kind, Kind.BLOCK)        # raw-block RWX is not file storage
        self.assertTrue(info["vm"].raw_block)
        self.assertEqual(info["obc"].kind, Kind.OBJECT)
        self.assertEqual(info["px"].kind, Kind.FILE)
        self.assertEqual(info["mystery"].kind, Kind.UNKNOWN)
        self.assertEqual(info["forced"].kind, Kind.BLOCK)


class FieldNeed(unittest.TestCase):
    SC = sc_classifier.classify([sc(FILE, "x.cephfs"), sc(BLOCK, "x.rbd"), sc("obc", "y/obc")], [])

    def _assess(self, spec, owned, peers=(), path=("blockStorageClass",)):
        fields, flats = model([spec])
        return field_need.assess(fields[path], fields, [("db1", flats[0])], lambda n: owned, self.SC,
                                 lambda keys, ex: [p for p in peers if p["_sink"] in keys])

    def test_value_flow_rwo_on_file_class_is_flagged(self):
        owned = [pvc("d1", FILE, ["ReadWriteOnce"], "o1", sink="pg.io/Cluster")]
        peers = [pvc(f"p{i}", BLOCK, ["ReadWriteOnce"], f"p{i}", sink="pg.io/Cluster") for i in range(4)]
        need = self._assess(edb_like(sc=FILE), owned, peers)
        self.assertEqual(need.need, Need.BLOCK)
        self.assertTrue(any("peers: 4/4" in e.detail for e in need.evidence))
        self.assertEqual(len(need.mismatches), 1)
        self.assertFalse(need.accepts(Kind.OBJECT))

    def test_rwx_means_file_even_with_block_in_the_name(self):
        need = self._assess(edb_like(sc=FILE), [pvc("d1", FILE, ["ReadWriteMany"], "o1")])
        self.assertEqual(need.need, Need.FILE)
        self.assertTrue(any("outranked" in e.detail for e in need.evidence))

    def test_peers_decide_without_flow_and_tokens_last(self):
        peers = [pvc(f"p{i}", FILE, ["ReadWriteMany"], f"p{i}", sink="a/B") for i in range(3)]
        owned = [pvc("d1", "other-class", ["ReadWriteOnce"], "o1", sink="a/B")]
        self.assertEqual(self._assess(edb_like(sc=FILE), owned, peers).need, Need.BLOCK)  # flow: no PVC on FILE
        self.assertEqual(self._assess(edb_like(sc=FILE), []).need, Need.BLOCK)            # name hint only

    def test_enum_with_both_kinds_is_either(self):
        fields, flats = model([{"storageClass": FILE}])
        f = fields[("storageClass",)]
        f.enum = [FILE, BLOCK]
        need = field_need.assess(f, fields, [("x", flats[0])], lambda n: [], self.SC)
        self.assertEqual(need.need, Need.EITHER)
        self.assertTrue(need.accepts(Kind.FILE) and need.accepts(Kind.BLOCK))


class FakeCluster:
    def __init__(self, pvcs, stss, objects):
        self._pvcs, self._stss, self._objects = pvcs, stss, objects

    def pvcs(self):
        return self._pvcs

    def statefulsets(self):
        return self._stss

    def resource_path(self, api_version, kind, ns):
        return f"{api_version}/{kind}/{ns}"

    def try_list(self, path):
        return self._objects.get(path, [])

    def list_many(self, paths):
        return {p: self.try_list(p) for p in paths}


class Graph(unittest.TestCase):
    def test_bottom_up_and_template_pvcs(self):
        wrapper = {"apiVersion": "w.io/v1", "kind": "Wrap", "metadata": {"name": "w", "namespace": "ns", "uid": "W"}}
        sink = {"metadata": {"name": "c", "namespace": "ns", "uid": "C", "ownerReferences": [
            {"apiVersion": "w.io/v1", "kind": "Wrap", "uid": "W", "controller": True}]}}
        sts = {"metadata": {"name": "web", "namespace": "ns", "uid": "S", "ownerReferences": [
            {"apiVersion": "w.io/v1", "kind": "Wrap", "uid": "W", "controller": True}]},
            "spec": {"volumeClaimTemplates": [{"metadata": {"name": "data"}}]}}
        pvcs = [pvc("c-1", BLOCK, ["ReadWriteOnce"], "P1", owner=("pg.io/v1", "Cluster", "C")),
                pvc("data-web-0", FILE, ["ReadWriteMany"], "P2"),
                pvc("other", FILE, ["ReadWriteMany"], "P3")]
        fc = FakeCluster(pvcs, [sts], {"pg.io/v1/Cluster/ns": [sink], "w.io/v1/Wrap/ns": [wrapper]})
        g = OwnerGraph(fc).build({"ns"})
        self.assertEqual({p["metadata"]["name"] for p in g.pvcs_under("W")}, {"c-1", "data-web-0"})
        self.assertEqual(pvcs[0]["_sink"], "pg.io/Cluster")
        self.assertEqual(pvcs[1]["_sink"], "w.io/Wrap")      # template PVC -> its StatefulSet's controller
        self.assertEqual(len(g.peer_pvcs({"pg.io/Cluster"}, {"P1"})), 0)


if __name__ == "__main__":
    unittest.main()
