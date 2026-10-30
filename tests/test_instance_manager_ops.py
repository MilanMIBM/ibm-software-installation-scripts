"""instance_manager ops: payloads, validation, edit/delete plans (fakes only; nothing runs)."""

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from tui.common.kube import KubeError  # noqa: E402
from tui.common.state import State  # noqa: E402
from tui.instance_manager.model import (  # noqa: E402
    Evidence, Field, FormModel, Instance, InstanceType, Kind, Mutability, Need, Role, StorageClassInfo, StorageNeed)
from tui.instance_manager.ops import credentials, payload as pl, planner  # noqa: E402

SC = {"fs": StorageClassInfo("fs", kind=Kind.FILE, expandable=True),
      "rbd": StorageClassInfo("rbd", kind=Kind.BLOCK, expandable=True,
                              evidence=[Evidence("config", "declared block in cpd_vars")]),
      "rbd2": StorageClassInfo("rbd2", kind=Kind.BLOCK, default=True),
      "obc": StorageClassInfo("obc", kind=Kind.OBJECT)}
ITYPE = InstanceType(key="cpd:db", display="db", group="db.io", version="v1", kind="Db", plural="dbs",
                     crd={"spec": {}}, max_instances=3, versions=["5.4.0"])


def F(path, **kw):
    kw.setdefault("payload", True)
    kw.setdefault("sources", {"S1"})
    return Field(path=path, **kw)


def model():
    fields = [
        F(("parameters", "nodes"), type="integer", minimum=1, maximum=5, default=1, role=Role.REPLICAS, label="Nodes"),
        F(("parameters", "flavour"), enum=["A", "B"], default="A"),
        F(("parameters", "oracle"), type="boolean", default=True, show_if={("parameters", "flavour"): ["B"]}),
        F(("parameters", "sc"), role=Role.STORAGE_CLASS, observed=["fs"], label="Storage class",
          storage=StorageNeed(Need.BLOCK, [Evidence("live", "peers 9/9 block")])),
        F(("parameters", "password"), role=Role.SECRET),
        F(("parameters", "mem"), observed=["4"], role=Role.MEMORY, aliases=[("resources", "limits", "memory")]),
        F(("resources", "limits", "memory"), observed=["4Gi"], role=Role.MEMORY, payload=False,
          aliases=[("parameters", "mem")], sources={"S3"}),
    ]
    return FormModel("cpd:db", {f.path: f for f in fields})


class Payload(unittest.TestCase):
    def test_initial_values_follow_the_storage_need(self):
        v = pl.initial_values(model(), SC)
        self.assertEqual(v[("parameters", "sc")], "rbd")      # observed "fs" is file: replaced by the declared block
        self.assertEqual(v[("parameters", "nodes")], 1)
        self.assertIsNone(v[("parameters", "password")])      # secrets never pre-filled

    def test_build_skips_hidden_and_masks(self):
        fm = model()
        v = pl.initial_values(fm, SC)
        v[("parameters", "password")] = "s3cret"
        p = pl.build(ITYPE, fm, v, "x1", "d", "ns", "5.4.0")
        params = p["create_arguments"]["parameters"]
        self.assertNotIn("oracle", params)                    # show_if flavour == B not met
        self.assertEqual(params["nodes"], 1)
        self.assertEqual(p["addon_type"], "db")
        self.assertNotIn("s3cret", str(pl.masked(p, fm)))
        self.assertNotIn("limits", str(p))                    # CR-only copies are not payload

    def test_validate(self):
        fm = model()
        v = pl.initial_values(fm, SC)
        errs, warns = pl.validate(ITYPE, fm, v, "Bad_Name", [], SC, r"^[A-Za-z][A-Za-z0-9_-]*$")
        self.assertTrue(any("Kubernetes resource name" in e for e in errs))
        v[("parameters", "nodes")] = 9
        v[("parameters", "sc")] = "fs"
        errs, warns = pl.validate(ITYPE, fm, v, "ok-name", ["a", "b", "c"], SC, None)
        self.assertTrue(any("above the maximum" in e for e in errs))
        self.assertTrue(any("at most 3" in e for e in errs))
        self.assertTrue(any("file storage" in w for w in warns))
        v[("parameters", "sc")] = "nope"
        errs, _ = pl.validate(ITYPE, fm, v, "ok", [], SC, None)
        self.assertTrue(any("no StorageClass nope" in e for e in errs))


