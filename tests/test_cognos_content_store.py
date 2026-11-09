"""Exercise preparation decisions without changing a database or cluster."""

import contextlib
import io
import json
import subprocess
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src/helpers"))
import cognos_content_store as store


def catalog(*, tables=0):
    return f"""Database Connection Information
COGNOS|CFG|applheapsz|1024|1024
COGNOS|CFG|locktimeout|240|240
COGNOS|CFG|codepage|1208|1208
COGNOS|CFG|codeset|UTF-8|UTF-8
COGNOS|BP|IBMDEFAULTBP|32768|49800
COGNOS|BP|CMDB_08KBP|8192|1000
COGNOS|BP|CMDB_32KBP|32768|1000
COGNOS|TS|USERSPACE1|32768|L|IBMDEFAULTBP
COGNOS|TS|TSN_SYS_CMDB|32768|T|CMDB_32KBP
COGNOS|TS|TSN_USR_CMDB|8192|U|CMDB_08KBP
COGNOS|TS|TSN_REG_CMDB|8192|A|CMDB_08KBP
COGNOS|SCHEMA|COGNOS_SVC|COGNOS_SVC|U
COGNOS|AUTH|Y|Y|Y
COGNOS|USE|TSN_USR_CMDB|Y
COGNOS|USE|TSN_REG_CMDB|Y
COGNOS|USE|USERSPACE1|Y
COGNOS|TABLES|{tables}
DB20000I The SQL command completed successfully.
"""


class PlanTests(unittest.TestCase):
    def setUp(self):
        self.settings = store.Settings("bludb", "cognos_svc", "cognos_svc")
        self.snapshot = store.parse_snapshot(catalog())

    def test_ready_store_needs_no_changes_even_with_content_tables(self):
        self.snapshot.table_count = 300
        self.assertTrue(store.plan(self.snapshot, self.settings).ready)

    def test_missing_objects_are_created_with_scoped_grants(self):
        self.snapshot.pools = {"IBMDEFAULTBP": (32768, 1000)}
        self.snapshot.spaces = {"USERSPACE1": (32768, "L", "IBMDEFAULTBP")}
        self.snapshot.schemas.clear()
        self.snapshot.auth = ()
        self.snapshot.use.clear()
        result = store.plan(self.snapshot, self.settings)
        sql = "\n".join(result.statements)
        self.assertFalse(result.errors)
        self.assertIn("CREATE BUFFERPOOL CMDB_08KBP", sql)
        self.assertIn("CREATE SYSTEM TEMPORARY TABLESPACE", sql)
        self.assertIn("CREATE SCHEMA COGNOS_SVC AUTHORIZATION COGNOS_SVC", sql)
        self.assertIn("IMPLICIT_SCHEMA ON DATABASE TO USER COGNOS_SVC", sql)
        self.assertNotIn("DBADM", sql)
        self.assertNotIn("PUBLIC", sql)

    def test_incompatible_definitions_block_changes(self):
        for kind, key, bad in (
            ("pools", "CMDB_08KBP", (16384, 1000)),
            ("spaces", "TSN_USR_CMDB", (8192, "T", "CMDB_08KBP")),
            ("schemas", "COGNOS_SVC", ("OTHER_OWNER", "U")),
            ("schemas", "COGNOS_SVC", ("COGNOS_SVC", "G")),
        ):
            with self.subTest(kind=kind):
                snap = store.parse_snapshot(catalog())
                getattr(snap, kind)[key] = bad
                self.assertTrue(store.plan(snap, self.settings).errors)

    def test_larger_buffer_pools_and_heaps_are_preserved(self):
        self.snapshot.pools["IBMDEFAULTBP"] = (32768, 100000)
        self.snapshot.config["applheapsz"] = ("2048", "2048")
        self.assertTrue(store.plan(self.snapshot, self.settings).ready)

    def test_deferred_setting_is_pending_without_duplicate_update(self):
        self.snapshot.config["locktimeout"] = ("-1", "240")
        result = store.plan(self.snapshot, self.settings)
        self.assertFalse(result.statements)
        self.assertEqual(len(result.pending), 1)

    def test_config_changes_are_deferred_and_never_reactivate_database(self):
        self.snapshot.config["applheapsz"] = ("256", "256")
        self.snapshot.config["locktimeout"] = ("-1", "-1")
        result = store.plan(self.snapshot, self.settings)
        self.assertEqual(result.statements, [
            "UPDATE DATABASE CONFIGURATION USING APPLHEAPSZ 1024 DEFERRED;",
            "UPDATE DATABASE CONFIGURATION USING LOCKTIMEOUT 240 DEFERRED;",
        ])
        self.assertEqual(len(result.pending), 2)

    def test_non_utf8_database_is_rejected(self):
        self.snapshot.config["codepage"] = ("1252", "1252")
        self.assertTrue(store.plan(self.snapshot, self.settings).errors)

    def test_incomplete_and_malformed_snapshots_fail_closed(self):
        for output in ("", catalog().replace("COGNOS|TABLES|0", ""), catalog().replace("|32768|49800", "|oops|49800")):
            with self.subTest(output=output[:20]), self.assertRaises(store.PreparationError):
                store.parse_snapshot(output)

    def test_identifiers_cannot_inject_sql_or_shell_syntax(self):
        for value in ("svc'; DROP DATABASE X", "$(touch file)", "svc@example.test", "PUBLIC"):
            with self.subTest(value=value), self.assertRaises(store.PreparationError):
                store.Settings("BLUDB", value, "COGNOS_SVC")


