"""SubServiceScreen (sub-plan §3.3): the sub-services of one instance, e.g. watsonx.data engines.

Breadcrumb `Instances › <instance> (<type>) › <sub-services>`; Esc / backspace (or a click on
"Instances") goes back with the main screen's selection kept. Same rows, forms, plan screen
and event log as the main screen; all loading and planning run on the hub's loader thread.
"""

from __future__ import annotations

from typing import ClassVar

from rich.text import Text
from textual.app import ComposeResult
from textual.binding import Binding, BindingType
from textual.containers import Horizontal, VerticalScroll
from textual.events import Click
from textual.screen import Screen
from textual.widgets import Footer, Label, Static

from ...common.ui_util import reconcile, set_attr, set_text
from ..hub import instance_key
from ..model import FormModel, Instance
from .rows import CatalogRow, InstanceRow, InstanceSelected, TypeSelected


class SubServiceScreen(Screen):
    DEFAULT_CSS = """
    SubServiceScreen #crumb { height: 1; padding: 0 1; background: $panel; }
    SubServiceScreen #sub-main { height: 1fr; }
    SubServiceScreen #sub-kinds { width: 26; border: round $panel-lighten-2; border-title-color: $text-muted; }
    SubServiceScreen #sub-list { width: 1fr; border: round $panel-lighten-2; border-title-color: $text-muted; }
    SubServiceScreen #sub-detail { width: 46%; border: round $panel-lighten-2; padding: 0 1; }
    """
    BINDINGS: ClassVar[list[BindingType]] = [
        Binding("escape", "back", "back"), Binding("backspace", "back", "back", show=False),
        Binding("n", "create", "new"), Binding("e", "edit", "edit capacity"), Binding("d", "delete", "delete"),
        Binding("R", "reload", "reload"),
    ]

    def __init__(self, sp, parent_type, parent: Instance):
        super().__init__()
        self.sp, self.parent_type, self.parent_inst = sp, parent_type, parent
        self.kinds: list[tuple[str, int | None]] = []
        self.items: dict[str, list[Instance]] = {}
        self.models: dict[str, FormModel] = {}
        self.kind_sel: str | None = None
        self.sel: str | None = None
        self._kind_rows: list[CatalogRow] = []
        self._rows: list[InstanceRow] = []

    def compose(self) -> ComposeResult:
        crumb = Text()
        crumb.append("Instances", style="underline")
        crumb.append(f" › {self.parent_inst.display_name or self.parent_inst.name} ({self.parent_type.display}) › ")
        crumb.append(self.sp.display_name, style="bold")
        yield Label(crumb, id="crumb")
        with Horizontal(id="sub-main"):
            yield VerticalScroll(id="sub-kinds")
            yield VerticalScroll(id="sub-list")
            yield Static("loading...", id="sub-detail")
        yield Footer()

    def on_mount(self) -> None:
        self.query_one("#sub-kinds").border_title = "types"
        self.query_one("#sub-list").border_title = "loading..."
        self.action_reload()

    # -- data (loader thread) -----------------------------------------------------
    def action_reload(self) -> None:
        def task() -> None:
            self.sp.bind(self.parent_inst)
            kinds = self.sp.kinds()
            items = {k: self.sp.list_instances(self.sp.itype(k)) for k, _ in kinds}
            self.app.call_from_thread(self._loaded, kinds, items)
        self.app.hub.run_task(f"sub-load-{self.parent_inst.name}", task)

    def update_items(self, kind: str, insts: list[Instance]) -> None:
        """From a running plan's watch loop (any thread)."""
        self.app.call_from_thread(self._loaded, self.kinds, {**self.items, kind: insts})

    def _loaded(self, kinds, items) -> None:
        self.kinds, self.items = kinds, items
        if self.kind_sel is None and kinds:
            self.kind_sel = next((k for k, _ in kinds if self.sp.itype(k).creatable), kinds[0][0])
        self._redraw()

    def _redraw(self) -> None:
        box = self.query_one("#sub-kinds", VerticalScroll)
        self._kind_rows, fresh = reconcile(box, self._kind_rows, [k for k, _ in self.kinds], lambda w: w.key,
                                           CatalogRow)
        for row in self._kind_rows:
            it = self.sp.itype(row.key)
            it.display = row.key
            row.set_class(row.key == self.kind_sel, "-selected")
            args = (it, self.items.get(row.key, []))
            self.call_after_refresh(row.fill, *args) if row in fresh else row.fill(*args)
        insts = self.items.get(self.kind_sel or "", [])
        lst = self.query_one("#sub-list", VerticalScroll)
        set_attr(lst, "border_title", f"{self.kind_sel or ''} · {len(insts)}"
                 + ("" if self.kind_sel and self.sp.itype(self.kind_sel).creatable else " · list only"))
        by = {instance_key(i): i for i in insts}
        self._rows, fresh = reconcile(lst, self._rows, list(by), lambda w: w.key, InstanceRow)
        for row in self._rows:
            args = (by[row.key], self.kind_sel or "", [])
            row.set_class(row.key == self.sel, "-selected")
            self.call_after_refresh(row.fill, *args) if row in fresh else row.fill(*args)
        inst = by.get(self.sel or "")
        t = Text()
        if inst is None:
            t.append("select an engine; n creates one from a starter template" if self.kind_sel else "")
        else:
            t.append(f"{inst.display_name or inst.name}\n", style="bold")
            t.append(f"{inst.reason}\n{' '.join(inst.badges)}\n\n", style="dim")
            eng = inst.meta.get("engine") or {}
            for k in ("id", "status", "origin", "type"):
                if eng.get(k) is not None:
                    t.append(f"  {k:<10}{eng[k]}\n")
            for k, v in sorted((inst.spec or {}).items()):
                if k.startswith(("presto_worker", "presto_coordinator", "scaleConfig", "type", "engineDisplayName")):
                    t.append(f"  {k}: ", style="dim")
                    t.append(f"{v}\n")
        set_text(self.query_one("#sub-detail", Static), t)

    def on_type_selected(self, msg: TypeSelected) -> None:
        msg.stop()
        if msg.key != self.kind_sel:
            self.kind_sel, self.sel = msg.key, None
            self._redraw()

    def on_instance_selected(self, msg: InstanceSelected) -> None:
        msg.stop()
        self.sel = msg.key
        self._redraw()

    def on_click(self, event: Click) -> None:
        if getattr(event.widget, "id", None) == "crumb" and event.x < len("Instances"):
            self.action_back()

    def action_back(self) -> None:
        self.app.pop_screen()

    # -- changes ----------------------------------------------------------------------
    def _selected(self) -> Instance | None:
        return next((i for i in self.items.get(self.kind_sel or "", []) if instance_key(i) == self.sel), None)

    def _plan(self, name: str, build) -> None:
        def task() -> None:
            plan = build()
            self.app.call_from_thread(self.app._show_plan, plan)
        self.app.hub.run_task(name, task)

    def action_create(self) -> None:
        if not self.app._can_change() or not self.kind_sel:
            return
        it = self.sp.itype(self.kind_sel)
        if not it.creatable:
            self.notify(f"{self.kind_sel} engines are list-only here", severity="warning")
            return

        def task() -> None:
            fm = self.sp.form_model(it)
            from .forms import CreateScreen
            self.app.call_from_thread(self.app.push_screen, CreateScreen(it, fm, {}, owner=self))
        self.app.hub.run_task("sub-form", task)

    offers_vault = False        # engines have no credentials of their own

    def plan_create(self, itype, fm, values, name, description, version, vault=None) -> None:
        kind = itype.key.split(":", 1)[1]
        self._plan("sub-plan-create", lambda: self.sp.plan_create(
            itype, fm, values, name, on_update=lambda insts: self.update_items(kind, insts)))

    def action_edit(self) -> None:
        inst = self._selected()
        if not self.app._can_change() or inst is None:
            return
        it = self.sp.itype(self.kind_sel)

        def task() -> None:
            view, edit = self.sp.edit_model(it, inst, self.sp.form_model(it))
            from .forms import EditScreen
            self.app.call_from_thread(self.app.push_screen, EditScreen(it, view, edit, {}, owner=self))
        self.app.hub.run_task("sub-edit-form", task)

    def plan_edit(self, itype, inst, fm, changes) -> None:
        kind = itype.key.split(":", 1)[1]
        original = self._selected() or inst
        self._plan("sub-plan-edit", lambda: self.sp.plan_edit(
            itype, original, fm, changes, on_update=lambda insts: self.update_items(kind, insts)))

    def action_delete(self) -> None:
        inst = self._selected()
        if not self.app._can_change() or inst is None:
            return
        it = self.sp.itype(self.kind_sel)
        kind = self.kind_sel
        self._plan("sub-plan-delete", lambda: self.sp.plan_delete(
            it, inst, on_update=lambda insts: self.update_items(kind, insts)))
