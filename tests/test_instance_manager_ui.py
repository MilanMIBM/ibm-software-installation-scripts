"""instance_manager TUI (Pilot) on a synthetic provider: no cluster, no cpd-cli."""

import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import pytest  # noqa: E402

from tui.common.state import State  # noqa: E402
from tui.instance_manager.hub import DataHub  # noqa: E402
from tui.instance_manager.model import (  # noqa: E402
    Evidence, Field, FormModel, Instance, InstanceType, Kind, Need, Role, StorageClassInfo, StorageNeed)
from tui.instance_manager.providers.base import Provider  # noqa: E402

SC = {"fs": StorageClassInfo("fs", kind=Kind.FILE), "rbd": StorageClassInfo("rbd", kind=Kind.BLOCK)}


class FakeCluster:
    def kinds_in_group(self, group):
        return [{"group": "db.io", "version": "v1", "kind": "DbEngine", "plural": "dbengines", "namespaced": True},
                {"group": "db.io", "version": "v1", "kind": "Db", "plural": "dbs", "namespaced": True}]

    def try_list(self, path):
        return [{}] if "dbengines" in path else []

    def list_many(self, paths):
        return {p: self.try_list(p) for p in paths}


class FakeProvider(Provider):
    id = "fake"
    namespace = "ns"

    def __init__(self):
        self.cluster = FakeCluster()
        self.notices = ["a test notice"]
        self.state = State.HEALTHY

    def discover_types(self):
        return [InstanceType(key="cpd:db", display="db", group="db.io", version="v1", kind="Db", plural="dbs",
                             crd={"spec": {}}, max_instances=2),
                InstanceType(key="cpd:vol", display="volumes", group="", version="", kind="", plural="",
                             creatable=False)]

    def list_instances(self, itype):
        if itype.key == "cpd:vol":
            return [Instance("cpd:vol", "vol-1", "ns", "", {}, State.HEALTHY, "zen: PROVISIONED")]
        return [Instance("cpd:db", "db-a", "ns", "u1", {"spec": {"sc": "fs", "nodes": 2}}, self.state, "ok",
                         badges=["zen+cr"], display_name="db-a"),
                Instance("cpd:db", "db-b", "ns", "u2", {"spec": {"sc": "rbd", "nodes": 1}}, State.FAILING,
                         "Failed", badges=["zen+cr"])]

    def form_model(self, itype, instances=None):
        sc = Field(path=("sc",), role=Role.STORAGE_CLASS, observed=["fs", "rbd"], sources={"S3"},
                   storage=StorageNeed(Need.BLOCK, [Evidence("live", "peers: 9/9 block", 0.7)],
                                       ["db-a: fs is file storage, field needs block-preferred"]))
        nodes = Field(path=("nodes",), type="integer", role=Role.REPLICAS, observed=[2, 1], minimum=1,
                      maximum=5, sources={"S1", "S3"})
        return FormModel(itype.key, {sc.path: sc, nodes.path: nodes}, instance_count=2)

    def storage_classes(self):
        return SC


def filled(app, selector) -> bool:
    """Rows exist, are laid out (a click needs a real region) and show their text."""
    rows = list(app.query(selector))
    return bool(rows) and all(r.region.height and str(r.query_one(".c-name").render()).strip() for r in rows)


async def settle(pilot, cond, tries=250):
    for _ in range(tries):
        await pilot.pause(0.03)
        if cond():
            return True
    app = pilot.app
    print(f"settle timed out: focused={app.focused!r} sel={getattr(app, 'inst_sel', None)} "
          f"type={getattr(app, 'type_sel', None)} screen={app.screen.__class__.__name__}")
    return False


