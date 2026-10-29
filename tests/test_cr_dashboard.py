"""cr_dashboard tests on hand-written synthetic objects (nothing captured from a cluster)."""

import sys
import unittest
from datetime import timedelta
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "src"))

from tui.cr_dashboard import graph, runner_events
from tui.cr_dashboard.classifier import Context, Thresholds, classify
from tui.cr_dashboard.display import display_rows
from tui.cr_dashboard.k8s_source import Hub, Introspector
from tui.cr_dashboard.model import (
    CRState,
    Edge,
    EdgeType,
    OperatorState,
    Phase,
    PodIssue,
    State,
    WorkloadHealth,
    WorkloadInfo,
    now_utc,
)
from tui.cr_dashboard.profiles import Profile, TargetSpec
from tui.cr_dashboard.status_normalize import normalize, parse_progress
from tui.cr_dashboard.store import Engine
from tui.cr_dashboard.workloads import WorkloadIndex

NOW = now_utc()


def iso(delta=timedelta()):
    return (NOW - delta).strftime("%Y-%m-%dT%H:%M:%SZ")


def obj(kind, name, ns="ops", status=None, spec=None, owners=(), uid=None, group="x.ibm.com", controller=None):
    refs = [{"uid": u, "kind": "Owner", "name": "o", **({"controller": True} if u == controller else {})}
            for u in owners]
    return {"apiVersion": f"{group}/v1", "kind": kind,
            "metadata": {"name": name, "namespace": ns, "uid": uid or f"uid-{name}", "ownerReferences": refs,
                         "creationTimestamp": iso(timedelta(hours=3))},
            "spec": spec or {}, "status": status or {}}


# ---------------------------------------------------------------------------
class NormalizeTests(unittest.TestCase):
    def test_kind_status_keys(self):
        self.assertEqual(normalize(obj("WKC", "w", status={"wkcStatus": "InProgress", "progress": "30%"}), "WKC").phase,
                         Phase.IN_PROGRESS)
        st = normalize(obj("Ibmcpd", "c", status={"controlPlaneStatus": "Completed", "currentVersion": "5.10.8"}), "Ibmcpd")
        self.assertEqual((st.phase, st.reconciled_version, st.progress), (Phase.COMPLETED, "5.10.8", 100))
        st = normalize(obj("Scheduling", "s", status={"cpd-schedulingStatus": "Completed"}), "Scheduling")
        self.assertEqual(st.phase, Phase.COMPLETED)

    def test_phase_state_and_plain_status(self):
        self.assertEqual(normalize(obj("CommonService", "c", status={"phase": "Succeeded"}), "CommonService").phase,
                         Phase.COMPLETED)
        self.assertEqual(normalize(obj("IBMLicensing", "instance", status={"state": "ACTIVE"}), "IBMLicensing").phase,
                         Phase.COMPLETED)
        self.assertEqual(normalize(obj("OperandRequest", "r", status={"phase": "Running"}), "OperandRequest").phase,
                         Phase.COMPLETED)
        self.assertEqual(normalize(obj("databandInstaller", "d", status={"status": "Completed"}), "databandInstaller").phase,
                         Phase.COMPLETED)

    def test_datastage_versions_list_and_message(self):
        st = normalize(obj("DataStage", "datastage", status={
            "dsStatus": "InProgress", "progress": "5%", "progressMessage": "Starting install of datastage",
            "versions": [{"name": "operator", "version": "10.0.8"}, {"name": "DataStage", "version": "5.4.8"}]}),
            "DataStage")
        self.assertEqual((st.progress, st.message, st.reconciled_version), (5, "Starting install of datastage", "5.4.8"))

    def test_shutdown_and_scale_fields(self):
        st = normalize(obj("WKC", "w", spec={"shutdown": "true", "scaleConfig": "medium"},
                           status={"wkcStatus": "Completed"}), "WKC")
        self.assertEqual(st.phase, Phase.SHUTDOWN)
        self.assertEqual(st.spec_scale, {"scaleConfig": "medium"})

    def test_ansible_conditions(self):
        conds = [{"type": "Running", "status": "True", "reason": "Running", "message": "Running reconciliation",
                  "lastTransitionTime": iso(timedelta(minutes=5))},
                 {"type": "Failure", "status": "True", "message": "boom", "lastTransitionTime": iso()}]
        st = normalize(obj("WKC", "w", status={"wkcStatus": "InProgress", "conditions": conds}), "WKC")
        self.assertTrue(st.reconciling)
        self.assertTrue(st.reconcile_failed)
        self.assertEqual(st.reconcile_failed_msg, "boom")

    def test_progress_parse(self):
        self.assertEqual([parse_progress(v) for v in ("90%", 55, "12", None, "n/a")], [90, 55, 12, None, None])


