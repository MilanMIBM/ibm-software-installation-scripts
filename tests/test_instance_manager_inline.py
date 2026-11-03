"""instance_manager default (inline) UI + the two-lane hub with the discovery cache (cache plan H1, U1-U3).

Synthetic providers only: no cluster, no cpd-cli. The modal (--classic-ui) flows stay covered by
test_instance_manager_ui.py.
"""

import os
import sys
import tempfile
import threading
import time
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import pytest  # noqa: E402
from test_instance_manager_ui import FakeProvider, FormProvider, filled, settle  # noqa: E402

from tui.common.state import State  # noqa: E402
from tui.instance_manager.hub import DataHub  # noqa: E402
from tui.instance_manager.model import Instance, InstanceType, Kind  # noqa: E402


def no_modal(app) -> bool:
    return len(app.screen_stack) == 1


def work(app) -> str:
    """What the big panel shows: overview, a form id, sub-detail, or plan."""
    return app.query_one("#switcher").current


def state(app) -> str:
    return app.query_one("#state").current


class FakeKube:
    def __init__(self):
        self.sent = []

    def send(self, method, path, body=None, **kw):
        self.sent.append((method, path, body, kw))
        return {}


class EditProvider(FakeProvider):
    """FakeProvider whose cluster can take a dry-run patch (the planner's server-side check)."""

    def __init__(self):
        super().__init__()
        self.cluster.kube = FakeKube()


@pytest.mark.asyncio
async def test_service_dropdown_new_button_form_with_filtered_picker_override_and_plan():
    from textual.widgets import Button, Checkbox, Input, Select

    from tui.instance_manager.ui.app import InstanceManagerApp
    from tui.instance_manager.ui.context import FormContext, PlanPanel
    from tui.instance_manager.ui.form_view import FormView
    from tui.instance_manager.ui.forms import FieldRow, StoragePicker
    from tui.instance_manager.ui.storage_kind_tag import StorageKindTag

    hub = DataHub(FormProvider(), poll=3600)
    app = InstanceManagerApp(hub, "t", animate=False)
    async with app.run_test(size=(220, 60)) as pilot:
        assert await settle(pilot, lambda: filled(app, "InstanceRow"))
        svc = app.query_one("#svc-select", Select)
        assert [v for _, v in svc._options if v is not Select.NULL] == ["__all__", "cpd:db", "cpd:vol"]
        assert svc.value == "__all__" and work(app) == "overview"
        assert app.query_one("#new-inst", Button).disabled          # all services: pick one first
        svc.value = "cpd:db"
        assert await settle(pilot, lambda: app.type_sel == "cpd:db"
                            and not app.query_one("#new-inst", Button).disabled)
        assert "db instances" in str(app.query_one("#inst-panel").border_title)
        assert not app.query_one("#sub-select").display             # db has no sub-service manager
        t0 = time.monotonic()
        await pilot.click("#new-inst")
        assert await settle(pilot, lambda: work(app) == "form-cpd_db")      # the form in the big panel
        assert no_modal(app) and state(app) == "ctx-form"
        form = app.query_one("#form-cpd_db", FormView)
        picker = form.query_one(StoragePicker)
        assert await settle(pilot, lambda: picker.query(StorageKindTag))
        assert picker.value == "rbd"                                 # observed "fs" is file; the field needs block
        assert [v for _, v in picker._options()] == ["rbd"]          # prefiltered: only compatible classes
        assert not picker.override and not picker.query_one("#sc-input").display
        # [x] override: the dropdown turns into a free-text field, the tag follows what is typed
        picker.query_one("#override", Checkbox).value = True
        assert await settle(pilot, lambda: picker.override and picker.query_one("#sc-input").display
                            and not picker.query_one("#sc-select").display)
        assert picker.value == "rbd"                                 # carried over into the text field
        picker.query_one("#sc-input", Input).value = "fs"
        tag = picker.query_one(StorageKindTag)
        assert await settle(pilot, lambda: tag.kind == Kind.FILE and tag.has_class("-mismatch"))
        picker.query_one("#sc-input", Input).value = "nope"
        assert await settle(pilot, lambda: "not a StorageClass" in str(tag.render()) and tag.has_class("-mismatch"))
        assert await settle(pilot, lambda: any("no StorageClass nope" in e for e in form.errors))
        picker.query_one("#sc-input", Input).value = "fs"
        oracle = next(r for r in form.query(FieldRow) if r.f.path[-1] == "oracle")
        assert not oracle.display
        next(r for r in form.query(FieldRow) if r.f.path[-1] == "flavour").query_one(Select).value = "B"
        assert await settle(pilot, lambda: oracle.display)
        # checks under the field and in the state panel, local only
        form.query_one("#name", Input).value = "Bad_Name"
        assert await settle(pilot, lambda: "lowercase" in str(form._err["name"].render()))
        fc = app.query_one("#ctx-form", FormContext)
        assert await settle(pilot, lambda: "lowercase" in str(fc.query_one("#fc-checks").render()))
        form.query_one("#name", Input).value = "db-new"
        assert await settle(pilot, lambda: '"display_name": "db-new"' in str(fc.query_one("#fc-preview").render())
                            and "storage" in str(fc.query_one("#fc-checks").render()))
        # the draft survives switching services (UI-D4)
        svc.value = "__all__"
        assert await settle(pilot, lambda: work(app) == "overview" and state(app) == "st-info")
        svc.value = "cpd:db"
        assert await settle(pilot, lambda: app.type_sel == "cpd:db")
        await pilot.click("#new-inst")
        assert await settle(pilot, lambda: work(app) == "form-cpd_db")
        assert app.query_one("#form-cpd_db", FormView) is form and form.name == "db-new"
        assert picker.override and picker.value == "fs"
        # preview -> the plan in the big panel; Esc goes back to the draft
        form.query_one("#preview", Button).press()
        assert await settle(pilot, lambda: work(app) == "plan")
        assert no_modal(app) and "plan" in str(app.query_one("#crumb").render())
        panel = app.query_one("#plan", PlanPanel)
        assert panel.plan.runnable and panel.plan.warnings
        run = panel.query_one("#run", Button)
        assert run.disabled
        panel.query_one("#ack", Checkbox).value = True
        assert await settle(pilot, lambda: not run.disabled)
        await pilot.press("escape")
        assert await settle(pilot, lambda: work(app) == "form-cpd_db")
        # untick override: back to the dropdown, on a compatible class
        picker.query_one("#override", Checkbox).value = False
        assert await settle(pilot, lambda: not picker.override and picker.value == "rbd")
        await pilot.press("escape")
        assert await settle(pilot, lambda: work(app) == "overview")
        assert time.monotonic() - t0 < 30


