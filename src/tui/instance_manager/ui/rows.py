"""Catalog rows (instance types) and instance rows: focusable custom widget rows.

Rows are reconciled in place (tui.common.ui_util.reconcile) and every cell is only touched
when its content changes, so a 30 s poll never redraws the list.
"""

from __future__ import annotations

from textual.app import ComposeResult
from textual.containers import Horizontal
from textual.message import Message
from textual.widgets import Label

from ...common.glow_dot import GlowDot
from ...common.state import State
from ...common.ui_util import set_text
from ..model import Instance, InstanceType

ALL = "__all__"


class _Deferred:
    """Rows are filled on the next refresh after reconcile() mounts them, and a later redraw can
    call fill() again before Textual has composed the row's labels. A fill that can't paint yet
    keeps the newest arguments and retries after the next refresh until the labels exist, so a
    row never stays blank and never paints older data."""
    _pending: tuple | None = None
    _retry_scheduled: bool = False

    def _labels_ready(self) -> bool:
        return self.is_mounted and bool(self.query(".c-name"))

    def _ready(self, *args) -> bool:
        if self._labels_ready():
            self._pending = None
            return True
        self._pending = args
        self._schedule()
        return False

    def _schedule(self) -> None:
        if not self._retry_scheduled and self.is_attached:
            self._retry_scheduled = True
            self.call_after_refresh(self._flush)

    def _flush(self) -> None:
        self._retry_scheduled = False
        if self._pending is None:
            return
        if self._labels_ready():
            args, self._pending = self._pending, None
            self.fill(*args)
        else:
            self._schedule()

    def on_mount(self) -> None:
        self._schedule()


class TypeSelected(Message):
    def __init__(self, key: str):
        super().__init__()
        self.key = key


class InstanceSelected(Message):
    def __init__(self, key: str):
        super().__init__()
        self.key = key


class CatalogRow(_Deferred, Horizontal, can_focus=True):
    DEFAULT_CSS = """
    CatalogRow { height: 1; }
    CatalogRow:focus { background: $boost; }
    CatalogRow.-selected { background: $accent 25%; }
    CatalogRow.-unmanaged .c-name { color: $text-muted; }
    CatalogRow Label { text-wrap: nowrap; text-overflow: ellipsis; }
    CatalogRow .c-name { width: 1fr; margin-left: 1; }
    CatalogRow .c-count { width: 9; content-align: right middle; color: $text-muted; }
    """

    def __init__(self, key: str):
        super().__init__()
        self.key = key

    def compose(self) -> ComposeResult:
        yield GlowDot(State.INACTIVE, "ring", size="mini")
        yield Label("", classes="c-name")
        yield Label("", classes="c-count")

    def fill(self, itype: InstanceType | None, instances: list[Instance]) -> None:
        if not self._ready(itype, instances):
            return
        worst = min((i.state for i in instances), key=lambda s: s.severity, default=State.INACTIVE)
        self.query_one(GlowDot).set_state(worst, "filled" if instances else "ring")
        name = itype.display if itype else "all types"
        set_text(self.query_one(".c-name", Label), name)
        cap = f"/{itype.max_instances}" if itype and itype.max_instances else ""
        set_text(self.query_one(".c-count", Label), f"{len(instances)}{cap}")
        self.set_class(bool(itype) and not itype.creatable, "-unmanaged")

    def on_focus(self) -> None:
        self.post_message(TypeSelected(self.key))

    def on_click(self) -> None:
        self.focus()


class InstanceRow(_Deferred, Horizontal, can_focus=True):
    DEFAULT_CSS = """
    InstanceRow { height: 1; }
    InstanceRow:odd { background: $surface-lighten-1 20%; }
    InstanceRow:focus { background: $boost; }
    InstanceRow.-selected { background: $accent 25%; }
    InstanceRow Label { text-wrap: nowrap; text-overflow: ellipsis; margin-left: 1; }
    InstanceRow .c-name { width: 26; }
    InstanceRow .c-type { width: 13; color: $text-muted; }
    InstanceRow .c-badge { width: 10; color: $warning; }
    InstanceRow .c-why { width: 1fr; color: $text-muted; }
    InstanceRow.-failing .c-name { color: $dot-failing; }
    InstanceRow.-stuck .c-name { color: $dot-stuck; }
    """

    def __init__(self, key: str):
        super().__init__()
        self.key = key

    def compose(self) -> ComposeResult:
        yield GlowDot()
        for c in ("c-name", "c-type", "c-badge", "c-why"):
            yield Label("", classes=c)

    def fill(self, inst: Instance, type_display: str, notes: list[str]) -> None:
        if not self._ready(inst, type_display, notes):
            return
        for s in State:
            self.set_class(s == inst.state, f"-{s.value}")
        self.query_one(GlowDot).set_state(inst.state)
        name = inst.name if not inst.display_name or inst.display_name == inst.name \
            else f"{inst.display_name} ({inst.name})"
        set_text(self.query_one(".c-name", Label), name)
        set_text(self.query_one(".c-type", Label), type_display)
        set_text(self.query_one(".c-badge", Label), " ".join(inst.badges))
        set_text(self.query_one(".c-why", Label), "  ".join([*notes, inst.reason]))

    def on_focus(self) -> None:
        self.post_message(InstanceSelected(self.key))

    def on_click(self) -> None:
        self.focus()