# ---------------------------------------------------------------------------
def cr(phase=Phase.COMPLETED, **kw):
    base = {"exists": True, "phase": phase, "raw_status": phase.value,
            "progress": 100 if phase == Phase.COMPLETED else 30, "message": "msg",
            "last_transition": NOW - timedelta(minutes=1)}
    base.update(kw)
    return CRState(**base)


def ctx(**kw):
    kw.setdefault("now", NOW)
    kw.setdefault("last_change", NOW - timedelta(minutes=1))
    return Context(th=Thresholds(), **kw)


class ClassifierTests(unittest.TestCase):
    def test_not_created_shutdown_unknown(self):
        self.assertEqual(classify(CRState(exists=False, phase=Phase.NOT_CREATED), None, None, ctx()).badge, "ring")
        self.assertEqual(classify(cr(Phase.SHUTDOWN), None, None, ctx()).state, State.INACTIVE)
        v = classify(cr(Phase.UNKNOWN), None, None, ctx())
        self.assertEqual((v.state, v.badge), (State.INACTIVE, "unknown"))

    def test_failed_status_red(self):
        self.assertEqual(classify(cr(Phase.FAILED), None, None, ctx()).state, State.FAILING)

    def test_crashing_pods_red_after_debounce_even_when_completed(self):
        fresh = WorkloadHealth(bad_pods=[PodIssue("api-1", "CrashLoopBackOff", NOW - timedelta(seconds=5))])
        old = WorkloadHealth(bad_pods=[PodIssue("api-1", "CrashLoopBackOff", NOW - timedelta(minutes=2))])
        self.assertEqual(classify(cr(), fresh, None, ctx()).state, State.HEALTHY)
        self.assertEqual(classify(cr(), old, None, ctx()).state, State.FAILING)

    def test_failed_job_red(self):
        wl = WorkloadHealth(failed_jobs=[PodIssue("setup-job", "BackoffLimitExceeded", NOW)])
        self.assertEqual(classify(cr(), wl, None, ctx()).state, State.FAILING)

    def test_d8_failed_reconcile_only_escalates_when_not_completed(self):
        op = OperatorState(introspection="ok", job_running=False, job_failed=True,
                           last_failed=(NOW, "Create PVC", "quota", "x.yml:1"))
        self.assertEqual(classify(cr(Phase.IN_PROGRESS), None, op, ctx()).state, State.FAILING)
        v = classify(cr(), None, op, ctx())
        self.assertEqual(v.state, State.HEALTHY)
        self.assertTrue(any(n.startswith("op!") for n in v.notices))

    def test_d8_operator_down(self):
        down = OperatorState(ready=False)
        v = classify(cr(), None, down, ctx())
        self.assertEqual(v.state, State.HEALTHY)
        self.assertIn("op! operator not ready", v.notices)
        self.assertEqual(classify(cr(Phase.IN_PROGRESS), None, down, ctx()).state, State.STUCK)

    def test_pending_pods_stuck(self):
        wl = WorkloadHealth(pending_pods=[PodIssue("p", "0/6 nodes are available", NOW - timedelta(minutes=3))])
        self.assertEqual(classify(cr(), wl, None, ctx()).state, State.STUCK)

    def test_blocked_by_failing_is_stuck(self):
        v = classify(cr(Phase.IN_PROGRESS), None, None, ctx(blocked_by=[("DataStage/datastage", State.FAILING)]))
        self.assertEqual((v.state, v.blocked_by), (State.STUCK, "DataStage/datastage"))
        v = classify(cr(), None, None, ctx(blocked_by=[("DataStage/datastage", State.FAILING)]))
        self.assertEqual(v.state, State.HEALTHY)

    def test_wait_loop_retries(self):
        op = OperatorState(introspection="ok", job_running=True, task="Wait until cr is completed: IKCPremium",
                           retry=(80, 91))
        self.assertEqual(classify(cr(Phase.IN_PROGRESS), None, op, ctx()).state, State.STUCK)
        op.retry = (10, 91)
        self.assertEqual(classify(cr(Phase.IN_PROGRESS), None, op, ctx()).state, State.PROGRESS)

    def test_stall(self):
        v = classify(cr(Phase.IN_PROGRESS), None, None, ctx(last_change=NOW - timedelta(minutes=40)))
        self.assertEqual(v.state, State.STUCK)
        self.assertEqual(classify(cr(Phase.IN_PROGRESS), None, None, ctx()).state, State.PROGRESS)

    def test_scaling_and_divergence(self):
        div = WorkloadHealth(workloads=[WorkloadInfo("Deployment", "api", 5, 3, 5, NOW - timedelta(minutes=2))])
        self.assertEqual(classify(cr(), div, None, ctx()).state, State.SCALING)
        old = WorkloadHealth(workloads=[WorkloadInfo("Deployment", "api", 5, 3, 5, NOW - timedelta(minutes=30))])
        self.assertEqual(classify(cr(), old, None, ctx()).state, State.FAILING)
        hpa = WorkloadHealth(hpa_scaling=["api 3→5"])
        self.assertEqual(classify(cr(), hpa, None, ctx()).state, State.SCALING)
        changed = ctx(scale_changed_at=NOW - timedelta(minutes=1))
        self.assertEqual(classify(cr(Phase.IN_PROGRESS), None, None, changed).state, State.SCALING)

    def test_drift_is_a_notice(self):
        v = classify(cr(reconciled_version="5.4.7"), None, None, ctx(expected_version="5.4.8"))
        self.assertEqual(v.state, State.HEALTHY)
        self.assertTrue(any(n.startswith("drift") for n in v.notices))


