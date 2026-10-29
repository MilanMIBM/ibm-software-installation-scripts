"""CRList: every shown CR as a widget row (dot, name, kind, state, %, why, time since change)."""

from __future__ import annotations

from datetime import datetime
from typing import ClassVar

from textual.app import ComposeResult
from textual.binding import Binding, BindingType
from textual.containers import Horizontal, VerticalScroll
from textual.widgets import Label

from ..model import State
from .chain_view import RowFocused
from .glow_dot import GlowDot
from .util import reconcile, set_text

SORTS = ("severity", "name", "kind", "progress", "changed")


def ago(ts: datetime | None, now: datetime) -> str:
    if ts is None:
        return ""
    s = int((now - ts).total_seconds())
    if s < 60:          # minute resolution: a ticking seconds column is just repaint churn
        return "<1m"
    if s < 3600:
        return f"{s // 60}m"
    if s < 86400:
        return f"{s // 3600}h"
    return f"{s // 86400}d"


class CRListRow(Horizontal, can_focus=True):
    DEFAULT_CSS = """
    CRListRow { height: 1; }
    CRListRow:odd { background: $surface-lighten-1 20%; }
    CRListRow:focus { background: $boost; }
    CRListRow Label { text-wrap: nowrap; text-overflow: ellipsis; margin-left: 1; }
    CRListRow .c-name { width: 30; }
    CRListRow .c-kind { width: 16; color: $text-muted; }
    CRListRow .c-state { width: 11; }
    CRListRow .c-pct { width: 4; content-align: right middle; }
    CRListRow .c-why { width: 1fr; color: $text-muted; }
    CRListRow .c-age { width: 4; content-align: right middle; color: $text-muted; }
    CRListRow.-failing .c-state { color: $dot-failing; }
    CRListRow.-stuck .c-state { color: $dot-stuck; }
    CRListRow.-scaling .c-state { color: $dot-scaling; }
    CRListRow.-progress .c-state { color: $dot-progress; }
    CRListRow.-healthy .c-state { color: $dot-healthy; }
    CRListRow.-inactive .c-state { color: $dot-inactive; }
    """

    def __init__(self, key: str, pending: tuple | None = None):
        super().__init__()
        self.key = key
        self._pending = pending   # (node, now): filled once the row has its children

    def compose(self) -> ComposeResult:
        yield GlowDot()
        for c in ("c-name", "c-kind", "c-state", "c-pct", "c-why", "c-age"):
            yield Label("", classes=c)

    def on_mount(self) -> None:
        if self._pending is not None:
            n, now = self._pending
            self._pending = None
            self.fill(n, now)

    def on_focus(self) -> None:
        self.post_message(RowFocused(self.key))

    def fill(self, n, now: datetime) -> None:
        """Show node n; every cell is only touched when its content changes."""
        v = n.verdict
        for s in State:
            self.set_class(s == v.state, f"-{s.value}")
        self.query_one(GlowDot).set_state(v.state, v.badge)
        set_text(self.query_one(".c-name", Label), n.label if not n.placeholder else n.component or n.label)
        set_text(self.query_one(".c-kind", Label), n.ref.kind if not n.placeholder else "-")
        set_text(self.query_one(".c-state", Label), v.state.word)
        pct = n.cr.progress
        quiet = v.state in (State.HEALTHY, State.INACTIVE)
        set_text(self.query_one(".c-pct", Label), "" if pct is None or (quiet and pct == 100) else f"{pct}")
        why = v.reason if v.state != State.HEALTHY or not v.notices else v.notices[0]
        if v.notices and v.state != State.HEALTHY:
            why = f"{why}  [{v.notices[0]}]"
        set_text(self.query_one(".c-why", Label), why)
        # healthy / inactive: time since the CR's own last transition; otherwise since the last change seen
        set_text(self.query_one(".c-age", Label), ago(v.since if quiet else (n.last_change or v.since), now))


class CRList(VerticalScroll, can_focus=False):
    BINDINGS: ClassVar[list[BindingType]] = [
        Binding("up,k", "move(-1)", "up", show=False),
        Binding("down,j", "move(1)", "down", show=False),
    ]
    DEFAULT_CSS = """
    CRList { border: round $panel-lighten-2; border-title-color: $text-muted; }
    CRList:focus-within { border: round $primary; }
    #list-head { height: 1; color: $text-muted; text-style: bold; }
    #list-head Label { margin-left: 1; }
    #list-head .h-dot { width: 3; margin-left: 0; }
    #list-head .c-name { width: 30; } #list-head .c-kind { width: 16; } #list-head .c-state { width: 11; }
    #list-head .c-pct { width: 4; } #list-head .c-why { width: 1fr; } #list-head .c-age { width: 4; }
    """

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self._rows: list[CRListRow] = []
        self.border_title = "all CRs"

    def compose(self) -> ComposeResult:
        with Horizontal(id="list-head"):
            yield Label("", classes="h-dot")
            for c, t in (("c-name", "NAME"), ("c-kind", "KIND"), ("c-state", "STATE"), ("c-pct", "%"),
                         ("c-why", "WHY"), ("c-age", "Δ")):
                yield Label(t, classes=c)

    def show(self, keys: list[str], nodes: dict, now: datetime) -> None:
        # rows are reused and moved when the sort order changes, never rebuilt
        self._rows, fresh = reconcile(self, self._rows, keys, lambda r: r.key,
                                      lambda k: CRListRow(k, pending=(nodes[k], now)),
                                      first_anchor=self.query_one("#list-head"))
        for r in self._rows:
            if r not in fresh and r.is_mounted and r.key in nodes:
                r.fill(nodes[r.key], now)

    def action_move(self, delta: int) -> None:
        if not self._rows:
            return
        f = self.app.focused
        i = self._rows.index(f) if isinstance(f, CRListRow) and f in self._rows else None
        j = 0 if i is None else max(0, min(len(self._rows) - 1, i + delta))
        self._rows[j].focus()
        self._rows[j].scroll_visible()


def sort_keys(keys: list[str], nodes: dict, mode: str, now: datetime) -> list[str]:
    def k(key):
        n = nodes[key]
        sev = n.verdict.state.severity
        if mode == "name":
            return (n.label.lower(),)
        if mode == "kind":
            return (n.ref.kind.lower(), n.label.lower())
        if mode == "progress":
            return (n.cr.progress if n.cr.progress is not None else 101, sev, n.label.lower())
        if mode == "changed":
            ts = n.last_change
            return (-(ts.timestamp()) if ts else 0, n.label.lower())
        return (sev, n.placeholder, n.label.lower())
    return sorted(keys, key=k)
