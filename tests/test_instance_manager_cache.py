"""instance_manager discovery cache (cache plan C1/C2): codec, store, redaction - synthetic data only."""

import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from tui.common.state import State  # noqa: E402
from tui.instance_manager.cache import codec, redact  # noqa: E402
from tui.instance_manager.cache.store import CacheStore, scope_name  # noqa: E402
from tui.instance_manager.discovery.merge import merge  # noqa: E402
from tui.instance_manager.discovery.observed import observe  # noqa: E402
from tui.instance_manager.discovery.roles import RoleContext, infer_all  # noqa: E402
from tui.instance_manager.model import (  # noqa: E402
    Evidence,
    FormModel,
    Instance,
    InstanceType,
    Kind,
    Mutability,
    Need,
    Role,
    StorageClassInfo,
    StorageNeed,
)
from tui.instance_manager.providers.cpd import extensions  # noqa: E402
from tui.instance_manager.providers.cpd.registry import AddonEntry  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_instance_manager_cpd import EXT  # noqa: E402

SECRET_VALUE = "Sup3r-S3cret-Pa55"


def rich_model() -> FormModel:
    """Every Field attribute set to something non-default, from the real discovery code."""
    s1, _ = extensions.provisioning_fields(EXT, sc_names={"fs-file", "rbd-block"})
    obs, _ = observe([{"parameters": {"size": "small", "nodes": 2, "unit": "Gi", "flag": True,
                                      "list": [{"name": "a", "v": 1}], "admin_password": SECRET_VALUE}}])
    fields = merge([s1, obs])
    extensions.attach_presets(fields, [])
    infer_all(fields, RoleContext(storage_classes={"fs-file"}))
    f = fields[("parameters", "nodes")]
    f.aliases = [("spec", "nodes"), ("spec", "[name=x]", "n")]
    f.alias_confirmed = True
    f.mutability = Mutability.IMMUTABLE
    f.notices.append("a notice")
    f.storage = StorageNeed(Need.BLOCK, [Evidence("live", "peers 9/9", 0.7)], ["i: fs is file storage"])
    f.enum_labels = {7: "seven", 2.5: "two and a half", "x": "ex"}
    f.preserve_unknown = True
    return FormModel("cpd:db", fields, ["model notice"], 3)


class Codec(unittest.TestCase):
    def test_model_round_trip(self):
        fm = rich_model()
        back = codec.dec_model(json.loads(json.dumps(codec.enc_model(fm, redact=False))))
        self.assertEqual(back, fm)
        self.assertIsInstance(next(iter(back.fields)), tuple)
        self.assertEqual(back.fields[("parameters", "extra")].show_if, {("parameters", "flavour"): ["B"]})

    def test_redacted_model_drops_secret_values(self):
        fm = rich_model()
        secret = fm.fields[("parameters", "admin_password")]
        self.assertEqual(secret.role, Role.SECRET)
        text = json.dumps(codec.enc_model(fm, redact=True))
        self.assertNotIn(SECRET_VALUE, text)
        back = codec.dec_model(json.loads(text))
        self.assertEqual(back.fields[("parameters", "admin_password")].observed, [])
        self.assertEqual(back.fields[("parameters", "nodes")], fm.fields[("parameters", "nodes")])

    def test_sc_type_instance_round_trip(self):
        sc = {"fs": StorageClassInfo("fs", "x.cephfs", Kind.FILE, [Evidence("config", "declared", 0.95)], True,
                                     True, "Immediate", {"ReadWriteMany": 3}, False)}
        self.assertEqual(codec.dec_sc_map(json.loads(json.dumps(codec.enc_sc_map(sc)))), sc)
        crd = {"metadata": {"name": "dbs.db.io"}, "spec": {}}
        it = InstanceType(key="cpd:db", display="db", group="db.io", version="v1", kind="Db", plural="dbs",
                          crd=crd, status_path=".status.x", max_instances=1, provider="cpd", notices=["n"],
                          versions=["5.4.0"], meta={"addon": AddonEntry("db", "cm", {"a": 1}, ["5.4.0"], 1, "Db")})
        back = codec.dec_type(json.loads(json.dumps(codec.enc_type(it))), {"dbs.db.io": crd}.get)
        self.assertEqual(back, it)
        inst = Instance("cpd:db", "db-a", "ns", "u1", {"spec": {"password": SECRET_VALUE}}, State.FAILING, "bad",
                        ["zen+cr"], "db-a", {"zen": {"id": "7", "provision_status": "FAILED", "token": "t0k"}})
        d = codec.enc_instance(inst)
        self.assertNotIn(SECRET_VALUE, json.dumps(d))
        self.assertNotIn("t0k", json.dumps(d))
        got = codec.dec_instance(json.loads(json.dumps(d)))
        self.assertEqual((got.name, got.state, got.meta["zen"]["id"], got.obj, got.meta["cached"]),
                         ("db-a", State.FAILING, "7", {}, True))