@pytest.mark.asyncio
async def test_delete_plan_in_the_big_panel_needs_the_typed_name_and_read_only_blocks():
    from textual.widgets import Button, Input

    from tui.instance_manager.ui.app import InstanceManagerApp
    from tui.instance_manager.ui.context import PlanPanel

    app = InstanceManagerApp(DataHub(FormProvider(), poll=3600), "t", animate=False)
    async with app.run_test(size=(220, 60)) as pilot:
        assert await settle(pilot, lambda: filled(app, "InstanceRow"))
        assert await settle(pilot, lambda: not app.query_one("#act-delete", Button).disabled)
        await pilot.click("#act-delete")
        assert await settle(pilot, lambda: work(app) == "plan")
        assert no_modal(app)
        panel = app.query_one("#plan", PlanPanel)
        assert panel.plan.confirm_name == "db-z"
        run = panel.query_one("#run", Button)
        panel.query_one("#confirm", Input).value = "db-"
        await pilot.pause(0.1)
        assert run.disabled
        panel.query_one("#confirm", Input).value = "db-z"
        assert await settle(pilot, lambda: not run.disabled)
        await pilot.press("escape")
        assert await settle(pilot, lambda: work(app) == "overview")

    ro = InstanceManagerApp(DataHub(FormProvider(), poll=3600), "t", animate=False, read_only=True)
    async with ro.run_test(size=(220, 60)) as pilot:
        assert await settle(pilot, lambda: filled(ro, "InstanceRow"))
        await pilot.press("d")
        await pilot.pause(0.3)
        assert work(ro) == "overview"