@pytest.mark.asyncio
async def test_browse_storage_tag_and_subservice_tab():
    from tui.instance_manager.ui.app import InstanceManagerApp
    from tui.instance_manager.ui.storage_kind_tag import StorageKindTag

    hub = DataHub(FakeProvider(), poll=3600)
    app = InstanceManagerApp(hub, "instance-manager · test", animate=False)
    async with app.run_test(size=(180, 45)) as pilot:
        assert await settle(pilot, lambda: len(app.query("InstanceRow")) == 3 and filled(app, "InstanceRow")
                            and filled(app, "CatalogRow"))
        # failing first, then the rest
        assert app.query("InstanceRow").first().key.startswith("cpd:db|ns|db-b")
        assert len(app.query("CatalogRow")) == 3 and app.query("CatalogRow.-unmanaged")
        # select db-a with the mouse: storage tab shows the kind of its class, flagged as a mismatch
        row = next(r for r in app.query("InstanceRow") if "|db-a|" in r.key)
        await pilot.click(row)
        assert await settle(pilot, lambda: app.inst_sel == row.key)
        assert await settle(pilot, lambda: len(app.query(StorageKindTag)) == 1
                            and app.query_one(StorageKindTag).kind == Kind.FILE)
        tag = app.query_one(StorageKindTag)
        assert tag.has_class("-file") and tag.has_class("-mismatch")
        # the selected row is marked "storage!" once its model is in
        assert await settle(pilot, lambda: "storage!" in str(row.query_one(".c-why").render()))
        # sub-services: candidates in the parent's API group, no provider -> grayed out with the reason
        tabs = app.query_one("#tabs")
        assert await settle(pilot, lambda: "DbEngine x1" in str(tabs.get_tab("tab-sub").tooltip))
        assert tabs.get_tab("tab-sub").disabled
        # select db-b (rbd = block): tag follows the selection, no mismatch
        row_b = next(r for r in app.query("InstanceRow") if "|db-b|" in r.key)
        await pilot.click(row_b)
        assert await settle(pilot, lambda: app.inst_sel == row_b.key)
        assert await settle(pilot, lambda: app.query_one(StorageKindTag).kind == Kind.BLOCK)
        assert not app.query_one(StorageKindTag).has_class("-mismatch")
        # problems only: db-b failing + db-a storage mismatch stay, healthy vol-1 goes
        await pilot.press("f")
        assert await settle(pilot, lambda: len(app.query("InstanceRow")) == 2)
        await pilot.press("question_mark")
        assert await settle(pilot, lambda: app.screen.__class__.__name__ == "LegendScreen")
        await pilot.press("escape")
        await pilot.press("x")
        assert await settle(pilot, lambda: app.screen.__class__.__name__ == "ExplainScreen")
        await pilot.press("escape")


@pytest.mark.asyncio
async def test_state_changes_are_announced_and_rows_reused():
    from tui.instance_manager.ui.app import InstanceManagerApp

    prov = FakeProvider()
    hub = DataHub(prov, poll=3600)
    app = InstanceManagerApp(hub, "t", animate=False)
    async with app.run_test(size=(180, 45)) as pilot:
        assert await settle(pilot, lambda: len(app.query("InstanceRow")) == 3)
        before = {r.key: r for r in app.query("InstanceRow")}
        prov.state = State.SCALING
        hub._poll_instances()
        assert await settle(pilot, lambda: any(e.text == "db-a: healthy -> scaling" for e in hub.events))
        after = {r.key: r for r in app.query("InstanceRow")}
        assert all(after[k] is before[k] for k in before)          # reconciled in place, not rebuilt


@pytest.mark.asyncio
async def test_auto_repair_toggle_persists_per_cluster():
    from tui.instance_manager.providers.cpd import profile as prof
    from tui.instance_manager.settings import Settings
    from tui.instance_manager.ui.app import InstanceManagerApp, ProfileCtx

    with tempfile.TemporaryDirectory() as d:
        st = Settings(Path(d) / "settings.json")
        ok = prof.ProfileStatus(state="ok", profile="p")
        ctx = ProfileCtx(status=ok, auto=False, source="default", api_url="https://api.c:6443", cli=None,
                         kube=None, namespace="ns")
        with patch.object(prof, "Settings", return_value=st), patch.object(prof, "repair") as rep:
            app = InstanceManagerApp(DataHub(FakeProvider(), poll=3600), "t", ctx, animate=False)
            async with app.run_test(size=(180, 45)) as pilot:
                await pilot.click("#auto-tag")
                assert await settle(pilot, lambda: ctx.auto)
                assert "auto-repair on (saved)" in str(app.query_one("#auto-tag").render())
                rep.assert_not_called()                 # healthy profile: toggling on repairs nothing
            assert st.cluster("https://api.c:6443")["auto_repair_profile"] is True


class FormProvider(FakeProvider):
    """Payload fields + a zen-only instance for delete (no cluster calls while planning)."""
    cli = None

    def list_instances(self, itype):
        if itype.key == "cpd:vol":
            return []
        return [Instance("cpd:db", "db-z", "ns", "", {}, State.HEALTHY, "zen: PROVISIONED",
                         meta={"zen": {"id": "9", "display_name": "db-z"}})]

    def form_model(self, itype, instances=None):
        def F(path, **kw):
            return Field(path=path, payload=True, sources={"S1"}, **kw)
        fields = [
            F(("parameters", "nodes"), type="integer", minimum=1, maximum=5, default=1, label="Nodes",
              role=Role.REPLICAS, order=0),
            F(("parameters", "flavour"), enum=["A", "B"], default="A", label="Flavour", order=1),
            F(("parameters", "oracle"), type="boolean", default=True, label="Oracle", order=2,
              show_if={("parameters", "flavour"): ["B"]}),
            F(("parameters", "sc"), role=Role.STORAGE_CLASS, observed=["fs"], label="Storage class", order=3,
              storage=StorageNeed(Need.BLOCK, [Evidence("live", "peers 9/9 block", 0.7)])),
        ]
        return FormModel(itype.key, {f.path: f for f in fields})


