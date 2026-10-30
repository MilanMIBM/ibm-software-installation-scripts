"""instance_details_vault: per-instance credentials -> Software Hub vault (fake vault, nothing sent)."""

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src" / "helpers"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import instance_details_vault as v  # noqa: E402
from softwarehub_internal_vault_helpers import StoreResult, VaultAPIError  # noqa: E402
from tui.instance_manager.ops import credentials  # noqa: E402


class FakeVault:
    def __init__(self):
        self.stored, self.deleted = [], []

    def current_user(self):
        return {"uid": "1000331001", "user_name": "cpadmin"}

    def current_uid(self):
        return "1000331001"

    def _request(self, method, path, **kw):
        if path.endswith("/dev1"):
            return {"uid": 1000331002, "username": "dev1"}
        raise VaultAPIError(method, path, 404, {"message": "not found"})

    def find_group(self, name):
        return {"group_id": 10000, "name": "All Users"} if name.lower() == "all users" else None

    def store_secret(self, name, secret, **kw):
        self.stored.append((name, secret, kw))
        return StoreResult("created", f"1000331001:{name}")

    def find_secret(self, name, **kw):
        return {"secret_urn": f"1000331001:{name}"}

    def delete_secret(self, urn):
        self.deleted.append(urn)


class Vault(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = patch.dict(os.environ, {"CONFIG_DIR": self.tmp.name, "CPD_USERNAME": "cpadmin"})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def test_store_all_values_and_never_list_the_owner(self):
        p = credentials.write_exports("edb", "edb_1", "ns", "https://api:6443",
                                      {"EDB_POSTGRES_EDB_1_PASSWORD": "p'1 $x", "EDB_POSTGRES_EDB_1_DBNAME": "app"},
                                      writer="5_prep_edb_postgres.sh")
        fake, logs = FakeVault(), []
        res = v.store(p, ["cpadmin", "dev1", "ghost", "group:All Users"], log=logs.append, vault=fake)
        self.assertEqual(res.action, "created")
        name, secret, kw = fake.stored[0]
        self.assertEqual(name, "edb-edb-1")                                   # letters, digits and '-' only
        self.assertEqual(kw["type"], "generic")
        vals = secret["generic"]
        self.assertEqual(vals["EDB_POSTGRES_EDB_1_PASSWORD"], "p'1 $x")       # every value, exactly
        self.assertEqual((vals["instance"], vals["type"], vals["namespace"]), ("edb_1", "edb", "ns"))
        users = kw["members"]["users"]
        self.assertEqual(users, [{"uid": "1000331002", "username": "dev1"}])  # owner cpadmin dropped
        self.assertEqual(kw["members"]["groups"], [{"group_id": "10000", "group_name": "All Users"}])
        self.assertTrue(any("no user 'ghost'" in m for m in logs))
        self.assertFalse(any("p'1" in m for m in logs))                       # values never logged

    def test_owner_only_means_no_members_and_deleted_instances_are_skipped(self):
        p = credentials.write_exports("db2oltp", "db2-1", "ns", "", {"DB2OLTP_DB2_1_PASSWORD": "x"})
        fake = FakeVault()
        v.store(p, ["cpadmin"], log=lambda m: None, vault=fake)
        self.assertIsNone(fake.stored[0][2]["members"])
        credentials.mark("db2oltp", "db2-1", "deleted")
        fake2 = FakeVault()
        self.assertIsNone(v.store(p, ["cpadmin"], log=lambda m: None, vault=fake2))
        self.assertEqual(fake2.stored, [])

    def test_toggles_and_delete(self):
        with patch.dict(os.environ, {"SERVICE_INSTANCE_VAULT_STORE": "false"}):
            self.assertFalse(v.enabled())
            self.assertTrue(v.enabled(True))                                  # the TUI checkbox / --vault wins
        with patch.dict(os.environ, {}, clear=False) as env:
            env.pop("SERVICE_INSTANCE_VAULT_STORE", None)
            env.pop("SERVICE_INSTANCE_VAULT_MEMBERS", None)
            self.assertTrue(v.enabled())                                      # on by default
            self.assertEqual(v.member_names(), ["cpadmin"])                   # cpadmin by default
        self.assertEqual(v.member_names("a, group:10000,"), ["a", "group:10000"])
        fake = FakeVault()
        self.assertTrue(v.delete("edb", "edb_1", log=lambda m: None, vault=fake))
        self.assertEqual(fake.deleted, ["1000331001:edb-edb-1"])


if __name__ == "__main__":
    unittest.main()