# ---------------------------------------------------------------------------
class GraphTests(unittest.TestCase):
    def test_wait_targets(self):
        self.assertEqual(graph.wait_target("Wait until cr is completed: IKCPremium"), "IKCPremium")
        self.assertEqual(graph.wait_target("Wait until DataStage is completed"), "DataStage")
        self.assertEqual(graph.wait_target("Wait for DataStage installation to complete"), "DataStage")
        self.assertIsNone(graph.wait_target("Wait for all pods to be ready"))
        self.assertIsNone(graph.wait_target("Create PX runtime PVC"))

    def test_depth_rule_and_fold(self):
        # comp A(1) -> comp B(2) -> comp C(3) -> comp D(4) ; D owns sub-CR s(5); B owns sub s2(3) owning s3(4)
        e = [Edge("A", "B", EdgeType.OWNS), Edge("B", "C", EdgeType.OWNS), Edge("C", "D", EdgeType.OWNS),
             Edge("D", "s", EdgeType.OWNS), Edge("B", "s2", EdgeType.OWNS), Edge("s2", "s3", EdgeType.OWNS)]
        comp = {"A": True, "B": True, "C": True, "D": True, "s": False, "s2": False, "s3": False}
        f = graph.build_forest(list(comp), e, is_component=comp, max_depth=3)
        self.assertTrue({"A", "B", "C", "D", "s2"} <= f.shown)
        self.assertEqual(f.folded, {"s": "D", "s3": "s2"})
        f = graph.build_forest(list(comp), e, is_component=comp, max_depth=None)
        self.assertEqual(f.folded, {})

    def test_waits_beats_owns_and_extra_parent_is_a_ref(self):
        e = [Edge("IKCStandard", "WKC", EdgeType.OWNS), Edge("WKC", "DataStage", EdgeType.WAITS),
             Edge("Other", "DataStage", EdgeType.OWNS)]
        comp = {k: True for k in ("IKCStandard", "WKC", "DataStage", "Other")}
        f = graph.build_forest(list(comp), e, is_component=comp, max_depth=3)
        self.assertEqual(f.parent_of["DataStage"], "WKC")
        self.assertTrue(any(r.ref_of == "DataStage" for r in f.rows))

    def test_reduce_depends(self):
        red = graph.reduce_depends({"wxdi": ["ccs", "wkc"], "wkc": ["ccs"], "ccs": []})
        self.assertEqual(red["wxdi"], ["wkc"])