class Coerce(unittest.TestCase):
    def test_coerce_like(self):
        self.assertEqual(planner.coerce_like("5", "4Gi"), "5Gi")
        self.assertEqual(planner.coerce_like(5, 4), 5)
        self.assertEqual(planner.coerce_like("3", 2), 3)
        self.assertEqual(planner.coerce_like(3, "2"), "3")
        self.assertEqual(planner.coerce_like("60", "50"), "60")
        self.assertEqual(planner.coerce_like("medium", "small"), "medium")


class FakeKube:
    def __init__(self, fail=False):
        self.calls, self.fail = [], fail

    def send(self, method, path, body=None, **kw):
        self.calls.append((method, path, body, kw))
        if self.fail and kw.get("dryRun"):
            raise KubeError(422, "spec.mem: Invalid value")
        return {}


class FakeGraph:
    objects = {}

    def ancestors(self, uid):
        return set()

    def pvcs_under(self, uid):
        return [{"metadata": {"name": "data-0", "uid": "p"}, "spec": {"storageClassName": "rbd2"}}]


class FakeProvider:
    namespace = "ns"

    def __init__(self, kube):
        self.cluster = type("C", (), {"kube": kube})()

    def storage_classes(self):
        return SC

    def graph(self, ns):
        return FakeGraph()


INST = Instance("cpd:db", "db1", "ns", "u1", {"spec": {"parameters": {"mem": "4"},
                                                      "resources": {"limits": {"memory": "4Gi"}}}},
                State.HEALTHY, "ok")


class Edit(unittest.TestCase):
    def test_alias_group_patched_and_dry_run(self):
        kube = FakeKube()
        plan = planner.plan_edit(FakeProvider(kube), ITYPE, INST, model(), {("parameters", "mem"): "5"})
        self.assertTrue(plan.runnable, plan.errors)
        self.assertIn(("resources.limits.memory", "4Gi", "5Gi"), plan.diff)
        method, path, body, kw = kube.calls[0]
        self.assertEqual((method, kw.get("dryRun")), ("PATCH", "All"))
        self.assertEqual(body, {"spec": {"parameters": {"mem": "5"}, "resources": {"limits": {"memory": "5Gi"}}}})
        self.assertTrue(any("one instance" in w for w in plan.warnings))    # unconfirmed alias group

    def test_rejections(self):
        fm = model()
        fm.fields[("parameters", "sc")].mutability = Mutability.IMMUTABLE
        plan = planner.plan_edit(FakeProvider(FakeKube()), ITYPE, INST, fm, {("parameters", "sc"): "rbd",
                                                                              ("parameters", "nodes"): 9})
        self.assertFalse(plan.runnable)
        self.assertTrue(any("can't change" in e for e in plan.errors))
        self.assertTrue(any("above the maximum" in e for e in plan.errors))
        plan = planner.plan_edit(FakeProvider(FakeKube(fail=True)), ITYPE, INST, model(), {("parameters", "mem"): "5"})
        self.assertTrue(any("dry-run rejected" in e for e in plan.errors))
        zen_only = Instance("cpd:db", "z", "ns", "", {}, State.HEALTHY, "")
        self.assertFalse(planner.plan_edit(FakeProvider(FakeKube()), ITYPE, zen_only, model(), {}).runnable)

    def test_storage_never_shrinks_or_grows_on_fixed_classes(self):
        fm = model()
        size = F(("ssize",), role=Role.STORAGE_SIZE, observed=["50"])
        fm.fields[size.path] = size
        inst = Instance("cpd:db", "db1", "ns", "u1", {"spec": {"ssize": "50"}}, State.HEALTHY, "")
        plan = planner.plan_edit(FakeProvider(FakeKube()), ITYPE, inst, fm, {("ssize",): "40"})
        self.assertTrue(any("can't shrink" in e for e in plan.errors))
        self.assertTrue(any("does not allow volume expansion" in e for e in plan.errors))   # rbd2 not expandable


class Delete(unittest.TestCase):
    def test_typed_confirmation_and_cr_only_dry_run(self):
        kube = FakeKube()
        plan = planner.plan_delete(FakeProvider(kube), ITYPE, INST)
        self.assertEqual(plan.confirm_name, "db1")
        self.assertEqual(kube.calls[0][0], "DELETE")
        self.assertEqual(kube.calls[0][3].get("dryRun"), "All")