@pytest.mark.asyncio
async def test_create_form_storage_picker_and_plan_gates():
    from textual.widgets import Button, Checkbox, Input, Select, Switch
    from tui.instance_manager.ui.app import InstanceManagerApp
    from tui.instance_manager.ui.forms import CreateScreen, FieldRow, PlanScreen, StoragePicker
    from tui.instance_manager.ui.storage_kind_tag import StorageKindTag

    hub = DataHub(FormProvider(), poll=3600)
    app = InstanceManagerApp(hub, "t", animate=False)
    async with app.run_test(size=(200, 60)) as pilot:
        assert await settle(pilot, lambda: filled(app, "CatalogRow") and len(app.query("CatalogRow")) == 3)
        row = next(r for r in app.query("CatalogRow") if r.key == "cpd:db")
        row.focus()
        hub.request_model("cpd:db")
        assert await settle(pilot, lambda: "cpd:db" in hub.models and hub.sc)
        await pilot.press("n")
        assert await settle(pilot, lambda: isinstance(app.screen, CreateScreen))
        scr = app.screen
        picker = scr.query_one(StoragePicker)
        assert picker.value == "rbd"                                 # observed "fs" is file; the field needs block
        assert picker.query_one(StorageKindTag).kind == Kind.BLOCK
        assert [v for _, v in picker._options()] == ["rbd"]          # filtered
        picker.query_one(Switch).value = True                        # show all
        assert await settle(pilot, lambda: [v for _, v in picker._options()] == ["rbd", "fs"])
        picker.query_one(Select).value = "fs"
        tag = picker.query_one(StorageKindTag)
        assert await settle(pilot, lambda: tag.kind == Kind.FILE and tag.has_class("-mismatch"))
        oracle = next(r for r in scr.query(FieldRow) if r.f.path[-1] == "oracle")
        assert not oracle.display                                   # show_if flavour == B
        flavour = next(r for r in scr.query(FieldRow) if r.f.path[-1] == "flavour")
        flavour.query_one(Select).value = "B"
        assert await settle(pilot, lambda: oracle.display)
        scr.query_one("#name", Input).value = "db-new"
        scr.query_one("#preview", Button).press()
        assert await settle(pilot, lambda: isinstance(app.screen, PlanScreen))
        plan = app.screen.plan
        assert plan.runnable and plan.warnings                      # wrong-kind class -> a warning to acknowledge
        run = app.screen.query_one("#run", Button)
        assert run.disabled
        app.screen.query_one("#ack", Checkbox).value = True
        assert await settle(pilot, lambda: not run.disabled)
        await pilot.press("escape")


@pytest.mark.asyncio
async def test_delete_needs_the_name_and_read_only_blocks_changes():
    from textual.widgets import Button, Input
    from tui.instance_manager.ui.app import InstanceManagerApp
    from tui.instance_manager.ui.forms import PlanScreen

    hub = DataHub(FormProvider(), poll=3600)
    app = InstanceManagerApp(hub, "t", animate=False)
    async with app.run_test(size=(200, 60)) as pilot:
        assert await settle(pilot, lambda: filled(app, "InstanceRow"))
        await pilot.press("d")
        assert await settle(pilot, lambda: isinstance(app.screen, PlanScreen))
        assert app.screen.plan.confirm_name == "db-z"
        run = app.screen.query_one("#run", Button)
        app.screen.query_one("#confirm", Input).value = "db-"
        await pilot.pause(0.1)
        assert run.disabled
        app.screen.query_one("#confirm", Input).value = "db-z"
        assert await settle(pilot, lambda: not run.disabled)
        await pilot.press("escape")

    ro = InstanceManagerApp(DataHub(FormProvider(), poll=3600), "t", animate=False, read_only=True)
    async with ro.run_test(size=(200, 60)) as pilot:
        assert await settle(pilot, lambda: filled(ro, "InstanceRow"))
        await pilot.press("d")
        await pilot.pause(0.3)
        assert not isinstance(ro.screen, PlanScreen)