# ---------------------------------------------------------------------------
class RunnerEventTests(unittest.TestCase):
    def test_running_job_with_retry(self):
        res = {"newest": {"id": "1", "finished": False, "task": "Wait until DataStage is completed",
                          "task_start": iso(timedelta(minutes=3)), "retry": [12, 240], "first": iso(timedelta(minutes=9)),
                          "last": iso()}}
        op = runner_events.apply_runner_result(OperatorState(), res)
        self.assertEqual((op.introspection, op.job_running, op.retry), ("ok", True, (12, 240)))

    def test_finished_job_failures(self):
        res = {"newest": {"id": "2", "finished": True, "failures": 1, "task": "Create PVC",
                          "failed": {"ts": iso(), "task": "Create PVC", "msg": "quota", "task_path": "a:1"}}}
        op = runner_events.apply_runner_result(OperatorState(), res)
        self.assertTrue(op.job_failed)
        self.assertEqual(op.last_failed[1:3], ("Create PVC", "quota"))

    def test_ignored_failure_is_routine(self):
        # DataStage ends every run on an ignored 'Synchronize global hardwarespec' failure (F9)
        res = {"newest": {"id": "3", "finished": True, "failures": 0, "final": "runner_on_failed",
                          "task": "Check install status", "failed": None}}
        op = runner_events.apply_runner_result(OperatorState(), res)
        self.assertFalse(op.job_failed)
        self.assertIsNone(op.last_failed)

    def test_watches_and_marker(self):
        text = "- version: v1\n  group: ds.cpd.ibm.com\n  kind: DataStage\n- version: v1\n  group: ds.cpd.ibm.com\n  kind: PXRuntime\n"
        self.assertEqual(runner_events.parse_watches(text)[1], ("ds.cpd.ibm.com", "v1", "PXRuntime"))
        self.assertEqual(runner_events.parse_marker("noise\n@@CRDASH@@{\"a\": 1}\n"), {"a": 1})
        self.assertEqual(runner_events.runner_path("g", "v1", "K", "ns", "n"), "/tmp/ansible-operator/runner/g/v1/K/ns/n")


# ---------------------------------------------------------------------------
def pod(name, owner_uid, ready=True, waiting=None, phase="Running", labels=None, sched=None):
    conds = [{"type": "Ready", "status": "True" if ready else "False", "lastTransitionTime": iso(timedelta(minutes=5))}]
    if sched:
        conds.append({"type": "PodScheduled", "status": "False", "message": sched,
                      "lastTransitionTime": iso(timedelta(minutes=5))})
    cs = [{"name": "c", "state": {"waiting": {"reason": waiting}} if waiting else {"running": {}}, "lastState": {}}]
    return {"metadata": {"name": name, "uid": f"uid-{name}", "ownerReferences": [{"uid": owner_uid}],
                         "labels": labels or {}},
            "status": {"phase": phase, "conditions": conds, "containerStatuses": cs}}


class WorkloadTests(unittest.TestCase):
    def setUp(self):
        self.dep = {"metadata": {"name": "api", "uid": "d1", "ownerReferences": [{"uid": "cr-ccs"}],
                                 "labels": {"icpdsupport/addOnId": "ccs"}},
                    "spec": {"replicas": 2}, "status": {"readyReplicas": 1, "updatedReplicas": 2}}
        self.rs = {"metadata": {"name": "api-rs", "uid": "rs1", "ownerReferences": [{"uid": "d1"}]}}
        self.orphan = {"metadata": {"name": "px", "uid": "d2", "ownerReferences": [],
                                    "labels": {"icpdsupport/addOnId": "ccs"}},
                       "spec": {"replicas": 1}, "status": {"readyReplicas": 1, "updatedReplicas": 1}}

    def index(self, pods, jobs=()):
        return WorkloadIndex(deployments=[self.dep, self.orphan], statefulsets=[], replicasets=[self.rs],
                             jobs=list(jobs), pods=pods, hpas=[], tracked_uids={"cr-ccs"},
                             label_key="icpdsupport/addOnId")

    def test_owner_chain_crash_and_label_fallback(self):
        h = self.index([pod("api-1", "rs1", ready=False, waiting="CrashLoopBackOff"), pod("api-2", "rs1")]).health()
        self.assertEqual([p.reason for p in h["cr-ccs"].bad_pods], ["CrashLoopBackOff"])
        names = {w.name for w in h["cr-ccs"].workloads}
        self.assertEqual(names, {"api", "px"})  # px attributed through the learned addOnId label

    def test_pending_and_failed_job(self):
        job_old = {"metadata": {"name": "j-1", "uid": "j1", "ownerReferences": [{"uid": "cr-ccs"}],
                                "creationTimestamp": iso(timedelta(hours=2))},
                   "status": {"conditions": [{"type": "Failed", "status": "True", "reason": "BackoffLimitExceeded"}]}}
        h = self.index([pod("api-1", "rs1", ready=False, phase="Pending", sched="0/6 nodes are available: cpu.")],
                       jobs=[job_old]).health()
        self.assertEqual(len(h["cr-ccs"].pending_pods), 1)
        self.assertEqual(len(h["cr-ccs"].failed_jobs), 1)