class Credentials(unittest.TestCase):
    def test_modes_and_markers(self):
        with tempfile.TemporaryDirectory() as d, patch.dict(os.environ, {"CONFIG_DIR": d}):
            p = credentials.write("edb", "db-1", "ns", "https://api:6443", {"password": "p'a$s \"x"})
            self.assertEqual(p, Path(d).resolve() / "managed-service-instances" / "edb" / "db-1-instance_details.sh")
            self.assertEqual(oct(p.stat().st_mode & 0o777), "0o600")
            self.assertEqual(oct(p.parent.stat().st_mode & 0o777), "0o700")
            text = p.read_text()
            self.assertTrue(text.startswith("# edb instance db-1 in ns, cluster https://api:6443, written by "))
            self.assertIn("export EDB_DB_1_PASSWORD=", text)              # prefixed: never clobbers shared names
            import subprocess
            out = subprocess.run(["zsh", "-c", f"source {p}; print -r -- $EDB_DB_1_PASSWORD"],
                                 capture_output=True, text=True).stdout.strip()
            self.assertEqual(out, "p'a$s \"x")                               # sourceable, value intact
            credentials.mark("edb", "db-1", "deleted")
            self.assertIn("# deleted", p.read_text())


if __name__ == "__main__":
    unittest.main()


class Migration(unittest.TestCase):
    LEGACY = """# Written by 3.3.1_get_instance_creds.sh on 2026-10-29T17:15:53Z
export CPD_URL="https://cpd"
export CPD_APIKEY="k"

# Written by 5_prep_edb_postgres.sh on 2026-10-29T21:25:12Z
#--- EDB Postgres - edb-a
export EDB_POSTGRES_EDB_A_PASSWORD="p'1 $x"
export EDB_POSTGRES_EDB_A_DBNAME="app"
#--- EDB Postgres - edb-b
export EDB_POSTGRES_EDB_B_PASSWORD="p2"

# Written by 5_prep_uifeatures_informix.sh on 2026-10-29T22:00:00Z
export INFORMIX_INSTANCE="ifx1"
export INFORMIX_DMC_PASSWORD="ip"
# >>> cql-gateway ns/dc1-cql
# Written by 5_2_prep_datastax_hcd_cql_gateway.sh on 2026-10-30T10:00:00Z
export DATASTAX_HCD_CQL_USER='u'
# <<< cql-gateway ns/dc1-cql
# Written by some_other_script.sh
export OTHER="stays"
"""

    def test_moves_instance_blocks_and_keeps_platform_values(self):
        import subprocess
        from tui.instance_manager.ops import migrate_details as md
        with tempfile.TemporaryDirectory() as d, patch.dict(os.environ, {"CONFIG_DIR": d,
                                                                         "PROJECT_CPD_INST_OPERANDS": "ns"}):
            details = Path(d) / "cpd_instance_details.sh"
            details.write_text(self.LEGACY)
            moves, rest = md.plan(details)
            got = {(t, n): v for t, n, v, _ in moves}
            self.assertEqual(set(got), {("edb", "edb-a"), ("edb", "edb-b"), ("informix", "ifx1"),
                                        ("datastax-hcd", "dc1-cql")})
            # the legacy double-quoted line expanded $x when sourced; the migrator keeps what scripts really saw
            self.assertEqual(got[("edb", "edb-a")]["EDB_POSTGRES_EDB_A_PASSWORD"], "p'1 ")
            self.assertIn("CPD_APIKEY", rest)
            self.assertIn('OTHER="stays"', rest)
            self.assertNotIn("EDB_POSTGRES", rest)
            self.assertNotIn("cql-gateway", rest)
            # old credential files: Db2 (service_instances/) and early TUI ones
            repo = Path(d) / "repo"
            (repo / "service_instances").mkdir(parents=True)
            (repo / "service_instances" / "db2oltp-1-credentials.txt").write_text(
                "# Db2 instance db2oltp-1\nDB2_INSTANCE_NAME=db2oltp-1\nDB2_USERNAME=db2admin\nDB2_PASSWORD=pw\n")
            olds = md.legacy_files(repo, Path(d) / "managed-service-instances")
            (f, typ, name, vals, trailer), = olds
            self.assertEqual((typ, name), ("db2oltp", "db2oltp-1"))
            self.assertEqual(vals["DB2OLTP_DB2OLTP_1_PASSWORD"], "pw")
            # the written file is sourceable and round-trips the awkward value
            p = credentials.write_exports("edb", "edb-a", "ns", "", {"EDB_POSTGRES_EDB_A_PASSWORD": "p'1 $x"})
            out = subprocess.run(["zsh", "-fc", f"source {p}; print -r -- $EDB_POSTGRES_EDB_A_PASSWORD"],
                                 capture_output=True, text=True).stdout
            self.assertEqual(out.rstrip("\n"), "p'1 $x")       # the new single-quoted format keeps $ literally