class ExecutionTests(unittest.TestCase):
    def settings(self):
        return store.Settings("BLUDB", "COGNOS_SVC", "COGNOS_SVC")

    def execute(self, db, apply=False):
        with contextlib.redirect_stdout(io.StringIO()):
            return store.prepare(db, self.settings(), apply)

    def test_check_executes_only_catalog_reads(self):
        from unittest.mock import Mock
        db = Mock()
        db.sql.return_value = catalog().replace("COGNOS|AUTH|Y|Y|Y", "")
        self.assertEqual(self.execute(db), 2)
        self.assertEqual(db.sql.call_count, 1)
        self.assertNotIn("GRANT ", db.sql.call_args.args[0])

    def test_apply_refuses_database_with_application_tables(self):
        from unittest.mock import Mock
        db = Mock()
        db.sql.return_value = catalog(tables=10).replace("COGNOS|AUTH|Y|Y|Y", "")
        with self.assertRaisesRegex(store.PreparationError, "Application tables"):
            self.execute(db, apply=True)
        self.assertEqual(db.sql.call_count, 1)

    def test_apply_blocks_all_mutations_when_object_conflicts(self):
        from unittest.mock import Mock
        db = Mock()
        db.sql.return_value = catalog().replace("|8192|1000", "|16384|1000").replace("COGNOS|AUTH|Y|Y|Y", "")
        self.assertEqual(self.execute(db, apply=True), 1)
        self.assertEqual(db.sql.call_count, 1)

    def test_apply_verifies_postconditions_and_ready_rerun_is_noop(self):
        from unittest.mock import Mock
        db = Mock()
        db.sql.side_effect = [catalog().replace("COGNOS|AUTH|Y|Y|Y", ""), "", catalog()]
        self.assertEqual(self.execute(db, apply=True), 0)
        self.assertEqual(db.sql.call_count, 3)
        self.assertIn("GRANT ", db.sql.call_args_list[1].args[0])
        db.reset_mock()
        db.sql.side_effect = None
        db.sql.return_value = catalog(tables=10)
        self.assertEqual(self.execute(db, apply=True), 0)
        self.assertEqual(db.sql.call_count, 1)

    def test_unapplied_deferred_value_returns_pending_after_apply(self):
        from unittest.mock import Mock
        db = Mock()
        db.sql.side_effect = [catalog().replace("|240|240", "|-1|-1"), "", catalog().replace("|240|240", "|-1|240")]
        self.assertEqual(self.execute(db, apply=True), 2)

    def test_remote_execution_stops_on_sql_error_and_cleans_tempfile(self):
        db = store.Db2("database-ns", "db2-example", "db2-pod", "db2inst1")
        with patch.object(db, "run", return_value="") as run:
            db.sql("SELECT 1 FROM SYSIBM.SYSDUMMY1;")
        args, stdin = run.call_args.args
        script = args[-1]
        self.assertIn("db2 -stxf", script)
        self.assertIn("trap ", script)
        self.assertIn('rm -f "$sql_file"', script)
        self.assertNotIn("DEACTIVATE", script.upper())
        self.assertEqual(stdin, "SELECT 1 FROM SYSIBM.SYSDUMMY1;")

    def test_command_errors_do_not_print_arbitrary_pod_output(self):
        with (
            patch.object(store.subprocess, "run", return_value=SimpleNamespace(returncode=4, stdout="SQL0551N password=hidden", stderr="SQLSTATE=42501")),
            self.assertRaisesRegex(store.PreparationError, "SQL0551N") as exc,
        ):
            store.Db2.run(["oc", "exec"])
        self.assertNotIn("hidden", str(exc.exception))

    def test_timeout_never_retries_mutating_sql(self):
        with (
            patch.object(store.subprocess, "run", side_effect=subprocess.TimeoutExpired("oc", 180)) as run,
            self.assertRaises(store.PreparationError),
        ):
            store.Db2.run(["oc", "exec"], "GRANT CONNECT ON DATABASE TO USER EXAMPLE;")
        self.assertEqual(run.call_count, 1)

    def test_multiple_pods_require_explicit_selection(self):
        def pod(name):
            return {"metadata": {"name": name}, "status": {"phase": "Running", "containerStatuses": [{"name": "db2u", "ready": True}]}}
        db = store.Db2("database-ns", "db2-example", None, "db2inst1")
        with patch.object(db, "run", return_value=json.dumps({"items": [pod("pod-a"), pod("pod-b")]})):
            with self.assertRaises(store.PreparationError):
                db.resolve_pod()
            db.pod = "pod-b"
            db.resolve_pod()
            self.assertEqual(db.pod, "pod-b")


if __name__ == "__main__":
    unittest.main()