# ---------------------------------------------------------------------------
class FakeProfile(Profile):
    name = "fake"

    def __init__(self, specs):
        super().__init__()
        self._specs = specs

    def namespaces(self):
        return ["ops"]

    def operator_namespaces(self):
        return []

    def resolve(self, crds):
        return self._specs


def spec(kind, name, plural=None, component=None):
    return TargetSpec(group="x.ibm.com", version="v1", kind=kind, plural=plural or kind.lower() + "s",
                      namespaced=True, name=name, namespaces=["ops"], component=component or kind.lower())


def fake_engine():
    specs = [spec("WatsonxDataIntelligence", "wxdi"), spec("WKC", "wkc-cr"), spec("DataStage", "datastage"),
             spec("CCS", "ccs-cr"), spec("Factsheet", "fs-cr")]
    hub = Hub(kube=None)
    wxdi = obj("WatsonxDataIntelligence", "wxdi", status={"watsonxdataintelligenceStatus": "InProgress", "progress": "90%"})
    wkc = obj("WKC", "wkc-cr", owners=["uid-wxdi"], status={"wkcStatus": "InProgress", "progress": "30%"})
    ds = obj("DataStage", "datastage", status={"dsStatus": "Failed", "progressMessage": "install failed"})
    ccs = obj("CCS", "ccs-cr", status={"ccsStatus": "Completed"})
    zen = [obj("ZenExtension", f"ext-{i}", owners=["uid-ccs-cr"], status={"zenStatus": "Completed"}) for i in range(3)]
    for s, items in ((specs[0], [wxdi]), (specs[1], [wkc]), (specs[2], [ds]), (specs[3], [ccs]), (specs[4], [])):
        hub._sync(s.collection, {o["metadata"]["uid"]: o for o in items})
    scan = TargetSpec(group="x.ibm.com", version="v1", kind="ZenExtension", plural="zenextensions", namespaced=True,
                      name=None, namespaces=["ops"], is_component=False)
    hub._sync("scan:" + scan.collection[3:], {o["metadata"]["uid"]: o for o in zen})
    hub.ops["WKC/ops/wkc-cr"] = OperatorState(introspection="ok", job_running=True,
                                              task="Wait until DataStage is completed", retry=(3, 240),
                                              task_started_at=NOW)
    profile = FakeProfile(specs)
    engine = Engine(profile, hub, {}, specs, [scan], th=Thresholds(), max_depth=3)
    return hub, profile, engine


class EngineTests(unittest.TestCase):
    def test_chain_blocked_by_failing_datastage(self):
        _hub, _p, engine = fake_engine()
        view = engine.compute()
        n = view.nodes
        self.assertEqual(n["DataStage/ops/datastage"].verdict.state, State.FAILING)
        self.assertEqual(n["WKC/ops/wkc-cr"].verdict.state, State.STUCK)
        self.assertIn("blocked by DataStage/datastage", n["WKC/ops/wkc-cr"].verdict.reason)
        self.assertEqual(n["Factsheet/ops/fs-cr"].verdict.badge, "ring")
        self.assertEqual(view.root_problems, ["DataStage/ops/datastage"])
        # DataStage sits under WKC through the WAITS edge
        self.assertEqual(n["WatsonxDataIntelligence/ops/wxdi"].worst_desc, State.FAILING)
        # three healthy ZenExtensions under CCS collapse into one group row
        groups = [d for d in display_rows(view.rows, n) if d.kind == "group"]
        self.assertEqual(len(groups), 1)
        self.assertEqual(len(groups[0].members), 3)


# ---------------------------------------------------------------------------
try:
    import pytest
except ImportError:  # pragma: no cover
    pytest = None