@pytest.mark.asyncio
async def test_instance_click_overview_state_panel_and_scale_form():
    from textual.widgets import Input

    from tui.instance_manager.ui.app import InstanceManagerApp
    from tui.instance_manager.ui.context import FormContext, PlanPanel
    from tui.instance_manager.ui.form_view import FormView

    prov = EditProvider()
    app = InstanceManagerApp(DataHub(prov, poll=3600), "t", animate=False)
    async with app.run_test(size=(220, 60)) as pilot:
        assert await settle(pilot, lambda: filled(app, "InstanceRow") and len(app.query("InstanceRow")) == 3)
        row = next(r for r in app.query("InstanceRow") if "|db-a|" in r.key)
        await pilot.click(row)
        assert await settle(pilot, lambda: app.inst_sel == row.key and "cpd:db" in app.hub.models)
        assert "db › db-a" in str(app.query_one("#crumb").render())
        assert await settle(pilot, lambda: "storage: fs is file storage" in str(app.query_one("#st-text").render()))
        await pilot.press("e")
        assert await settle(pilot, lambda: work(app).startswith("edit-"))
        form = app.query_one(f"#{work(app)}", FormView)
        assert "db-a › Scale" in str(app.query_one("#crumb").render())
        nodes = form.query_one(Input)
        assert nodes.value == "2"
        nodes.value = "3"
        fc = app.query_one("#ctx-form", FormContext)
        assert await settle(pilot, lambda: "2 -> 3" in str(fc.query_one("#fc-preview").render()))
        form.query_one("#preview").press()
        assert await settle(pilot, lambda: work(app) == "plan")
        plan = app.query_one("#plan", PlanPanel).plan
        assert plan.diff == [("nodes", "2", "3")] and plan.runnable
        assert prov.cluster.kube.sent and prov.cluster.kube.sent[0][3].get("dryRun") == "All"   # server dry-run
        await pilot.press("escape", "escape")
        assert await settle(pilot, lambda: work(app) == "overview")
        assert not [c for c in app.query_one("#switcher").children if (c.id or "").startswith("edit-")]
        # another instance while the Scale form is open: its overview, the form goes away
        await pilot.press("e")
        assert await settle(pilot, lambda: work(app).startswith("edit-"))
        other = next(r for r in app.query("InstanceRow") if "|db-b|" in r.key)
        await pilot.click(other)
        assert await settle(pilot, lambda: work(app) == "overview" and app.inst_sel == other.key)


@pytest.mark.asyncio
async def test_legend_profile_and_fields_are_inline():
    from tui.instance_manager.providers.cpd import profile as prof
    from tui.instance_manager.ui.app import InstanceManagerApp, ProfileCtx

    ok = prof.ProfileStatus(state="ok", profile="p", url="https://cpd", live_url="https://cpd")
    pctx = ProfileCtx(status=ok, auto=False, source="default", api_url="https://api.c:6443", cli=None, kube=None,
                      namespace="ns")
    app = InstanceManagerApp(DataHub(FakeProvider(), poll=3600), "t", pctx, animate=False)
    async with app.run_test(size=(220, 60)) as pilot:
        assert await settle(pilot, lambda: filled(app, "InstanceRow"))
        await pilot.press("question_mark")
        assert await settle(pilot, lambda: app.query_one("#legend-strip").has_class("-open"))
        await pilot.press("P")
        strip = app.query_one("#profile-strip")
        assert await settle(pilot, lambda: strip.has_class("-open") and "https://cpd" in
                            str(strip.query_one("#ps-body").render()))
        assert strip.query_one("#repair").disabled                  # healthy: nothing to repair
        await pilot.press("x")
        tabs = app.query_one("#tabs")
        assert await settle(pilot, lambda: tabs.active == "tab-fields"
                            and "fields shown" in str(app.query_one("#fields-text").render()))
        await pilot.press("escape")
        assert await settle(pilot, lambda: not strip.has_class("-open"))
        await pilot.press("escape")
        assert await settle(pilot, lambda: not app.query_one("#legend-strip").has_class("-open"))
        await pilot.press("l")
        assert app.query_one("#events").has_class("-collapsed")
        assert no_modal(app)


def _wxd_spec():
    """The test lakehouse spec plus storage fields the way the live one words them."""
    from test_instance_manager_wxd import SPEC
    spec = {**SPEC, "definitions": dict(SPEC["definitions"])}
    milvus = dict(spec["definitions"]["milvusP"])
    milvus["properties"] = {**milvus["properties"],
                            "block_storage_class": {"type": "string", "description": "rwo storage class",
                                                    "example": "nfs"},
                            "file_storage_class": {"type": "string", "description": "rwx storage class"},
                            "volume_storage_class": {"type": "string", "description": "Type of the storage"}}
    spec["definitions"]["milvusP"] = milvus
    return spec