@pytest.mark.asyncio
async def test_subservice_screen_starter_template_and_back():
    import os
    from textual.widgets import Input, Select
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from test_instance_manager_wxd import FakeAPI, FakeFacts
    from tui.instance_manager.subservices import REGISTRY
    from tui.instance_manager.subservices.wxd import provider as wp
    from tui.instance_manager.ui.app import InstanceManagerApp
    from tui.instance_manager.ui.forms import CreateScreen, FieldRow
    from tui.instance_manager.ui.subservice_screen import SubServiceScreen

    class WxdParent(FormProvider):
        def discover_types(self):
            return [InstanceType(key="cpd:watsonx-data", display="watsonx-data", group="wxd.io", version="v1",
                                 kind="Wxd", plural="wxds", crd={"spec": {}}, max_instances=1)]

        def list_instances(self, itype):
            return [Instance(itype.key, "lakehouse", "ns", "u", {"spec": {"zenServiceInstanceId": "1"}},
                             State.HEALTHY, "ok", meta={"zen": {"id": "1"}})]

    from test_instance_manager_wxd import SPEC
    sp = wp.WxdEngines(cluster=type("C", (), {"find_crd": lambda s, k: None, "try_list": lambda s, p, **kw: []})())
    sp.spec = SPEC
    api = FakeAPI()
    sp.api = lambda: api
    sp.bind = lambda parent: (setattr(sp, "parent", parent), setattr(sp, "namespace", "ns"),
                              setattr(sp, "facts", FakeFacts()))
    REGISTRY.append(sp)
    try:
        with patch.dict(os.environ, {"CPD_URL": "https://x", "CPD_USERNAME": "u", "CPD_APIKEY": "k"}):
            app = InstanceManagerApp(DataHub(WxdParent(), poll=3600), "t", animate=False)
            async with app.run_test(size=(200, 60)) as pilot:
                assert await settle(pilot, lambda: filled(app, "InstanceRow"))
                tabs = app.query_one("#tabs")
                assert await settle(pilot, lambda: not tabs.get_tab("tab-sub").disabled)
                await pilot.press("s")
                assert await settle(pilot, lambda: isinstance(app.screen, SubServiceScreen)
                                    and len(app.screen.query("CatalogRow")) == len(sp.collections()))
                scr = app.screen
                assert sp.itype(scr.kind_sel).creatable              # a creatable type is preselected
                scr.kind_sel = "presto"
                scr._redraw()
                await pilot.press("n")
                assert await settle(pilot, lambda: isinstance(app.screen, CreateScreen))
                form = app.screen
                rows = {r.f.path[-1]: r for r in form.query(FieldRow)}
                rows["size_config"].query_one(Select).value = "small"
                assert await settle(pilot, lambda: rows["presto_worker_replicas"].value == "10")
                rows["size_config"].query_one(Select).value = "starter"
                assert await settle(pilot, lambda: rows["presto_worker_replicas"].value == "1")
                rows["presto_worker_replicas"].query_one(Input).value = "3"   # and it stays editable
                assert rows["presto_worker_replicas"].value == "3"
                await pilot.press("escape")
                assert await settle(pilot, lambda: isinstance(app.screen, SubServiceScreen))
                await pilot.press("escape")
                assert await settle(pilot, lambda: not isinstance(app.screen, SubServiceScreen))
    finally:
        REGISTRY.remove(sp)


@pytest.mark.asyncio
async def test_rows_filled_before_mount_still_paint():
    """Regression: a fill() that arrives before the row's labels exist used to leave the row blank."""
    from textual.app import App
    from tui.instance_manager.ui.rows import CatalogRow, InstanceRow

    inst = Instance("cpd:db", "db-a", "ns", "u1", {}, State.HEALTHY, "ok", badges=["zen+cr"])

    from tui.common.glow_dot import DOT_COLORS

    class Host(App):
        def get_css_variables(self):
            return {**super().get_css_variables(), **{f"dot-{k.value}": c for k, c in DOT_COLORS.items()}}

        def compose(self):
            return []

    app = Host()
    async with app.run_test() as pilot:
        row, cat = InstanceRow("k"), CatalogRow("cpd:db")
        row.fill(inst, "db", [])                                # before mount: no labels yet
        cat.fill(None, [inst])
        await app.screen.mount(row, cat)
        row.fill(inst, "db", ["storage!"])                      # newer data while still composing
        assert await settle(pilot, lambda: str(row.query_one(".c-name").render()) == "db-a"
                            and "storage!" in str(row.query_one(".c-why").render())
                            and str(cat.query_one(".c-name").render()) == "all types")


@pytest.mark.asyncio
async def test_problems_filter_is_off_by_default_and_says_so():
    from tui.instance_manager.ui.app import InstanceManagerApp

    app = InstanceManagerApp(DataHub(FakeProvider(), poll=3600), "t", animate=False)
    async with app.run_test(size=(180, 45)) as pilot:
        assert await settle(pilot, lambda: filled(app, "InstanceRow") and len(app.query("InstanceRow")) == 3)
        assert app.problems_only is False
        assert "· all" in str(app.query_one("#instances").border_title)
        await pilot.press("f")
        assert await settle(pilot, lambda: "problems only" in str(app.query_one("#instances").border_title))