if pytest is not None:
    @pytest.mark.asyncio
    async def test_ui_glow_dots_and_keys():
        from tui.cr_dashboard.ui.app import DashboardApp
        from tui.cr_dashboard.ui.glow_dot import GlowDot

        hub, profile, engine = fake_engine()
        intro = Introspector(None, hub, [], enabled=False)
        app = DashboardApp(kube=None, profile=profile, hub=hub, engine=engine, intro=intro, resources=[],
                           user="tester", header="cr-dashboard · test")
        async with app.run_test(size=(160, 45)) as pilot:
            app._recompute()
            for _ in range(50):   # rows are filled after the next refresh
                await pilot.pause(0.02)
                if any(d.state == State.FAILING for d in app.query("ChainRow GlowDot")):
                    break
            states = {d.state for d in app.query(GlowDot)}
            assert {State.FAILING, State.STUCK, State.HEALTHY, State.INACTIVE} <= states
            red = next(d for d in app.query("ChainRow GlowDot") if d.state == State.FAILING)
            assert red.has_class("-failing")
            before = red.glow
            app.pulse.tick(0.25)
            assert red.glow != before          # the pulse clock drives the glow
            await pilot.press("f")             # problems only
            for _ in range(50):
                await pilot.pause(0.02)
                if len(app.query("CRListRow")) == 2:
                    break
            assert len(app.query("CRListRow")) == 2  # WKC stuck (blocked), DataStage failing; wxdi is just in progress
            await pilot.press("question_mark")
            await pilot.pause()
            assert app.screen.__class__.__name__ == "LegendScreen"
            await pilot.press("escape")
            await pilot.press("a")
            assert app.pulse.animate is False

    @pytest.mark.asyncio
    async def test_ui_click_arrows_expand_and_collapse():
        from tui.cr_dashboard.ui.app import DashboardApp
        from tui.cr_dashboard.ui.chain_view import ToggleArrow

        hub, profile, engine = fake_engine()
        intro = Introspector(None, hub, [], enabled=False)
        app = DashboardApp(kube=None, profile=profile, hub=hub, engine=engine, intro=intro, resources=[],
                           user="tester", header="cr-dashboard · test")

        def rows():
            return list(app.query("ChainRow"))

        def row(pred):
            return next(r for r in rows() if r.is_mounted and pred(r))

        def arrow(r) -> str:
            return str(r.query_one(ToggleArrow).render()).strip()

        def arrow_of(pred) -> str:
            r = next((r for r in rows() if r.is_mounted and pred(r)), None)
            return arrow(r) if r is not None else ""

        async def settle(cond):
            for _ in range(50):
                await pilot.pause(0.02)
                if cond():
                    return True
            return False

        async with app.run_test(size=(160, 45)) as pilot:
            app._recompute()
            is_group = lambda r: r.drow.kind == "group"
            is_wxdi = lambda r: r.drow.key.startswith("WatsonxDataIntelligence/")
            assert await settle(lambda: arrow_of(is_group) == "▶")   # rows are filled after a refresh
            n_before = len(rows())

            # sub-CR group: ▶ -> click -> ▼ with its 3 ZenExtensions shown
            await pilot.click(row(is_group).query_one(ToggleArrow))
            assert await settle(lambda: len(rows()) == n_before + 3 and arrow_of(is_group) == "▼")
            assert sum(1 for r in rows() if r.drow.key.startswith("ZenExtension/")) == 3

            # click again: folded back into one row
            await pilot.click(row(is_group).query_one(ToggleArrow))
            assert await settle(lambda: len(rows()) == n_before and arrow_of(is_group) == "▶")

            # a chain: collapsing wxdi hides WKC and DataStage under it
            await pilot.click(row(is_wxdi).query_one(ToggleArrow))
            assert await settle(lambda: arrow_of(is_wxdi) == "▶"
                                and not any(r.drow.key.startswith("WKC/") for r in rows()))
            assert not any(r.drow.key.startswith("DataStage/") for r in rows())
            assert app.selected == row(is_wxdi).drow.key   # the click also selected the row

            # and expand it again
            await pilot.click(row(is_wxdi).query_one(ToggleArrow))
            assert await settle(lambda: any(r.drow.key.startswith("DataStage/") for r in rows()))

            # a leaf has no arrow: clicking its arrow cell does nothing
            leaf = row(lambda r: r.drow.key.startswith("DataStage/"))
            await pilot.click(leaf.query_one(ToggleArrow))
            await pilot.pause(0.1)
            assert any(r.drow.key.startswith("DataStage/") for r in rows())