@pytest.mark.asyncio
async def test_subservice_dropdown_list_and_forms_with_filtered_storage():
    from test_instance_manager_wxd import FakeAPI, FakeFacts
    from textual.widgets import Button, Input, Select

    from tui.instance_manager.subservices import REGISTRY
    from tui.instance_manager.subservices.wxd import provider as wp
    from tui.instance_manager.ui.app import InstanceManagerApp
    from tui.instance_manager.ui.form_view import FormView
    from tui.instance_manager.ui.forms import FieldRow, StoragePicker
    from tui.instance_manager.ui.sub_view import SubItemRow

    class WxdParent(FormProvider):
        def discover_types(self):
            return [InstanceType(key="cpd:watsonx-data", display="watsonx-data", group="wxd.io", version="v1",
                                 kind="Wxd", plural="wxds", crd={"spec": {}}, max_instances=1)]

        def list_instances(self, itype):
            return [Instance(itype.key, "lakehouse", "ns", "u", {"spec": {"zenServiceInstanceId": "1"}},
                             State.HEALTHY, "ok", meta={"zen": {"id": "1"}})]

    sp = wp.WxdEngines(cluster=type("C", (), {"find_crd": lambda s, k: None, "try_list": lambda s, p, **kw: []})())
    sp.spec = _wxd_spec()
    api = FakeAPI()
    sp.api = lambda: api
    sp.bind = lambda parent: (setattr(sp, "parent", parent), setattr(sp, "namespace", "ns"),
                              setattr(sp, "facts", FakeFacts()))
    REGISTRY.append(sp)
    try:
        with patch.dict(os.environ, {"CPD_URL": "https://x", "CPD_USERNAME": "u", "CPD_APIKEY": "k"}):
            app = InstanceManagerApp(DataHub(WxdParent(), poll=3600), "t", animate=False)
            async with app.run_test(size=(220, 60)) as pilot:
                assert await settle(pilot, lambda: filled(app, "InstanceRow"))
                sub = app.query_one("#sub-select", Select)
                # the sub-service dropdown spawns next to the service dropdown, with the kinds as options
                assert await settle(pilot, lambda: sub.display and not sub.disabled)
                assert [v for _, v in sub._options if v is not Select.NULL] == ["milvus", "presto", "spark"]
                assert sub.value == "milvus"                           # the first creatable kind
                panel = app.query_one("#sub-panel")
                assert await settle(pilot, lambda: panel.display and app.query_one("#left").has_class("-sub"))
                assert "milvus · 0" in str(panel.border_title)
                sub.value = "spark"
                assert await settle(pilot, lambda: app.query_one("#new-sub", Button).disabled)   # list only
                sub.value = "presto"
                assert await settle(pilot, lambda: len(app.query(SubItemRow)) == 1 and filled(app, "SubItemRow"))
                await pilot.click(app.query_one(SubItemRow))
                assert await settle(pilot, lambda: work(app) == "sub-detail")
                assert "lakehouse › watsonx.data engines › presto › p-old" in str(app.query_one("#crumb").render())
                assert "p-old" in str(app.query_one("#sd-text").render())
                await pilot.click("#new-sub")
                assert await settle(pilot, lambda: work(app).startswith("subform-"))
                form = app.query_one(f"#{work(app)}", FormView)
                rows = {r.f.path[-1]: r for r in form.query(FieldRow)}
                rows["size_config"].query_one(Select).value = "small"
                assert await settle(pilot, lambda: rows["presto_worker_replicas"].value == "10")
                rows["presto_worker_replicas"].query_one(Input).value = "3"
                assert rows["presto_worker_replicas"].value == "3"
                await pilot.press("escape")
                assert await settle(pilot, lambda: work(app) == "overview")
                # a sub-service form's storage fields: dropdowns filtered by what the API spec says
                sub.value = "milvus"
                assert await settle(pilot, lambda: not app.query_one("#new-sub", Button).disabled)
                await pilot.click("#new-sub")
                assert await settle(pilot, lambda: work(app).startswith("subform-"))
                form = app.query_one(f"#{work(app)}", FormView)
                assert await settle(pilot, lambda: len(form.query(StoragePicker)) == 3)
                pickers = {p.f.path[-1]: p for p in form.query(StoragePicker)}
                assert [v for _, v in pickers["block_storage_class"]._options()] == ["rbd"]     # rwo
                assert [v for _, v in pickers["file_storage_class"]._options()] == ["fs"]       # rwx
                assert sorted(v for _, v in pickers["volume_storage_class"]._options()) == ["fs", "rbd"]
                assert pickers["block_storage_class"].value == "rbd"        # the example "nfs" isn't a class here
                await pilot.press("escape")
                assert await settle(pilot, lambda: work(app) == "overview")
    finally:
        REGISTRY.remove(sp)


