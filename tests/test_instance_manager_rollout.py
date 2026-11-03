"""instance_manager rollout: an instance is healthy only when it is done (synthetic objects only)."""

import sys
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from tui.common.state import State  # noqa: E402
from tui.instance_manager import rollout  # noqa: E402
from tui.instance_manager.rollout import LABEL, Snapshot  # noqa: E402

NOW = datetime(2026, 11, 3, 12, 0, tzinfo=UTC)
AGO = (NOW - timedelta(minutes=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
ZID = "1793705528580936"


def meta(name, uid, owner=None, labels=True):
    m = {"name": name, "uid": uid, "creationTimestamp": AGO, "labels": {LABEL: ZID} if labels else {}}
    if owner:
        m["ownerReferences"] = [{"apiVersion": owner[0], "kind": owner[1], "name": owner[2],
                                 "uid": owner[3] if len(owner) > 3 else f"u-{owner[2]}", "controller": True}]
    return m


def sts(name, desired, ready, owner=("ifx.ibm.com/v2", "Informix", "informix-1")):
    return {"kind": "StatefulSet", "metadata": meta(name, f"u-{name}", owner), "spec": {"replicas": desired},
            "status": {"readyReplicas": ready, "updatedReplicas": desired, "currentReplicas": desired}}


def pod(name, owner, *, phase="Running", ready=False, scheduled=True, waiting=None, message="", inits=None):
    conds = [{"type": "PodScheduled", "status": "True" if scheduled else "False", "lastTransitionTime": AGO,
              **({} if scheduled else {"reason": "Unschedulable", "message": message})},
             {"type": "Ready", "status": "True" if ready else "False", "lastTransitionTime": AGO}]
    cs = [{"name": "c", "state": {"waiting": {"reason": waiting, "message": message}} if waiting else
           ({"running": {}} if phase == "Running" else {})}]
    return {"kind": "Pod", "metadata": meta(name, f"u-{name}", owner),
            "status": {"phase": phase, "conditions": conds, "containerStatuses": cs, "startTime": AGO,
                       **({"initContainerStatuses": inits} if inits else {})}}


def cr(kind, name, status):
    return {"apiVersion": "ifx.ibm.com/v2", "kind": kind, "metadata": {"name": name, "uid": f"u-{name}"},
            "status": status}


IFX_RUNNING = {"informixStatus": "InProgress", "progress": "100%",
               "progressMessage": "All replicas reporting as ready.",
               "conditions": [{"type": "Completed", "status": "False"},
                              {"type": "Failed", "status": "True", "message": "Informix is not yet healthy"}]}
IFX_DONE = {"informixStatus": "Completed", "conditions": [{"type": "Completed", "status": "True"}]}
SERVER_POD_OWNER = ("apps/v1", "StatefulSet", "informix-1-server", "u-informix-1-server")


def snap(sets=(), pods=()):
    s = Snapshot()
    s.groups[ZID] = {"deployments": [], "statefulsets": list(sets), "replicasets": [], "jobs": [], "pods": list(pods)}
    return s


def assess(s, zen="PROVISIONED", crs=None, cr_obj=None):
    crs = crs or {}
    return rollout.assess(ZID, zen, cr_obj, s, lambda api, kind, name: crs.get((kind, name)), now=NOW)


class Stages(unittest.TestCase):
    def test_zen_provisioned_while_unscheduled_is_not_healthy(self):
        s = snap([sts("informix-1-server", 1, 0)],
                 [pod("informix-1-server-0", SERVER_POD_OWNER, phase="Pending", scheduled=False,
                      message="0/15 nodes are available: 15 Insufficient memory.")])
        ro = assess(s, crs={("Informix", "informix-1"): cr("Informix", "informix-1", IFX_RUNNING)})
        self.assertEqual(ro.stage, "scheduling")
        self.assertEqual(ro.state, State.STUCK)                     # pending past the debounce
        self.assertIn("Insufficient memory", ro.problems[0].message)
        self.assertEqual((ro.ready, ro.total), (0, 1))

    def test_image_pull_back_off_fails_with_the_registry_message(self):
        s = snap([sts("informix-1-server", 1, 0)],
                 [pod("informix-1-server-0", SERVER_POD_OWNER, waiting="ImagePullBackOff",
                      message='Back-off pulling image "preprod.icr.io/cp/cpd/informix-eng@sha256:1"')])
        ro = assess(s, crs={("Informix", "informix-1"): cr("Informix", "informix-1", IFX_RUNNING)})
        self.assertEqual(ro.state, State.FAILING)
        self.assertEqual(ro.stage, "pulling images")
        self.assertIn("preprod.icr.io", ro.reason)
        self.assertEqual(ro.problems[0].reason, "ImagePullBackOff")

    def test_init_containers_running(self):
        s = snap([sts("informix-1-server", 1, 0)],
                 [pod("informix-1-server-0", SERVER_POD_OWNER,
                      inits=[{"name": "init", "state": {"running": {}}}])])
        ro = assess(s, crs={("Informix", "informix-1"): cr("Informix", "informix-1", IFX_RUNNING)})
        self.assertEqual((ro.state, ro.stage), (State.PROGRESS, "initialising"))
        self.assertTrue(ro.reason.startswith("initialising · 0/1 ready"))

    def test_replicas_ready_but_the_cr_still_provisioning(self):
        s = snap([sts("informix-1-server", 1, 1)], [pod("informix-1-server-0", SERVER_POD_OWNER, ready=True)])
        ro = assess(s, crs={("Informix", "informix-1"): cr("Informix", "informix-1", IFX_RUNNING)})
        self.assertEqual((ro.state, ro.stage), (State.PROGRESS, "provisioning"))
        self.assertLess(ro.fraction, 1.0)

    def test_healthy_only_when_cr_workloads_and_zen_agree(self):
        s = snap([sts("informix-1-server", 1, 1)], [pod("informix-1-server-0", SERVER_POD_OWNER, ready=True)])
        crs = {("Informix", "informix-1"): cr("Informix", "informix-1", IFX_DONE)}
        ro = assess(s, crs=crs)
        self.assertEqual((ro.state, ro.stage), (State.HEALTHY, "ready"))
        self.assertEqual(ro.fraction, 1.0)
        ro = assess(s, zen="PROVISION_IN_PROGRESS", crs=crs)              # zen hasn't caught up
        self.assertEqual(ro.state, State.PROGRESS)

    def test_zen_alone_without_a_cr(self):
        s = snap([sts("x-server", 2, 1, owner=None)])
        self.assertEqual(assess(s).state, State.PROGRESS)                   # PROVISIONED, 1/2 ready
        s = snap([sts("x-server", 2, 2, owner=None)])
        self.assertEqual(assess(s).state, State.HEALTHY)

    def test_no_evidence_is_never_healthy_while_zen_is_busy(self):
        ro = assess(Snapshot(), zen="PENDING")
        self.assertEqual((ro.state, ro.stage, ro.evidence), (State.PROGRESS, "waiting for the operator", False))
        ro = assess(Snapshot(), zen="PROVISIONED")
        self.assertEqual((ro.state, ro.evidence), (State.HEALTHY, False))
        self.assertIn("no labelled workloads", ro.reason)

    def test_pods_run_by_a_cr_count_as_a_unit(self):
        owner = ("postgresql.k8s.enterprisedb.io/v1", "Cluster", "edb-db")
        s = snap(pods=[pod("edb-db-1", owner, ready=True), pod("edb-db-2", owner)])
        ro = assess(s, crs={("Cluster", "edb-db"): cr("Cluster", "edb-db", {"phase": "Cluster in healthy state"})})
        self.assertEqual([(u.kind, u.name, u.desired, u.ready) for u in ro.units], [("Cluster", "edb-db", 2, 1)])
        self.assertNotEqual(ro.state, State.HEALTHY)

    def test_a_shut_down_sibling_does_not_outvote_a_completed_cr(self):
        s = snap([sts("informix-1-server", 1, 1)], [pod("informix-1-server-0", SERVER_POD_OWNER, ready=True)])
        s.groups[ZID]["deployments"].append(
            {"kind": "Deployment", "metadata": meta("lh", "u-lh", ("ifx.ibm.com/v2", "Lakehouse", "lh")),
             "spec": {"replicas": 0}, "status": {}})
        crs = {("Informix", "informix-1"): cr("Informix", "informix-1", IFX_DONE),
               ("Lakehouse", "lh"): cr("Lakehouse", "lh", {"status": "Shutdown"})}
        self.assertEqual(assess(s, crs=crs).state, State.HEALTHY)

    def test_collect_groups_by_the_instance_label(self):
        class FakeCluster:
            def try_list(self, path, **q):
                assert q == {"labelSelector": LABEL}
                if path.endswith("/statefulsets"):
                    return [sts("a", 1, 1), {"metadata": {"name": "z", "labels": {LABEL: "0"}}}]
                return []
        s = rollout.collect(FakeCluster(), "ns")
        self.assertEqual(list(s.groups), [ZID])
        self.assertEqual(len(s.group(ZID)["statefulsets"]), 1)
        self.assertEqual(s.group("missing")["pods"], [])


class ToggleSettingUI(unittest.IsolatedAsyncioTestCase):
    async def test_word_and_label_toggle_and_inner_switch_messages_stay_inside(self):
        from textual.app import App
        from textual.widgets import Switch

        from tui.common.toggle import ToggleSetting

        seen, leaked = [], []

        class T(App):
            def compose(self):
                yield ToggleSetting("Also save the credentials", id="vault")

            def on_toggle_setting_changed(self, event):
                seen.append(event.value)

            def on_switch_changed(self, event):
                leaked.append(event.value)

        app = T()
        async with app.run_test(size=(80, 6)) as pilot:
            box = app.query_one("#vault", ToggleSetting)
            while not box.query(".ts-label") or not box.query_one(".ts-label").region.height:
                await pilot.pause(0.02)
            self.assertEqual(str(box.query_one(".ts-state").render()), "OFF")
            await pilot.click(".ts-label")
            await pilot.pause(0.05)
            self.assertTrue(box.value)
            self.assertTrue(box.has_class("-on"))
            self.assertTrue(box.query_one(Switch).value)
            self.assertEqual(str(box.query_one(".ts-state").render()), "ON")
            await pilot.press("space")                                   # the focused switch
            await pilot.pause(0.05)
            self.assertFalse(box.value)
            box.value = True                                             # programmatic: no message
            await pilot.pause(0.05)
            self.assertEqual(seen, [True, False])
            self.assertEqual(leaked, [])


if __name__ == "__main__":
    unittest.main()
