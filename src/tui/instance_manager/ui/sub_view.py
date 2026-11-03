"""Sub-services of one instance (e.g. watsonx.data engines and services), for the inline UI.

SubServices is not a widget: it holds the bound provider, its kinds and their items for one
parent instance, and the app paints them into
  the sub-service dropdown   (#sub-select, next to the service dropdown: the kinds)
  the sub-item list          (#sub-panel, right of the instance list: the chosen kind's items + New)
  the item detail            (#sub-detail in the big panel: the item, Resize / Delete)
The owner protocol (preview / plan_create / plan_edit / plan_delete) lets the shared FormView
and PlanPanel work on sub-services exactly as on main types. Loading and planning run on the
hub's interactive lane; the warm path reads the cached spec and operator facts.
"""

from __future__ import annotations

from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor

from rich.text import Text
from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.message import Message
from textual.widgets import Button, Static

from ..hub import instance_key
from ..model import Instance, InstanceType
from .rows import InstanceRow


def engine_text(inst: Instance | None, kind_sel: str | None) -> Text:
    t = Text()
    if inst is None:
        t.append("select an item in the list; + New creates one from a starter template" if kind_sel
                 else "loading...", style="dim")
        return t
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
    return t


class SubItemSelected(Message):
    def __init__(self, key: str):
        super().__init__()
        self.key = key


class SubItemRow(InstanceRow):
    """An item of the chosen sub-service kind (same look as an instance row, its own message)."""

    def on_focus(self, event) -> None:
        event.prevent_default()             # Textual would also run InstanceRow.on_focus (InstanceSelected)
        self.post_message(SubItemSelected(self.key))


class SubDetail(Vertical):
    """Big-panel view of one sub-service item: its fields, Resize and Delete."""

    DEFAULT_CSS = """
    SubDetail { height: 1fr; }
    SubDetail #sd-actions { height: 3; padding: 0 1; }
    SubDetail #sd-actions Button { margin-right: 1; }
    SubDetail #sd-body { height: 1fr; padding: 0 1; }
    """

    def compose(self) -> ComposeResult:
        with Horizontal(id="sd-actions"):
            yield Button("Resize (e)", id="act-sub-edit", compact=True)
            yield Button("Delete (d)", id="act-sub-delete", variant="error", compact=True)
        with VerticalScroll(id="sd-body"):
            yield Static("", id="sd-text")


class SubServices:
    offers_vault = False        # engines have no credentials of their own

    def __init__(self, app, sp, parent_type: InstanceType, parent: Instance,
                 on_change: Callable[[], None] | None = None):
        self.app, self.sp, self.parent_type, self.parent_inst = app, sp, parent_type, parent
        self.on_change = on_change or (lambda: None)
        self.parent_key = instance_key(parent)
        self.kinds: list[tuple[str, int | None]] = []
        self.items: dict[str, list[Instance]] = {}
        self.kind_sel: str | None = None
        self.sel: str | None = None
        self.loaded = False
        self.error: str | None = None
        self.v = 0                  # bumps on every change: the app repaints what shows it

    @property
    def display_name(self) -> str:
        return self.sp.display_name

    @property
    def crumb(self) -> str:
        return f"{self.parent_type.display} › {self.parent_inst.display_name or self.parent_inst.name} › " \
               f"{self.sp.display_name}"

    def itype(self, kind: str | None = None) -> InstanceType | None:
        kind = kind or self.kind_sel
        return self.sp.itype(kind) if kind else None

    # -- data (interactive lane) ------------------------------------------------------------------
    def reload(self) -> None:
        def task() -> None:
            try:
                self.sp.bind(self.parent_inst)
                kinds = self.sp.kinds()
                with ThreadPoolExecutor(max_workers=max(1, min(8, len(kinds)))) as pool:
                    lists = list(pool.map(lambda k: self.sp.list_instances(self.sp.itype(k)), [k for k, _ in kinds]))
                items = {k: v for (k, _), v in zip(kinds, lists, strict=True)}
            except Exception as e:                       # shown in the dropdown, never a crash
                self.app.call_from_thread(self._failed, str(e))
                return
            self.app.call_from_thread(self._loaded, kinds, items)
        self.app.hub.run_task(f"sub-load-{self.parent_inst.name}", task)

    def update_items(self, kind: str, insts: list[Instance]) -> None:
        """From a running plan's watch loop (any thread)."""
        self.app.call_from_thread(self._loaded, self.kinds, {**self.items, kind: insts})

    def _failed(self, err: str) -> None:
        self.error, self.loaded = err, True
        self.v += 1
        self.on_change()

    def _loaded(self, kinds, items) -> None:
        self.kinds, self.items, self.loaded, self.error = kinds, items, True, None
        if self.kind_sel is None and kinds:
            self.kind_sel = next((k for k, _ in kinds if self.sp.itype(k).creatable), kinds[0][0])
        if self.sel and not self.selected():
            self.sel = None
        self.v += 1
        self.on_change()

    def count(self, kind: str) -> int:
        got = self.items.get(kind)
        if got is not None:
            return len(got)
        return next((n or 0 for k, n in self.kinds if k == kind), 0)

    def current_items(self) -> list[Instance]:
        return self.items.get(self.kind_sel or "", [])

    def selected(self) -> Instance | None:
        return next((i for i in self.current_items() if instance_key(i) == self.sel), None)

    def choose_kind(self, kind: str | None) -> bool:
        if kind == self.kind_sel:
            return False
        self.kind_sel, self.sel = kind, None
        self.v += 1
        return True

    # -- the owner protocol the app's forms and plans use ---------------------------------------------
    def preview(self, form) -> dict | None:
        """The create request and the resize patch, as the plan will send them (no cluster call)."""
        bodies = getattr(self.sp, "create_bodies", None)
        if form.spec.mode != "create" or bodies is None:
            return None
        try:
            body, custom, chosen, _ = bodies(form.spec.fm, form.values(), form.name)
        except (TypeError, ValueError):
            return None
        out = {"request": body}
        if custom:
            out[f"then patch the WxdEngine CR (changed from {chosen})"] = custom
        return out

    def plan_create(self, itype, fm, values, name, description, version, vault=None):
        kind = itype.key.split(":", 1)[1]
        return lambda: self.sp.plan_create(itype, fm, values, name,
                                           on_update=lambda insts: self.update_items(kind, insts))

    def plan_edit(self, itype, inst, fm, changes):
        kind = itype.key.split(":", 1)[1]
        original = self.selected() or inst
        return lambda: self.sp.plan_edit(itype, original, fm, changes,
                                         on_update=lambda insts: self.update_items(kind, insts))

    def plan_delete(self):
        inst = self.selected()
        if inst is None or not self.kind_sel:
            return None
        it, kind = self.sp.itype(self.kind_sel), self.kind_sel
        return lambda: self.sp.plan_delete(it, inst, on_update=lambda insts: self.update_items(kind, insts))