# -- H1: the hub with the discovery cache ----------------------------------------------------------------
class _CacheEnv:
    def __init__(self):
        from test_instance_manager_cache import OPTIONS
        self.tmp = tempfile.TemporaryDirectory()
        self.cfg = Path(self.tmp.name)
        (self.cfg / "install-options.yml").write_text(OPTIONS)
        self.env = patch.dict(os.environ, {"CONFIG_DIR": str(self.cfg)})

    def __enter__(self):
        self.env.start()
        for k in ("CPD_URL", "CPD_USERNAME", "CPD_APIKEY"):
            os.environ.pop(k, None)
        return self

    def __exit__(self, *a):
        self.env.stop()
        self.tmp.cleanup()

    def make(self, kube, cli):
        from test_instance_manager_cache import ENV

        from tui.instance_manager.cache.manager import DiscoveryCache
        from tui.instance_manager.providers.cpd.provider import CpdProvider
        from tui.instance_manager.providers.k8s_crd.cluster import Cluster
        prov = CpdProvider(Cluster(kube), "ns", cli)
        cache = DiscoveryCache(prov, kube, "ns", operators_ns="ops", env=dict(ENV), storage_flags={"file_sc": "fs"},
                               root=self.cfg / "instance_manager_cache")
        cache.attach()
        return prov, cache


@pytest.mark.asyncio
async def test_first_run_shows_the_build_progress_and_reaches_100():
    from test_instance_manager_cache import FakeCli, FakeKube

    from tui.instance_manager.ui.app import InstanceManagerApp

    class SlowCli(FakeCli):
        def get_instance(self, name, service_type):
            time.sleep(0.4)
            return super().get_instance(name, service_type)

    with _CacheEnv() as env:
        kube = FakeKube()
        prov, cache = env.make(kube, SlowCli(kube))
        hub = DataHub(prov, poll=3600, cache=cache, include_subservices=False)
        assert not hub.types                                   # nothing cached yet
        app = InstanceManagerApp(hub, "t", animate=False)
        async with app.run_test(size=(220, 60)) as pilot:
            t0 = time.monotonic()
            assert await settle(pilot, lambda: app.query_one("#build").has_class("-open"))
            assert time.monotonic() - t0 < 0.5 + 0.3              # within 0.5 s (plus one tick)
            assert "building the discovery cache" in str(app.query_one("#bv-title").render())
            assert await settle(pilot, lambda: hub.build is not None and hub.build.finished, tries=400)
            assert hub.build.fraction == 1.0
            assert await settle(pilot, lambda: not app.query_one("#build").has_class("-open"))
            assert "cache: fresh" in str(app.query_one("#cache-tag").render())
            assert [t.key for t in hub.types] == ["cpd:db"] and hub.model_state["cpd:db"] == "fresh"
            assert await settle(pilot, lambda: len(app.query("InstanceRow")) == 2)


@pytest.mark.asyncio
async def test_warm_start_paints_from_the_cache_and_changes_wait_for_live_state():
    from test_instance_manager_cache import FakeCli, FakeKube

    from tui.instance_manager.cache.progress import Progress  # noqa: F401
    from tui.instance_manager.ui.app import InstanceManagerApp

    with _CacheEnv() as env:
        kube = FakeKube()
        cli = FakeCli(kube)
        prov, cache = env.make(kube, cli)
        cache.check()
        cache.build(include_subservices=False)               # an earlier run built it
        cli.gets.clear()
        prov2, cache2 = env.make(kube, cli)
        gate = threading.Event()
        hub = DataHub(prov2, poll=3600, before_load=lambda: gate.wait(10), cache=cache2, include_subservices=False)
        # painted before start(): types, models, StorageClass kinds and the cached instance list
        assert [t.key for t in hub.types] == ["cpd:db"]
        assert hub.model_state == {"cpd:db": "cached"} and set(hub.sc) == {"fs", "rbd"}
        assert all(i.meta.get("cached") for i in hub.instances["cpd:db"]) and not hub.live
        app = InstanceManagerApp(hub, "t", animate=False)
        async with app.run_test(size=(220, 60)) as pilot:
            assert await settle(pilot, lambda: len(app.query("InstanceRow")) == 2 and filled(app, "InstanceRow"),
                                tries=20)                       # first paint, no cluster call yet
            assert "cache: cached" in str(app.query_one("#cache-tag").render())
            await pilot.press("d")                               # a cached instance: changes wait for live state
            await pilot.pause(0.3)
            assert work(app) == "overview"
            gate.set()
            assert await settle(pilot, lambda: hub.live and not any(
                i.meta.get("cached") for i in hub.instances["cpd:db"]))
            assert await settle(pilot, lambda: hub.model_state.get("cpd:db") == "fresh", tries=400)
            assert cli.gets == []                                # S4 came from the cache