class Redaction(unittest.TestCase):
    def test_secret_keys_only_and_shape_kept(self):
        params = {"adminPassword": SECRET_VALUE, "api_token": "abc", "nodes": 3, "empty_password": "",
                  "nested": {"passwords": {"admin": "x"}, "storageClass": "fs"}, "flag_token": True}
        got = redact.redact(params)
        self.assertEqual(got["adminPassword"], redact.REDACTED)
        self.assertEqual(got["api_token"], redact.REDACTED)
        self.assertEqual(got["nested"]["passwords"]["admin"], redact.REDACTED)    # everything below a secret key
        self.assertEqual((got["nodes"], got["empty_password"], got["flag_token"]), (3, "", True))
        self.assertEqual(got["nested"]["storageClass"], "fs")
        self.assertEqual(params["adminPassword"], SECRET_VALUE)                   # a copy


class Store(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "instance_manager_cache"

    def tearDown(self):
        self.tmp.cleanup()

    def test_scope_name(self):
        self.assertEqual(scope_name("https://api.c.example.com:6443", "cpd"), "api.c.example.com_6443--cpd")
        self.assertEqual(scope_name("https://api.c:6443", None, "--crd-ab12"), "api.c_6443--all--crd-ab12")

    def test_atomic_parts_manifest_and_permissions(self):
        st = CacheStore("s", self.root)
        st.write("sources/addons", {"a": 1}, fp="rv1", took_s=0.5)
        st.write("models/cpd_db", {"m": [1, 2]})
        st.save_manifest()
        self.assertEqual(stat.S_IMODE(os.stat(st.dir).st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(os.stat(st.dir / "sources" / "addons.json").st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(st.dir / "manifest.json").st_mode), 0o600)
        again = CacheStore("s", self.root)
        self.assertEqual(again.read("sources/addons"), {"a": 1})
        self.assertEqual(again.meta("sources/addons")["fp"], "rv1")
        # a part that doesn't match the manifest counts as missing, never an error
        (st.dir / "models" / "cpd_db.json").write_text('{"m": [9]}')
        self.assertIsNone(CacheStore("s", self.root).read("models/cpd_db"))
        (st.dir / "sources" / "addons.json").write_text("{not json")
        self.assertIsNone(CacheStore("s", self.root).read("sources/addons"))
        self.assertIsNone(again.read("never/written"))
        self.assertEqual(again.drop_prefix("models/"), ["models/cpd_db"])
        self.assertTrue(again.clear())
        self.assertFalse(st.dir.exists())

    def test_bad_part_names_are_refused(self):
        st = CacheStore("s", self.root)
        with self.assertRaises(ValueError):
            st.write("../escape", {})


if __name__ == "__main__":
    unittest.main()


# -- C2: the manager, the providers' read-through hooks and the probe on a fake cluster ----------------
from unittest.mock import patch  # noqa: E402

from tui.common.kube import KubeError  # noqa: E402
from tui.instance_manager.cache import summary as sm  # noqa: E402
from tui.instance_manager.cache.manager import DiscoveryCache, model_part  # noqa: E402
from tui.instance_manager.cache.progress import Part, Progress, TerminalBar  # noqa: E402
from tui.instance_manager.providers.cpd.provider import CpdProvider  # noqa: E402
from tui.instance_manager.providers.k8s_crd.cluster import Cluster  # noqa: E402

ADDONS = {"db": {"versions": {"5.4.0": {}}, "details": {
    "custom_resource_kind": "Db", "provisionURL": "#/provisioning/db/5.4.0?extensionName=db-schema"}}}
CRD = {"metadata": {"name": "dbs.db.io", "resourceVersion": "11"},
       "spec": {"group": "db.io", "names": {"kind": "Db", "plural": "dbs"}, "scope": "Namespaced",
                "versions": [{"name": "v1", "served": True, "storage": True,
                              "schema": {"openAPIV3Schema": {"properties": {"spec": {"type": "object",
                                         "x-kubernetes-preserve-unknown-fields": True}}}}},
                             {"name": "v0", "served": False, "storage": False}]},
       "status": {"big": "x" * 100}}
ENV = {"OCP_URL": "https://api.test:6443", "PROJECT_CPD_INST_OPERANDS": "ns", "PROJECT_CPD_INST_OPERATORS": "ops",
       "VERSION": "5.4.0", "PATCH_ID": "8", "CPD_COMPONENTS": "edb_cp4d,db", "STG_CLASS_FILE": "fs",
       "STG_CLASS_BLOCK": "rbd", "INSTALL_OPTIONS": "true", "INSTALL_OPTIONS_FILE": "install-options.yml",
       "OCP_PASSWORD": "never-stored-1", "IBM_ENTITLEMENT_KEY": "never-stored-2", "CPD_APIKEY": "never-stored-3"}
OPTIONS = "non_olm:\n  watsonxData:\n    a: 1\n    adminPassword: planted-pw-9\n---\nnon_olm:\n  match360:\n    b: 2\n"


class FakeKube:
    host = "https://api.test:6443"

    def __init__(self):
        self.calls: list[str] = []
        self.cm_rv = "100"
        self.cm_extra = ""
        self.crd_rv = "11"
        self.digest = "aaa"
        self.zen_ids = ["7", "8"]

    def get(self, path, timeout=None, accept=None, **q):
        self.calls.append(path + ("#meta" if accept and "PartialObjectMetadata" in accept else ""))
        cm = {"metadata": {"name": "db-addon", "resourceVersion": self.cm_rv},
              "data": {"add-ons.json": json.dumps(ADDONS) + self.cm_extra,
                       "extensions": json.dumps([EXT]), "unrelated": "x"}}
        crs = [{"metadata": {"name": f"db-{z}", "namespace": "ns", "uid": f"u{z}"},
                "spec": {"zenServiceInstanceId": z, "parameters": {"nodes": 2, "sc": "fs"}},
                "status": {"dbStatus": "Completed"}} for z in self.zen_ids]
        table = {
            "/apis": {"items": [{"metadata": {"name": "db.io"}, "versions": [{"version": "v1", "resources": [
                {"resource": "dbs", "singularResource": "db", "responseKind": {"kind": "Db"},
                 "scope": "Namespaced"}]}]}]},
            "/api": {"items": []},
            "/apis/apiextensions.k8s.io/v1/customresourcedefinitions/dbs.db.io":
                {**CRD, "metadata": {**CRD["metadata"], "resourceVersion": self.crd_rv}},
            "/api/v1/namespaces/ns/configmaps": {"items": [cm]},
            "/apis/db.io/v1/namespaces/ns/dbs": {"items": crs},
            "/apis/storage.k8s.io/v1/storageclasses": {"items": [
                {"metadata": {"name": "fs"}, "provisioner": "x.cephfs.csi"},
                {"metadata": {"name": "rbd"}, "provisioner": "x.rbd.csi"}]},
            "/api/v1/persistentvolumeclaims": {"items": []},
            "/apis/apps/v1/statefulsets": {"items": []},
            "/api/v1/namespaces/ns/secrets": {"items": []},
            "/apis/config.openshift.io/v1/clusterversions/version": {"spec": {"clusterID": "cid-1"}},
            "/apis/cpd.ibm.com/v1/namespaces/ns/ibmcpds": {"items": [{"spec": {"version": "5.10.8"}}]},
            "/apis/apps/v1/namespaces/ops/deployments": {"items": [
                {"metadata": {"name": "db-operator"}, "spec": {"template": {"spec": {"containers": [
                    {"image": f"icr.io/db@sha256:{self.digest}"}]}}}}]},
        }
        if path not in table:
            raise KubeError(404, path)
        return json.loads(json.dumps(table[path]))


class FakeCli:
    profile = "p"
    available = True

    def __init__(self, kube):
        self.kube = kube
        self.gets: list[str] = []

    def list_instances(self, timeout=180):
        return [{"id": z, "display_name": f"db-{z}", "service_type": "db", "namespace": "ns",
                 "provision_status": "PROVISIONED"} for z in self.kube.zen_ids]

    def get_instance(self, name, service_type):
        self.gets.append(name)
        return {"parameters": {"nodes": 2, "sc": "fs", "adminPassword": SECRET_VALUE}}


class Manager(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cfg = Path(self.tmp.name) / "cfg"
        self.cfg.mkdir()
        (self.cfg / "install-options.yml").write_text(OPTIONS)
        self.env = patch.dict(os.environ, {"CONFIG_DIR": str(self.cfg)}, clear=False)
        self.env.start()
        for k in ("CPD_URL", "CPD_USERNAME", "CPD_APIKEY"):
            os.environ.pop(k, None)
        self.kube = FakeKube()
        self.cli = FakeCli(self.kube)

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def cache(self, env=None, flags=None):
        prov = CpdProvider(Cluster(self.kube), "ns", self.cli)
        c = DiscoveryCache(prov, self.kube, "ns", operators_ns="ops", env=dict(env or ENV),
                           storage_flags=flags or {"file_sc": "fs"}, root=self.cfg / "instance_manager_cache")
        c.attach()
        return prov, c

    def cold(self):
        prov, c = self.cache()
        st = c.check()
        self.assertTrue(st.cold and st.need_build)
        lines = []
        c.build(TerminalBar(stream=_Lines(lines), tty=False), include_subservices=False)
        return prov, c, lines

    def test_cold_build_then_warm_reads_through(self):
        prov, c, lines = self.cold()
        self.assertTrue(any(ln.startswith("[cache 1/") and "add-on registry" in ln for ln in lines))
        self.assertTrue(lines[-1].startswith(f"[cache {len(lines)}/{len(lines)} 100%]"))
        self.assertEqual(len(self.cli.gets), 2)                       # S4 for both instances
        cold_types = prov.discover_types()
        cold_fm = prov.form_model(cold_types[0])
        # warm: a new process, same cluster
        self.kube.calls.clear()
        self.cli.gets.clear()
        prov2, c2 = self.cache()
        st = c2.check()
        self.assertEqual((st.need_build, st.lines, st.dropped), (False, [], []))
        types = prov2.discover_types()
        self.assertEqual([t.key for t in types], ["cpd:db"])
        self.assertEqual(types[0].crd, cold_types[0].crd)
        fm = prov2.form_model(types[0])
        self.assertEqual(fm, cold_fm)                                  # identical with or without the cache
        self.assertEqual(self.cli.gets, [])                           # no cpd-cli get
        self.assertNotIn("/apis/apiextensions.k8s.io/v1/customresourcedefinitions/dbs.db.io", self.kube.calls)
        self.assertNotIn("/apis", self.kube.calls)                    # no API index for discovery
        self.assertNotIn("/api/v1/namespaces/ns/configmaps", self.kube.calls)   # the probe's metadata list only
        self.assertIn("/apis/apiextensions.k8s.io/v1/customresourcedefinitions/dbs.db.io#meta", self.kube.calls)
        snap = c2.snapshot()
        self.assertEqual([t.key for t in snap.types], ["cpd:db"])
        self.assertEqual(snap.models["cpd:db"].fields.keys(), cold_fm.fields.keys())
        self.assertEqual({i.name for i in snap.instances["cpd:db"]}, {"db-7", "db-8"})
        self.assertEqual(set(snap.sc), {"fs", "rbd"})
        # the CRD is trimmed to the served version, losslessly for discovery
        crd = c2.sources.get("sources/crd/dbs.db.io")
        self.assertEqual([v["name"] for v in crd["spec"]["versions"]], ["v1"])
        self.assertNotIn("status", crd)

    def test_no_secret_reaches_the_cache(self):
        self.cold()
        blob = "".join(p.read_text() for p in (self.cfg / "instance_manager_cache").rglob("*.json"))
        for secret in (SECRET_VALUE, "planted-pw-9", "never-stored-1", "never-stored-2", "never-stored-3"):
            self.assertNotIn(secret, blob)
        summary = json.loads(next((self.cfg / "instance_manager_cache").rglob("cpd_vars_summary.json")).read_text())
        self.assertEqual(set(summary["values"]), set(sm.ALLOWLIST))
        self.assertEqual(set(summary["install_options"]["components"]), {"watsonxData", "match360"})
        self.assertEqual(summary["patch_level"], "5.4.0.8")
        self.assertEqual(summary["cluster_patch"]["ibmcpd_version"], "5.10.8")
        for p in (self.cfg / "instance_manager_cache").rglob("*.json"):
            self.assertEqual(stat.S_IMODE(os.stat(p).st_mode), 0o600)

    def _changed(self, env=None, flags=None, dry=False):
        prov, c = self.cache(env, flags)
        c.dry = dry
        st = c.check()
        return c, st

    def test_each_summary_change_rebuilds_exactly_its_parts(self):
        self.cold()
        catalog = {"catalog", "sources/addons", "sources/crd_for/db", model_part("cpd:db")}
        cases = {
            "CPD_COMPONENTS": ({**ENV, "CPD_COMPONENTS": "edb_cp4d"}, catalog),
            "VERSION": ({**ENV, "VERSION": "5.4.1"}, catalog),
            "PATCH_ID": ({**ENV, "PATCH_ID": "9"}, catalog),
            "STG_CLASS_FILE": ({**ENV, "STG_CLASS_FILE": "fs2"}, {"storage", model_part("cpd:db")}),
        }
        for key, (env, expect) in cases.items():
            with self.subTest(key):
                c, st = self._changed(env, dry=True)
                self.assertTrue(st.need_build)
                self.assertTrue(any(key in ln for ln in st.lines), st.lines)
                self.assertEqual(set(st.dropped) & (catalog | {"storage"}), expect)
                self.assertFalse(any(p.startswith("sources/s4/") for p in st.dropped))   # S4 is kept

    def test_patch_lines_name_the_level(self):
        self.cold()
        c, st = self._changed({**ENV, "PATCH_ID": "9"})
        self.assertIn("patch level 5.4.0.8 -> 5.4.0.9", "\n".join(st.lines))

    def test_install_options_section_change_names_the_component(self):
        self.cold()
        (self.cfg / "install-options.yml").write_text(OPTIONS.replace("a: 1", "a: 2"))
        c, st = self._changed()
        self.assertIn("install options changed: watsonxData", "\n".join(st.lines))
        self.assertNotIn("match360", "\n".join(st.lines))
        self.assertIn("catalog", st.dropped)

    def test_operator_digest_change_counts_as_a_patch(self):
        self.cold()
        self.kube.digest = "bbb"
        c, st = self._changed()
        self.assertIn("cluster patch level changed: 1 operator(s) (db-operator)", "\n".join(st.lines))
        self.assertIn("catalog", st.dropped)

    def test_storage_flags_and_check_cache_writes_nothing(self):
        self.cold()
        before = {p: p.read_bytes() for p in (self.cfg / "instance_manager_cache").rglob("*") if p.is_file()}
        c, st = self._changed(flags={"file_sc": "fs", "sc_kind": ["rbd=file"]}, dry=True)
        self.assertIn("storage", st.dropped)
        after = {p: p.read_bytes() for p in (self.cfg / "instance_manager_cache").rglob("*") if p.is_file()}
        self.assertEqual(before, after)

    def test_addon_rv_bump_without_content_change_rebuilds_nothing(self):
        self.cold()
        self.kube.cm_rv = "101"
        c, st = self._changed()
        self.assertFalse(st.need_build)
        self.assertEqual(st.dropped, [])
        self.assertIn("re-saved with the same content", "\n".join(st.lines))
        self.kube.cm_extra = " "
        self.kube.cm_rv = "102"
        c, st = self._changed()
        self.assertTrue(st.need_build)
        self.assertIn("add-on registry changed: db-addon", "\n".join(st.lines))

    def test_crd_change_and_gone_instance_s4(self):
        self.cold()
        self.kube.crd_rv = "12"
        c, st = self._changed()
        self.assertIn("CRD dbs.db.io changed (rv 11 -> 12)", "\n".join(st.lines))
        self.assertIn("sources/crd/dbs.db.io", st.dropped)
        self.kube.zen_ids = ["7"]                        # db-8 was deleted
        prov, c = self.cache()
        c.check()
        prov.zen_records()
        c.finish()
        self.assertEqual(c.sources.names("sources/s4/"), ["sources/s4/db/7"])

    def test_another_cluster_at_the_same_url_wipes_the_scope(self):
        self.cold()
        orig = FakeKube.get

        def other(kube, path, **kw):
            if path.endswith("clusterversions/version"):
                return {"spec": {"clusterID": "cid-2"}}
            return orig(kube, path, **kw)
        with patch.object(FakeKube, "get", other):
            c, st = self._changed()
        self.assertTrue(st.cold and st.need_build)
        self.assertIn("catalog", st.dropped)

    def test_zen_api_forms_are_rechecked_past_the_cache(self):
        items = [{"extension_name": "only-in-zen", "extension_point_id": "service_provisioning", "details": {}}]
        with patch.object(CpdProvider, "_fetch_zen_extensions", staticmethod(lambda point: items)):
            self.cold()
            prov, c = self.cache()
            c.check()
            self.assertIs(prov.revalidate_zen_extensions(), False)           # unchanged
            items.append({"extension_name": "new-form", "extension_point_id": "service_provisioning",
                          "details": {}})
            self.assertIs(prov.revalidate_zen_extensions(), True)            # changed: cached anew
            self.assertEqual(len(c.sources.get("sources/zen_ext/service_provisioning")["items"]), 2)
            prov.addons()
            self.assertIn("new-form", prov._prov_ext)
        with patch.object(CpdProvider, "_fetch_zen_extensions", staticmethod(lambda point: None)):
            self.assertIsNone(prov.revalidate_zen_extensions())             # API not configured


    def test_an_instance_details_configmap_without_registry_data_changes_nothing(self):
        self.cold()
        orig = FakeKube.get

        def with_details(kube, path, **kw):
            out = orig(kube, path, **kw)
            if path == "/api/v1/namespaces/ns/configmaps":
                out["items"].append({"metadata": {"name": "db-9-details", "resourceVersion": "5"},
                                     "data": {"connection": "x"}})
            return out
        with patch.object(FakeKube, "get", with_details):
            prov, c = self.cache()
            with patch("tui.instance_manager.cache.probe.addon_rvs",
                       return_value={"db-addon": "100", "db-9-details": "5"}):
                st = c.check()
        self.assertEqual((st.need_build, st.dropped), (False, []))
        self.assertFalse(any("add-on registry" in ln for ln in st.lines), st.lines)


class _Lines:
    def __init__(self, out):
        self.out = out

    def write(self, s):
        self.out.extend(x for x in s.splitlines() if x.strip())

    def flush(self):
        pass

    def isatty(self):
        return False


class ProgressBar(unittest.TestCase):
    def test_weighted_fraction_and_plain_lines(self):
        lines = []
        pr = Progress([Part("a", "fast", weight=1), Part("b", "slow", "cpd-cli", weight=3)],
                      TerminalBar(stream=_Lines(lines), tty=False))
        pr.run("a", lambda: None)
        self.assertAlmostEqual(pr.fraction, 0.25)
        pr.run("b", lambda: 1 / 0)
        pr.finish()
        self.assertEqual(lines[0].split(" took")[0], "[cache 1/2  25%] fast")
        self.assertIn("[cache 2/2 100%] slow (cpd-cli)", lines[1])
        self.assertIn("FAILED: division by zero", lines[1])