@pytest.mark.asyncio
async def test_R_rebuilds_the_cache_with_the_progress_view():
    from test_instance_manager_cache import FakeCli, FakeKube

    from tui.instance_manager.ui.app import InstanceManagerApp

    class SlowCli(FakeCli):
        def get_instance(self, name, service_type):
            time.sleep(0.3)
            return super().get_instance(name, service_type)

    with _CacheEnv() as env:
        kube = FakeKube()
        cli = SlowCli(kube)
        prov, cache = env.make(kube, cli)
        cache.check()
        cache.build(include_subservices=False)
        cli.gets.clear()
        prov2, cache2 = env.make(kube, cli)
        hub = DataHub(prov2, poll=3600, cache=cache2, include_subservices=False)
        app = InstanceManagerApp(hub, "t", animate=False)
        async with app.run_test(size=(220, 60)) as pilot:
            assert await settle(pilot, lambda: hub.live and hub.model_state.get("cpd:db") == "fresh", tries=400)
            assert cli.gets == []                                    # warm: no cpd-cli get
            await pilot.press("R")
            assert await settle(pilot, lambda: app.query_one("#build").has_class("-open"))
            assert await settle(pilot, lambda: hub.build is not None and hub.build.finished
                                and not app.query_one("#build").has_class("-open"), tries=400)
            assert len(cli.gets) == 2                                # everything rebuilt, S4 included
            assert any("re-discovering everything" in e.text for e in hub.events)


def test_plans_wait_for_a_fresh_model_c_d1():
    from test_instance_manager_cache import FakeCli, FakeKube

    with _CacheEnv() as env:
        kube = FakeKube()
        prov, cache = env.make(kube, FakeCli(kube))
        cache.check()
        cache.build(include_subservices=False)
        prov2, cache2 = env.make(kube, FakeCli(kube))
        hub = DataHub(prov2, poll=3600, cache=cache2, include_subservices=False)
        cached = hub.models["cpd:db"]
        assert hub.model_state["cpd:db"] == "cached"
        cache2.check()
        hub._checked.set()
        with patch.object(type(prov2), "assess_storage", wraps=prov2.assess_storage) as assess:
            fm = hub.ensure_fresh("cpd:db")
            assert assess.called                                     # storage needs re-checked live
        assert hub.model_state["cpd:db"] == "fresh" and fm is hub.models["cpd:db"] and fm is not cached
        assert hub.ensure_fresh("cpd:db") is fm                     # once per run


@pytest.mark.asyncio
async def test_stray_startup_keys_leave_all_services_and_no_filter(monkeypatch):
    """A terminal's reply to a start-up query arrives as typed keys ("rgb:1f1f/..."): nothing may react."""
    from textual.widgets import Select

    from tui.instance_manager.ui import app as im_app
    monkeypatch.setattr(im_app, "STARTUP_KEY_GRACE", 30.0)
    app = im_app.InstanceManagerApp(DataHub(FormProvider(), poll=3600), "t", animate=False)
    async with app.run_test(size=(220, 60)) as pilot:
        assert await settle(pilot, lambda: filled(app, "InstanceRow"))
        assert app.focused is None                                   # the dropdown doesn't catch typing
        await pilot.press(*"rgb:1f1f/1d1d/1e1e")
        await pilot.pause(0.3)
        assert app.problems_only is False and app.type_sel == "__all__"
        assert app.query_one("#svc-select", Select).value == "__all__"
        assert work(app) == "overview" and no_modal(app)
